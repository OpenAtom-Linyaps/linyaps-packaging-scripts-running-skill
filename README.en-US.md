English | **[中文](README.md)**

# linyaps-packaging-scripts-running-skill

Automated task orchestration for [linyaps](https://linyaps.org.cn/) packaging. Reads task definitions from **JSON** or **CSV** files and dispatches them by `tasks[].type` to the matching sub-skill: **binary** (default) tasks run pre-adapted projects via `pak_linyaps.sh`; **source** tasks compile and package via `ll-builder build` + `ll-builder export`.

## Architecture

**Agent + Sub-Skill** two-layer architecture, orchestrated by an OpenCode Agent, with 4 independently encapsulated sub-skills.

```
User Task (JSON/CSV)
    │
    ▼
┌─────────────────────────────────────┐
│  linyaps-packaging-scripts-running-skill (Agent)   │  ← Entry: dispatch logic
│  ├─ reads agent-config.json         │
│  ├─ groups tasks by type            │
│  └─ dispatches to sub-skill         │
└──────────┬──────────────────────────┘
       type│                    type
    ┌──────┴──────┐      ┌──────┴──────┐
    │ binary      │      │ source      │
    │ (or unset)  │      │             │
    ▼             ▼      ▼             ▼
┌──────────────────────────┐ ┌──────────────────────────┐
│ linglong-binary-runner   │ │ linglong-source-updater  │
│                          │ │                          │
│ pak_linyaps.sh           │ │ ll-builder build         │
│                          │ │ ll-builder export        │
└──────────────────────────┘ └──────────────────────────┘
```

## Workflow

### Phase 1: Initialization

| Step | Responsibility | Helper script |
|------|----------------|---------------|
| 1.1 | Read `agent-config.json`, parse `global` and `version_extract_examples` | — |
| 1.2 | Resolve `${tag}`: substitute with `date +"%Y-%m-%d"` | — |
| 1.3 | Load task file: CSV → JSON first; JSON parsed directly | `csv_to_json.sh` |
| 1.4 | Pre-flight: binary checks `pak_linyaps.sh`; source validates `linglong.yaml` | `validate_projects.sh` / `validate-linglong-yaml.py` |

### Phase 2: Dispatch

| Task type | Sub-skill | Executor |
|-----------|-----------|----------|
| `binary` (default) | `linglong-binary-runner` | `run_tasks.sh` |
| `source` | `linglong-source-updater` | `run_tasks.sh` |

### Phase 3: Result Summary

Merge results from each sub-skill, tally success / failure, and print the final summary.

## Project Structure

```
.
├── agents/
│   └── linyaps-packaging-runner.agent.md   # Agent entry (dispatch logic)
├── agent-config.json                       # Global configuration
├── scripts/
│   ├── common.sh                           # Shared library (15 functions + build constraints)
│   └── check-agent-status.sh               # Agent health check
├── scripts-manifest.json                   # Script distribution map
├── skills/
│   ├── config/
│   │   └── arch_mapping.json               # URL arch keyword → linyaps arch
│   ├── linglong-binary-runner/             # [Sub-skill] binary packaging
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       ├── common.sh                   # Shared library (copy)
│   │       ├── run_tasks.sh                # Binary task executor
│   │       └── validate_projects.sh        # Pre-flight check
│   ├── linglong-source-updater/            # [Sub-skill] source compilation
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   └── manifests-for-yaml.md       # linglong.yaml field spec
│   │   └── scripts/
│   │       ├── common.sh                   # Shared library (copy)
│   │       ├── run_tasks.sh                # Source task executor (6 steps)
│   │       ├── download-and-checksum.sh    # Download + sha256 + analysis
│   │       ├── update-linglong-yaml.py     # Insert sources/build rules
│   │       └── validate-linglong-yaml.py   # Dual-mode YAML validator
│   └── linyaps-multica-packer-dispatch/    # [Sub-skill] Multica dispatch
│       ├── SKILL.md
│       └── scripts/
│           ├── common.sh                   # Shared library (copy)
│           ├── check-agent-status.sh       # Agent health check (copy)
│           ├── csv_to_json.sh              # CSV-to-JSON converter & unified entry
│           ├── detect_init_source.sh       # Init source detection
│           └── dispatch.sh                 # Dispatch orchestrator
└── task-example.json                       # Reference JSON (binary + source)
```

### Key Files Explained

| File | Description |
|------|-------------|
| `agents/linyaps-packaging-runner.agent.md` | **Agent entry** — reads config, groups tasks by `type`, dispatches to sub-skills |
| `skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh` | **Unified entry point** — accepts CSV or JSON, converts CSV to JSON, triggers agent dispatch |
| `scripts/common.sh` | Shared library used by all sub-skill scripts (colored output, parse_json, download, arch validation, build retry + timeout, etc.) |
| `skills/linglong-binary-runner/scripts/run_tasks.sh` | **Binary executor** — download → arch validation → run `pak_linyaps.sh` |
| `skills/linglong-source-updater/scripts/run_tasks.sh` | **Source executor** — 6-step pipeline (validate → download/checksum → update YAML → build → export) |
| `skills/config/arch_mapping.json` | Maps URL arch keywords (`amd64`, `x64`, `aarch64`) to linyaps arch identifiers (`x86_64`, `arm64`) |
| `task-example.json` | Reference JSON task file with both binary and source examples |

## Configuration

`agent-config.json` holds the global configuration (fixed path `WORKSPACE_ROOT/agent-config.json`):

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

| Field | Purpose | Default |
|-------|---------|---------|
| `projects_root` | Root directory of adapted packaging projects | `./projects` |
| `projects_repo` | Git repository URL (auto clone/pull) | empty string |
| `output_dir` | Output directory, supports `${tag}` placeholder | `./output/${tag}` |
| `data_dir` | Data log directory | `./data/${tag}.log` |
| `build_tmp_dir` | Build cache directory | `./build_cache` |
| `src_dir` | Source download directory | `./src` |

> **`${tag}` resolution rule**: Right after loading, every `${tag}` in a path is substituted with `date +"%Y-%m-%d"`; all subsequent steps use the resolved full path.

**Load order (highest priority first):**

1. `global` section of the task JSON
2. `global` section of `agent-config.json` (fallback)
3. Hardcoded defaults

## Task File Formats

### JSON Format

A JSON task file contains a `global` block and a `tasks` array (see `task-example.json`).

| Field | Required | Description |
|-------|----------|-------------|
| `pkgName` | **Yes** | Package name, used to locate the project directory (e.g., `com.opera.browser`) |
| `type` | No | Task type: `binary` (default) or `source` |
| `src_url` | **Yes** | Upstream source download URL |
| `arch` | **Yes** | Target architecture: `x86_64` or `arm64` |
| `orig_version` | No | Upstream version; auto-extracted from `src_url` if empty |
| `kind` | Source only | Source kind: `archive`, `git`, `file`, `dsc` (default: `archive`) |
| `name` | Source only | Source name field in the linglong.yaml `sources` entry (default: `src`) |

### CSV Format

CSV files must use UTF-8 encoding with the header: `记录ID,包名,架构,版本,网站地址,下载地址`.

| CSV Column | JSON Field | Required | Description |
|------------|------------|----------|-------------|
| `包名` | `pkgName` | **Yes** | Package name for project directory lookup |
| `架构` | `arch` | **Yes** | Target architecture (`x86_64` / `arm64`) |
| `版本` | `orig_version` | No | Upstream version; auto-extracted from URL if empty |
| `下载地址` | `src_url` | **Yes** | Upstream source download URL |

> **Note:** CSV tasks default to `type=binary`. For source tasks, use JSON format with `"type": "source"`.

## Execution Flow

### Binary (default)

`pak_linyaps.sh` is the only entry point, scoped to pre-adapted projects (directory contains `pak_linyaps.sh` + `templates/linglong.yaml`):

1. Extract version from URL (if not provided)
2. Validate architecture (URL vs declared arch)
3. Download upstream source package
4. Locate project (`CI_ll_<pkgName>` / `<pkgName>`)
5. Detect `--build_tmp_dir` support
6. Run `pak_linyaps.sh` (with retry + timeout)

> **Constraint**: Must NOT modify `linglong.yaml` or call `ll-builder` directly.

### Source

Scoped to source projects with a `linglong.yaml` but no `pak_linyaps.sh` — a 6-step pipeline:

| Step | Responsibility |
|------|----------------|
| S-1 | Validate input `linglong.yaml` (no `sources` section) |
| S-2 | Download + sha256 + directory analysis |
| S-3 | Insert `sources` + fix build rules |
| S-4 | Validate output `linglong.yaml` (has `sources`) |
| S-5 | `ll-builder build` |
| S-6 | `ll-builder export --layer --no-develop -z zstd`, move `.layer` to output_dir |

> **Constraint**: Input `linglong.yaml` must pass pre-validation; build rules must use `${PREFIX}` paths.

## Architecture Validation

Before downloading, the script validates that the declared architecture matches the one implied by the download URL:

| Result | Behavior |
|--------|----------|
| **MATCH** | ✅ Proceed with packaging |
| **MISMATCH** | ❌ Skip task, count as failure |
| **UNKNOWN** | ⚠️ Print LLM analysis prompt, continue execution |

## Testing

```bash
# Preview CSV → JSON (dry-run mode, no packaging)
./skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh my-tasks.csv --dry-run

# Execute packaging with your adapted projects
./skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh my-tasks.csv \
  --projects_root=/path/to/adapted/projects

# Direct execution with a JSON task file
./skills/linyaps-multica-packer-dispatch/scripts/csv_to_json.sh task-example.json
```

## Constraints

| Topic | Decision |
|-------|----------|
| Task dispatch | Group by `tasks[].type` (default `binary`), dispatch to the matching sub-skill |
| `${PREFIX}` install path | All install-directory args in the `build` section must use `${PREFIX}`; hardcoding `/usr` or `/usr/local` is forbidden (except `/usr` inside system commands such as `apt-get`, `dpkg`) |
| `.linyaps_genius` | Source `build` section must include `touch ${PREFIX}/.linyaps_genius` and `chmod -R 755 ${PREFIX}` |
| Retry & timeout | Each build task runs at most `MAX_BUILD_ATTEMPTS` (2) times, per-attempt timeout `BUILD_TIMEOUT_SEC` (1800s), 10s retry interval |
| Multi-arch | When versions differ across architectures, prefer the x86_64 build |
| Arch mapping | `arch_mapping.json` is authoritative; leave to LLM analysis when unrecognized |
| CSV encoding | UTF-8; supports both simplified (`下载地址`) and traditional (`下載地址`) Chinese headers |
| Version extraction | When `orig_version` is empty, match `version_extract_examples` regexes against the URL |
| Execution permission | `pak_linyaps.sh` must be executable (`chmod +x`) |
| Path convention | All script calls use paths relative to the workspace root; do not `cd` before executing |
