---
name: linyaps-packaging-precheck
description: >
  包装环境前置检测 SKILL。在进入打包流程前统一检查 CLI 工具可用性、
  网络连通性、配置完整性和脚本完整性。为 workflow 和 agent 提供门控依据。
  Agent 和其它技能通过 skill() 或直接调用 precheck.sh 使用。
argument-hint: '[--config=<path>] [--workspace=<slug>] [--checks=<list>] [--output=<path>]'
user-invocable: false
---

# linyaps 包装环境前置检测 SKILL

在进入打包流程前，统一执行 CLI 工具、网络、配置、脚本四类可作性检测。
检测不通过时立即终止流程，避免在缺失依赖的环境下空跑。

## 目录约定

- 入口脚本：`skills/linyaps-packaging-precheck/scripts/precheck.sh`
- 共享库：`skills/linyaps-packaging-precheck/scripts/common.sh`
- 上游信息查询：`skills/linyaps-packaging-precheck/scripts/query_upstream.sh`

## 调用方式

### 方式 A：Workflow / CLI 直接调用

```bash
# 全量检查
bash skills/linyaps-packaging-precheck/scripts/precheck.sh \
  --config=for-multica/agent-config.json \
  --workspace=linyaps

# 指定检查项子集
bash skills/linyaps-packaging-precheck/scripts/precheck.sh \
  --checks=cli_tools,network_s3

# 输出到文件
bash skills/linyaps-packaging-precheck/scripts/precheck.sh \
  --output=<data_dir>/precheck_result.json
```

### 方式 B：Agent 通过 `skill()` 调用

```
result = skill("linyaps-packaging-precheck", {
  config: "for-multica/agent-config.json",
  workspace: "linyaps"
})
```

## 检查项清单

| 检查 ID | 检测内容 | 判定标准 | 前置依赖 |
|---------|---------|---------|---------|
| `cli_tools` | ll-builder, rclone, curl, python3, git, file, jq | `command -v` 均存在 | 无 |
| `config_validity` | agent-config.json 解析性、路径中无 `${tag}` 残留 | JSON 解析成功 + 无未替换占位符 | 无 |
| `network_s3` | S3 存储桶列表可达 | `rclone lsd cicd2:/linyaps/packaging-CI-output/` 成功 | rclone |
| `network_webhook` | webhook 端点连通性 | HTTP 2xx/3xx | curl |
| `network_upstream` | n8n upstream API 可达 | HTTP 2xx/3xx | curl |
| `script_integrity` | 所有 skill 脚本在预期路径存在 | 约 20 条路径均 `-f` 通过 | 无 |

## 输出

```json
{
  "passed": false,
  "timestamp": "2026-07-13 10:30:00",
  "summary": {
    "total": 6,
    "passed": 5,
    "failed": 1,
    "skipped": 0
  },
  "checks": [
    {"name": "cli_tools", "status": "passed", "message": "all 7 CLI tools available"},
    {"name": "network_s3", "status": "failed", "message": "rclone lsd failed: ..."}
  ]
}
```

- 退出码 0 = `passed=true`，全部通过
- 退出码 1 = `passed=false`，存在失败项

## 边界说明

本 SKILL **仅做环境可作性检测**，不涉及业务级验证：

| 归 precheck | 由下游 skill 负责 |
|------------|-----------------|
| CLI 工具可用性 | Agent 状态查询（`check-agent-status.sh`，dispatch 使用） |
| 网络连通性（S3/webhook/upstream） | 任务 JSON 字段完整性（binary-runner / source-updater 各自校验） |
| 配置 JSON 可解析 | 初始化来源检测（`detect_init_source.sh`，dispatch 使用） |
| 所有脚本路径存在 | 项目目录预验证（`validate_projects.sh`，binary-runner 使用） |
| 上游数据查询（`query_upstream.sh`） | — |

## 约束

1. **只读检测**：本 SKILL 不创建、修改、删除任何文件，不发送网络写请求
2. **无副用作**：即使 `network_webhook` 和 `network_upstream` 检测也只是 HEAD/GET 探测，不影响远端状态
3. **独立运行**：不依赖其它 SKILL 的输出结果