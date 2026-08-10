> [English](README.en-US.md) | **中文**

# linyaps 打包任务执行器

[linyaps](https://linyaps.org.cn/)（玲珑）打包脚本的自動化任務編排工具。從 **JSON** 或 **CSV** 任務文件讀取定義，按 `tasks[].type` 分派到對應子 SKILL：**binary**（預設）任務使用 `pak_linyaps.sh` 執行已適配項目打包；**source** 任務使用 `ll-builder build` + `ll-builder export` 執行源碼編譯打包。

## 架构

**Agent + Sub-Skill** 两层架构，由 OpenCode Agent 编排，4 个子 Skill 各自独立封装。

```
User Task (JSON/CSV)
    │
    ▼
┌─────────────────────────────────────┐
│  linyaps-packaging-runner (Agent)   │  ← 入口：分派逻辑
│  ├─ 读取 agent-config.json          │
│  ├─ 按 type 分组任务                │
│  └─ 分派到子 SKILL                  │
└──────────┬──────────────────────────┘
       type│                    type
    ┌──────┴──────┐      ┌──────┴──────┐
    │ binary      │      │ source      │
    │ (或未指定)   │      │             │
    ▼             ▼      ▼             ▼
┌──────────────────┐ ┌──────────────────────┐
│ linglong-binary- │ │ linglong-source-     │
│ runner           │ │ updater              │
│                  │ │                      │
│ pak_linyaps.sh   │ │ ll-builder build     │
│                  │ │ ll-builder export    │
└──────────────────┘ └──────────────────────┘
```

## 工作流

### Phase 1: 初始化

| 步骤 | 职责 | 辅助脚本 |
|------|------|----------|
| 1.1 | 读取 `agent-config.json`，解析 `global` 与 `version_extract_examples` | — |
| 1.2 | `${tag}` 路径解析：以 `date +"%Y-%m-%d"` 替换含 `${tag}` 的路径 | — |
| 1.3 | 加载任务文件：CSV 先转 JSON；JSON 直接解析 | `csv_to_json.sh` |
| 1.4 | 前置验证：binary 检查 `pak_linyaps.sh`；source 校验 `linglong.yaml` | `validate_projects.sh` / `validate-linglong-yaml.py` |

### Phase 2: 分派执行

| 任务类型 | 子 Skill | 执行脚本 |
|----------|----------|----------|
| `binary`（预设） | `linglong-binary-runner` | `run_tasks.sh` |
| `source` | `linglong-source-updater` | `run_tasks.sh` |

### Phase 3: 结果汇总

合并各子 SKILL 结果，分类统计成功 / 失败，输出最终统计。

## 目录结构

```
.
├── agents/
│   └── linyaps-packaging-runner.agent.md   # Agent 入口（分派逻辑）
├── agent-config.json                       # 全局配置
├── scripts/
│   ├── common.sh                           # 共享函数库（15 个函数 + 构建约束）
│   └── check-agent-status.sh               # Agent 健康检查
├── scripts-manifest.json                   # 脚本位置分布映射表
├── skills/
│   ├── config/
│   │   └── arch_mapping.json               # URL 架构关键字 → linyaps arch
│   ├── linglong-binary-runner/             # [子 SKILL] binary 打包
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       ├── common.sh                   # 共享库（副本）
│   │       ├── run_tasks.sh                # Binary 任务执行器
│   │       └── validate_projects.sh        # 前置检测
│   ├── linglong-source-updater/            # [子 SKILL] source 编译打包
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   └── manifests-for-yaml.md       # linglong.yaml 字段规范
│   │   └── scripts/
│   │       ├── common.sh                   # 共享库（副本）
│   │       ├── run_tasks.sh                # Source 任务执行器（6 步骤）
│   │       ├── download-and-checksum.sh    # 下载 + sha256 + 分析
│   │       ├── update-linglong-yaml.py     # 插入 sources/build 规则
│   │       └── validate-linglong-yaml.py   # 双模式 YAML 验证器
│   └── linyaps-multica-packer-dispatch/    # [子 SKILL] Multica 指派
│       ├── SKILL.md
│       └── scripts/
│           ├── common.sh                   # 共享库（副本）
│           ├── check-agent-status.sh       # Agent 健康检查（副本）
│           ├── csv_to_json.sh              # CSV 转 JSON & 统一入口
│           ├── detect_init_source.sh       # 初始化来源检测
│           └── dispatch.sh                 # 指派编排器
└── task-example.json                       # 参考 JSON（binary + source）
```

### 关键文件说明

| 文件 | 说明 |
|------|------|
| `agents/linyaps-packaging-runner.agent.md` | **Agent 入口** — 读取配置、按 `type` 分组任务、分派到子 SKILL |
| `skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh` | **统一入口** — 接受 CSV 或 JSON，转换后触发 Agent 分派 |
| `scripts/common.sh` | 所有子 SKILL 共享的函数库（颜色输出、parse_json、下载、架构验证、构建重试与超时等） |
| `skills/linglong-binary-runner/scripts/run_tasks.sh` | **Binary 执行器** — 下载 → 架构验证 → 执行 `pak_linyaps.sh` |
| `skills/linglong-source-updater/scripts/run_tasks.sh` | **Source 执行器** — 6 步骤管线（验证 → 下载校验 → 更新 YAML → 构建 → 导出） |
| `skills/config/arch_mapping.json` | URL 架构关键字（`amd64`、`x64`、`aarch64`）映射到 linyaps 架构（`x86_64`、`arm64`） |
| `task-example.json` | JSON 任务文件范例，含 binary 和 source 两种类型 |

## 配置

`agent-config.json` 全局配置（固定路径 `WORKSPACE_ROOT/agent-config.json`）：

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

| 字段 | 用途 | 预设值 |
|------|------|--------|
| `projects_root` | 已适配打包项目根目录 | `./projects` |
| `projects_repo` | Git 仓库 URL（自动 clone/pull） | 空字符串 |
| `output_dir` | 产出目录，支持 `${tag}` 占位符 | `./output/${tag}` |
| `data_dir` | 数据记录目录 | `./data/${tag}.log` |
| `build_tmp_dir` | 构建缓存目录 | `./build_cache` |
| `src_dir` | 资源下载目录 | `./src` |

> **`${tag}` 路径即时解析规则**：加载配置后立即以 `date +"%Y-%m-%d"` 替换 `${tag}` 为完整路径，后续所有步骤使用已解析的完整路径。

**载入顺序（优先级从高到低）**：

1. 任务 JSON 中的 `global` 区段
2. `agent-config.json` 的 global 区段（fallback）
3. 硬编码默认值

## 任务文件格式

### JSON 格式

JSON 任务文件包含 `global` 配置区块和 `tasks` 数组（见 `task-example.json`）。

| 字段 | 必填 | 说明 |
|------|------|------|
| `pkgName` | **是** | 包名，用于定位项目目录（如 `com.opera.browser`） |
| `type` | 否 | 任务类型：`binary`（预设）或 `source` |
| `src_url` | **是** | 上游资源下载地址 |
| `arch` | **是** | 目标架构：`x86_64` 或 `arm64` |
| `orig_version` | 否 | 上游版本号；为空时从 `src_url` 自动提取 |
| `kind` | Source 专用 | 源码类型：`archive`、`git`、`file`、`dsc`（预设：`archive`） |
| `name` | Source 专用 | linglong.yaml 中 sources 条目的 name 字段（预设：`src`） |

### CSV 格式

CSV 文件必须使用 UTF-8 编码，表头为：`记录ID,包名,架构,版本,网站地址,下载地址`。

| CSV 字段 | JSON 字段 | 必填 | 说明 |
|----------|-----------|------|------|
| `包名` | `pkgName` | **是** | 包名，用于项目目录查找 |
| `架构` | `arch` | **是** | 目标架构（`x86_64` / `arm64`） |
| `版本` | `orig_version` | 否 | 上游版本号；为空时从 URL 自动提取 |
| `下载地址` | `src_url` | **是** | 上游资源下载地址 |

> **注意：** CSV 任务预设为 `type=binary`。如需 source 类型，请使用 JSON 格式并设定 `"type": "source"`。

## 执行流程

### Binary（预设）

`pak_linyaps.sh` 为唯一入口，范围是已适配打包脚本的项目（目录下含 `pak_linyaps.sh` + `templates/linglong.yaml`）：

1. 从 URL 提取版本号（如未提供）
2. 架构验证（URL vs 宣告架构）
3. 下载上游资源
4. 定位项目（`CI_ll_<pkgName>` / `<pkgName>`）
5. 检测 `--build_tmp_dir` 支援
6. 执行 `pak_linyaps.sh`（含重试与超时）

> **约束**：严禁改写 `linglong.yaml` 或直接调用 `ll-builder`。

### Source（源码）

范围是含 `linglong.yaml` 但无 `pak_linyaps.sh` 的源码项目，6 步骤管线：

| 步骤 | 职责 |
|------|------|
| S-1 | 验证输入 `linglong.yaml`（无 sources 段） |
| S-2 | 下载 + sha256 + 目录分析 |
| S-3 | 插入 sources + 修正 build 规则 |
| S-4 | 验证输出 `linglong.yaml`（有 sources 段） |
| S-5 | `ll-builder build` |
| S-6 | `ll-builder export --layer --no-develop -z zstd`，移动 `.layer` 到 output_dir |

> **约束**：输入 `linglong.yaml` 必须通过预验证；build 规则必须使用 `${PREFIX}` 路径。

## 架构验证

下载前验证任务宣告架构与下载 URL 隐含架构是否匹配：

| 结果 | 行为 |
|------|------|
| **MATCH** | ✅ 继续执行打包 |
| **MISMATCH** | ❌ 跳过任务，计入失败统计 |
| **UNKNOWN** | ⚠️ 输出 LLM 分析提示，继续执行 |

## 测试

```bash
# 预览 CSV 转 JSON（dry-run 模式，不执行打包）
./skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh my-tasks.csv --dry-run

# 使用已适配项目执行打包
./skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh my-tasks.csv \
  --projects_root=/path/to/adapted/projects

# 直接使用 JSON 任务文件
./skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh task-example.json
```

## 约束条件

| 议题 | 决策 |
|------|------|
| 任务分派 | 按 `tasks[].type` 分组（预设 `binary`），分别分派到对应子 SKILL |
| `${PREFIX}` 安装目录 | `build` 段所有安装目录参数必须使用 `${PREFIX}`，禁止硬编码 `/usr` 或 `/usr/local`（系统命令如 `apt-get`、`dpkg` 中的 `/usr` 除外） |
| `.linyaps_genius` | source 的 build 段必须包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}` |
| 重试与超时 | 每个构建任务最多 `MAX_BUILD_ATTEMPTS`（2）次，单次超时 `BUILD_TIMEOUT_SEC`（1800 秒），重试间隔 10 秒 |
| 多架构 | 多架构版本不一致时，优先使用 x86_64 架构的版本 |
| 架构映射 | `arch_mapping.json` 为主，无法识别时留给 LLM 分析 |
| CSV 编码 | UTF-8 编码，同时支持简体（下载地址）和繁体（下載地址）中文表头 |
| 版本提取 | `orig_version` 为空时，匹配 `version_extract_examples` 正则从 URL 提取 |
| 执行权限 | `pak_linyaps.sh` 需具有执行权限（`chmod +x`） |
| 路径约定 | 所有脚本调用使用相对于 workspace 根目录的路径，不使用 `cd` 切换后执行 |
