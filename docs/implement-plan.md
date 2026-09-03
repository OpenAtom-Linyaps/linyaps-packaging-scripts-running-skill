# 实施计划：apt 异常检测与终止阻塞

## 1. 背景
来自 `examples/issue-59.analyze-report.md`（#59、#55 分析报告）：
- **issue #59**：`buildext.apt.{build_depends,depends}` 含仓库不存在的包 → 整个 apt 事务全失败（all-or-nothing），一个都装不上。
- **issue #59**：个别 deb configure 失败（如 `sane-utils` 的 `groupadd/useradd`）→ apt configure 卡住 → 后续装不上；agent 现用 `|| true`/`dpkg --configure -a || true` 绕过（report L440-453），而非终止阻塞。

用户澄清：
- 该 SKILL **不负责逐个依赖的 apt 可用性预检**，只负责监控 build 阶段 apt 状态是否异常，命中即**终止并阻塞**。
- 终止+阻塞（匹配 #59），不重试、不绕过 `|| true`/`dpkg --configure -a || true`；写入 feedback「apt 配置失败需人工/阻塞」并阻塞该 pkgName。阻塞需进入上报链路。

## 2. 决策（已与用户确认）
- 检测到 build 期 apt 异常 → **终止并阻塞**（不再重试、不再绕过），并 mark 该 pkgName 阻塞。
- apt 错误标签落点：`detect-apt-error.sh` 产出的类型串写入 `linyaps-multica-packer-dispatch` 的 `update_issue_status` 评论（issue 评论，经 `multica issue comment add` 发送），可见 apt 错误根因。
- 依你上一轮所选：**走派 SKILL issue 评论**（非 webhook）。故 apt 类型在 SKILL 的 `update_issue_status` 中展示。

## 2. 修改清单

### 2.1 新增 `skills/linglong-source-updater/scripts/detect-apt-error.sh`（全权负责 apt 异常扫描+判定，`check-build-active.sh` 不动）
扫描 build 阶段 apt 错误标记：
- `E: Unable to locate package`（依赖缺失 → apt 整体失败）
- `Sub-process returned an error`、`dpkg: error processing package`、`not fully configured`、`postinst`、`groupadd` 等（deb 配置失败 → 阻塞）
命中即输出阻塞判定（含类型标签 `apt:dep-missing` / `apt:configure-failed`）并写 blocked 态。

### 2.2 阻塞/重试逻辑加固（`for-multica/agent.md`，Step S-5 / Step 7 / Step 9）
在 build 逻辑接通 `detect-apt-error.sh` 检测。命中 apt 异常时**不再重试、不再绕过**（`|| true` / `dpkg --configure -a || true` 一律禁止），直接判阻塞并入阻塞统计。

### 2.3 issue 评论透出 apt 类型（`skills/linyaps-multica-packer-dispatch/SKILL.md` → Action 3 `update_issue_status`）
在状态（统计）评论末尾追加附注，带上 `detect-apt-error.sh` 输出的类型标签（如 `阻塞明细: apt-config-wailed, <pkgName>`），使 issue 评论可看出 apt 错误。
</think>实施计划已写入文档。

<｜DSML｜tool_calls>
<｜DSML｜invoke name="bash">
<｜DSML｜parameter name="command" string="true">test -f /media/ut005422/Data-2/linyaps-project/ai-labs/docs.an-xie-shou.md && echo "文件存在" || echo "不存在"
