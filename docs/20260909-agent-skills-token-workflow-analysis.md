# Agent + Skills 高 Token Workflow 分析报告

## 分析范围

本报告分析 `examples/20260904-top10-token-actions-independent.human.md` 第 3 节列出的高 token 行为，并映射到当前仓库的 agent、SKILL 与脚本 workflow。

使用的分析器：

```text
/home/ut005422@uos/.agents/skills/agentlytics-session-logs-analyze-skill-v1.2026.9.3.1/scripts/session_analyze.py
```

已执行 `deps-check`；环境依赖检查通过。仓库内不存在 `scripts/session_analyze.py`，因此本次使用 skill 目录中的真实 CLI。输入 session 仅作只读分析。

## Top 10 总览

十个 session 总 token 为 **128,185,807**。该总量来自已有独立报告，并以可解析 session 的 `stats` 输出核对。

| 排名 | Session | 模型 | 总 token | cache 命中率 |
|---:|---|---|---:|---:|
| 1 | `01a039e8-a448-77b7-9d8b-bf79c61bbf10` | gpt-5.6-luna | 24,780,832 | 70.97% |
| 2 | `01a039ae-1b9c-729d-81b4-d9510406ee61` | gpt-5.6-luna | 18,193,576 | 无法解析 |
| 3 | `01a03a55-3bae-75d0-8884-8cb3d3278f64` | gpt-5.6-luna | 14,058,437 | 70.68% |
| 4 | `01a03a8e-3f37-7462-8610-45acc8e933eb` | deepseek-v4-flash | 11,927,502 | 0% |
| 5 | `01a03ab3-91ab-7733-ae1d-2e2bf5508093` | gpt-5.6-luna | 11,434,525 | 76.43% |
| 6 | `01a039ca-3586-7278-8838-0ca1bc74deaa` | gpt-5.6-luna | 10,075,880 | 48.62% |
| 7 | `01a03a54-3a43-758d-b8b8-14217d4c47c8` | gpt-5.6-luna | 9,864,282 | 59.38% |
| 8 | `01a03954-392a-702c-8465-f986e18e5de3` | deepseek-v4-pro | 9,722,197 | 0% |
| 9 | `01a0426c-f3c3-749e-8fe8-8e057dcd3eca` | gpt-5.6-luna | 9,269,533 | 71.14% |
| 10 | `01a039a3-2a98-7488-b1c5-74a2bee53623` | gpt-5.6-luna | 8,859,215 | 39.12% |

## 高 token 行为与代码区域

### 1. 完整 `build.log` 注入上下文

**session 证据**

- `01a039e8-a448-77b7-9d8b-bf79c61bbf10.full.json:L5420`
- 报告记录：构建阶段输出完整 `build.log`，没有使用 `tail` 截断。

**对应代码**

- `skills/linglong-binary-runner/scripts/run_tasks.sh:151-163,183-191`
  - 构建输出写入 `${OUTPUT_DIR}/${pkg_name}.log`。
  - 成功路径输出 `tail -5`，失败路径输出 `tail -10`。
- `skills/linglong-source-updater/scripts/run_tasks.sh:206-222`
  - `run_monitored_build()` 将构建输出写入 `${log}.build`。
  - 构建结束后执行 `cat "$blg" >> "$lg"`，把完整构建日志追加到总日志。
- `skills/linglong-source-updater/scripts/run_tasks.sh:224-279`
  - 执行 `ll-builder build` 与 `ll-builder export`。
  - 失败路径输出 `tail -n 100`，但完整日志已先写入总日志。

**结论**

主要风险是调用方或 LLM 后续读取完整总日志，而不是 runner 的最终 `tail` 摘要。上下文大小随编译日志长度线性增长。

证据等级：session 行为由已有报告确认；日志产生与聚合机制由源码确认；具体 session 调用参数未完全重新复核。

### 2. 不当监控导致全量编译日志进入上下文

**session 证据**

- `01a039ae-1b9c-729d-81b4-d9510406ee61.full.json:L1014→L1019`
- 报告记录：监控方案不当，使编译 log 全量注入 context。

该 session 当前无法被 analyzer 解析，错误为：

```text
JSONDecodeError: Expecting ',' delimiter: line 1019 column 8
```

**对应代码**

- `skills/linglong-source-updater/scripts/monitor-build.sh:1-23`
  - 设计目标是后台运行构建并周期查询状态，避免 idle watchdog。
- `monitor-build.sh:63-115`
  - `start` 使用 `timeout "$timeout" "$@" >"$log" 2>&1`，将完整构建输出写入日志文件。
- `monitor-build.sh:117-155`
  - `status` 只输出运行状态、耗时、PID 或退出码。
- `monitor-build.sh:157-187`
  - `wait` 等待状态文件完成并返回构建退出码，不主动输出构建日志。

**结论**

监控器的状态输出本身是小体积摘要。token 膨胀发生在监控 workflow 额外读取日志，或把日志内容拼接到后续 agent 消息时。源码能确认完整日志文件会生成，但不能单独证明每次监控都会把完整日志送入 LLM。

证据等级：session 行为由已有报告确认；监控器行为由源码确认；原始 session 因 JSON 格式错误无法重新验证。

### 3. 遍历所有 agents 介绍

**session 证据**

- `01a039e8-a448-77b7-9d8b-bf79c61bbf10.full.json:L5751`
- 报告记录：异常遍历所有 agents 介绍。

**正常 workflow**

- `agents/linyaps-packaging-runner.agent.md:106-172`
  - Phase 1 读取 `agent-config.json`、执行 precheck、同步项目仓库并一次性加载统一约束。
  - 文档明确要求约束只加载一次、不重复展开。
- `agents/linyaps-packaging-runner.agent.md:174-195`
  - 根据 `tasks[].type` 分组，仅调用 binary 或 source 子 skill。
- `skills/linyaps-multica-packer-dispatch/SKILL.md:92-121`
  - 按任务类型和能力筛选目标 agent，并按真实 CLI name 解析精确 UUID。

**结论**

正常 packer 主链不需要读取所有 agent 的完整介绍；只需读取配置中的能力信息并选择目标 skill。全量 agent 介绍属于范围失控的 session 侧行为。当前仓库未找到与该行为完全一致的递归遍历命令，因此不能把它归因于入口 agent 文档必然触发。

### 4. 错误遍历所有目录

**session 证据**

- Geany：`01a03a55-3bae-75d0-8884-8cb3d3278f64.full.json:L332→L337`
- Mkvtoolnix GUI：`01a03ab3-91ab-7733-ae1d-2e2bf5508093.full.json:L306→L321`
- 报告均标记为错误遍历所有目录。

**对应代码**

- `skills/linglong-binary-runner/scripts/run_tasks.sh:108-115`
  - 调用 `find_project_dir "$pkg_name" "$PACK_REPO_DIR"`。
- `skills/linglong-source-updater/scripts/run_tasks.sh:109-116`
  - 调用 `find_source_project_dir "$pkg_name" "$PACK_REPO_DIR"`。
- `skills/linglong-source-updater/scripts/run_tasks.sh:282-290`
  - 产物查找限制在目标项目单层目录：`find "$project_dir" -maxdepth 1 -name "*.layer"`。
- `agents/linyaps-packaging-runner.agent.md:143-161`
  - `pack_repo_dir` 是固定共享目录，执行同步与项目定位。

**结论**

正常范围应是指定 `pack_repo_dir` 中的目标项目，以及目标项目内必要文件。全仓库无界扫描不是这些脚本的正常输出，可能来自项目定位失败、路径解析错误或调用方排查。大量无关路径会进入工具输出并在后续消息中重复携带。

## 完整 workflow

```text
linyaps-packaging-runner
  ├─ Phase 1
  │   ├─ 读取 agent-config.json
  │   ├─ precheck
  │   ├─ query_upstream（仅缺字段时）
  │   ├─ 同步 pack_repo_dir
  │   └─ 一次性加载 constraints skill
  ├─ Phase 2
  │   ├─ 按 tasks[].type 分组
  │   ├─ binary → linglong-binary-runner
  │   │   └─ run_task → pak_linyaps.sh → build_with_retry → tail 摘要
  │   └─ source → linglong-source-updater
  │       └─ run_source_task
  │           ├─ YAML 校验/源码下载/版本更新
  │           ├─ monitor-build.sh start
  │           ├─ monitor-build.sh wait
  │           ├─ cat .build log → 总日志
  │           └─ build/export 重试
  └─ Phase 3
      ├─ 合并子任务结果
      ├─ status_upload
      ├─ update_issue_status
      └─ post_fix_log
```

## Dispatch 相关区域

- `skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh:77-88`：强制解析 issue UUID。
- `dispatch.sh:111-149`：按能力筛选 agent，按真实 CLI name 解析 UUID。
- `dispatch.sh:152-180`：`busy`/`running` 状态仍继续 dispatch，由平台排队，不硬阻断。
- `dispatch.sh:182-227`：发送 mention、执行 issue assign、写入 assignment log。
- `dispatch.sh:229-256`：汇总成功、失败、待初始化数量并计算 issue 状态。
- `dispatch.sh:258-294`：读取 fix log 并发布 issue comment。

这些 dispatch 操作会增加调用次数和状态上下文，但当前证据不足以把它们认定为 Top 10 token 的主要根因。主要根因仍是大型日志和无界目录/agent 输出。

## 验证状态与限制

### 成功

- `deps-check` 成功。
- 十个 session 中九个 `verify -v` 返回 `VALID`。
- 九个可解析 session 的 `stats` 成功输出 token、cache、消息角色和模型统计。
- 已核对入口 agent、binary runner、source runner、monitor-build 和 dispatch 源码区域。

### 无法重新验证

```text
examples/top10-sessions-data/01a039ae-1b9c-729d-81b4-d9510406ee61.full.json
```

错误：

```text
JSONDecodeError: Expecting ',' delimiter: line 1019 column 8
```

因此该 session 的 `stats`、`tools`、`by-message`、`by-segment`、`timing` 无法重新执行。

本次未重新聚合十个 session 的完整 `tools --order`、`by-message`、`by-segment`、`timing` 输出；未补写未经 CLI 证实的工具频次、cache 或 segment 数字；未运行构建、Multica API 或修改输入数据。

## CLI 操作记录

```bash
python3 /home/ut005422@uos/.agents/skills/agentlytics-session-logs-analyze-skill-v1.2026.9.3.1/scripts/session_analyze.py deps-check

python3 /home/ut005422@uos/.agents/skills/agentlytics-session-logs-analyze-skill-v1.2026.9.3.1/scripts/session_analyze.py verify <session>.full.json -v

python3 /home/ut005422@uos/.agents/skills/agentlytics-session-logs-analyze-skill-v1.2026.9.3.1/scripts/session_analyze.py stats <session>.full.json
```
