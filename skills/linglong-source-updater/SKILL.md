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

整個流程分為三個階段，LLM 在**更新階段完成後、構建階段開始前**介入檢閱，避免帶著錯誤進入構建。

```
Phase A（更新階段）
  ├─ A-1: 驗證輸入 linglong.yaml（無 sources 段）
  ├─ A-2: 下載源碼並計算摘要
  └─ A-3: 更新 linglong.yaml（version + sources + build 修正）
         └─ A-4: 驗證輸出 linglong.yaml（含 sources 段）
              ↓
Phase B（LLM 只讀檢閱）← 在此介入，確保 linglong.yaml 無誤
  └─ 若發現異常 → 重新執行 A-2~A-3
              ↓
Phase C（構建階段）
  ├─ ll-builder build
  └─ ll-builder export
```

### Phase A: 更新 linglong.yaml（不構建）

使用逐個腳本完成更新，**不要包含構建步驟**：

```bash
# A-1: 驗證輸入 linglong.yaml（無 sources 段）
python3 skills/linglong-source-updater/scripts/validate-linglong-yaml.py <project_dir>/linglong.yaml

# A-2: 下載源碼並分析
source_json=$(bash skills/linglong-source-updater/scripts/download-and-checksum.sh <src_url> <kind> <name> [commit])

# 從 source_json 中提取字段
dl_kind=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])")
dl_url=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
dl_digest=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('digest',''))")
dl_name=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
dl_commit=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('commit',''))")

# A-3: 更新 linglong.yaml（更新 version、添加 sources、修正 build）
python3 skills/linglong-source-updater/scripts/update-linglong-yaml.py \
  --path="<project_dir>" \
  --version="<orig_version>" \
  --kind="$dl_kind" \
  --url="$dl_url" \
  --digest="$dl_digest" \
  --name="$dl_name" \
  [--commit="$dl_commit"]

# A-4: 驗證輸出 linglong.yaml（含 sources 段）
python3 skills/linglong-source-updater/scripts/validate-linglong-yaml.py <project_dir>/linglong.yaml --allow-sources
```

> 如果使用 `download-and-checksum.sh` 時不需要預先執行 validate（該腳本在步驟內已隱含前提檢查），但首次調用 validate-linglong-yaml.py（A-1）是檢查起始狀態的必要步驟。

### Phase B: LLM 只讀檢閱

Phase A 完成後，LLM **只讀**檢閱生成的 `linglong.yaml` 確認正確性：

```bash
cat <project_dir>/linglong.yaml
```

檢閱要點：
- `package.version` 是否為目標版本
- `sources` 段格式是否正確（`digest` 為純十六進位，無 `sha256:` 前綴）
- `build` 段是否包含 SRC_ROOT 切換 → prefix 修正 → touch/chmod 的標準結構

**LLM 不得對 `linglong.yaml` 做任何編輯操作**。若檢閱發現異常，應重新執行 Phase A 的 A-2~A-3 步驟（下載 + 更新），而非手動修改。

### Phase C: 構建

LLM 檢閱確認無誤後，執行構建：

```bash
cd <project_dir>
ll-builder build --skip-output-check
ll-builder export --layer --no-develop -z zstd
```

若項目需要等待構建進程，參考下方的「構建進度檢測」。

## 約束

- **標準執行路徑**：Phase A（逐個腳本更新）→ Phase B（LLM 檢閱）→ Phase C（構建）。LLM 檢閱必須在 Phase A 之後、Phase C 之前，不可顛倒
- 作為更新階段捷徑，`run_tasks.sh` 也可用於一鍵執行 Phase A 全部子步驟（A-1~A-4），但調用後必須先執行 Phase B（LLM 檢閱），確認無誤後再手動執行 Phase C（構建）。**禁止直接使用 `run_tasks.sh` 的完整流程（含構建），因為這會跳過 LLM 檢閱**
- `update-linglong-yaml.py` 是唯一的 `build` 字段修改入口，其自動化操作（SRC_ROOT 插入、prefix 修正、touch/chmod 追加）是**允許的標準行為**
- **LLM 只讀** `linglong.yaml`——檢閱時不得做任何編輯操作。若需修改，重新執行 Phase A 中的對應腳本
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