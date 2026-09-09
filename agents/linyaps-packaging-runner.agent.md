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


根據用戶提供的 JSON 或 CSV 任務文件，按 `tasks[].type` 分派到對應的子 SKILL 執行打包。

## 配置

全局配置存放在 `agent-config.json`（固定路徑 `WORKSPACE_ROOT/agent-config.json`）。

### agent-config.json 結構

```json
{
  "global": {
    "pack_repo_dir": "/path/to/projects",
    "projects_repo": "",
    "output_dir": "./output",
    "data_dir": "./data",
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
| `pack_repo_dir` | 打包腳本項目根目錄 | `./projects` |
| `projects_repo` | Git 倉庫 URL（非空時每次任務先安全同步 `pack_repo_dir`） | 空字串 |
| `output_dir` | 產出目錄，由配置直接指定 | `./output` |
| `data_dir` | 數據記錄目錄，由配置直接指定 | `./data` |
| `build_tmp_dir` | 構建臨時目錄根目錄；每個 binary 任務建立隨機子目錄 | `./build_cache` |
| `src_dir` | 資源下載目錄，由配置直接指定 | `./src` |


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
| linyaps-packaging.constraints | `skills/linyaps-packaging.constraints/` | 統一約束唯一權威（Phase 1 一次載入） |

## 工作流程

### Phase 1: 初始化

#### 1.1 載入配置

1. **讀取 `agent-config.json`**：解析 `global` 配置和 `version_extract_examples`
2. **使用配置中的完整路徑**，不進行日期或模板解析
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
- **提示詞已有的 `src_url`/`orig_version` 為第一候選**：API 返回不得覆蓋已存在字段，僅填充缺失字段。
- 字段齊全時直接跳過 query；已存在字段被 API 返回不同值時僅記錄 warning，不更新 task（對齊 Issue-61 原則）。

#### 1.3 前置驗證

對 binary 類型任務，使用 `validate_projects.sh` 檢查 `pak_linyaps.sh` 存在且可執行。

對 source 類型任務，使用 `validate-linglong-yaml.py` 檢查 `linglong.yaml` 格式。

#### 1.4 同步 `pack_repo_dir` 打包腳本倉庫

在進入分派執行前，對 `pack_repo_dir` 進行安全同步（僅當 `projects_repo` 非空時）：

```
source scripts/common.sh
sync_projects_root "<projects_repo>" "<pack_repo_dir>" || exit 1
```

`sync_projects_root` 流程（`scripts/common.sh`）：

- 目錄不存在 → `git clone <projects_repo> <pack_repo_dir>`；clone 失敗 → 返回 1，終止流程。
- 目錄已存在 → `git fetch origin`，判斷本地是否落後上游：
  - 已最新 → 跳過（零開銷）。
  - 落後 → `git stash push -u`（含未跟踪構建產物，如 `linglong.yaml`/`config/`）→ `git rebase --autostash origin/<branch>` → `git stash pop` 恢復本地改動。
- rebase 或 stash pop 衝突 → `git rebase --abort`，本地改動保留不丟失，返回 1 **阻斷本次流程**。
- `git fetch` 因網絡失敗 → 保留現有快取版本繼續（不阻斷）。

> **時效性說明**：`pack_repo_dir` 為固定絕對共享目錄（跨 issue 保留），每次任務觸發都執行安全同步以復用構建緩存並保持腳本最新。

#### 1.5 載入統一約束 SKILL（僅一次）

在 Phase 1 末尾載入唯一約束來源，後續所有步驟引用約束時指向本 SKILL，不重複展開：

```
result = skill("linyaps-packaging.constraints", {})
```

> 統一約束（`${PREFIX}` 安裝目錄、構建重試/超時、項目目錄持久化、路徑解析、修改日誌）以
> `skills/linyaps-packaging.constraints/SKILL.md` 為唯一權威，正文不再重複明列。

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

### Phase 3: 结果彙總

- 合併各子 SKILL 的短结构化结果；每项仅保留 `pkgName`、`type`、`status`、`elapsed`、`attempts`、`artifact`、`error_summary`、`log_path`。
- 完整构建日志必须留在本地日志路径；入口 agent 禁止读取或粘贴完整日志、完整 agent 文档、完整目录树或未限定范围的工具输出。异常摘要由子 skill 生成；入口只按 `log_path` 引用。
- 分类统计：成功数 / 失败数 / 待初始化数（binary 项目找不到）/ 待源码初始化数（source 项目找不到）。
- 执行 `skills/linyaps-packaging-report/scripts/status_upload.sh` 上报状态（若为初始化后首次打包，依来源类型使用 `status_upload_initOnly.sh`）。
- **（issue-63 護欄）** 只要打包成功，**必須立即、無條件**執行產物上傳+狀態回報；上傳/回報未確認完成，不得进入下一任务或结束流程。
- 输出最终短统计，不输出原始 API 响应或目录扫描结果。


## 約束

### binary 類型約束
- 打包入口唯一性：必須通過 `pak_linyaps.sh` 執行
- 嚴禁自行生成/改寫 `linglong.yaml` 或直接調用 `ll-builder`

### source 類型約束
- 使用 `ll-builder build` + `ll-builder export`，不依賴 `pak_linyaps.sh`
- 輸入的 `linglong.yaml` 必須先通過 validate 檢測
- **Issue-60 防護（本轮产物）**：構建**只復用 ll-builder 依賴緩存**；`linglong.yaml` 的 `version`/`sources` 與 `.layer` 產物均須為**本輪**，不得把上一輪遺留產物作為本輪結果。`orig_version` 為空/提取失敗 → **阻塞**，不得沿襲歷史 `version`；`package.version` 必用本輪 `orig_version` 強覆蓋，`sources[].digest` 必為本輪下載計算值；產物 `.layer` 僅取本輪 `export` 生成者（mtime 晚於本輪構建開始）。

### ${PREFIX} 安裝目錄約束
- 詳見統一約束 SKILL（`skills/linyaps-packaging.constraints/SKILL.md` 第 1 節），此處不再重複列表。所有安裝路徑用 `${PREFIX}`，禁止硬編碼 `/usr` / `/usr/local`。

### 通用約束
- 所有腳本調用使用相對於 workspace 根目錄的路徑，不使用 `cd` 切換後執行
- 多架構版本不一致時，優先使用 x86_64 架構的版本
- 下載資源時處理重定向 URL
- 資源已存在時跳過重複下載
- 操作 `pack_repo_dir` 內項目前，必須先同步該打包腳本倉庫；同步時先 `stash -u` 暫存本地一切改動（含未跟踪文件），rebase 後再恢復
- `projects_repo` 非空時，分派前必須執行 `sync_projects_root`；rebase / stash 衝突時返回非 0 並**阻斷流程**，禁止強行繼續操作過期快取

### 構建約束（由 `@MAX_BUILD_ATTEMPTS@` / `@BUILD_TIMEOUT_SEC@` 控制）
- 詳見統一約束 SKILL（`skills/linyaps-packaging.constraints/SKILL.md` 第 2 節）：重試不超過
  `@MAX_BUILD_ATTEMPTS@` 次、首輪窗口 `@BUILD_TIMEOUT_SEC@`、進度檢測優先於 timeout、
  apt 異常不得繞過。此處不再重複。

## 修改日志约束

- 詳見統一約束 SKILL（`skills/linyaps-packaging.constraints/SKILL.md` 第 5 節）。
- 修改日志暫存於 `data_dir/<pkgName>.fix-log.md`；非 multica 場景下僅在最終輸出摘要中展示。
