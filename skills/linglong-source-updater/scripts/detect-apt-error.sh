#!/usr/bin/env bash
# detect-apt-error.sh — 掃描 build 階段 apt 異常並輸出阻塞判定
# 用法：bash detect-apt-error.sh <log_file> <pkgName>
# 輸出：JSON {"detected": true/false, "type": "apt:dep-missing"|"apt:configure-failed", "pkgName": "<pkgName>"}
# 依賴: scripts/common.sh（共享函數）
# 退出碼：0 = 未命中 apt 異常；1 = 命中 apt 異常（已寫阻塞標記）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LOG_PATH="${1:-}"
PKG_NAME="${2:-}"

if [[ -z "$LOG_PATH" || ! -f "$LOG_PATH" ]]; then
  echo '{"detected": false, "type": "", "pkgName": ""}'
  exit 0
fi

source "$SCRIPT_DIR/common.sh"

# 依賴缺失 → apt 整體失敗（all-or-nothing）
if grep -qE "E: Unable to locate package" "$LOG_PATH" 2>/dev/null; then
  TYPE="apt:dep-missing"
# deb configure 失敗 → 阻塞
elif grep -qE "Sub-process returned an error|dpkg: error processing package|not fully configured|postinst|groupadd|useradd" "$LOG_PATH" 2>/dev/null; then
  TYPE="apt:configure-failed"
else
  TYPE=""
fi

if [[ -z "$TYPE" ]]; then
  log_info "未检测到 apt 異常（僅掃描，非依賴預檢）"
  echo '{"detected": false, "type": "", "pkgName": ""}'
  exit 0
fi

log_err "檢測到 apt 異常 ($TYPE)，阻塞 ${PKG_NAME}：不重試、不繞過"
echo "BLOCKED:apt:${TYPE#apt:},${PKG_NAME}" >> "${REPO_ROOT}/skills/.apt-blocked-state"

cat <<EOF
{"detected": true, "type": "$TYPE", "pkgName": "$PKG_NAME"}
EOF

exit 1
