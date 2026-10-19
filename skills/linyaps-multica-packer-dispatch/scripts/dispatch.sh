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
AGENT_NAME_OVERRIDE=""
SUCCESS_COUNT=0
FAIL_COUNT=0
PENDING_COUNT=0
SRC_PENDING_COUNT=0
FIX_LOG_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--workspace=*) WORKSPACE="${1#*=}" ;;
	--output=*) OUTPUT_FILE="${1#*=}" ;;
	--pkgName=*) PKG_NAME="${1#*=}" ;;
	--src_url=*) SRC_URL="${1#*=}" ;;
	--arch=*) ARCH="${1#*=}" ;;
	--type=*) TYPE="${1#*=}" ;;
	--data-dir=*) DATA_DIR="${1#*=}" ;;
	--config=*) CONFIG_FILE="${1#*=}" ;;
	--agent-config-path=*) CONFIG_FILE="${1#*=}" ;;
	--agent-name=*) AGENT_NAME_OVERRIDE="${1#*=}" ;;
	--success=*) SUCCESS_COUNT="${1#*=}" ;;
	--fail=*) FAIL_COUNT="${1#*=}" ;;
	--pending=*) PENDING_COUNT="${1#*=}" ;;
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
		echo "$json" >"$OUTPUT_FILE"
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

	# 按精确 type 过滤候选 agent，emit: cfg_id<TAB>cfg_uuid<TAB>cfg_name
	agent_candidates() {
		python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
agents = cfg.get('assignment', {}).get('agents', [])
target_type = sys.argv[2]
for a in agents:
    if a.get('type') == target_type:
        print('\t'.join([a.get('id',''), a.get('uuid',''), a.get('name','')]))
" "$CONFIG_FILE" "$TYPE"
	}

	ID_FALLBACK=0
	SELECTION_REASON=""
	TARGET_AGENT_ID=""
	TARGET_AGENT_UUID=""
	TARGET_AGENT_NAME=""

	if [[ -n "$AGENT_NAME_OVERRIDE" ]]; then
		# --agent-name 覆盖路径：保留 LLM 运行时显式指派能力
		if ! TARGET_AGENT_UUID=$(get_agent_uuid_by_name "$AGENT_NAME_OVERRIDE"); then
			log_warn "无法解析 agent uuid（${AGENT_NAME_OVERRIDE}），跳过指派"
			output_json "{\"assigned\":false,\"target_agent\":\"${AGENT_NAME_OVERRIDE}\",\"reason\":\"agent_uuid_missing\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
			exit 0
		fi
		TARGET_AGENT_NAME="$AGENT_NAME_OVERRIDE"
		SELECTION_REASON="agent_name_override"
	else
		# 脚本端候选池选择：type 精确过滤 + idle 优先 + 负载感知决胜
		mapfile -t CANDIDATES < <(agent_candidates)
		valid_list=()
		invalid_uuid_list=()
		for line in "${CANDIDATES[@]}"; do
			cfg_id=$(echo "$line" | cut -f1)
			cfg_uuid=$(echo "$line" | cut -f2)
			cfg_name=$(echo "$line" | cut -f3)
			if is_uuid "$cfg_uuid"; then
				valid_list+=("${cfg_id}"$'\t'"${cfg_uuid}"$'\t'"${cfg_name}")
			else
				invalid_uuid_list+=("${cfg_id}"$'\t'"${cfg_name}")
			fi
		done

		if [[ ${#valid_list[@]} -gt 0 ]]; then
			# 查询所有 valid 候选状态
			idle_list=()
			busy_list=()
			for entry in "${valid_list[@]}"; do
				cfg_id=$(echo "$entry" | cut -f1)
				cfg_uuid=$(echo "$entry" | cut -f2)
				cfg_name=$(echo "$entry" | cut -f3)
				WS_ARG=""
				[[ -n "$WORKSPACE" ]] && WS_ARG="-w $WORKSPACE"
				STATUS_RESULT=$(bash "$SCRIPT_DIR/check-agent-status.sh" \
					$WS_ARG -u "$cfg_uuid" -o json 2>/dev/null || true)
				AGENT_STATUS="unknown"
				RUNNING_COUNT=0
				if [[ -n "$STATUS_RESULT" ]]; then
					AGENT_STATUS=$(echo "$STATUS_RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('agent', {}).get('status', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null) || AGENT_STATUS="unknown"
					RUNNING_COUNT=$(echo "$STATUS_RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data.get('running_tasks', [])))
except Exception:
    print(0)
" 2>/dev/null) || RUNNING_COUNT=0
				fi
				if [[ "$AGENT_STATUS" == "idle" ]]; then
					idle_list+=("${cfg_id}"$'\t'"${cfg_uuid}"$'\t'"${cfg_name}"$'\t'"${RUNNING_COUNT}")
				else
					busy_list+=("${cfg_id}"$'\t'"${cfg_uuid}"$'\t'"${cfg_name}"$'\t'"${RUNNING_COUNT}")
				fi
			done

			# idle 优先；无 idle 则负载感知（running_count 最小者）
			if [[ ${#idle_list[@]} -gt 0 ]]; then
				pick_list=("${idle_list[@]}")
				SELECTION_REASON="idle_first"
			else
				pick_list=("${busy_list[@]}")
				SELECTION_REASON="load_aware"
			fi

			# 同优先级内随机决胜（负载相同时）
			if [[ "$SELECTION_REASON" == "load_aware" ]]; then
				# 找到最小 running_count
				min_count=$(printf '%s\n' "${pick_list[@]}" | cut -f4 | sort -n | head -1)
				mapfile -t min_list < <(printf '%s\n' "${pick_list[@]}" | awk -F'\t' -v mc="$min_count" '$4==mc')
				pick_list=("${min_list[@]}")
			fi
			# 随机抽一个
			pick_idx=$((RANDOM % ${#pick_list[@]}))
			picked="${pick_list[$pick_idx]}"
			TARGET_AGENT_ID=$(echo "$picked" | cut -f1)
			TARGET_AGENT_UUID=$(echo "$picked" | cut -f2)
			TARGET_AGENT_NAME=$(echo "$picked" | cut -f3)
			# 捕获选中 agent 的状态（避免后续重复查询）
			PICKED_AGENT_STATUS="unknown"
			if [[ "$SELECTION_REASON" == "idle_first" ]]; then
				PICKED_AGENT_STATUS="idle"
			fi
			ID_FALLBACK=0
		elif [[ ${#invalid_uuid_list[@]} -gt 0 ]]; then
			# id fallback：候选 uuid 无效，退回 cfg_id 作为 --to-id
			pick_idx=$((RANDOM % ${#invalid_uuid_list[@]}))
			picked="${invalid_uuid_list[$pick_idx]}"
			TARGET_AGENT_ID=$(echo "$picked" | cut -f1)
			TARGET_AGENT_NAME=$(echo "$picked" | cut -f2)
			TARGET_AGENT_UUID=""
			ID_FALLBACK=1
			SELECTION_REASON="id_fallback"
			log_warn "候选 agent uuid 无效，退回 id fallback（违反 issue-68 --to-id <uuid> 约束，紧急降级）"
		else
			# 无候选
			output_json "{\"assigned\":false,\"target_agent\":\"\",\"reason\":\"no_candidate\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
			exit 0
		fi
	fi

	# 状态检查
	# - script-side valid_list 路径：选择循环已捕获状态，不重复查询
	# - override 路径：查询一次
	# - id_fallback 路径：uuid 无效，跳过（仅记 unknown）
	AGENT_STATUS="unknown"
	if [[ -n "$AGENT_NAME_OVERRIDE" ]]; then
		if command -v multica &>/dev/null; then
			WS_ARG=""
			[[ -n "$WORKSPACE" ]] && WS_ARG="-w $WORKSPACE"
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
	elif [[ "$ID_FALLBACK" -eq 0 ]]; then
		# valid_list 路径：状态已在选择循环中捕获
		AGENT_STATUS="${PICKED_AGENT_STATUS:-unknown}"
	else
		# id_fallback 路径：uuid 无效，状态不可查
		AGENT_STATUS="unknown"
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
			# id_fallback 路径 uuid 无效，跳过 mention（无法构造 mention://agent/<uuid>）
			if [[ "$ID_FALLBACK" -eq 0 ]]; then
				MENTION="[@${TARGET_AGENT_NAME}](mention://agent/${TARGET_AGENT_UUID})"
				# comment add --output json 的响应不参与本 skill 输出，丢弃 stdout 避免污染
				multica issue comment add "$ISSUE_ID" \
					--content "${MENTION} 請為 ${PKG_NAME} 進行項目初始化適配工作（${ARCH}）。下載地址：${SRC_URL}${TYPE_TAG}" \
					--output json >/dev/null 2>/dev/null || log_warn "multica comment 发送失败"
			else
				log_warn "id_fallback 路径跳过 mention 评论（uuid 无效，无法构造 mention://agent/<uuid>）"
			fi

			# Step 2: 指派 issue 给目标 agent
			# - 正常路径: --to-id <uuid>
			# - id_fallback 路径: --to-id <cfg_id>（违反 issue-68 约束的紧急降级）
			ASSIGN_TARGET_ID="$TARGET_AGENT_UUID"
			if [[ "$ID_FALLBACK" -eq 1 ]]; then
				ASSIGN_TARGET_ID="$TARGET_AGENT_ID"
			fi
			if multica issue assign "$ISSUE_ID" --to-id "$ASSIGN_TARGET_ID" \
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
			echo "assigned_init, ${PKG_NAME}, ${TARGET_AGENT_NAME}, ${ARCH}, $(date +'%Y-%m-%d %H:%M:%S')" >>"${DATA_DIR}/assignment.log"
		else
			echo "assigned_src_init, ${PKG_NAME}, ${TARGET_AGENT_NAME}, ${ARCH}, source, $(date +'%Y-%m-%d %H:%M:%S')" >>"${DATA_DIR}/assignment.log"
		fi
	fi

	ID_FALLBACK_JSON="false"
	[[ "$ID_FALLBACK" -eq 1 ]] && ID_FALLBACK_JSON="true"
	output_json "$(
		cat <<JSON
{"assigned":${ASSIGNED},"target_agent":"${TARGET_AGENT_NAME}","target_agent_uuid":"${TARGET_AGENT_UUID}","reason":"${SELECTION_REASON}","id_fallback":${ID_FALLBACK_JSON},"timestamp":"$(date +'%Y-%m-%d %H:%M:%S')","agent_status":"${AGENT_STATUS}"}
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

	output_json "$(
		cat <<JSON
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

	output_json "$(
		cat <<JSON
{"posted":${POSTED},"pkgName":"${PKG_NAME}","timestamp":"$(date +'%Y-%m-%d %H:%M:%S')"}
JSON
	)"

else
	log_err "未知 action: ${ACTION}"
	log_info "可用 action: detect_init_source, dispatch_project_not_found, update_issue_status, post_fix_log"
	exit 1
fi
