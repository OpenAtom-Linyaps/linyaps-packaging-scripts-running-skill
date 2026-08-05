---
name: linglong-source-updater
description: '更新已初始化的 linglong.yaml，補充上游源碼信息，更新構建規則。用於 source 類型任務（特徵：目錄下有 linglong.yaml 但缺少 sources 段）。支援 archive/git/file/dsc 四種源碼類型。'
references:
  - references/manifests-for-yaml.md
  - references/sources.section.example.yaml
  - references/build.section.example.yaml
user-invocable: false
---

# linyaps Source 源碼編譯打包器

當 agent 分派 `type=source` 的任務時使用此 skill。

## 目錄約定

- 下載校驗腳本：`skills/linglong-source-updater/scripts/download-and-checksum.sh`
- YAML 更新腳本（可選輔助）：`skills/linglong-source-updater/scripts/update-linglong-yaml.py`
- 格式驗證腳本：`skills/linglong-source-updater/scripts/validate-linglong-yaml.py`
- 字段規範參考：`skills/linglong-source-updater/references/manifests-for-yaml.md`
- 共享庫：`skills/linglong-source-updater/scripts/common.sh`
- 架構映射：`skills/config/arch_mapping.json`

> **注意**：`run_tasks.sh` 已棄用，不再使用。原因見下方說明。

## 使用前提

- 目標項目目錄下存在 `linglong.yaml`，且格式正確、無 sources 段
- `build` 字段中必須包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
- `build` 段中所有安裝目錄參數出現 `/usr` 或 `/usr/local` 絕對路徑均為錯誤：
  - `--prefix=/usr` / `--libdir=/usr/lib` / `--bindir=/usr/bin`
  - `-DCMAKE_INSTALL_PREFIX=/usr` / `-DCMAKE_INSTALL_LIBDIR=/usr/lib`
  - `QMAKE_INSTALL_PREFIX=/usr`
  - 以上均須以 `${PREFIX}` 替代（系統命令如 `apt-get`、`dpkg` 中的 `/usr` 除外）

## 輸入

標準任務 JSON，`tasks[].type` 為 `source`：

```json
{
  "tasks": [
    {
      "pkgName": "com.example.sourceapp",
      "type": "source",
      "src_url": "https://example.com/sourceapp-2.0.tar.gz",
      "arch": "x86_64",
      "orig_version": "2.0",
      "kind": "archive",
      "name": "src"
    }
  ]
}
```

## 執行流程

### 1. 源碼下載與分析

調用 `download-and-checksum.sh` 下載源碼並計算摘要：

```bash
bash scripts/download-and-checksum.sh <src_url> <kind> <name> [commit]
```

輸出 JSON 格式結果，包含 `kind`、`url`、`digest`、`name`、`commit` 等字段。

### 2. 編輯 linglong.yaml

根據上一步的 JSON 輸出，手動編輯項目目錄下的 `linglong.yaml`：

- 更新 `package.version` 為最新版本號
- 添加 `sources` 段，包含 `kind`、`url`、`digest`（archive/dsc）或 `commit`（git）
- 確保 `build` 段：
  - 第一行進入源碼目錄：`export SRC_ROOT=$(ls -d /project/linglong/sources/<name>/*)` 後 `cd ${SRC_ROOT}`
  - 所有安裝路徑使用 `${PREFIX}` 而非硬編碼的 `/usr` 或 `/usr/local`
  - 包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
- `sources` 段的 `digest` 字段必須為純數值格式（如 `a54f62cbfcf7a09a3ad633...`），不得包含 `sha256:` 等前綴

可選：使用 `update-linglong-yaml.py` 輔助生成 sources 段內容，但推薦手動編輯以確保準確性。

### 3. 驗證

調用 `validate-linglong-yaml.py` 檢查 YAML 格式：

```bash
python3 scripts/validate-linglong-yaml.py <project_dir>/linglong.yaml --allow-sources
```

### 4. 構建

告知用戶手動進入項目目錄執行：

```bash
cd <project_dir>
ll-builder build --skip-output-check
```

## 約束

- 不使用 `run_tasks.sh`：該腳本內部通過 `common.sh` 引入 `find_project_dir()` 函數，該函數依賴 `pak_linyaps.sh` 文件存在來定位項目目錄，不適用於源碼項目（源碼項目應以 `linglong.yaml` 為標識）
- `build` 第一個步驟必須進入源碼目錄，使用 `export SRC_ROOT=$(ls -d /project/linglong/sources/<name>/*)` 動態發現後 `cd ${SRC_ROOT}`
- `build` 段必須包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
- `${PREFIX}` 安裝目錄約束同上
- `sources` 段的 `digest` 字段不得包含 `sha256:` 等加密方法前綴
- 參考示例：`references/build.section.example.yaml`、`references/sources.section.example.yaml`