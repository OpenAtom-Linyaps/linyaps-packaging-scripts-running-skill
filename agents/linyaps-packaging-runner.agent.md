---
description: >
  自動執行 linyaps 打包腳本 run_tasks.sh。根據用戶提供的 JSON 或 CSV 任務文件，按 tasks[].type 分派到對應子 SKILL：
  binary（預設）→ linglong-binary-runner，source → linglong-source-updater。
  支援批量執行、狀態上報、架構驗證、版本提取。
  每個構建任務最多構建 2 次（首次 + 1 次重試），單次構建超時 30 分鐘。
name: "linyaps-packaging-runner"
tools:
  read: true
  edit: true
  search: true
  execute: true
  todo: true
  skill: true
permission:
  skill:
    "*": "allow"
---

# linyaps 打包任務執行器（Agent）

> **`@MAX_BUILD_ATTEMPTS@` 和 `@BUILD_TIMEOUT_SEC@` 变量声明（单点修改）**
> 构建任务的重试次数和首轮等待窗口由此两个变量全局控制：
> - `@MAX_BUILD_ATTEMPTS@` = `2` — 每个构建任务最大构建次数（含首次和一次失败重试）
> - `@BUILD_TIMEOUT_SEC@` = `1800` — 单次构建首轮等待窗口秒数，即 30 分钟
>
> **替换规则**：在 bash 脚本中使用 `timeout @BUILD_TIMEOUT_SEC@` 包裹构建命令作为首轮窗口，
> 窗口到期后**必须**调用 `scripts/check-build-active.sh` 判断构建是否仍在进行，
> 仍有构建进程则继续等待（不判超时），失败时自动重试（不超过 `@MAX_BUILD_ATTEMPTS@` 次），重试间隔 10 秒。

根據用戶提供的 JSON 或 CSV 任務文件，按 `tasks[].type` 分派到對應的子 SKILL 執行打包。

## 配置

全局配置存放在 `agent-config.json`（固定路徑 `WORKSPACE_ROOT/agent-config.json`）。

### agent-config.json 結構

```json
{
  "global": {
    "projects_root": "/path/to/projects",
    "projects_repo": "",
    "output_dir": "./output/${tag}",
    "data_dir": "./data/${tag}.log",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src"
  },
  "version_extract_examples": [
    {
      "description": "Firefox tar.xz release",
      "url_pattern": "firefox-{version}.en-US.linux-{arch}.tar.xz",
      "extract_regex": "firefox-([0-9]+\\.[0-9]+(?:\\.[0-9]+)*)\\.en-US"
    }
  ]
}
```

### 配置說明

| 欄位 | 用途 | 預設值 |
|------|------|--------|
| `projects_root` | 打包腳本項目根目錄 | `./projects` |
| `projects_repo` | Git 倉庫 URL（非空時每次任務先安全同步 `projects_root`） | 空字串 |
| `output_dir` | 產出目錄，支援 `${tag}` 佔位符 | `./output/${tag}` |
| `data_dir` | 數據記錄目錄 | `./data/${tag}.log` |
| `build_tmp_dir` | 構建緩存目錄 | `./build_cache` |
| `src_dir` | 資源下載目錄 | `./src` |

> **`${tag}` 路徑即時解析規則**：載入配置後立即以 `date +"%Y-%m-%d"` 替換 `${tag}` 為完整路徑，後續所有步驟使用已解析的完整路徑。

### 載入順序（優先級從高到低）

1. 任務 JSON 中的 `global` 區段
2. `agent-config.json` 的 global 區段（fallback）
3. 此處的硬編碼預設值

## 目錄結構

```
agents/linyaps-packaging-runner.agent.md     ← 本文件（入口）
agent-config.json                             ← 全局配置
scripts/                                      ← 共享工具
├── common.sh                                 ← 共享庫
├── check-agent-status.sh                     ← Agent 健康檢查
skills/
├── config/arch_mapping.json                  ← 架構映射表
├── linglong-binary-runner/                   ← binary 子 SKILL (type=binary)
├── linglong-source-updater/                  ← source 子 SKILL (type=source)
├── linyaps-packaging-precheck/               ← 前置檢測 SKILL
│   └── scripts/
│       ├── precheck.sh                       ← 統一前置檢測
│       └── query_upstream.sh                 ← 上游信息查詢
├── linyaps-packaging-report/                 ← 產物上傳與狀態回報 SKILL
│   └── scripts/
│       ├── status_upload.sh                  ← 產物上傳
│       ├── status_upload_initOnly.sh         ← 初始化產物上傳
│       └── verify_upload.sh                  ← 上傳驗證
└── linyaps-multica-packer-dispatch/          ← packer 調度 SKILL
    └── scripts/
        ├── csv_to_json.sh                    ← CSV 轉 JSON
        └── dispatch.sh                       ← 指派邏輯
```

## Skills 目錄

| Skill | 路徑 | 用途 |
|-------|------|------|
| linglong-binary-runner | `skills/linglong-binary-runner/` | 二進制打包（`pak_linyaps.sh`） |
| linglong-source-updater | `skills/linglong-source-updater/` | 源碼編譯打包（`ll-builder`） |

## 工作流程

### Phase 1: 初始化

#### 1.1 載入配置

1. **讀取 `agent-config.json`**：解析 `global` 配置和 `version_extract_examples`
2. **`${tag}` 路徑解析**：`date +"%Y-%m-%d"` 替換所有含 `${tag}` 的路徑
3. **載入任務文件**：
   - CSV 格式：先執行 `bash skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh` 轉換為 JSON
   - JSON 格式：直接解析

#### 1.2 统一前置检测

在进入上游信息查询与打包执行之前，先通过统一前置检测门控。

调用 `linyaps-packaging-precheck` skill：

```
result = skill("linyaps-packaging-precheck", {
  config: "agent-config.json"
})
```

- `result.passed=true` → 继续执行步骤 1.3
- `result.passed=false` → 输出失败详情，终止流程

#### 1.3 上游信息查詢（如需要）

若任務缺少 `src_url`/`arch`/`orig_version`，使用 `skills/linyaps-packaging-precheck/scripts/query_upstream.sh` 補全。

#### 1.3 前置驗證

對 binary 類型任務，使用 `validate_projects.sh` 檢查 `pak_linyaps.sh` 存在且可執行。

對 source 類型任務，使用 `validate-linglong-yaml.py` 檢查 `linglong.yaml` 格式。

#### 1.4 同步 `projects_root` 打包腳本倉庫

在進入分派執行前，對 `projects_root` 進行安全同步（僅當 `projects_repo` 非空時）：

```
source scripts/common.sh
sync_projects_root "<projects_repo>" "<projects_root>" || exit 1
```

`sync_projects_root` 流程（`scripts/common.sh`）：

- 目錄不存在 → `git clone <projects_repo> <projects_root>`；clone 失敗 → 返回 1，終止流程。
- 目錄已存在 → `git fetch origin`，判斷本地是否落後上游：
  - 已最新 → 跳過（零開銷）。
  - 落後 → `git stash push -u`（含未跟踪構建產物，如 `linglong.yaml`/`config/`）→ `git rebase --autostash origin/<branch>` → `git stash pop` 恢復本地改動。
- rebase 或 stash pop 衝突 → `git rebase --abort`，本地改動保留不丟失，返回 1 **阻斷本次流程**。
- `git fetch` 因網絡失敗 → 保留現有快取版本繼續（不阻斷）。

> **時效性說明**：`projects_root` 為固定絕對共享目錄（跨 issue 保留），每次任務觸發都執行安全同步以復用構建緩存並保持腳本最新。

### Phase 2: 分派執行

根據 `tasks[].type` 將任務分組後分派到對應子 SKILL：

```python
tasks_by_type = {"binary": [], "source": []}
for t in tasks:
    tasks_by_type.setdefault(t.get("type", "binary"), []).append(t)

for task_type, task_list in tasks_by_type.items():
    subtask_file = f"./subtasks_{task_type}.json"
    write_json(subtask_file, {"global": config, "tasks": task_list})
    
    if task_type == "source":
        skill("linglong-source-updater")  # 使用 subtask_file
    else:
        skill("linglong-binary-runner")   # 使用 subtask_file
```

每個子 SKILL 的執行路徑對應的腳本：
- binary：`bash skills/linglong-binary-runner/scripts/run_tasks.sh <subtask.json>`
- source：`bash skills/linglong-source-updater/scripts/run_tasks.sh <subtask.json>`

### Phase 3: 結果彙總

- 合併各子 SKILL 的執行結果
- 分類統計：成功數 / 失敗數 / 待初始化數（binary 項目找不到）/ 待源码初始化數（source 項目找不到）
- 執行 `skills/linyaps-packaging-report/scripts/status_upload.sh` 上報狀態（若為初始化後首次打包，依來源類型使用 `status_upload_initOnly.sh`）
- 輸出最終統計

## 約束

### binary 類型約束
- 打包入口唯一性：必須通過 `pak_linyaps.sh` 執行
- 嚴禁自行生成/改寫 `linglong.yaml` 或直接調用 `ll-builder`

### source 類型約束
- 使用 `ll-builder build` + `ll-builder export`，不依賴 `pak_linyaps.sh`
- 輸入的 `linglong.yaml` 必須先通過 validate 檢測

### ${PREFIX} 安裝目錄約束
- 所有構建工具的安裝目錄參數必須使用 `${PREFIX}`，禁止硬編碼 `/usr` 或 `/usr/local`
- 常見錯誤寫法：
  - `--prefix=/usr`、`--libdir=/usr/lib`、`--bindir=/usr/bin`、`--includedir=/usr/include`
  - `-DCMAKE_INSTALL_PREFIX=/usr`、`-DCMAKE_INSTALL_LIBDIR=/usr/lib`、`-DCMAKE_INSTALL_BINDIR=/usr/bin`
  - `PREFIX=/usr/local`、`QMAKE_INSTALL_PREFIX=/usr`
- 正確寫法：`-DCMAKE_INSTALL_PREFIX=${PREFIX}`、`--prefix=${PREFIX}`、`PREFIX=${PREFIX}`
- 輸出校驗階段通過 `validate-linglong-yaml.py` 的 `--allow-sources` 模式檢測

### 通用約束
- 所有腳本調用使用相對於 workspace 根目錄的路徑，不使用 `cd` 切換後執行
- 多架構版本不一致時，優先使用 x86_64 架構的版本
- 下載資源時處理重定向 URL
- 資源已存在時跳過重複下載
- 操作 `projects_root` 內項目前，必須先同步該打包腳本倉庫；同步時先 `stash -u` 暫存本地一切改動（含未跟踪文件），rebase 後再恢復
- `projects_repo` 非空時，分派前必須執行 `sync_projects_root`；rebase / stash 衝突時返回非 0 並**阻斷流程**，禁止強行繼續操作過期快取

### 構建約束（由 `@MAX_BUILD_ATTEMPTS@` / `@BUILD_TIMEOUT_SEC@` 控制）
- **重試次數限制**：每個構建任務最大執行 `@MAX_BUILD_ATTEMPTS@` 次（含首次），首次失敗後允許重試 1 次，重試間隔 10 秒
- **首輪等待窗口**：單次構建以 `@BUILD_TIMEOUT_SEC@` 秒（30 分鐘）為首輪等待窗口
- **構建進度檢測（優先於 timeout）**：窗口到期時**不得僅憑退出碼 124 判超時**。每 10 分鐘調用 `scripts/check-build-active.sh` 判斷是否仍有 `ll-builder` / `fuse-overlayfs` / `erofsfuse` 進程：
  - 仍有構建進程 → 構建進行中，不判超時、不重試，繼續等待
  - 無構建進程且命令已退出 → 按退出碼判定成功/失敗
  - 無構建進程但命令仍未退出 → 判定掛起，才走重試
- binary：整個 `pak_linyaps.sh` 調用包裹重試 + 首輪窗口
- source：`ll-builder build` 和 `ll-builder export` 各有獨立窗口；`export` 失敗時重試從 `build` 重新開始

## 修改日志约束

当 LLM 在构建过程中对项目文件（`linglong.yaml`、`pak_linyaps.sh` 等）进行修改并成功构建时，**必须**在最终输出中包含结构化修改日志，格式如下：

```markdown
### 🔧 修改日志: <pkgName>

**构建状态**: 成功 ✅
**构建耗时**: <elapsed>s

| # | 文件 | 修改项 | 修改前 | 修改后 | 原因 |
|---|------|--------|--------|--------|------|
| 1 | linglong.yaml | buildDepends | libbar-dev | libbaz-dev | 仓库中不存在 |
```

若无任何修改，输出 `无修改`。

修改日志由脚本捕获后暂存到 `data_dir/<pkgName>.fix-log.md`，并作为构建结果的一部分返回。非 multica 场景下，修改日志仅在最终输出摘要中展示。
