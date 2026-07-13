---
name: linyaps-packaging-report
description: >
  产物流传与状态上报 SKILL。每个任务打包完成后，将构建产物上传至 S3
  并向 webhook 回报状态。支持常规上传和初始化后首次打包两种模式。
argument-hint: '<action> <params>'
user-invocable: false
---

# linyaps 产物流传与状态上报 SKILL

## 目录约定

- 上传脚本：`skills/linyaps-packaging-report/scripts/status_upload.sh`
- 初始化上传：`skills/linyaps-packaging-report/scripts/status_upload_initOnly.sh`
- 上传验证：`skills/linyaps-packaging-report/scripts/verify_upload.sh`
- 共享库：`skills/linyaps-packaging-report/scripts/common.sh`

## 脚本说明

| 脚本 | 用途 | 调用位置 |
|------|------|----------|
| `status_upload.sh` | 常规产物流传 + webhook 状态回传 | Step 7.6（非 init 场景） |
| `status_upload_initOnly.sh` | 初始化后首次打包的产物流传 + webhook 状态回传 | Step 7.6（init 场景） |
| `verify_upload.sh` | rclone 上传后通过 wget 验证文件可访问 | 被 `status_upload*.sh` 内部调用 |

## 调用方式

### 成功上传
```bash
bash skills/linyaps-packaging-report/scripts/status_upload.sh \
  "<pkgName>" "<arch>" "non-verified" \
  "<layer_file>" \
  "<orig_version>" "<linyapsPkgVer>" \
  "<placeholder>"
```

### 失败上传
```bash
bash skills/linyaps-packaging-report/scripts/status_upload.sh \
  "<pkgName>" "<arch>" "failed" "null" \
  "<orig_version>" "<orig_version>" \
  "<placeholder>"
```

### 脚本选择逻辑
```bash
UPLOAD_SCRIPT=$([ "$IS_INIT_ASSIGNED" = "true" ] || [ "$SRC_INIT_ASSIGNED" = "true" ] \
  && echo "skills/linyaps-packaging-report/scripts/status_upload_initOnly.sh" \
  || echo "skills/linyaps-packaging-report/scripts/status_upload.sh")
```

## 约束

1. **不阻断流程**：上传失败不影响后续任务，仅记录警告
2. **依赖 rclone 和 curl**：rclone 用于 S3 上传，curl 用于 webhook 通知
3. **与 dispatch 解耦**：仅负责上传与回报，不涉及指派逻辑