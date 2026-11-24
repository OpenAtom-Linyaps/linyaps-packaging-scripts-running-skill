#!/bin/bash
# linyaps binary 打包執行器 — 透過 pak_linyaps.sh 執行二進制打包
# 用法: ./run_tasks.sh <task.json> [--agent-config-path=<path>]
# 依賴: scripts/common.sh（共享庫）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENT_CONFIG_PATH=""
TASK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-config-path=*) AGENT_CONFIG_PATH="${1#*=}"; shift ;;
    *) TASK_FILE="$1"; shift ;;
  esac
done

if [[ -z "$TASK_FILE" ]]; then
  echo "用法: $0 <task.json> [--agent-config-path=<path>]" >&2
  exit 1
fi

CONFIG_FILE="${AGENT_CONFIG_PATH:-${REPO_ROOT}/agent-config.json}"

source "$SCRIPT_DIR/common.sh"

check_python3

eval "$(parse_json "$TASK_FILE" "$CONFIG_FILE")"

if [[ -z "$PACK_REPO_DIR" || "$PACK_REPO_DIR" == '""' ]]; then
    log_err "JSON 中缺少 global.pack_repo_dir"
    exit 1
fi

PACK_REPO_DIR="$(cd "$PACK_REPO_DIR" 2>/dev/null && pwd || echo "$PACK_REPO_DIR")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" || OUTPUT_DIR="./output"
SRC_DIR="$(cd "$(dirname "$SRC_DIR")" 2>/dev/null && pwd)/$(basename "$SRC_DIR")" || SRC_DIR="./src"

OUTPUT_DIR=$(json_strip "$OUTPUT_DIR")
SRC_DIR=$(json_strip "$SRC_DIR")
BUILD_TMP_DIR=$(json_strip "$BUILD_TMP_DIR")
DATA_DIR=$(json_strip "$DATA_DIR")

log_info "項目根目錄: $PACK_REPO_DIR"
log_info "輸出目錄:   $OUTPUT_DIR"
log_info "資源目錄:   $SRC_DIR"

PROJECTS_REPO=$(json_strip "$PROJECTS_REPO")
sync_projects_root "$PROJECTS_REPO" "$PACK_REPO_DIR" || exit 1

init_directories

SUCCESS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()
# write_exec_proof — 寫入 binary 構建執行憑證（constraints §6）
# 参数:
#   $1  out_dir    — 輸出目錄
#   $2  pkg_name   — 包名
#   $3  arch       — 架構
#   $4  build_cmd  — 實際執行的完整命令行
#   $5  exit_code  — 構建退出碼
#   $6  started_at — 開始時間（ISO8601）
#   $7  finished_at — 結束時間（ISO8601）
#   $8...         — layer 文件路徑（一個或多個）
write_exec_proof() {
    local out_dir="$1" pkg_name="$2" arch="$3" build_cmd="$4" exit_code="$5" started_at="$6" finished_at="$7"
    shift 7

    local proof="$out_dir/${pkg_name}.exec-proof.json"
    local -a layer_entries=()
    local layer_file digest entry
    for layer_file in "$@"; do
        [[ -f "$layer_file" ]] || continue
        digest="$(sha256sum "$layer_file" | cut -d' ' -f1)"
        entry="$(python3 -c 'import json,sys;print(json.dumps({"file":sys.argv[1],"sha256":sys.argv[2]}))' "$(basename "$layer_file")" "$digest")"
        layer_entries+=("$entry")
    done

    local cmd_json
    cmd_json="$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$build_cmd")"
    {
        echo "{"
        echo "  \"pkg_name\": \"${pkg_name}\","
        echo "  \"task_type\": \"binary\","
        echo "  \"command\": ${cmd_json},"
        echo "  \"exit_code\": ${exit_code},"
        echo "  \"started_at\": \"${started_at}\","
        echo "  \"finished_at\": \"${finished_at}\","
        echo "  \"layers\": [$(IFS=,; echo "${layer_entries[*]}")]"
        echo "}"
    } > "$proof"
    echo "exec-proof written: $proof"
}

# _report_status — 調用 status_upload.sh 上傳產物並回報狀態（report skill）
# 參數:
#   $1  filepath  — layer 文件路徑；"null" 表示無產物（失敗/阻塞）
#   $2  status    — pakStatus 值：non-verified / failed / upload-failed
#   $3  pkg_name  — 包名
#   $4  arch      — 架構
#   $5  orig_ver  — 上游版本號
_report_status() {
    local filepath="$1" status="$2" pkg_name="$3" arch="$4" orig_ver="$5"
    export TASK_TYPE=binary
    bash "$REPO_ROOT/skills/linyaps-packaging-report/scripts/status_upload.sh" \
        "$filepath" "$orig_ver" "$status" "$pkg_name" "$arch" \
        || echo "warn: status_upload.sh failed for $pkg_name (exit $?)"
}

run_task() {
    local idx="$1"
    local pkg_name_var="TASK_${idx}_PKGNAME"
    local src_url_var="TASK_${idx}_SRC_URL"
    local arch_var="TASK_${idx}_ARCH"
    local ver_var="TASK_${idx}_ORIG_VERSION"

    local pkg_name="${!pkg_name_var}"
    local src_url="${!src_url_var}"
    local arch="${!arch_var}"
    local orig_version="${!ver_var}"

    pkg_name=$(json_strip "$pkg_name")
    src_url=$(json_strip "$src_url")
    arch=$(json_strip "$arch")
    orig_version=$(json_strip "$orig_version")

    log_info "=========================================="
    log_info "任務 [$((idx+1))/$TASK_COUNT]: $pkg_name"
    log_info "=========================================="

    if [[ -z "$orig_version" ]]; then
        orig_version=$(extract_version_from_url "$src_url" "$pkg_name" "$CONFIG_FILE")
        if [[ -n "$orig_version" ]]; then
            log_info "從 URL 提取版本號: $orig_version"
        else
            log_err "無法從 URL 提取版本號: $src_url"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            RESULTS+=("$pkg_name: 失敗 (無法提取版本號)")
            _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
        fi
    fi

    if ! validate_arch_match "$src_url" "$arch" "$ARCH_MAPPING_FILE" "$pkg_name"; then
        log_err "架構不匹配，跳過任務 $pkg_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (架構不匹配: URL 架構 vs 宣告 arch=${arch})")
        _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
    fi

    local src_path
    src_path=$(download_source "$src_url" "$SRC_DIR" "$pkg_name") || {
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (下載失敗)")
        _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
    }

    local project_dir
    project_dir=$(find_project_dir "$pkg_name" "$PACK_REPO_DIR") || {
        log_err "找不到項目目錄: $pkg_name (在 $PACK_REPO_DIR 下)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (找不到項目目錄)")
        _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
    }
    log_ok "項目目錄: $project_dir"

    local pak_script="$project_dir/pak_linyaps.sh"
    chmod +x "$pak_script"

    local task_build_tmp_dir
    if ! task_build_tmp_dir=$(mktemp -d -p "$BUILD_TMP_DIR"); then
        log_err "無法建立任務緩存目錄（根目錄: $BUILD_TMP_DIR）"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (無法建立任務緩存目錄)")
        _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
    fi
    log_info "任務緩存目錄: $task_build_tmp_dir"

    local build_tmp_arg=""
    if supports_build_tmp_dir "$pak_script"; then
        build_tmp_arg="--build_tmp_dir=${task_build_tmp_dir}"
        log_info "檢測到 --build_tmp_dir 支援"
    else
        log_info "該項目不支援 --build_tmp_dir，跳過該參數"
    fi

    local -a cmd=(./pak_linyaps.sh \
  --linyaps_arch="$arch" \
  --origin_version="$orig_version" \
  --src_path="$src_path" \
  --output_dir="$OUTPUT_DIR")
    if [[ -n "$build_tmp_arg" ]]; then
        cmd+=(--build_tmp_dir="$task_build_tmp_dir")
    fi

    log_info "執行命令:"
    printf '%s ' "${cmd[@]}"
    echo ""
    echo ""

    local log_file="$OUTPUT_DIR/${pkg_name}.log"
    local start_time
    start_time=$(date +%s)
    local started_at_iso
    started_at_iso="$(date -Is)"

    if (
        cd "$project_dir" && build_with_retry "$pkg_name 打包（binary）" "$MAX_BUILD_ATTEMPTS" "$BUILD_TIMEOUT_SEC" "${cmd[@]}"
    ) > "$log_file" 2>&1; then
        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log_ok "$pkg_name 打包成功 (耗時 ${elapsed}s)"
        log_info "最後輸出:"
        tail -5 "$log_file" | sed 's/^/  /'

        # A fix log is publishable only when bound to the immutable task issue.
        local fix_log_path="${DATA_DIR}/${pkg_name}.fix-log.md"
        if [[ -f "$fix_log_path" ]]; then
            if [[ -z "${MULTICA_ISSUE_TASK_ID:-}" ]]; then
                log_err "blocked: issue_id_required; refusing unbound fix-log comment"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                RESULTS+=("$pkg_name: 阻塞 (缺少任务 issue ID)")
                _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
            fi
            log_info "檢測到修改日志，發布到 issue..."
            bash "$REPO_ROOT/skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh" post_fix_log --pkgName="$pkg_name" --fix-log-path="$fix_log_path" ${DATA_DIR:+--data-dir="$DATA_DIR"} || {
                log_err "blocked: fix-log publication failed"
                _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
            }
        fi

        # exec-proof（constraints §6）：成功路徑寫入執行憑證，供 status_upload.sh 門禁校驗
        local build_cmd_str finished_at_iso
        finished_at_iso="$(date -Is)"
        build_cmd_str="$(printf '%q ' "${cmd[@]}")"
        local -a proof_layers=()
        local layer_glob
        for layer_glob in "$OUTPUT_DIR/${pkg_name}_"*"_binary.layer"; do
            [[ -f "$layer_glob" ]] && proof_layers+=("$layer_glob")
        done
        write_exec_proof "$OUTPUT_DIR" "$pkg_name" "$arch" "$build_cmd_str" 0 "$started_at_iso" "$finished_at_iso" ${proof_layers[@]+"${proof_layers[@]}"} \
            || echo "warn: failed to write exec-proof for $pkg_name (gate will block upload)"

        # ── 上傳至 S3 並回報狀態（report skill）─────────────────
        if [[ ${#proof_layers[@]} -gt 0 ]]; then
            _report_status "${proof_layers[0]}" "non-verified" "$pkg_name" "$arch" "$orig_version"
        else
            echo "warn: no layer file found for $pkg_name, reporting failed"
            _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
        fi
    else
        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log_err "$pkg_name 打包失敗 (耗時 ${elapsed}s)"
        log_err "錯誤輸出:"
        tail -10 "$log_file" | sed 's/^/  /'
        FAIL_COUNT=$((FAIL_COUNT + 1))
        _report_status "null" "failed" "$pkg_name" "$arch" "$orig_version"
    fi
    echo ""
}

log_info "共 $TASK_COUNT 個 binary 打包任務"
echo ""

for ((i = 0; i < TASK_COUNT; i++)); do
    run_task "$i"
done

print_results_summary "$TASK_COUNT" "$SUCCESS_COUNT" "$FAIL_COUNT" "${RESULTS[@]}"
