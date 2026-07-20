#!/usr/bin/env bash
# linyaps-packaging-precheck: precheck.sh — 统一前置检测编排脚本
#
# 在进入打包流程前统一检查 CLI 工具可用性、网络连通性、
# 配置完整性和脚本完整性。为 workflow 和 agent 提供门控依据。
#
# 用法：
#   bash skills/linyaps-packaging-precheck/scripts/precheck.sh
#   bash skills/linyaps-packaging-precheck/scripts/precheck.sh --config=<path> --workspace=<slug>
#   bash skills/linyaps-packaging-precheck/scripts/precheck.sh --checks=cli_tools,network_s3
#   bash skills/linyaps-packaging-precheck/scripts/precheck.sh --output=<path>
#
# 返回值：0 = 全部通过，1 = 存在失败项

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_ROOT/../.." && pwd)"

source "$SCRIPT_DIR/common.sh"

# ---- 默认值 ----
CONFIG_FILE=""
WORKSPACE=""
OUTPUT_FILE=""
RUN_CHECKS=""  # 空 = 全部

# ---- 预定义检查项全列表 ----
ALL_CHECKS="cli_tools,config_validity,network_s3,network_webhook,network_upstream,script_integrity"

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config=*)           CONFIG_FILE="${1#*=}" ;;
    --agent-config-path=*) CONFIG_FILE="${1#*=}" ;;
    --workspace=*) WORKSPACE="${1#*=}" ;;
    --output=*)   OUTPUT_FILE="${1#*=}" ;;
    --checks=*)   RUN_CHECKS="${1#*=}" ;;
    -h|--help)
      echo "用法: $(basename "$0") [选项]"
      echo "  --config=<path>         agent-config.json 路径（可选，用于 config_validity 检查）"
      echo "  --agent-config-path=<path>  同 --config"
      echo "  --workspace=<slug>      multica workspace slug（可选）"
      echo "  --output=<path>         JSON 结果写入路径（可选，默认 stdout）"
      echo "  --checks=<list>         检查项列表，逗号分隔（默认全部）"
      echo "可选检查项: ${ALL_CHECKS}"
      exit 0 ;;
    *)
      log_err "未知参数: $1"
      exit 1 ;;
  esac
  shift
done

if [[ -z "$RUN_CHECKS" ]]; then
  RUN_CHECKS="$ALL_CHECKS"
fi

# 将逗号分隔转为空格分隔的数组
IFS=',' read -ra CHECK_LIST <<< "$RUN_CHECKS"

# ---- 全局状态 ----
PASSED=true
CHECKS_JSON=""
CHECK_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

append_check() {
  local name="$1" status="$2" message="$3"
  local comma=""
  if [[ -n "$CHECKS_JSON" ]]; then comma=","; fi
  CHECKS_JSON="${CHECKS_JSON}${comma}{\"name\":\"${name}\",\"status\":\"${status}\",\"message\":\"${message}\"}"
  CHECK_COUNT=$((CHECK_COUNT + 1))
  case "$status" in
    passed) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    failed) PASSED=false; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    skipped) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

should_run() {
  local name="$1"
  for c in "${CHECK_LIST[@]}"; do
    [[ "$c" == "$name" ]] && return 0
  done
  return 1
}

# ============================================================
# 检查项 1: cli_tools — CLI 工具可用性
# ============================================================
check_cli_tools() {
  local missing=()
  local available=()
  local tools=("ll-builder" "rclone" "curl" "python3" "git" "file" "jq")

  for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      available+=("$tool")
    else
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    append_check "cli_tools" "passed" "all ${#available[@]} CLI tools available: ${available[*]}"
  else
    append_check "cli_tools" "failed" "missing CLI tools: ${missing[*]}"
  fi
}

# ============================================================
# 检查项 2: config_validity — 配置完整性
# ============================================================
check_config_validity() {
  local cfg="${CONFIG_FILE:-${REPO_ROOT}/for-multica/agent-config.json}"

  if [[ ! -f "$cfg" ]]; then
    cfg="${REPO_ROOT}/agent-config.json"
    if [[ ! -f "$cfg" ]]; then
      append_check "config_validity" "failed" "no agent-config.json found (tried --config, for-multica/, root/)"
      return
    fi
  fi

  # JSON 可解析性
  if ! python3 -c "import json; json.load(open('${cfg}'))" 2>/dev/null; then
    append_check "config_validity" "failed" "${cfg} is not valid JSON"
    return
  fi

  # 路径中无 ${tag} 残留
  if python3 -c "
import json
with open('${cfg}') as f:
    cfg = json.load(f)
global_cfg = cfg.get('global', {})
for key, val in global_cfg.items():
    if isinstance(val, str) and '\${tag}' in val:
        print(f'unresolved: {key} = {val}')
        exit(1)
" 2>/dev/null; then
    append_check "config_validity" "passed" "${cfg} valid JSON, all paths resolved"
  else
    local unresolved
    unresolved=$(python3 -c "
import json
with open('${cfg}') as f:
    cfg = json.load(f)
global_cfg = cfg.get('global', {})
for key, val in global_cfg.items():
    if isinstance(val, str) and '\${tag}' in val:
        print(f'{key}={val}')
" 2>/dev/null)
    append_check "config_validity" "failed" "${cfg} contains unresolved \${tag}: ${unresolved}"
  fi
}

# ============================================================
# 检查项 3: network_s3 — S3 存储桶可达
# ============================================================
check_network_s3() {
  if ! command -v rclone &>/dev/null; then
    append_check "network_s3" "skipped" "rclone not available, skipping S3 check"
    return
  fi

  local result
  result=$(rclone lsd "cicd2:/linyaps/packaging-CI-output/" 2>&1) || true
  if [[ -n "$result" ]] || [[ $? -eq 0 ]]; then
    append_check "network_s3" "passed" "S3 bucket cicd2:/linyaps/packaging-CI-output/ is accessible"
  else
    append_check "network_s3" "failed" "Cannot access S3 bucket: $(echo "$result" | head -1)"
  fi
}

# ============================================================
# 检查项 4: network_webhook — webhook 端点可达
# ============================================================
check_network_webhook() {
  if ! command -v curl &>/dev/null; then
    append_check "network_webhook" "skipped" "curl not available, skipping webhook check"
    return
  fi

  local webhook_url="https://cooperation.uniontech.com/api/workflow/hooks/NmEzMGZlNDlmNzE3ZmIyMmIwZjVlODQ2"
  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 --max-time 10 "${webhook_url}" 2>&1 || true)
  if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]] || [[ "$http_code" == "000" ]]; then
    append_check "network_webhook" "passed" "Webhook endpoint reachable (HTTP ${http_code})"
  else
    append_check "network_webhook" "failed" "Webhook endpoint returned HTTP ${http_code}"
  fi
}

# ============================================================
# 检查项 5: network_upstream — n8n upstream API 可达
# ============================================================
check_network_upstream() {
  if ! command -v curl &>/dev/null; then
    append_check "network_upstream" "skipped" "curl not available, skipping upstream check"
    return
  fi

  local script="$SCRIPT_DIR/query_upstream.sh"
  if [[ ! -f "$script" ]]; then
    append_check "network_upstream" "skipped" "query_upstream.sh not found at ${script}"
    return
  fi

  local upstream_url
  upstream_url=$(grep -oP 'https?://[^"'"'"']+' "$script" | head -1 || true)
  if [[ -z "$upstream_url" ]]; then
    append_check "network_upstream" "skipped" "no upstream URL found in query_upstream.sh"
    return
  fi

  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 --max-time 10 "${upstream_url}" 2>&1 || true)
  if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]] || [[ "$http_code" == "000" ]]; then
    append_check "network_upstream" "passed" "Upstream API reachable (HTTP ${http_code})"
  else
    append_check "network_upstream" "failed" "Upstream API returned HTTP ${http_code} for ${upstream_url}"
  fi
}

# ============================================================
# 检查项 6: script_integrity — 所有 skill 脚本存在
# ============================================================
check_script_integrity() {
  local missing_paths=()
  local paths=(
    # linyaps-packaging-precheck 自身
    "$SCRIPT_DIR/precheck.sh"
    "$SCRIPT_DIR/common.sh"
    "$SKILL_ROOT/SKILL.md"

    # linyaps-multica-packer-dispatch
    "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh"
    "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/scripts/detect_init_source.sh"
    "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh"
    "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh"
    "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/scripts/common.sh"
    "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/SKILL.md"

    # linyaps-packaging-precheck (自身 + query_upstream)
    "$REPO_ROOT/skills/linyaps-packaging-precheck/scripts/query_upstream.sh"

    # linyaps-packaging-report
    "$REPO_ROOT/skills/linyaps-packaging-report/scripts/status_upload.sh"
    "$REPO_ROOT/skills/linyaps-packaging-report/scripts/status_upload_initOnly.sh"
    "$REPO_ROOT/skills/linyaps-packaging-report/scripts/verify_upload.sh"
    "$REPO_ROOT/skills/linyaps-packaging-report/scripts/common.sh"
    "$REPO_ROOT/skills/linyaps-packaging-report/SKILL.md"

    # linglong-binary-runner
    "$REPO_ROOT/skills/linglong-binary-runner/scripts/run_tasks.sh"
    "$REPO_ROOT/skills/linglong-binary-runner/scripts/validate_projects.sh"
    "$REPO_ROOT/skills/linglong-binary-runner/scripts/common.sh"

    # linglong-source-updater
    "$REPO_ROOT/skills/linglong-source-updater/scripts/run_tasks.sh"
    "$REPO_ROOT/skills/linglong-source-updater/scripts/download-and-checksum.sh"
    "$REPO_ROOT/skills/linglong-source-updater/scripts/update-linglong-yaml.py"
    "$REPO_ROOT/skills/linglong-source-updater/scripts/validate-linglong-yaml.py"
    "$REPO_ROOT/skills/linglong-source-updater/scripts/common.sh"
  )

  for p in "${paths[@]}"; do
    if [[ ! -f "$p" ]]; then
      missing_paths+=("$p")
    fi
  done

  if [[ ${#missing_paths[@]} -eq 0 ]]; then
    append_check "script_integrity" "passed" "all ${#paths[@]} skill scripts exist"
  else
    append_check "script_integrity" "failed" "missing ${#missing_paths[@]} scripts: $(printf '%s; ' "${missing_paths[@]}")"
  fi
}

# ---- 执行 ----
for check in cli_tools config_validity network_s3 network_webhook network_upstream script_integrity; do
  if should_run "$check"; then
    "check_${check}"
  else
    append_check "$check" "skipped" "excluded by --checks filter"
  fi
done

# ---- 汇总 ----
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
SUMMARY="{\"total\":${CHECK_COUNT},\"passed\":${PASS_COUNT},\"failed\":${FAIL_COUNT},\"skipped\":${SKIP_COUNT}}"
RESULT="{\"passed\":${PASSED},\"timestamp\":\"${TIMESTAMP}\",\"summary\":${SUMMARY},\"checks\":[${CHECKS_JSON}]}"

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$RESULT" > "$OUTPUT_FILE"
  log_info "precheck result written to ${OUTPUT_FILE}"
else
  echo "$RESULT"
fi

if [[ "$PASSED" == "true" ]]; then
  log_ok "precheck passed (${PASS_COUNT}/${CHECK_COUNT})"
  exit 0
else
  log_err "precheck failed (${FAIL_COUNT}/${CHECK_COUNT} checks failed)"
  exit 1
fi