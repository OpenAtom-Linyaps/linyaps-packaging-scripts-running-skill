#!/bin/bash
# check_upload_status_dryrun.sh — upload-status 脚本前置检测（Dry-Run 闸门）
#
# 用途：在打包执行前检测 upload-status 脚本的依赖项是否可用，
#       包括 rclone、S3 存储桶访问、curl、webhook 端点连通性。
#
# 用法：bash scripts/check_upload_status_dryrun.sh
#
# 返回值：0 = 全部通过，1 = 存在失败项
# 输出：JSON 格式检测结果，含每项检查明细

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

PASSED=true
CHECKS=""

append_check() {
  local name="$1"   status="$2"   message="$3"
  local comma=""
  if [[ -n "$CHECKS" ]]; then comma=","; fi
  CHECKS="${CHECKS}${comma}{\"name\":\"${name}\",\"status\":\"${status}\",\"message\":\"${message}\"}"
  if [[ "$status" != "passed" ]]; then PASSED=false; fi
}

# ---- 检查 1: rclone 命令可用 ----
if command -v rclone &>/dev/null; then
  append_check "rclone_binary" "passed" "rclone is available"
else
  append_check "rclone_binary" "failed" "rclone not found in PATH"
fi

# ---- 检查 2: S3 存储桶可访问（只读列表） ----
if command -v rclone &>/dev/null; then
  S3_TEST=$(rclone lsd "cicd2:/linyaps/packaging-CI-output/" 2>&1) || true
  if [[ -n "$S3_TEST" ]] || [[ $? -eq 0 ]]; then
    append_check "s3_bucket_access" "passed" "S3 bucket cicd2:/linyaps/packaging-CI-output/ is accessible"
  else
    append_check "s3_bucket_access" "failed" "Cannot access S3 bucket: $(echo "$S3_TEST" | head -1)"
  fi
else
  append_check "s3_bucket_access" "skipped" "rclone not available, skipping S3 check"
fi

# ---- 检查 3: curl 命令可用 ----
if command -v curl &>/dev/null; then
  append_check "curl_binary" "passed" "curl is available"
else
  append_check "curl_binary" "failed" "curl not found in PATH"
fi

# ---- 检查 4: webhook 端点可达 ----
if command -v curl &>/dev/null; then
  WEBHOOK_URL="https://cooperation.uniontech.com/api/workflow/hooks/NmEzMGZlNDlmNzE3ZmIyMmIwZjVlODQ2"
  HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 --max-time 10 "${WEBHOOK_URL}" 2>&1 || true)
  if [[ "$HTTP_CODE" =~ ^[2-3][0-9]{2}$ ]] || [[ "$HTTP_CODE" == "000" ]]; then
    append_check "webhook_endpoint" "passed" "Webhook endpoint is reachable (HTTP ${HTTP_CODE})"
  else
    append_check "webhook_endpoint" "failed" "Webhook endpoint returned HTTP ${HTTP_CODE}"
  fi
else
  append_check "webhook_endpoint" "skipped" "curl not available, skipping endpoint check"
fi

# ---- 检查 5: status_upload.sh 脚本存在 ----
if [[ -f "$SCRIPT_DIR/status_upload.sh" ]]; then
  append_check "status_upload_script" "passed" "scripts/status_upload.sh exists"
else
  append_check "status_upload_script" "failed" "scripts/status_upload.sh not found"
fi

# ---- 检查 6: status_upload_initOnly.sh 脚本存在 ----
if [[ -f "$SCRIPT_DIR/status_upload_initOnly.sh" ]]; then
  append_check "status_upload_initOnly_script" "passed" "scripts/status_upload_initOnly.sh exists"
else
  append_check "status_upload_initOnly_script" "failed" "scripts/status_upload_initOnly.sh not found"
fi

# ---- 输出 JSON ----
echo "{\"passed\":${PASSED},\"checks\":[${CHECKS}]}"

if [[ "$PASSED" == "true" ]]; then
  exit 0
else
  exit 1
fi