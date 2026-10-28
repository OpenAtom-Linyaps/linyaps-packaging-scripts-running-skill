# Webhook 迁移计划：cooperation GET → n8n POST

> **状态**：决策完整（decision-complete），无待定设计问题。
> **范围**：仅状态上报（status upload）webhook 调用。`query_upstream.sh` 不在范围内（已有自己的 n8n 端点，不改动）。

## 1. 背景与目标

两个上报脚本（`status_upload.sh`、`status_upload_initOnly.sh`）当前用 GET 查询字符串向旧端点 `cooperation.uniontech.com/api/workflow/hooks/...` 回报状态。旧端点已弃用，迁移到 n8n POST JSON body 方案。

### 新端点（用户已确认，均为 `/webhook/` 生产路径）

| 端点变量 | 新 URL | 对应 n8n 工作流 / 数据表 |
|---|---|---|
| `WEBHOOK_URL`（常规打包） | `https://n8n.cicd.getdeepin.org/webhook/cc3680f7-b312-4e3b-98e8-41a9fd75563c` | `apps-packaging.workflow.json` → `agent-dev-appsPackaging-data` |
| `WEBHOOK_INIT_URL`（初始化后首次打包） | `https://n8n.cicd.getdeepin.org/webhook/953c519d-b695-40fc-90cc-cd06f5ada3aa` | `apps-init.workflow.json` → `agent-dev-appsInit-data` |

### n8n 验证规则（来自 `examples/n8n-workflow/README.md` §4 + 工作流 Code 节点）

| 规则 | apps-packaging（常规） | apps-init（initOnly） |
|---|---|---|
| 必填字段 | `linyapsPkgName`, `linyapsPkgArch`, `pakStatus`, `linyapsPkgVer`, `linyapsPkgUrl` | `upstreamPkgName`, `linyapsPkgName`, `linyapsPkgArch`, `pakStatus`, `upstreamVer`, `linyapsPkgVer`, `linyapsPkgUrl` |
| `pakStatus` 枚举 | `non-verified`、`failed`（其余值 → 400） | 同左 |
| 未知字段 | 拒绝 400 | 同左 |
| body 格式 | 单个 JSON 对象或对象数组；空对象/空数组 → 400 | 同左 |
| 成功响应 | `200 {"ok":true,"inserted":N}` | 同左 |
| 验证失败 | `400 {"ok":false,"error":"..."}` | 同左 |
| DB 失败 | `500 {"ok":false,"error":"..."}` | 同左 |

## 2. 关键设计决策（已定）

### 决策 1：pakStatus 映射规则

n8n 仅接受 `non-verified` 和 `failed`。脚本内部有三种额外的中间 pakStatus 值需要处理：

| 内部 pakStatus | webhook 发送值 | 说明 |
|---|---|---|
| `non-verified` | `non-verified` | 直接透传 |
| `failed` | `failed` | 直接透传 |
| `blocked:pak_linyaps_bypass` | **`failed`** | 内部状态保留用于 stderr/exit code；webhook body 映射为 `failed` |
| `upload-failed` | **`failed`** | 同上 |

**实现**：在构造 JSON body 前，创建一个 `webhook_pakStatus` 变量做映射：
```bash
webhook_pakStatus="$pakStatus"
case "$pakStatus" in
    blocked:pak_linyaps_bypass|upload-failed) webhook_pakStatus="failed" ;;
esac
```
JSON body 中使用 `webhook_pakStatus`，stderr 日志和 exit code 继续使用原始 `pakStatus`。

### 决策 2：`upstreamPkgName` 获取方式（仅 initOnly）

apps-init 端点要求 `upstreamPkgName`（7 个必填字段之一），但 `status_upload_initOnly.sh` 当前没有该参数来源。

**决策**：新增位置参数 `$6 upstreamPkgName`。由 LLM（调用方 agent）负责传入。理由：用户确认"旧方案可以正常使用，应该是LLM负责导入参数"。

- `status_upload.sh`（常规）：**不需要** `upstreamPkgName`（apps-packaging 不要求）。
- `status_upload_initOnly.sh`（initOnly）：**新增** `$6 upstreamPkgName`，必填。
- 若 `$6` 为空，脚本报错退出（`echo "ERROR: upstreamPkgName is required for init webhook" >&2; exit 1`），不发送请求。

### 决策 3：`bypass_flag` 完全移除

旧方案在 exec-proof 门禁失败时设 `bypass_flag="&pak_linyaps_bypass=1"` 并追加到 GET URL。n8n 拒绝未知字段（400），因此：
- 删除 `bypass_flag` 变量声明（`status_upload.sh:89`、`status_upload_initOnly.sh:90`）。
- 删除 `bypass_flag="&pak_linyaps_bypass=1"` 赋值（`status_upload.sh:121`、`status_upload_initOnly.sh:122`）。
- webhook 调用不再拼接 `${bypass_flag}`。

内部 pakStatus `blocked:pak_linyaps_bypass` 保留（用于 stderr + exit 1），仅映射为 `failed` 发给 webhook。

## 3. 执行步骤

### 3.0 导出实施方案到 docs（执行第一步）

在开始任何脚本修改前，将本计划文件导出到仓库 docs 目录，作为实施记录留存：

```bash
# 执行期间：从 local://webhook-n8n-migration-plan.md 读取完整内容，
# 写入仓库 docs/plan/ 目录（遵循 <日期>-<slug>-plan.md 命名约定）
cat > docs/plan/20261028-webhook-n8n-migration-plan.md <<'PLANEOF'
<本计划文件完整内容>
PLANEOF
```
> 实现者注意：`local://webhook-n8n-migration-plan.md` 是本计划的会话本地副本，执行时已恢复到工作树可写状态。用其完整内容替换 `<本计划文件完整内容>` 占位符。

- **目标路径**：`docs/plan/20261028-webhook-n8n-migration-plan.md`（遵循现有命名约定 `<日期>-<slug>-plan.md`，如 `20261019-dispatch-skill-sync-plan.md`）。
- **内容来源**：`local://webhook-n8n-migration-plan.md` 的完整内容。
- **时机**：执行阶段的第一步，先于 §3.1 的任何文件修改。
- **目的**：实施前留存决策完整方案，供后续审查与回溯。

### 3.1 `skills/linyaps-packaging-report/scripts/report_endpoints.sh`

**第 10–11 行**（注释）：更新回退默认值描述：
```
#   webhook_url      = https://n8n.cicd.getdeepin.org/webhook/cc3680f7-b312-4e3b-98e8-41a9fd75563c
#   webhook_init_url = https://n8n.cicd.getdeepin.org/webhook/953c519d-b695-40fc-90cc-cd06f5ada3aa
```

**第 16–17 行**（注释）：同上。

**第 46–47 行**（实际值）：
```bash
WEBHOOK_URL="https://n8n.cicd.getdeepin.org/webhook/cc3680f7-b312-4e3b-98e8-41a9fd75563c"
WEBHOOK_INIT_URL="https://n8n.cicd.getdeepin.org/webhook/953c519d-b695-40fc-90cc-cd06f5ada3aa"
```

agent-config.json 解析逻辑（第 49–72 行）不变——仍支持从 config 覆盖 `webhook_url`/`webhook_init_url`，仅默认值改变。

### 3.2 `skills/linyaps-packaging-report/scripts/status_upload.sh`

#### 3.2.1 头部注释（第 4 行）
```
# 用途：每個任務打包完成後，將構建產物上傳至 S3 並向 n8n webhook 回報狀態。
```

#### 3.2.2 `bypass_flag` 移除（第 89、121 行）
- 第 89 行 `bypass_flag=""` → 删除。
- 第 121 行 `bypass_flag="&pak_linyaps_bypass=1"` → 删除。

#### 3.2.3 pakStatus 映射 + JSON body 构造 + webhook 调用（第 166–173 行）

**当前**：
```bash
# ── Webhook 回報 ─────────────────────────────────────────
echo "   reporting status: $pakStatus"
if curl --retry 3 --retry-delay 2 -fsS "${WEBHOOK_URL}?linyapsPkgName=$linyapsPkgName&linyapsPkgArch=$linyapsPkgArch&pakStatus=$pakStatus&upstreamVer=$upstreamVer&linyapsPkgVer=$linyapsPkgVer&linyapsPkgUrl=$linyapsPkgUrl${bypass_flag}"; then
    echo "   status reported"
else
    echo "ERROR: webhook report failed for <$linyapsPkgName> — pakStatus=$pakStatus, url=$linyapsPkgUrl" >&2
    exit 1
fi
```

**替换为**：
```bash
# ── Webhook 回報（n8n POST JSON）─────────────────────────
# pakStatus 映射：n8n 仅接受 non-verified / failed
webhook_pakStatus="$pakStatus"
case "$pakStatus" in
    blocked:pak_linyaps_bypass|upload-failed) webhook_pakStatus="failed" ;;
esac

echo "   reporting status: $pakStatus (webhook: $webhook_pakStatus)"

# 构造 JSON body（apps-packaging 必填 5 字段）
json_body=$(cat <<JSONEOF
{"linyapsPkgName":"$linyapsPkgName","linyapsPkgArch":"$linyapsPkgArch","pakStatus":"$webhook_pakStatus","upstreamVer":"$upstreamVer","linyapsPkgVer":"$linyapsPkgVer","linyapsPkgUrl":"$linyapsPkgUrl"}
JSONEOF
)

if curl --retry 3 --retry-delay 2 -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d "$json_body" \
    "$WEBHOOK_URL"; then
    echo "   status reported"
else
    echo "ERROR: webhook report failed for <$linyapsPkgName> — pakStatus=$pakStatus, url=$linyapsPkgUrl" >&2
    exit 1
fi
```

**说明**：
- `upstreamVer` 虽然 apps-packaging 不在必填列表中（必填 5 字段不含 `upstreamVer`），但它是可写字段（ALLOWED 包含），发送不会触发 400。
- JSON body 使用 heredoc 构造，避免 `jq` 依赖。
- `linyapsPkgUrl` 值为 `"null"` 字符串时，n8n 的 `normText` 会将其保留为字符串 `"null"` 而非 null（因为非空字符串）。这在 `failed`/`blocked`/`upload-failed` 路径下可接受——pakStatus 为 `failed`，url 值不影响状态语义。**不额外处理**，保持简单。

#### 3.2.4 第 174–176 行（blocked exit 逻辑）
不变。`blocked:pak_linyaps_bypass` 仍 exit 1。

### 3.3 `skills/linyaps-packaging-report/scripts/status_upload_initOnly.sh`

#### 3.3.1 头部注释
**第 4 行**：
```
# 用途：每個任務打包完成後，將構建產物上傳至 S3 並向 n8n webhook 回報狀態。
```

**第 8–9 行**（用法说明）：新增 `$6` 参数：
```
#   bash skills/linyaps-packaging-report/scripts/status_upload_initOnly.sh <filepath> <upstreamVer> <pakStatus> [<pkgName>] [<pkgArch>] [<upstreamPkgName>]
```

**第 11–16 行**（参数说明）：追加：
```
#   $6  upstreamPkgName — 上游包名（apps-init webhook 必填，由调用方提供）
```

#### 3.3.2 参数读取（第 43–47 行后）
追加：
```bash
upstreamPkgName="${6:-}"
```

#### 3.3.3 `bypass_flag` 移除（第 90、122 行）
同 status_upload.sh。

#### 3.3.4 pakStatus 映射 + JSON body 构造 + webhook 调用（第 167–174 行）

**当前**：
```bash
# ── Webhook 回報（初始化專用端點） ───────────────────────
echo "   reporting status: $pakStatus"
if curl --retry 3 --retry-delay 2 -fsS "${WEBHOOK_INIT_URL}?linyapsPkgName=$linyapsPkgName&linyapsPkgArch=$linyapsPkgArch&pakStatus=$pakStatus&upstreamVer=$upstreamVer&linyapsPkgVer=$linyapsPkgVer&linyapsPkgUrl=$linyapsPkgUrl${bypass_flag}"; then
    echo "   status reported"
else
    echo "ERROR: webhook report failed for <$linyapsPkgName> — pakStatus=$pakStatus, url=$linyapsPkgUrl" >&2
    exit 1
fi
```

**替换为**：
```bash
# ── Webhook 回報（n8n POST JSON，初始化專用端點）─────────
# pakStatus 映射：n8n 仅接受 non-verified / failed
webhook_pakStatus="$pakStatus"
case "$pakStatus" in
    blocked:pak_linyaps_bypass|upload-failed) webhook_pakStatus="failed" ;;
esac

# upstreamPkgName 校验（apps-init 必填）
if [ -z "$upstreamPkgName" ]; then
    echo "ERROR: upstreamPkgName is required for init webhook (apps-init required field)" >&2
    exit 1
fi

echo "   reporting status: $pakStatus (webhook: $webhook_pakStatus)"

# 构造 JSON body（apps-init 必填 7 字段）
json_body=$(cat <<JSONEOF
{"upstreamPkgName":"$upstreamPkgName","linyapsPkgName":"$linyapsPkgName","linyapsPkgArch":"$linyapsPkgArch","pakStatus":"$webhook_pakStatus","upstreamVer":"$upstreamVer","linyapsPkgVer":"$linyapsPkgVer","linyapsPkgUrl":"$linyapsPkgUrl"}
JSONEOF
)

if curl --retry 3 --retry-delay 2 -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d "$json_body" \
    "$WEBHOOK_INIT_URL"; then
    echo "   status reported"
else
    echo "ERROR: webhook report failed for <$linyapsPkgName> — pakStatus=$pakStatus, url=$linyapsPkgUrl" >&2
    exit 1
fi
```

#### 3.3.5 第 176–178 行（blocked exit 逻辑）
不变。

### 3.4 `skills/linyaps-packaging-precheck/scripts/precheck.sh`

#### `check_network_webhook`（第 162–176 行）

n8n webhook 节点响应 POST 请求；裸 GET 会返回 404/405。探测方案改为 POST 一个故意无效的 body（空 JSON object `{}`），任何 HTTP 响应（200/400/500）都证明端点可达；只有连接拒绝/超时（`000`）才判定不可达。

**当前**：
```bash
check_network_webhook() {
  if ! command -v curl &>/dev/null; then
    append_check "network_webhook" "skipped" "curl not available, skipping webhook check"
    return
  fi

  local webhook_url="${WEBHOOK_URL}"
  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 --max-time 10 "${webhook_url}" 2>&1 || true)
  if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]] || [[ "$http_code" == "000" ]]; then
    append_check "network_webhook" "passed" "Webhook endpoint reachable (HTTP ${http_code})"
  else
    append_check "network_webhook" "failed" "Webhook endpoint returned HTTP ${http_code})"
  fi
}
```

**替换为**：
```bash
check_network_webhook() {
  if ! command -v curl &>/dev/null; then
    append_check "network_webhook" "skipped" "curl not available, skipping webhook check"
    return
  fi

  local webhook_url="${WEBHOOK_URL}"
  local http_code
  # n8n webhook 仅响应 POST；发送空 body 探测可达性。
  # 任何 HTTP 响应码（200/400/500）= 可达；仅 000（连接拒绝/超时）= 不可达。
  http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 --max-time 10 \
    -X POST -H 'Content-Type: application/json' -d '{}' "${webhook_url}" 2>&1 || true)
  if [[ "$http_code" != "000" ]]; then
    append_check "network_webhook" "passed" "Webhook endpoint reachable (HTTP ${http_code})"
  else
    append_check "network_webhook" "failed" "Webhook endpoint unreachable (HTTP ${http_code})"
  fi
}
```

**注意**：旧逻辑将 `000` 也判为 passed（`|| [[ "$http_code" == "000" ]]`），这在旧 GET 方案中是为了容忍 curl 对某些端点的非标准行为。新方案中 `000` 明确表示连接失败，改为 failed。

### 3.5 文档更新

#### `skills/linyaps-packaging-report/SKILL.md`（第 22 行）
当前提到 `pak_linyaps_bypass=1` webhook 上报机制已不适用（n8n 不接受该字段）。更新为：

```markdown
上传失败必须输出明确警告并标记 `upload-failed`；不得静默为成功，也不得阻断后续任务。依赖 rclone/curl，webhook 使用脚本内置重试。webhook 上报采用 POST JSON（n8n），pakStatus 仅发送 `non-verified`/`failed`（`blocked:pak_linyaps_bypass` 和 `upload-failed` 内部状态映射为 `failed` 上报）。公共路径、日志和结果边界引用 constraints skill。
```

#### `skills/linyaps-packaging.constraints/SKILL.md`（第 86 行）
当前：
```
`status_upload.sh` 门禁将此类结果阻断为 `blocked:pak_linyaps_bypass`（跳过 S3 上传）并向 webhook 上报 `pak_linyaps_bypass=1`。
```
更新为：
```
`status_upload.sh` 门禁将此类结果阻断为 `blocked:pak_linyaps_bypass`（跳过 S3 上传），webhook 以 `failed` 状态上报。
```

#### `skills/linyaps-packaging-report/SKILL.md`（第 20 行）
追加 initOnly 参数说明：
```markdown
…init 来源时使用 initOnly 脚本（需额外传 `upstreamPkgName` 作为第 6 参数）。两个上传脚本均设环境变量 `TASK_TYPE`…
```

### 3.6 调用方更新（`upstreamPkgName` 传递）

#### `linglong-binary-runner/scripts/run_tasks.sh`

`_report_status` 函数（第 107–113 行）调用 `status_upload.sh`（常规），不调用 initOnly，因此**不需要**传 `upstreamPkgName`。无需修改。

> `run_tasks.sh` 只调用常规 `status_upload.sh`，apps-packaging 端点不要求 `upstreamPkgName`。

#### `agents/linyaps-packaging-runner.agent.md`

第 37 行已说明 source 任务由 agent 显式调用 `status_upload.sh`。若 agent 调用 initOnly 变体，需传 `upstreamPkgName`。更新第 37 行追加说明：

```markdown
…source 由 agent 显式调用）；initOnly 变体需额外传 `upstreamPkgName` 作为第 6 参数（由 agent 从任务上下文获取）。最后汇总短结果。
```

#### Session 日志中的 initOnly 调用模式

历史 session 日志显示 initOnly 调用均为 3 参数（`<filepath> <upstreamVer> <pakStatus>`）。迁移后需传 6 参数（追加 `<pkgName> <pkgArch> <upstreamPkgName>`）。这是调用方行为变更，由 agent 在调用时适配。脚本对 `$4`/`$5` 已有回退逻辑（filepath 为 null 时从参数取），`$6` 为新增必填。

## 4. JSON Body 规范

### 4.1 `status_upload.sh` → apps-packaging（常规）

```json
{
  "linyapsPkgName": "<包名>",
  "linyapsPkgArch": "<架构>",
  "pakStatus": "non-verified | failed",
  "upstreamVer": "<上游版本>",
  "linyapsPkgVer": "<linyaps 版本>",
  "linyapsPkgUrl": "<S3 URL 或 null>"
}
```

字段来源：
- `linyapsPkgName` / `linyapsPkgArch` / `linyapsPkgVer`：从 filepath 文件名提取，或从 `$4`/`$5` 回退。
- `pakStatus`：`webhook_pakStatus`（映射后）。
- `upstreamVer`：`$2`。
- `linyapsPkgUrl`：S3 上传成功后为公开 URL，失败/null 路径为字符串 `"null"`。

### 4.2 `status_upload_initOnly.sh` → apps-init（initOnly）

```json
{
  "upstreamPkgName": "<上游包名>",
  "linyapsPkgName": "<包名>",
  "linyapsPkgArch": "<架构>",
  "pakStatus": "non-verified | failed",
  "upstreamVer": "<上游版本>",
  "linyapsPkgVer": "<linyaps 版本>",
  "linyapsPkgUrl": "<S3 URL 或 null>"
}
```

字段来源同上，`upstreamPkgName` 来自 `$6`。

## 5. 不在范围内

- **`query_upstream.sh`**：已有自己的 n8n 端点 `https://n8n.cicd.getdeepin.org/webhook/1f678037-e7f2-484c-a28b-b5c233fde531`，不改动。
- **`check_network_upstream`**（precheck.sh 第 181–207 行）：检测 `query_upstream.sh` 的上游 API 可达性，不改动。
- **agent-config.json**：不新增 webhook 字段覆盖。`report_endpoints.sh` 默认值即权威值。
- **n8n 工作流 JSON**：不在本仓库维护范围（工作流在 n8n 实例上管理），仅 `examples/n8n-workflow/` 下的文档供参考。

## 6. 验证清单

实施后逐项验证：

1. **`report_endpoints.sh` 默认值**：`source` 后 `echo $WEBHOOK_URL` / `echo $WEBHOOK_INIT_URL` 输出新 URL。
2. **`status_upload.sh` POST body**：用 `--dry-run` 或截获 curl 命令验证 JSON body 格式正确、无 `bypass_flag` 残留。
3. **`status_upload.sh` pakStatus 映射**：模拟 `blocked:pak_linyaps_bypass` 场景，验证 webhook body 中 `pakStatus` 为 `failed`。
4. **`status_upload_initOnly.sh` upstreamPkgName 校验**：不传 `$6` 时报错退出；传 `$6` 时 JSON body 包含该字段。
5. **`status_upload_initOnly.sh` POST body**：验证 7 字段 JSON body 格式。
6. **`precheck.sh check_network_webhook`**：对新 URL 发送 POST `{}`，验证非 `000` 响应判为 passed。
7. **端到端**：对 n8n 测试端点发送真实请求，验证 `200 {"ok":true,"inserted":1}` 响应。

## 7. 风险与注意事项

- **n8n 工作流需激活**：两个 n8n 工作流当前 `active: false`（见 JSON）。生产 URL `/webhook/` 仅在激活后响应。激活前调用会返回 404。实施前需在 n8n UI 激活工作流并绑定 Postgres 凭据。
- **`linyapsPkgUrl` = `"null"` 字符串**：在 failed/blocked 路径下，`linyapsPkgUrl` 设为字符串 `"null"` 而非 JSON null。n8n `normText` 对非空字符串保留原值，不会触发必填字段缺失错误（因为值非空）。行为可接受。
- **initOnly 调用方变更**：历史 3 参数调用需改为 6 参数。agent 需在调用 initOnly 时传 `upstreamPkgName`。脚本对缺失 `$6` 报错退出，不会静默发送无效请求。
- **JSON 转义**：heredoc 构造 JSON body 时，变量值中的双引号/反斜杠未转义。包名/版本号通常不含这些字符，但若出现会导致 JSON 格式错误（n8n 返回 400）。当前系统数据未见此类情况，保持简单实现。
