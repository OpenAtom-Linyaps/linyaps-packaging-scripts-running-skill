#!/usr/bin/env bash
# check-build-active.sh
# 玲珑构建进度检测脚本 —— 判断当前是否有玲珑构建相关进程在运行。
# 供 binary / source updater 的 LLM 每 10 分钟调用一次，作为是否判定构建超时/挂起的依据。
#
# 检测的进程：ll-builder、fuse-overlayfs、erofsfuse
# 任一进程存在 → exit 0（构建进行中）；均不存在 → exit 1（构建已结束 / 未运行）。
#
# 用法: $(basename "$0") [选项]
# 选项:
#   -o, --output <format>   输出格式: text / json（默认 text）
#   -h, --help              显示帮助信息

set -euo pipefail

VERSION="1.0.0"
# 需检测的构建相关进程
WATCH_PROCESSES=( "ll-builder" "fuse-overlayfs" "erofsfuse" )

usage() {
  cat <<EOF
check-build-active.sh v$VERSION

检测当前是否有玲珑构建相关进程（ll-builder / fuse-overlayfs / erofsfuse）在运行。
任一进程存在则判定构建进行中（exit 0）；均不存在则判定构建已结束（exit 1）。

选项:
  -o, --output <format>   输出格式: text / json（默认 text）
  -h, --help              显示此帮助信息

示例:
  $(basename "$0")              # text 输出，构建进行中时 exit 0
  $(basename "$0") -o json      # json 输出活跃进程名列表
  if $(basename "$0"); then echo "构建进行中"; else echo "构建未运行"; fi
EOF
  exit 0
}

OUTPUT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      OUTPUT="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "未知选项: $1" >&2
      usage ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "错误: --output 必须是 text 或 json" >&2
  usage
fi

# 收集当前活跃的构建进程名（去重）
# 使用 pgrep -x 精确匹配进程 comm 名，避免 -f 匹配到脚本自身/调用方 shell 的命令行而误报。
active=()
for proc in "${WATCH_PROCESSES[@]}"; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    active+=( "$proc" )
  fi
done

if [[ "${#active[@]}" -gt 0 ]]; then
  if [[ "$OUTPUT" == "json" ]]; then
    printf '{"build_active": true, "processes": %s}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${active[@]}")"
  else
    echo "构建进行中 (active processes: ${active[*]})"
  fi
  exit 0
fi

if [[ "$OUTPUT" == "json" ]]; then
  echo '{"build_active": false, "processes": []}'
else
  echo "构建未运行 (no build process found)"
fi
exit 1
