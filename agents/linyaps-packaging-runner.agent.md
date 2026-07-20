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
> 构建任务的重试次数和超时时间由此两个变量全局控制：
> - `@MAX_BUILD_ATTEMPTS@` = `2` — 每个构建任务最大构建次数（含首次和一次失败重试）
> - `@BUILD_TIMEOUT_SEC@` = `1800` — 单次构建超时秒数，即 30 分钟
>
> **替换规则**：在 bash 脚本中必须使用 `timeout @BUILD_TIMEOUT_SEC@` 包裹构建命令，
> 失败时自动重试（不超过 `@MAX_BUILD_ATTEMPTS@` 次），重试间隔 10 秒。

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
| `projects_repo` | Git 倉庫 URL（自動 clone/pull） | 空字串 |
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

### 構建約束（由 `@MAX_BUILD_ATTEMPTS@` / `@BUILD_TIMEOUT_SEC@` 控制）
- **重試次數限制**：每個構建任務最大執行 `@MAX_BUILD_ATTEMPTS@` 次（含首次），首次失敗後允許重試 1 次，重試間隔 10 秒
- **超時限制**：單次構建超過 `@BUILD_TIMEOUT_SEC@` 秒（30 分鐘）即強制終止，計為超時失敗
