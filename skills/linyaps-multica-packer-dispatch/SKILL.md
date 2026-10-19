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

**配置接收**：`agent_config_path` 由调用方通过 `skill()` 传入。本 skill 同时必须继承已由 agent handoff 设置并导出的 `MULTICA_ISSUE_TASK_ID`（严格 UUID）；缺失、无效或与当前 issue 不一致均返回 `blocked`，不发送任何 comment/assign/status API 请求。

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

**消费者**：packer agent 中步骤 7.6（`status_upload.sh` vs `status_upload_initOnly.sh` 选择）。两个上传脚本均启 exec-proof 门禁：binary 任务成功上报必须带 `run_tasks.sh` 生成的 exec-proof（constraints §6），source 任务须显式传 `TASK_TYPE=source`；init-source 任务因属 source 类型而豁免，但仍可用 initOnly 脚本的初始化专用 webhook 端点。

1. 从 `MULTICA_ISSUE_TASK_ID` 读取并严格校验当前 issue UUID；禁止使用 `multica issue list --limit 1` 或评论内容推断身份。
2. 通过 `multica issue comment list "<ISSUE_ID>" --output json` 获取评论并匹配初始化来源。
3. 优先级匹配：`linyaps-init` >> `linyaps-src-init`。
4. CLI 查询失败、身份缺失或任务上下文不一致 → `blocked`，不继续后续动作。

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
  "agent_name": "<可选：CLI 真实 agent name，覆盖脚本端选择>"
}
```

- `type`：`"binary"` 或 `"source"`，作为**精确类型过滤**候选池（`agent.type == $TYPE`）
- `agent_name`**：可选覆盖。传入时**跳过脚本端候选池选择**，直接按 CLI 真实 name 解析 uuid 并指派（保留 LLM 运行时显式指派能力）；缺省时由脚本端按 `type` 过滤 + idle 优先 + 负载感知决胜自动选择。

**输出**：
```json
{
  "assigned": true,
  "target_agent": "linyaps-init-1",
  "target_agent_uuid": "353646a1-0adb-4e5f-be22-1de300ef4104",
  "reason": "idle_first",
  "id_fallback": false,
  "timestamp": "2026-07-09 10:30:00",
  "agent_status": "idle"
}
```

- `reason`：选择路径，取值 `agent_name_override` / `idle_first` / `load_aware` / `id_fallback` / `no_candidate` / `agent_uuid_missing`
- `id_fallback`：布尔值，`true` 表示因候选 uuid 全部无效退回 `cfg_id` 作 `--to-id`（违反 issue-68 约束的紧急降级，部署须回填真实 uuid 以消除该路径）

**执行逻辑**：
1. **候选池筛选**：从 `for-multica/agent-config.json` 的 `assignment.agents[]` 按**精确 `type` 字段**过滤（`agent.type == $TYPE`），emit `cfg_id<TAB>cfg_uuid<TAB>cfg_name`。
2. **选择路径**（二选一）：
   - **A. `--agent-name` 覆盖路径**（`agent_name` 非空）：跳过候选池选择，按 CLI 真实 name 调 `get_agent_uuid_by_name()` 解析精确 UUID。`reason=agent_name_override`。
   - **B. 脚本端候选池选择**（`agent_name` 省略，默认路径）：
     1. 校验候选 uuid：`is_uuid(cfg_uuid)` → `valid_list` / `invalid_uuid_list`
     2. `valid_list` 非空 → 查询每个候选状态（`check-agent-status.sh -u <uuid>`），分 `idle_list` / `busy_list`：
        - `idle_list` 非空 → 随机抽一个，`reason=idle_first`
        - `idle_list` 空 → 取 `running_count` 最小者，同负载随机抽一个，`reason=load_aware`
     3. `valid_list` 空 + `invalid_uuid_list` 非空 → id fallback：随机抽一个用 `cfg_id` 作 `--to-id`，`reason=id_fallback`、`id_fallback=true`（**违反 issue-68 `--to-id <uuid>` 约束，紧急降级路径，部署须回填真实 uuid 以消除**）
     4. 两者皆空 → `reason=no_candidate`，跳过指派
3. **状态检查**：
   - 覆盖路径：调 `check-agent-status.sh -n <name>` 查询一次
   - 脚本端 valid_list 路径：选择循环已查状态，复用 `PICKED_AGENT_STATUS`，不重复查询
   - id_fallback 路径：uuid 无效，状态不可查，记 `unknown`
4. **指派执行**：`ISSUE_ID=$(get_issue_id)` 精确 UUID：
   - 正常路径（`id_fallback=false`）：发送 `[@name](mention://agent/<uuid>)` 评论 + `multica issue assign --to-id <uuid>`
   - id_fallback 路径：跳过 mention（uuid 无效无法构造 URI）+ `multica issue assign --to-id <cfg_id>`（紧急降级）
5. **记录指派日志**：写入 `data_dir/assignment.log`：
   ```
   assigned_init, <pkgName>, <agent_name>, <arch>, <timestamp>      # binary
   assigned_src_init, <pkgName>, <agent_name>, <arch>, source, <timestamp>  # source
   ```
6. multica CLI 不可用 → `cli_unavailable`；查不到 ISSUE_ID → `issue_id_not_found`；覆盖路径 name 未匹配 → `agent_uuid_missing`。均记录警告，**不阻断**

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

| agent id | uuid (占位) | type | capabilities | 触发条件 |
|----------|-------------|------|-------------|---------|
| `init-tracker` | `…0001` | `binary` | `project_init` | binary 任务找不到项目目录 |
| `linyaps-src-init-1` | `…0002` | `source` | `src_project_init` | source 任务找不到项目目录 |
| `linyaps-src-init-2` | `…0003` | `source` | `src_project_init` | source 任务找不到项目目录（热备） |

> `uuid` 字段为占位值（`00000000-0000-4000-8000-00000000000X`），部署后须回填真实 multica agent UUID。`type` 为脚本端候选池过滤的精确字段（`agent.type == $TYPE`）。packer 类（`linyaps-packer-1/2`）与 `upstream-tracker` 不参与 init 指派，故无 `type` 字段。

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
5. **精确 UUID 管理（强制）+ 脚本端候选池选择**：
   - issue / agent / workspace 一律以 multica `--output json` 返回的 `id`（UUID）为唯一标识，禁止 `grep issue-\d+` / `comment-\d+` / `--to <slug>` / `@name` 模糊匹配
   - 指派必须用 `--to-id <agent-uuid>`；@mention 必须用 `[@name](mention://agent/<uuid>)`
   - **默认路径由脚本端候选池选择**：按 `agent.type == $TYPE` 精确过滤 + idle 优先 + 负载感知决胜（同负载随机抽），候选 uuid 须通过 `is_uuid()` 校验
   - **`--agent-name` 为可选覆盖**：传入时跳过候选池选择，按 CLI 真实 name 调 `get_agent_uuid_by_name()` 解析 uuid（保留 LLM 运行时显式指派能力）
   - **id_fallback 紧急降级路径**：候选 uuid 全部无效时退回 `cfg_id` 作 `--to-id`，**违反 issue-68 `--to-id <uuid>` 约束**，仅作紧急降级存在；部署须回填真实 multica agent UUID 到 config `uuid` 字段以消除该路径。id_fallback 路径跳过 mention（uuid 无效无法构造 `mention://agent/<uuid>`）

## 输出与日志边界

- `dispatch_project_not_found` 只返回匹配能力、CLI agent name/UUID、agent 状态和 `assigned/reason`；不得输出完整 agent 列表、配置正文或 API 原始响应。
- `update_issue_status` 只返回 `issue_status` 与 `comment_id`；`post_fix_log` 只读取传入的 `FIX_LOG_PATH` 并返回 `posted`、`pkgName` 和时间戳。
- CLI 原始响应必须留在脚本内部解析或重定向；构建日志不得通过本 skill 发布，fix-log 之外的文件不得读取。