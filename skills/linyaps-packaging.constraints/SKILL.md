---
name: linyaps-packaging.constraints
description: >
  linyaps 打包全流程的单一权威约束集。作为唯一出处，统一承载安装目录(PREFIX)、
  构建重试/超时、项目目录持久化、路径解析、修改日志等约束。
  两个 agent（linyaps-packaging-runner / for-multica）在初始化阶段通过 skill() 一次载入，
  各子 SKILL 不再重复展开这些约束，仅引用本 SKILL。
argument-hint: '{}'
user-invocable: false
---

# linyaps 打包统一约束（单一权威）

本 SKILL 是打包全流程约束的**唯一出处**。agent 在 Phase 1 初始化末尾通过
`skill("linyaps-packaging.constraints", {})` **一次载入**；子 SKILL 与后续步骤引用约束时，
一律指向本 SKILL，不在各处重复展开，避免固定上下文放大。

## 1. 安装目录 ${PREFIX} 约束

- 所有构建工具的安装目录参数必须使用 `${PREFIX}`，禁止硬编码 `/usr` 或 `/usr/local`。
- 常见错误写法（均须改写）：
  - `--prefix=/usr`、`--libdir=/usr/lib`、`--bindir=/usr/bin`、`--includedir=/usr/include`
  - `-DCMAKE_INSTALL_PREFIX=/usr`、`-DCMAKE_INSTALL_LIBDIR=/usr/lib`、`-DCMAKE_INSTALL_BINDIR=/usr/bin`
  - `PREFIX=/usr/local`、`QMAKE_INSTALL_PREFIX=/usr`
- 正确写法：`--prefix=${PREFIX}`、`-DCMAKE_INSTALL_PREFIX=${PREFIX}`、`PREFIX=${PREFIX}`。
- 系统命令（`apt-get`、`dpkg`、`pip` 等）内出现的 `/usr` 除外。
- 输出校验阶段由 `validate-linglong-yaml.py --allow-sources` 检测。

## 2. 构建重试 / 超时约束

变量（单点修改）：`@MAX_BUILD_ATTEMPTS@` = `2`，`@BUILD_TIMEOUT_SEC@` = `1800`。

- 每个构建任务最多执行 `@MAX_BUILD_ATTEMPTS@` 次（含首次），重试间隔 10 秒。
- 单次构建以 `@BUILD_TIMEOUT_SEC@` 秒为首轮等待窗口。
- 窗口到期**不得仅凭退出码 124 判超时**：调用 `check-build-active.sh` 判断是否仍有
  `ll-builder` / `fuse-overlayfs` / `erofsfuse` 进程。
  - 仍有构建进程 → 仍进行中，不判超时、不重试，继续等待。
  - 无构建进程且命令已退出 → 按退出码判定成功/失败。
  - 无构建进程但命令未退出 → 判挂起，才走重试。
- binary：整个 `pak_linyaps.sh` 调用包裹重试 + 首轮窗口。
- source：`ll-builder build` 和 `ll-builder export` 各有独立窗口；`export` 失败重试从 `build` 开始。
- **apt 异常不得绕过**：命中 `detect-apt-error.sh` 的 apt 错误即阻塞该 pkgName，**禁止**
  `|| true` / `dpkg --configure -a || true` 绕过，不进入重试循环。

## 3. 项目目录持久化与缓存复用

- source 项目位于固定的 `<pack_repo_dir>`（`global.pack_repo_dir`，固定绝对共享目录，跨 issue 保留）。
- **版本升级间不得删除项目目录**（仅原地更新 `linglong.yaml`/文件），以复用 ll-builder 依赖缓存。
- **禁止**使用 `build_tmp_dir/<pkgName>` 独立缓存子目录（source 类型）。
- 同一 pkgName 构建由 `<pack_repo_dir>/.linyaps-locks/.linyaps-build-<pkgName>.lock/` 工作锁互斥；
  构建前 `acquire_build_lock`，完成/失败后显式 `release_build_lock`。
- **Issue-60 产物校勘**：`package.version` 必用本轮 `orig_version` 强覆盖（`orig_version` 空/提取
  失败 → 阻塞，不得沿袭历史）；`sources[].digest` 必为本轮计算值；`.layer` 仅取本轮 `export`
  生成的（`mtime` 晚于本轮构建开始）。

## 4. 路径解析与脚本调用约束

- 所有脚本调用使用相对于 workspace 根目录的路径，不使用 `cd` 切换后执行。
配置中的路徑直接使用，不由流程推導或替換模板；binary 任務目錄由 runner 在配置根目錄下隨機建立。
- 操作 `pack_repo_dir` 内项目前，必须先 `sync_projects_root` 安全同步（fetch + `stash -u` +
  rebase + `stash pop`）；rebase/stash 冲突返回非 0 并**阻断流程**。
- 多架构版本不一致时，优先使用 x86_64 架构版本。
- 下载资源处理重定向 URL；资源已存在时跳过重复下载。

## 5. 修改日志格式约束

当 LLM 在构建过程中修改项目文件（`linglong.yaml`、`pak_linyaps.sh` 等）并成功构建时，
**必须**在最终输出中包含结构化修改日志，格式如下：

```markdown
### 🔧 修改日志: <pkgName>

**构建状态**: 成功 ✅
**构建耗时**: <elapsed>s

| # | 文件 | 修改项 | 修改前 | 修改后 | 原因 |
|---|------|--------|--------|--------|------|
| 1 | linglong.yaml | buildDepends | libbar-dev | libbaz-dev | 仓库中不存在 |
```

若无修改，输出 `无修改`。修改日志由脚本捕获暂存到 `<data_dir>/<pkgName>.fix-log.md`。

## 6. binary 打包入口约束

- type=binary 任务的唯一执行入口是 `skills/linglong-binary-runner/scripts/run_tasks.sh`；成功意味着 `pak_linyaps.sh` 真实执行且产出了 `$OUTPUT_DIR/<pkgName>.exec-proof.json`。
- agent 直接调用 `ll-builder`、改写项目 `linglong.yaml`、手工执行 `pak_linyaps.sh` 的分步命令，对 type=binary 均属违规；`status_upload.sh` 门禁将此类结果阻断为 `blocked:pak_linyaps_bypass`（跳过 S3 上传），webhook 以 `failed` 状态上报。
- source 任务不受本节约束（其直接驱动 `ll-builder` 属 `linglong-source-updater` Phase C 设计），但成功上报须带 `TASK_TYPE=source` 调用 `status_upload.sh`。

## 补充说明

- 子 SKILL 仅保留与本 SKILL 不冲突、且属于自身执行细节的说明；凡属上述 1-5 的约束，
  一律引用本 SKILL，不做二次展开。
