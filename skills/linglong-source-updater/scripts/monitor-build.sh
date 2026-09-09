#!/usr/bin/env bash
# monitor-build.sh
# 玲珑构建监控包装器 —— 后台启动 + 周期轮询，规避 idle watchdog。
#
# 背景：在前台直接执行 ll-builder build/export 会长时间无输出，触发
# 平台 idle watchdog（agent 无新消息达阈值）强制停止。本脚本把构建放到
# 后台运行，通过状态文件让 LLM 每 ~5 分钟轮询一次；每次轮询是一个独立的
# bash 调用、产生新的 agent 消息，从而重置 watchdog。
#
# 三种模式：
#   start  <state_file> [--timeout SEC] [--log FILE] [--heartbeat SEC] -- <cmd...>
#       状态写入 <state_file>；构建结束由子 shell 把 `EXIT=<code>` 追加到状态文件。
#   status <state_file>
#       <1s 返回：仅打印状态、elapsed、PID、EXIT 和日志路径；运行中 exit 1，已结束 exit 0。
#   wait   <state_file> [--timeout SEC]
#       阻塞直到构建结束，返回构建退出码；只输出状态字段和日志路径，不输出构建正文。
#
# 日志正文始终写入 `--log` 指定文件。调用方必须只在异常诊断或用户明确要求时读取该文件的有界尾部/关键区域。

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<EOF
monitor-build.sh v$VERSION

后台启动构建并周期性查询状态，避免前台长命令触发 idle watchdog。

用法:
  $(basename "$0") start <state_file> [--timeout SEC] [--log FILE] [--heartbeat SEC] -- <cmd...>
  $(basename "$0") status <state_file>
  $(basename "$0") wait <state_file> [--timeout SEC]

start:
  后台启动 <cmd>（带 timeout），日志写入 --log，立即返回。状态文件记录
  PID / 启动时刻 / 超时 / 日志路径；子 shell 在构建结束时追加 EXIT=<code>。

status:
  运行中 → 打印 running (elapsed,PID)，exit 1；
  已结束 → 打印 finished EXIT=<code>，exit 0（构建码从输出读取）。

wait:
  阻塞直到构建结束，返回构建退出码。

选项:
  --timeout SEC    构建超时秒数（默认 1800，仅 start/wait）
  --log FILE       构建日志文件（默认 build.log）
  --heartbeat SEC  预留心跳间隔（保留参数，默认 300）
  -h, --help       显示帮助
EOF
  exit 0
}

DEFAULT_TIMEOUT=1800

# --- start ---
cmd_start() {
  local state="$1"; shift
  local timeout="$DEFAULT_TIMEOUT"
  local log="build.log"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --log) log="$2"; shift 2 ;;
      --heartbeat) shift 2 ;;  # 保留参数
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    echo "错误: start 需要 -- <cmd...>" >&2
    exit 2
  fi

  local state_dir
  state_dir="$(dirname "$state")"
  mkdir -p "$state_dir"
  rm -f "$state"

  local start_epoch
  start_epoch=$(date +%s)

  (
    # set -e 会在 timeout 返回非零时立即中止子 shell，故此处显式关闭
    set +e
    timeout "$timeout" "$@" >"$log" 2>&1
    local rc=$?
    set -e
    printf '\nEXIT=%s\n' "$rc" >> "$state"
    exit "$rc"
  ) &

  local pid=$!
  disown "$pid" 2>/dev/null || true

  {
    echo "PID=$pid"
    echo "START=$start_epoch"
    echo "TIMEOUT=$timeout"
    echo "LOG=$log"
  } > "$state"

  echo "status=started pid=$pid timeout=${timeout}s log_path=$log state_file=$state"
}

# --- status ---
cmd_status() {
  local state="$1"
  if [[ ! -f "$state" ]]; then
    echo "status=missing state_file=$state"
    exit 3
  fi
  local pid start_epoch timeout log_path
  pid=$(awk -F= '/^PID=/{print $2}' "$state" | head -1)
  start_epoch=$(awk -F= '/^START=/{print $2}' "$state" | head -1)
  timeout=$(awk -F= '/^TIMEOUT=/{print $2}' "$state" | head -1)
  log_path=$(awk -F= '/^LOG=/{print $2}' "$state" | head -1)
  timeout="${timeout:-$DEFAULT_TIMEOUT}"
  local elapsed=$(( $(date +%s) - start_epoch ))
  if grep -q '^EXIT=' "$state"; then
    local exit_code
    exit_code=$(grep '^EXIT=' "$state" | tail -1 | cut -d= -f2)
    echo "status=finished exit_code=$exit_code elapsed=${elapsed}s pid=$pid log_path=$log_path"
    exit 0
  fi
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "status=running elapsed=${elapsed}s timeout=${timeout}s pid=$pid log_path=$log_path"
    if (( elapsed >= timeout )); then
      echo "status=timeout timeout=${timeout}s pid=$pid log_path=$log_path"
      kill "$pid" 2>/dev/null || true
    fi
    exit 1
  fi
  echo "status=stale_state pid=$pid state_file=$state"
  exit 1
}

# --- wait ---
cmd_wait() {
  local state="$1"; shift
  local timeout="$DEFAULT_TIMEOUT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local waited=0
  local interval=5
  while (( waited < timeout )); do
    if [[ ! -f "$state" ]]; then
      echo "status=missing state_file=$state" >&2
      return 3
    fi
    if grep -q '^EXIT=' "$state"; then
      local exit_code log_path
      exit_code=$(grep '^EXIT=' "$state" | tail -1 | cut -d= -f2)
      log_path=$(awk -F= '/^LOG=/{print $2}' "$state" | head -1)
      echo "status=finished exit_code=$exit_code log_path=$log_path"
      return "$exit_code"
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done

  echo "monitor-build: wait 超时（${timeout}s），构建仍在运行" >&2
  return 124
}

MODE="${1:-}"
if [[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  usage
fi
shift

case "$MODE" in
  start) cmd_start "$@" ;;
  status) cmd_status "$@" ;;
  wait) cmd_wait "$@" ;;
  *) echo "未知模式: $MODE" >&2; usage ;;
esac
