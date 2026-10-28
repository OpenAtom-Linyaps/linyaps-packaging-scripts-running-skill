# Agent + Skills Token Boundary Optimization Implementation Plan

## Context

基于 `docs/20260909-agent-skills-token-workflow-analysis.md`，本方案优化 linyaps packaging agent 与 skills 的输出边界，阻止完整构建日志、无界 agent/目录扫描和重复上下文进入 LLM context，同时保持构建、重试、产物上传和 issue 状态回报行为不变。

已确认的高 token 来源包括：完整 `build.log`、全量编译日志、遍历所有 agents 介绍和遍历所有目录。source runner 的 `run_monitored_build` 曾把完整 `.build` 日志追加到总日志；binary runner 已使用有限 tail 摘要；monitor 已负责后台执行和状态查询。

## Approach

### 1. 建立统一上下文与输出契约

- 入口 agent 与子 skill 只返回任务级短摘要，不读取或粘贴完整构建日志、完整 agent 文档、完整目录树或未限定范围的工具输出。
- 固定摘要字段：`pkgName`、`type`、`status`、`elapsed`、`attempts`、`artifact`、`error_summary`、`log_path`。
- 完整日志只保存在本地 `OUTPUT_DIR`/任务日志路径；`error_summary` 由子 skill 生成，入口 agent 不自行 `cat` 日志。
- agent 发现只查询当前任务类型需要的 skill 和匹配能力的 agent 元数据。
- 项目定位只使用 `pack_repo_dir` 和当前 `pkgName`；产物查找只使用目标项目目录；失败只返回受限错误摘要。
- 保持 precheck、同步、任务分组、构建、上传和 issue 状态回报顺序不变。

### 2. 构建日志本地化

- source build/export 通过 `monitor-build.sh --log <local-file>` 将 stdout/stderr 写入本地日志。
- 删除完整 `.build` 日志追加到总日志的行为。
- 每次 build/export attempt 使用不重复的日志路径。
- 总日志只写阶段、attempt、退出码和日志路径。
- 正常完成不主动读取日志正文。
- 异常诊断规则：先读取末尾最多 100 行；无法判定时再读取关键模式及前后文；诊断总量最多 200 行。关键模式包括 `error`、`failed`、`fatal`、`undefined reference`、`Unable to locate package`、`dpkg: error`。
- 保持 `ll-builder build`、`ll-builder export`、timeout、重试、产物检查、fix-log 发布和最终计数语义不变。
- binary runner 保留有限 tail 摘要模式，禁止全文件读取。

### 3. monitor-build 状态边界

- `start/status/wait` 只输出状态字段、PID、耗时、timeout、退出码和日志路径。
- 构建正文始终保存在 `--log` 指定的本地文件。
- 保持退出语义：`status` 完成返回 0、运行中返回 1；`wait` 返回构建退出码，超时返回 124；状态文件缺失返回 3。
- 只有异常状态或用户明确要求诊断时，才读取日志的有界尾部或关键区域。

### 4. multica agent 边界

- `for-multica/agent.md` 明确 multica agent 是初始化/指派 agent，不是通用目录探索 agent。
- 只读取传入 issue、当前 `type` 匹配的能力记录和当前 `pkgName` 项目。
- 输出单条结构化摘要：`pkgName`、`type`、`status`、`agent_name`、`issue_id`、`project_dir`、`log_path`、`error_summary`。
- 禁止输出所有 agent 说明、所有 workspace、目录树或完整 API 响应。
- 保留精确 UUID、可信来源、issue 绑定和 dispatch SKILL 责任边界。
- 初始化/构建 stdout/stderr 重定向到本地日志；异常按 100/200 行规则诊断；fix-log 只发布当前任务指定文件。

### 5. multica dispatch 边界

- 能力筛选只返回匹配 agent 的 CLI name/UUID、匹配能力、当前状态和 dispatch 结果。
- `dispatch_project_not_found`、`update_issue_status`、`post_fix_log` 只返回短结构化结果。
- 原始 API 响应不得输出到 LLM context，只解析所需 UUID、status 和 comment_id。
- 保留 `get_agent_uuid_by_name`、`get_issue_id`、`get_workspace_id` 的精确 UUID 校验。
- 保留 busy/running 不阻断、空候选、CLI 不可用和 UUID 错误的既有非阻断语义。
- `post_fix_log` 只读取传入的 `FIX_LOG_PATH`，不得混入构建日志或其他任务日志。

### 6. 防回归验证

- 使用临时 fixture 和 mock 命令，不运行真实构建、网络调用或 Multica API。
- 验证 200 行以上构建输出完整保存在本地日志，正常输出不包含构建正文。
- 覆盖 build 成功、build 失败重试、export 失败、timeout 和状态文件缺失。
- 验证 monitor 的状态输出和退出码语义。
- 验证不存在包名和多个相邻项目时只输出受限定位结果。
- 验证 multica 能力匹配、busy、空候选、UUID 错误和 fix-log 发布只返回短结果。
- 没有新的 analyzer 聚合统计时，只报告输出行数/字节边界，不声称具体 token 降幅。

## Critical files & anchors

- `agents/linyaps-packaging-runner.agent.md`：入口分派、上下文和结果汇总契约。
- `for-multica/agent.md`：multica agent 职责、issue/agent/workspace 约束和输出边界。
- `skills/linglong-source-updater/scripts/run_tasks.sh`：source 日志重定向、build/export 重试和错误摘要。
- `skills/linglong-source-updater/scripts/monitor-build.sh`：后台构建、状态文件和 status/wait 输出协议。
- `skills/linyaps-multica-packer-dispatch/SKILL.md` 与 `scripts/dispatch.sh`：能力筛选、UUID 查询、指派、状态更新和 fix-log 输出。

## Verification commands

```bash
bash -n skills/linglong-source-updater/scripts/run_tasks.sh
bash -n skills/linglong-source-updater/scripts/monitor-build.sh
bash -n skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh
python3 -m pytest -q tests/test_dispatch_uuid.py
```

额外 smoke test 使用临时目录和 mock 命令生成 220 行输出，确认完整日志保留在本地文件，而 `monitor-build.sh start/wait` 只返回状态和日志路径。

## Assumptions & contingencies

- 完整日志保留在本地，不删除日志，不改变构建命令输入。
- 末尾诊断上限固定为 100 行，关键区域总上限固定为 200 行。
- 如果发现消费者依赖旧总日志中的完整正文，应迁移为读取明确的独立日志路径，不通过兼容别名继续输出完整正文。
- 若公共项目定位函数已经限制搜索范围，只收紧调用方输出，不重复实现路径解析。
- multica 平台失败继续遵循现有非阻断规则；issue 身份、可信来源和 UUID 校验失败继续遵循现有阻断语义。
