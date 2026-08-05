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
- YAML 更新腳本：`skills/linglong-source-updater/scripts/update-linglong-yaml.py`
- 格式驗證腳本：`skills/linglong-source-updater/scripts/validate-linglong-yaml.py`
- 構建進度檢測：`skills/linglong-source-updater/scripts/check-build-active.sh`
- 自動化管線腳本：`skills/linglong-source-updater/scripts/run_tasks.sh`
- 字段規範參考：`skills/linglong-source-updater/references/manifests-for-yaml.md`
- 共享庫：`skills/linglong-source-updater/scripts/common.sh`
- 架構映射：`skills/config/arch_mapping.json`

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

### 2. 自動化更新 linglong.yaml

**使用 `run_tasks.sh` 自動化管線執行完整流程**，該腳本會自動完成以下操作：

1. 驗證輸入 `linglong.yaml`（無 sources 段）
2. 下載源碼並校驗（`download-and-checksum.sh`）
3. 更新 `linglong.yaml`（`update-linglong-yaml.py`）：
   - 更新 `package.version`
   - 添加 `sources` 段（`kind`、`url`、`digest`、`name`）
   - `digest` 自動去除非十六進位前綴（如 `sha256:`）
   - `build` 首行插入 SRC_ROOT 目錄切換命令
   - 修正 `${prefix}` → `${PREFIX}`，硬編碼 `/usr` 路徑 → `${PREFIX}`
   - 確保 `build` 末尾有 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
4. 驗證輸出 `linglong.yaml`（含 sources 段）
5. 執行 `ll-builder build && ll-builder export`（含重試與超時保護）

```bash
bash skills/linglong-source-updater/scripts/run_tasks.sh <subtask.json>
```

> `run_tasks.sh` 是標準執行路徑，`update-linglong-yaml.py` 是唯一的 `build` 字段修改入口。

### 3. LLM 只讀檢閱

`run_tasks.sh` 執行完成後，LLM **只讀**檢閱生成的 `linglong.yaml` 確認正確性：

```bash
cat <project_dir>/linglong.yaml
```

檢閱要點：
- `package.version` 是否為目標版本
- `sources` 段格式是否正確（`digest` 為純十六進位，無 `sha256:` 前綴）
- `build` 段是否包含 SRC_ROOT 切換 → prefix 修正 → touch/chmod 的標準結構

**LLM 不得對 `linglong.yaml` 做任何編輯操作**。若檢閱發現異常，應重新執行 `run_tasks.sh` 或 `update-linglong-yaml.py`，而非手動修改。

### 4. 構建

若需要單獨執行構建（或 `run_tasks.sh` 未包含構建步驟時）：

```bash
cd <project_dir>
ll-builder build --skip-output-check
```

## 約束

- `run_tasks.sh` 是標準執行路徑，其中 `update-linglong-yaml.py` 是唯一的 `build` 字段修改入口，其自動化操作（SRC_ROOT 插入、prefix 修正、touch/chmod 追加）是**允許的標準行為**
- **LLM 只讀** `linglong.yaml`——檢閱時不得做任何編輯操作。若需修改，重新執行腳本
- `build` 第一個步驟必須進入源碼目錄，使用 `export SRC_ROOT=$(ls -d /project/linglong/sources/<name>/*)` 動態發現後 `cd ${SRC_ROOT}`
- `build` 段必須包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
- `${PREFIX}` 安裝目錄約束：所有安裝路徑使用 `${PREFIX}` 而非硬編碼的 `/usr` 或 `/usr/local`
- `sources` 段的 `digest` 字段不得包含 `sha256:` 等加密方法前綴
- 參考示例：`references/build.section.example.yaml`、`references/sources.section.example.yaml`

## 構建進度檢測（避免長構建被誤判超時）

部分項目構建時間可能超過單次 `timeout` 窗口，導致被誤判為超時。**不要僅憑 `timeout` 的退出碼（124）判定構建失敗。**

`ll-builder build` / `ll-builder export` 執行期間，每 **10 分鐘**調用一次 `scripts/check-build-active.sh` 判斷當前是否有 `ll-builder`、`fuse-overlayfs`、`erofsfuse` 之一在運行：

```bash
bash skills/linglong-source-updater/scripts/check-build-active.sh
# exit 0 → 仍有構建進程 → 構建進行中，不判超時，繼續等待
# exit 1 → 無構建進程 → 構建已結束

bash skills/linglong-source-updater/scripts/check-build-active.sh -o json
# {"build_active": true/false, "processes": [...]}
```

判定規則：
- **仍有構建進程**（尤其 `ll-builder` 本體）→ 構建仍進行中，**不判超時、不重試**，繼續等待構建完成。
- **無構建進程且命令已退出** → 正常結束或失敗，按退出碼判定。
- **無構建進程但命令仍未退出** → 構建疑似掛起，才判超時並走重試。