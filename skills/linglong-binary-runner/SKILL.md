---
name: linglong-binary-runner
description: '透過 pak_linyaps.sh 自動執行 linyaps 二進制打包。用於已適配便捷打包腳本的項目（特徵：目錄下有 pak_linyaps.sh），不感知 linglong.yaml。使用場景：批量執行 JSON/CSV 任務中的 binary 類型打包。'
argument-hint: '<task.json> [--agent-config-path=<path>]'
user-invocable: false
---

# linyaps Binary 打包執行器

當 agent 分派 `type=binary`（或未指定 type）的任務時使用此 skill。

## 目錄約定

- 執行腳本：`skills/linglong-binary-runner/scripts/run_tasks.sh`
- 驗證腳本：`skills/linglong-binary-runner/scripts/validate_projects.sh`
- 構建進度檢測：`skills/linglong-binary-runner/scripts/check-build-active.sh`
- 共享庫：`skills/linglong-binary-runner/scripts/common.sh`（含 `sync_projects_root`）
- 架構映射：`skills/config/arch_mapping.json`

## 輸入

標準任務 JSON，`tasks[].type` 為 `binary` 或未指定，並可選傳入 `--agent-config-path=<path>` 指定 `agent-config.json` 路徑：

```json
{
  "global": {
    "pack_repo_dir": "/path/to/projects",
    "output_dir": "./output"
  },
  "tasks": [
    {
      "pkgName": "com.opera.browser",
      "type": "binary",
      "src_url": "https://example.com/opera-stable_130.0_amd64.deb",
      "arch": "x86_64",
      "orig_version": "130.0.5847.92"
    }
  ]
}
```

## 執行流程

1. **解析 JSON**：讀取 `pack_repo_dir`、`projects_repo`、`output_dir`、`build_tmp_dir`、`src_dir`
2. **同步 pack_repo_dir**（`run_tasks.sh` 內建）：若配置 `global.projects_repo`，打包前對 `<pack_repo_dir>` 執行安全同步（fetch → 落後檢測 → `stash -u` → `rebase --autostash` → `stash pop`，衝突即阻斷 `exit 1`）
3. **初始化目錄**：建立 src_dir、output_dir、build_tmp_dir
4. **對每個任務**：
   - 從 URL 提取版本號（若未提供）
   - 架構匹配驗證（以 arch_mapping.json）
   - 下載原始資源
   - 查找項目目錄（查找 pak_linyaps.sh）
   - 檢測 `--build_tmp_dir` 支援
   - 執行 `pak_linyaps.sh` 打包
5. **輸出結果統計**

## 約束

- 打包入口唯一性：所有操作必須通過 `pak_linyaps.sh` 執行，嚴禁自行改寫 `linglong.yaml` 或調用 `ll-builder`
- 嚴禁修改 `pak_linyaps.sh` 或 `linglong.yaml` 的內容

## 構建進度檢測（避免長構建被誤判超時）

- 進程檢測判斷規則（仍有構建進程不判超時 / 已退出按退出碼 / 未退出判掛起）見統一約束 SKILL
  （`skills/linyaps-packaging.constraints/SKILL.md` 第 2 節），此處不重複。**不要僅憑 `timeout` 退出碼（124）判定失敗。**

構建執行期間，每 **10 分鐘**調用一次 `scripts/check-build-active.sh`：

```bash
bash skills/linglong-binary-runner/scripts/check-build-active.sh
# exit 0 → 仍有構建進程 → 構建進行中，不判超時，繼續等待
# exit 1 → 無構建進程 → 構建已結束

bash skills/linglong-binary-runner/scripts/check-build-active.sh -o json
# {"build_active": true/false, "processes": [...]}
```
