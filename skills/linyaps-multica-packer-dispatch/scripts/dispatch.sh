#!/usr/bin/env bash
# linyaps-multica-packer-dispatch: dispatch.sh
#
# 统一指派入口脚本，四种 action：
#   detect_init_source       — 检测初始化来源
#   dispatch_project_not_found — 项目未找到时发起指派
#   update_issue_status       — 更新 issue 状态
#   post_fix_log              — 发布修改日志为 issue comment
#
# 使用方式：
#   bash dispatch.sh detect_init_source [--workspace=<slug>] [--output=<path>]
#   bash dispatch.sh dispatch_project_not_found --pkgName=<name> --src_url=<url> --arch=<arch> --type=<binary|source> --agent-name=<CLI真实name> [--workspace=<slug>] [--data-dir=<path>] [--config=<path>]
#   bash dispatch.sh update_issue_status --success=<n> --fail=<n> --pending=<n> --src-pending=<n> [--workspace=<slug>]
#   bash dispatch.sh post_fix_log --pkgName=<name> --fix-log-path=<path> [--workspace=<slug>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_ROOT/../.." && pwd)"

source "$SCRIPT_DIR/common.sh"

ACTION="${1:-}"
shift || true

# ---- 参数解析 ----
WORKSPACE=""
OUTPUT_FILE=""
PKG_NAME=""
SRC_URL=""
ARCH=""
TYPE=""
DATA_DIR=""
CONFIG_FILE="${AGENT_CONFIG_PATH:-${REPO_ROOT}/for-multica/agent-config.json}"
TARGET_AGENT_NAME=""
SUCCESS_COUNT=0
FAIL_COUNT=0
PENDING_COUNT=0
SRC_PENDING_COUNT=0
FIX_LOG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace=*)  WORKSPACE="${1#*=}" ;;
    --output=*)     OUTPUT_FILE="${1#*=}" ;;
    --pkgName=*)    PKG_NAME="${1#*=}" ;;
    --src_url=*)    SRC_URL="${1#*=}" ;;
    --arch=*)       ARCH="${1#*=}" ;;
    --type=*)       TYPE="${1#*=}" ;;
    --data-dir=*)   DATA_DIR="${1#*=}" ;;
    --config=*)     CONFIG_FILE="${1#*=}" ;;
    --agent-config-path=*) CONFIG_FILE="${1#*=}" ;;
    --agent-name=*) TARGET_AGENT_NAME="${1#*=}" ;;
    --success=*)    SUCCESS_COUNT="${1#*=}" ;;
    --fail=*)       FAIL_COUNT="${1#*=}" ;;
    --pending=*)    PENDING_COUNT="${1#*=}" ;;
    --src-pending=*) SRC_PENDING_COUNT="${1#*=}" ;;
    --fix-log-path=*) FIX_LOG_PATH="${1#*=}" ;;
    *)
      log_err "未知参数: $1"
      exit 1
      ;;
  esac
  shift
done

output_json() {
  local json="$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$json" > "$OUTPUT_FILE"
  else
    echo "$json"
  fi
}

require_task_issue() {
  local issue_id
  if ! issue_id=$(get_issue_id); then
    output_json '{"blocked":true,"reason":"issue_id_required"}'
    return 1
  fi
  export MULTICA_ISSUE_TASK_ID="$issue_id"
}

if [[ "$ACTION" == "detect_init_source" || "$ACTION" == "dispatch_project_not_found" || "$ACTION" == "update_issue_status" || "$ACTION" == "post_fix_log" ]]; then
  require_task_issue || exit 2
fi

# ---- detect_init_source ----
if [[ "$ACTION" == "detect_init_source" ]]; then
  exec bash "$SCRIPT_DIR/detect_init_source.sh" \
    ${WORKSPACE:+--workspace="$WORKSPACE"} \
    ${OUTPUT_FILE:+--output="$OUTPUT_FILE"}

# ---- dispatch_project_not_found ----
elif [[ "$ACTION" == "dispatch_project_not_found" ]]; then
  if [[ -z "$PKG_NAME" || -z "$SRC_URL" || -z "$ARCH" || -z "$TYPE" ]]; then
    echo '{"error":"缺少必填参数: --pkgName, --src_url, --arch, --type"}' >&2
    exit 1
  fi
  if [[ "$TYPE" != "binary" && "$TYPE" != "source" ]]; then
    echo '{"error":"type 必须是 binary 或 source"}' >&2
    exit 1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{"error":"agent-config.json 不存在: '"$CONFIG_FILE"'"}' >&2
    exit 1
  fi

# 读取配置，筛选目标 agent
  if [[ "$TYPE" == "binary" ]]; then
    TARGET_CAPABILITY="project_init"
  else
    TARGET_CAPABILITY="src_project_init"
  fi

  # config 仅用于判定目标能力是否存在（决策依据，不充当 CLI agent 身份）
  TARGET_AGENT_ID=$(python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
agents = cfg.get('assignment', {}).get('agents', [])
cap = '$TARGET_CAPABILITY'
for a in agents:
    if cap in a.get('capabilities', []):
        print(a['id'])
        sys.exit(0)
" 2>/dev/null || true)

  if [[ -z "$TARGET_AGENT_ID" ]]; then
    echo '{"error":"未找到 capabilities 包含 '"$TARGET_CAPABILITY"' 的 agent"}' >&2
    # 不阻断，标记为未指派
    output_json "{\"assigned\":false,\"target_agent\":\"\",\"reason\":\"capability_not_found\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
    exit 0
  fi

  # CLI 真实 agent name 必须由 Agent 运行时显式传入（--agent-name），脚本不做 slug→name 映射
  if [[ -z "$TARGET_AGENT_NAME" ]]; then
    echo '{"error":"缺少 --agent-name=<CLI 真实 agent name>（由 Agent 运行时决策并显式传入）"}' >&2
    output_json "{\"assigned\":false,\"target_agent\":\"$TARGET_AGENT_ID\",\"reason\":\"agent_name_required\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
    exit 0
  fi

  # 按 CLI 真实 name 解析精确 UUID
  if ! TARGET_AGENT_UUID=$(get_agent_uuid_by_name "$TARGET_AGENT_NAME"); then
    log_warn "无法解析 agent uuid（${TARGET_AGENT_NAME}），跳过指派"
    output_json "{\"assigned\":false,\"target_agent\":\"${TARGET_AGENT_NAME}\",\"reason\":\"agent_uuid_missing\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
    exit 0
  fi

  # 状态检查（热备方案）
  AGENT_STATUS="unknown"
  if command -v multica &>/dev/null; then
    WS_ARG=""
    if [[ -n "$WORKSPACE" ]]; then
      WS_ARG="-w $WORKSPACE"
    fi
    STATUS_RESULT=$(bash "$SCRIPT_DIR/check-agent-status.sh" \
      $WS_ARG -n "$TARGET_AGENT_NAME" -o json 2>/dev/null || true)
    if [[ -n "$STATUS_RESULT" ]]; then
      AGENT_STATUS=$(echo "$STATUS_RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('agent', {}).get('status', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null) || AGENT_STATUS="unknown"
    fi
    if [[ "$AGENT_STATUS" == "idle" ]]; then
      log_info "目标智能体 ${TARGET_AGENT_NAME}（${TARGET_AGENT_UUID}）空闲，可立即指派"
    elif [[ "$AGENT_STATUS" == "busy" || "$AGENT_STATUS" == "running" ]]; then
      log_warn "目标智能体 ${TARGET_AGENT_NAME} 当前繁忙，仍发起指派（由平台排队处理）"
    else
      log_warn "无法查询目标智能体 ${TARGET_AGENT_NAME} 状态（${AGENT_STATUS}），直接发起指派"
    fi
  else
    log_warn "multica CLI 不可用，跳过状态检查"
  fi

  # 指派执行
  ASSIGNED=false
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    if ! ISSUE_ID=$(get_issue_id); then
      log_warn "无法取得精确 ISSUE_ID（issue_id_not_found / cli_unavailable / invalid_uuid），跳过指派"
    elif [[ -n "$ISSUE_ID" ]]; then
      TYPE_TAG=""
      [[ "$TYPE" == "source" ]] && TYPE_TAG="，類型：source"

      # Step 1: 发送 @mention 评论（UUID 绑定格式，通知 agent）
      MENTION="[@${TARGET_AGENT_NAME}](mention://agent/${TARGET_AGENT_UUID})"
      multica issue comment add "$ISSUE_ID" \
        --content "${MENTION} 請為 ${PKG_NAME} 進行項目初始化適配工作（${ARCH}）。下載地址：${SRC_URL}${TYPE_TAG}" \
        --output json 2>/dev/null || log_warn "multica comment 发送失败"

      # Step 2: 指派 issue 给目标 agent（--to-id <uuid>）
      if multica issue assign "$ISSUE_ID" --to-id "$TARGET_AGENT_UUID" \
        2>/dev/null; then
        ASSIGNED=true
      else
        log_warn "multica assign 失败"
      fi
    else
      log_warn "ISSUE_ID 为空，跳过指派"
    fi
  else
    log_warn "multica CLI 不可用，跳过指派"
  fi

  # 记录指派日志
  if [[ -n "$DATA_DIR" ]]; then
    mkdir -p "$DATA_DIR"
    if [[ "$TYPE" == "binary" ]]; then
      echo "assigned_init, ${PKG_NAME}, ${TARGET_AGENT_NAME}, ${ARCH}, $(date +'%Y-%m-%d %H:%M:%S')" >> "${DATA_DIR}/assignment.log"
    else
      echo "assigned_src_init, ${PKG_NAME}, ${TARGET_AGENT_NAME}, ${ARCH}, source, $(date +'%Y-%m-%d %H:%M:%S')" >> "${DATA_DIR}/assignment.log"
    fi
  fi

  output_json "$(cat <<JSON
{"assigned":${ASSIGNED},"target_agent":"${TARGET_AGENT_NAME}","target_agent_uuid":"${TARGET_AGENT_UUID}","timestamp":"$(date +'%Y-%m-%d %H:%M:%S')","agent_status":"${AGENT_STATUS}"}
JSON
)"

# ---- update_issue_status ----
elif [[ "$ACTION" == "update_issue_status" ]]; then
  # 计算 issue 状态
  if [[ "$FAIL_COUNT" -eq 0 && "$PENDING_COUNT" -eq 0 && "$SRC_PENDING_COUNT" -eq 0 ]]; then
    ISSUE_STATUS="审查完成"
  elif [[ "$SUCCESS_COUNT" -eq 0 && "$FAIL_COUNT" -gt 0 && "$PENDING_COUNT" -eq 0 && "$SRC_PENDING_COUNT" -eq 0 ]]; then
    ISSUE_STATUS="阻塞"
  elif [[ "$PENDING_COUNT" -gt 0 || "$SRC_PENDING_COUNT" -gt 0 ]]; then
    ISSUE_STATUS="进行中"
  else
    ISSUE_STATUS="部分完成"
  fi

  COMMENT_ID=""
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    ISSUE_ID=$(get_issue_id) || ISSUE_ID=""
    if [[ -n "$ISSUE_ID" ]]; then
      COMMENT_ID=$(get_comment_id "$ISSUE_ID" "結果：成功 ${SUCCESS_COUNT} / 失敗 ${FAIL_COUNT} / 待初始化 ${PENDING_COUNT} / 待源码初始化 ${SRC_PENDING_COUNT}") || COMMENT_ID=""
    fi
  fi

  output_json "$(cat <<JSON
{"issue_status":"${ISSUE_STATUS}","comment_id":"${COMMENT_ID:-""}"}
JSON
)"

# ---- post_fix_log ----
elif [[ "$ACTION" == "post_fix_log" ]]; then
  if [[ -z "$PKG_NAME" || -z "$FIX_LOG_PATH" ]]; then
    echo '{"error":"缺少必填参数: --pkgName, --fix-log-path"}' >&2
    exit 1
  fi
  if [[ ! -f "$FIX_LOG_PATH" ]]; then
    log_warn "fix log 文件不存在: ${FIX_LOG_PATH}，跳过"
    output_json '{"posted":false,"pkgName":"'"${PKG_NAME}"'","error":"file_not_found"}'
    exit 0
  fi

  POSTED=false
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    ISSUE_ID=$(get_issue_id) || ISSUE_ID=""
    if [[ -n "$ISSUE_ID" ]]; then
      FIX_CONTENT=$(cat "$FIX_LOG_PATH")
      if get_comment_id "$ISSUE_ID" "$FIX_CONTENT" >/dev/null 2>&1; then
        POSTED=true
        log_ok "修改日志已发布为 issue comment: ${PKG_NAME}"
      else
        log_warn "multica comment 发送失败（${PKG_NAME}）"
      fi
    else
      log_warn "无法取得精确 ISSUE_ID，跳过 post_fix_log"
    fi
  else
    log_warn "multica CLI 不可用，跳过 post_fix_log"
  fi

  output_json "$(cat <<JSON
{"posted":${POSTED},"pkgName":"${PKG_NAME}","timestamp":"$(date +'%Y-%m-%d %H:%M:%S')"}
JSON
)"

else
log_err "未知 action: ${ACTION}"
  log_info "可用 action: detect_init_source, dispatch_project_not_found, update_issue_status, post_fix_log"
  exit 1
fi