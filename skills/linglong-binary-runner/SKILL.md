---
name: linglong-binary-runner
description: '透過 pak_linyaps.sh 自動執行 linyaps 二進制打包。用於已適配便捷打包腳本的項目（特徵：目錄下有 pak_linyaps.sh），不感知 linglong.yaml。使用場景：批量執行 JSON/CSV 任務中的 binary 類型打包。'
argument-hint: '<task.json> [--agent-config-path=<path>]'
user-invocable: false
---

# linyaps Binary 打包執行器

當 agent 分派 `type=binary`（或未指定 type）的任務時使用此 skill。

## 脚本与输入

- 执行入口：`skills/linglong-binary-runner/scripts/run_tasks.sh`
- 项目验证：`validate_projects.sh`
- 构建进度：`check-build-active.sh`
- 架构映射：`skills/config/arch_mapping.json`

输入为标准任务 JSON，`tasks[].type` 为 `binary` 或未指定；可传 `--agent-config-path=<path>`。具体配置字段由配置文件和公共 constraints skill 提供，不在此复制 JSON 模板。

## 执行流程

解析配置 → 初始化目录 → 每项提取版本、验证架构、下载资源、精确定位 `pak_linyaps.sh`、检测 `--build_tmp_dir` 支持并调用脚本 → 输出短结果。

## 类型约束

- 所有打包操作必须通过 pak_linyaps.sh（由 run_tasks.sh 驱动）；入口与门禁规则见 linyaps-packaging.constraints §6。
- 公共路径、同步、缓存、重试/超时和日志边界只引用 `skills/linyaps-packaging.constraints/SKILL.md`。

构建期间每 10 分钟独立调用 `check-build-active.sh`；仍有构建进程时不得判定超时，不得仅凭退出码 124 判失败。

