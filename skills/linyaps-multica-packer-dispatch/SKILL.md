---
name: linyaps-multica-packer-dispatch
description: >
  【Packer 节点专用 / Multica 平台】指派分发 SKILL。
  由 linyaps-packer-1/linyaps-packer-2 在打包过程中调用，用于：
  (1) detect_init_source — 检测当前任务是否由 init 节点触发；
  (2) dispatch_project_not_found — 项目未适配时向 init-tracker / linyaps-src-init 发起指派；
  (3) update_issue_status — 汇总后更新 issue 状态；
  (4) post_fix_log — LLM 修复后发布修改日志为 issue comment。
  不适用于其他节点类型（init-tracker、linyaps-src-init 等）。
argument-hint: '<action> <params> [agent_config_path]'
user-invocable: false
---

# linyaps Packer 节点指派分发 SKILL

由 `linyaps-packer-1` / `linyaps-packer-2` 在打包流程中调用，负责 multica 平台上与智能体指派相关的三类操作。

## 目录约定

- 共享脚本：`skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh`
- 配置来源：`for-multica/agent-config.json` 的 `assignment` 区段
- 本 skill 脚本：`skills/linyaps-multica-packer-dispatch/scripts/`

**配置接收**：`agent_config_path` 由调用方通过 `skill()` 传入，本 skill 将其映射为 `--config=<path>`（或 `--agent-config-path=<path>`）参数传递给 `dispatch.sh` 脚本。

## 四种 Action 接口

### Action 1: `detect_init_source`

检测当前打包任务是否由 `linyaps-init`（binary 初始化）或 `linyaps-src-init`（源码初始化）节点触发。

**调用时机**：packer 初始化阶段（原步骤 1.4）

**输入**：
```json
{
  "action": "detect_init_source",
  "agent_config_path": "for-multica/agent-config.json"
}
```

**输出**：
```json
{
  "IS_INIT_ASSIGNED": false,
  "SRC_INIT_ASSIGNED": false
}
```

**消费者**：packer agent 中步骤 7.6（`status_upload.sh` vs `status_upload_initOnly.sh` 选择）

**执行逻辑**：
1. 通过 `multica issue list --output json --limit 1` 取当前 issue 的精确 `id`（UUID）
2. 若获取到 ISSUE_ID（UUID），通过 `multica issue comment list "<ISSUE_ID>" --output json` 获取评论
3. 优先级匹配：`linyaps-init` >> `linyaps-src-init`（binary 场景比例更高）
   - 评论包含 `linyaps-init` → `IS_INIT_ASSIGNED=true`
   - 否则包含 `linyaps-src-init` → `SRC_INIT_ASSIGNED=true`
   - 均不含 → 两者 false
4. multica CLI 不可用或查询失败 → 两标记均为 false，**不阻断流程**

### Action 2: `dispatch_project_not_found`

打包过程中项目目录未找到时，向对应初始化智能体发起指派。

**调用时机**：packer 定位项目阶段（原步骤 5）

**输入**：
```json
{
  "action": "dispatch_project_not_found",
  "agent_config_path": "for-multica/agent-config.json",
  "pkgName": "com.example.app",
  "src_url": "https://example.com/app_1.0_amd64.deb",
  "arch": "x86_64",
  "type": "binary",
  "orig_version": "1.0",
  "agent_name": "<CLI 真实 agent name，由 Agent 运行时决策并显式传入>"
}
```

- `type`：`"binary"` 或 `"source"`，决定指派目标的**能力**（`project_init` / `src_project_init`）
- `agent_name`**：目标 agent 的 **CLI 真实 name**（如 `linyaps-init-1` / `linyaps-src-init-1`）。**必须由 Agent（LLM）运行时决策**并显式传入：脚本**不**做 config slug/中文 name → CLI name 的映射。

**输出**：
```json
{
  "assigned": true,
  "target_agent": "linyaps-init-1",
  "target_agent_uuid": "353646a1-0adb-4e5f-be22-1de300ef4104",
  "timestamp": "2026-07-09 10:30:00",
  "agent_status": "idle"
}
```

**执行逻辑**：
1. 从 `for-multica/agent-config.json` 的 `assignment.agents[]` 筛选目标**能力**（决策依据，不充当 CLI name）：
   - `type=binary` → capabilities 包含 `project_init` 的 agent
   - `type=source` → capabilities 包含 `src_project_init` 的 agent
2. **按 CLI 真实 name 提取 uuid**：`agent_name` 必填，缺失则输出 `agent_name_required` 并跳过；随后调用 `get_agent_uuid_by_name()`（`multica agent list --output json` 的 `name → id`）解析**精确 agent UUID**。
3. **状态检查（热备方案）**：
   ```bash
   bash skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh \
     -w "<global.workspace 解析值>" \
     -n "<CLI 真实 agent name>" \
     -o json
   ```
   - `idle` → 记录"目标空闲，可立即指派"
   - `busy` → 记录警告"目标繁忙，仍发起指派（由平台排队）"，**不阻断**
   - 脚本报错 → 记录警告"无法查询状态，直接发起指派"，**不阻断**
4. **指派执行**：`ISSUE_ID=$(get_issue_id)` 精确 UUID；发送 UUID 绑定提到 `mention://agent/<uuid>` 的评论，再用 `--to-id <uuid>` 指派：
   ```bash
   ISSUE_ID=$(get_issue_id)
   if [ -n "$ISSUE_ID" ]; then
     MENTION="[@${TARGET_AGENT_NAME}](mention://agent/${TARGET_AGENT_UUID})"
     multica issue comment add "$ISSUE_ID" --content "${MENTION} 请为 ${pkgName} 进行项目初始化适配工作（${arch}）。下载地址：${src_url}" --output json
     multica issue assign "$ISSUE_ID" --to-id "${TARGET_AGENT_UUID}"
   fi
   ```
5. **记录指派日志**：写入 `data_dir/assignment.log`：
   ```
   assigned_init, <pkgName>, <agent_name>, <arch>, <timestamp>      # binary
   assigned_src_init, <pkgName>, <agent_name>, <arch>, source, <timestamp>  # source
   ```
6. multica CLI 不可用 → `cli_unavailable`；查不到 ISSUE_ID → `issue_id_not_found`；agent name 未匹配 → `agent_uuid_missing`。均记录警告，**不阻断**

### Action 3: `update_issue_status`

所有任务执行完毕后，根据统计更新 multica issue 状态。

**调用时机**：packer 完成阶段（原步骤 9）

**输入**：
```json
{
  "action": "update_issue_status",
  "agent_config_path": "for-multica/agent-config.json",
  "success_count": 8,
  "fail_count": 1,
  "pending_count": 2,
  "src_pending_count": 1
}
```

**输出**：
```json
{
  "issue_status": "审查完成",
  "comment_id": "025ee379-4e8d-469b-ab60-71003b25dd6d"
}
```

**执行逻辑**：
1. 根据统计判断 issue 状态：
   - 全部成功（`fail_count=0 && pending_count=0 && src_pending_count=0`）→ `"审查完成"`
   - 存在待初始化或待源码初始化任务 → `"进行中"`
   - 全部失败且无待初始化/待源码初始化 → `"阻塞"`
   - 部分失败（存在成功任务，且无待初始化） → `"部分完成"`
2. 通过 `multica issue comment add` 发送状态评论（评论 id 为精确 UUID）：
   ```bash
   ISSUE_ID=$(get_issue_id)
   if [ -n "$ISSUE_ID" ]; then
     # 读取 apt 阻塞明细（由 detect-apt-error.sh 写入），追加到评论末尾
     APT_BLOCKED=""
     if [ -f "skills/.apt-blocked-state" ]; then
       APT_BLOCKED="$(grep '^BLOCKED:apt:' "skills/.apt-blocked-state" | tr '\n' ';' | sed 's/;*$//')"
     fi
     CONTENT="结果：成功 ${success_count} / 失败 ${fail_count} / 待初始化 ${pending_count} / 待源码初始化 ${src_pending_count}"
     if [ -n "$APT_BLOCKED" ]; then
       CONTENT="${CONTENT} ｜ 阻塞明细: ${APT_BLOCKED}"
     fi
     COMMENT_ID=$(get_comment_id "$ISSUE_ID" "$CONTENT")
   fi
   ```
   > `skills/.apt-blocked-state` 中的记录形如 `BLOCKED:apt:dep-missing,<pkgName>` / `BLOCKED:apt:configure-failed,<pkgName>`，即由 `linglong-source-updater/scripts/detect-apt-error.sh` 检测 build 期 apt 异常后写入，使 issue 评论可看出 apt 错误根因。

## 指派目标配置

定义在 `for-multica/agent-config.json` 的 `assignment` 区段，本 skill **只读读取**，不自持配置。

### `assignment.agents[]`

| agent id | capabilities | 触发条件 |
|----------|-------------|---------|
| `init-tracker` | `project_init` | binary 任务找不到项目目录 |
| `linyaps-src-init-1` | `src_project_init` | source 任务找不到项目目录 |
| `linyaps-src-init-2` | `src_project_init` | source 任务找不到项目目录（热备） |

### `assignment.default_strategy`

| 场景 | handler | 目标 agent |
|------|---------|-----------|
| binary 项目未找到 | `assign-to-agent` | `init-tracker` |
| source 项目未找到 | `assign-to-agent` | `linyaps-src-init-1` |
| 构建失败 | `mark-failed` | 无（直接标记失败） |

### Action 4: `post_fix_log`

LLM 修复项目问题后，将修改日志发布为 issue comment。

**调用时机**：每个任务构建成功后（步骤 7.55），当 `data_dir/<pkgName>.fix-log.md` 存在时。

**输入**：
```json
{
  "action": "post_fix_log",
  "agent_config_path": "for-multica/agent-config.json",
  "pkgName": "com.example.app",
  "fix_log_path": "/data/linyaps-CI-output/2026-08-05.log/com.example.app.fix-log.md",
  "workspace": "linyaps"
}
```

**输出**：
```json
{
  "posted": true,
  "pkgName": "com.example.app",
  "timestamp": "2026-08-05 14:30:00"
}
```

**执行逻辑**：
1. 校验 `--fix-log-path` 指向的文件存在
2. 通过 `get_issue_id()` 查询当前 ISSUE_ID（精确 UUID）
3. 通过 `get_comment_id()`（`multica issue comment add ... --output json`）发布 fix log 内容为 issue comment
4. multica CLI 不可用或查询不到 ISSUE_ID → 记录警告，**不阻断**

## 约束

1. **仅 Packer 节点调用**：此 skill 不应被 init-tracker、linyaps-src-init 或其他节点类型使用
2. **与 agent-config.json 的 assignment 区段绑定**：目标 agent 列表、策略均从配置读取
3. **支持横向扩展**：`linyaps-packer-1`、`linyaps-packer-2` 均可调用，共享同一份 dispatch 逻辑
4. **`check_endpoint` 冷备未上线**：当前 `check_endpoint` 字段为 `null`，使用 `check-agent-status.sh` 脚本作为热备方案；后续上线后改由端点查询
5. **精确 UUID 管理（强制）**：
   - issue / agent / workspace 一律以 multica `--output json` 返回的 `id`（UUID）为唯一标识，禁止 `grep issue-\d+` / `comment-\d+` / `--to <slug>` / `@name` 模糊匹配
   - 指派必须用 `--to-id <agent-uuid>`；@mention 必须用 `[@name](mention://agent/<uuid>)`
   - **agent 一律「按 CLI 真实 name」提取 uuid**（`multica agent list --output json` 的 `name → id`）；config 的 `assignment.agents[].id`（slug/中文）**不**等于 CLI name，slug→CLI name 映射由 Agent（LLM）运行时决策并以 `--agent-name=<CLI name>` 显式传入，**脚本不硬编码映射**