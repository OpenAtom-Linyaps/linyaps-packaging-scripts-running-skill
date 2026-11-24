---
name: linglong-source-updater
description: '更新已初始化的 linglong.yaml，補充上游源碼信息，更新構建規則。用於 source 類型任務（特徵：目錄下有 linglong.yaml 但缺少 sources 段）。支援 archive/git/file/dsc 四種源碼類型。'
references:
  - references/manifests-for-yaml.md
  - references/sources.section.example.yaml
  - references/build.section.example.yaml
  - references/complete-linglong.example.yaml
user-invocable: false
---

# linyaps Source 源碼編譯打包器

當 agent 分派 `type=source` 的任務時使用此 skill。

## 类型契约

执行顺序固定为 Phase A 更新 → Phase B LLM 只读复核 → Phase C `ll-builder build`/`export`。Phase A 使用 `validate-linglong-yaml.py`、`download-and-checksum.sh`、`update-linglong-yaml.py`；LLM 不直接编辑 YAML，异常时重跑 A-2~A-3。

构建必须使用本轮 `orig_version`、本轮 digest 与本轮 export 产物；不得沿用历史 version、digest 或 `.layer`。构建前后按公共 constraints 的锁、持久化、超时和日志规则执行，monitor-build/status 用于长构建轮询。

**产物上传与状态回报是强制步骤，无论构建成功或失败都必须执行**：
- 成功：`TASK_TYPE=source bash skills/linyaps-packaging-report/scripts/status_upload.sh <layer_file> <orig_version> non-verified`
- 失败：`TASK_TYPE=source bash skills/linyaps-packaging-report/scripts/status_upload.sh null <orig_version> failed <pkgName> <arch>`

跳过上传或仅在上传成功时回报均属违规（constraints §6）。上传脚本内部处理 upload-failed 和 blocked 状态；调用方只需如实传入 filepath 和 pakStatus。

`package.id` 优先对应任务 `pkgName`；`package.version` 为四段数字且各段不以 0 开头；sources digest 不含 `sha256:` 前缀。公共 `${PREFIX}`、安装路径、apt 和修改日志规则只引用 `linyaps-packaging.constraints`。

参考 `references/manifests-for-yaml.md`、`references/sources.section.example.yaml`、`references/build.section.example.yaml`、`references/complete-linglong.example.yaml`。
脚本入口保持不变：`skills/linglong-source-updater/scripts/validate-linglong-yaml.py`、`download-and-checksum.sh`、`update-linglong-yaml.py`、`monitor-build.sh`、`check-build-active.sh`；共享锁函数来自 `scripts/common.sh`。