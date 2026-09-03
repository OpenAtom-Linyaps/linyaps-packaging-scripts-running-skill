# Issue 68 Agent/Skill 影响修复实施方案

## 1. 背景

当前 dispatch skill 的 `detect_init_source`、`dispatch_project_not_found`、`update_issue_status`、`post_fix_log` 以及共享 `get_issue_id` 会通过 `multica issue list --limit 1` 获取 issue UUID，无法绑定平台 handoff 注入的当前任务，可能将评论、mention、指派和状态更新发送到错误 issue。

## 2. 目标

- 将当前任务 issue UUID 捕获一次，并通过 `MULTICA_ISSUE_TASK_ID` 在 agent、子 skill 和 runner 间不可变传递。
- 所有 issue、agent、workspace、comment、thread 和 mention 操作使用精确 UUID。
- 身份缺失、无效、不一致或 CLI 校验失败时统一返回结构化 `blocked`，且不发送副作用 API 请求。
- 删除 `issue list --limit 1` 的身份 fallback。

## 3. 实施步骤

### 3.1 Agent 身份契约

修改 `for-multica/agent.md` 与 `agents/linyaps-packaging-runner.agent.md`：

1. 从平台注入的 `Your assigned issue ID` 或 `multica issue get <UUID>` 参数捕获任务 UUID。
2. 严格校验 UUID 后设置并导出 `MULTICA_ISSUE_TASK_ID`。
3. 只有 `LIN-xxxx` 时，执行精确 identifier 匹配；零条或多条匹配均阻断。
4. 禁止从旧评论、workspace 状态、最近 issue 或列表首项推断身份。
5. 将变量传递给全部子 skill、runner 和最终状态回报。

### 3.2 共享身份入口

修改 `skills/linyaps-multica-packer-dispatch/scripts/common.sh`：

- `get_issue_id` 只读取并校验 `MULTICA_ISSUE_TASK_ID`。
- 缺失返回 `issue_id_required` 和非零退出码。
- 无效 UUID 返回结构化失败，不调用 issue API。
- 移除 `multica issue list --limit 1`。
- 保留 agent、workspace、comment UUID 校验，并增加当前 issue 一致性校验所需的 JSON 解析。

### 3.3 Dispatch action 契约与门控

修改 `SKILL.md`、`dispatch.sh`、`detect_init_source.sh`：

- 四个 action 固定使用任务 UUID：`detect_init_source`、`dispatch_project_not_found`、`update_issue_status`、`post_fix_log`。
- comment、assign、status、fix-log API 调用前完成身份和任务上下文校验。
- 校验 issue、pkgName、arch、type、目标 agent UUID、comment parent/thread 和 mention URI。
- 指派必须使用 `--to-id <uuid>`，mention 必须使用 `mention://agent/<uuid>`。
- 缺失 UUID、CLI 失败、busy agent、上下文不匹配或无效 parent/thread 均返回 `blocked`，不得继续调用 API。

### 3.4 Runner 与入口传播

修改 `csv_to_json.sh`、binary runner、source runner 及入口调用链：

- 显式继承和传递 `MULTICA_ISSUE_TASK_ID`。
- 初始化来源 dispatch、fix-log 发布和最终状态回报均绑定该 UUID。
- 缺少身份时禁止发布未绑定评论，并进入阻塞终态。

### 3.5 失败终态

- delegated task 空输出、身份不一致、agent UUID 缺失、busy、项目目录与 pkgName 不匹配统一记录为 `blocked`。
- 禁止依据 commit 或历史状态猜测初始化已完成。
- 只有 pkgName 精确匹配且身份校验通过时才允许继续。

## 4. 测试与验收

扩展 `tests/test_dispatch_uuid.py`，覆盖：

- 任务 UUID 优先级和严格 UUID 校验。
- 禁止 `issue list --limit 1` fallback。
- 跨 issue、跨 pkgName 的 comment/assign 拒绝。
- mention UUID、目标 agent UUID 和 parent/thread 校验。
- 缺少任务环境变量时的结构化 blocked 结果及零 API 请求。
- binary/source runner 的任务 UUID 传播。

验证命令：

```bash
pytest -q tests/test_dispatch_uuid.py
```

另用 fake `multica` 验证多 issue 返回时始终使用 `MULTICA_ISSUE_TASK_ID`，并验证所有 blocked 场景没有 `issue comment add` 或 `issue assign` 请求。

## 5. 范围与约束

- 只修改本仓库 agent、skill、script 和 test，不修改 Multica 平台 CLI。
- 不保留兼容性的列表首项 fallback。
- 若 CLI 无法提供必要的一致性字段，则以平台注入 UUID 加任务参数校验作为最低安全门；无法验证时阻断。
