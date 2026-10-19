#!/usr/bin/env bash
set -euo pipefail

VERSION="1.1.0"
DEFAULT_WORKSPACE="linyaps"

UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

usage() {
	cat <<EOF
check-agent-status.sh v$VERSION

用法: $(basename "$0") [选项] [agent ...]

检查指定 workspace 中一个或多个 agent 的运行状态，列出正在运行的任务（排除已结束任务）。

选项:
  -w, --workspace <slug>   工作空间 slug（默认: $DEFAULT_WORKSPACE）
  -n, --name     <name>    单个 agent 名称（与 -u 互斥）
  -u, --uuid     <uuid>    单个 agent UUID（与 -n 互斥）
  -o, --output   <format>  输出格式: table / json（默认 table）
  -h, --help               显示此帮助信息

模式:
  -n <name>     按名称查询单个 agent
  -u <uuid>     按 UUID 查询单个 agent
  位置参数       批量查询多个 agent（自动识别 name/uuid）

示例:
  $(basename "$0") -n linyaps-packer-1
  $(basename "$0") -w linyaps -u 353646a1-0adb-4e5f-be22-1de300ef4104 -o json
  $(basename "$0") linyaps-packer-1 linyaps-packer-2 -o json
EOF
	exit 0
}

WORKSPACE="$DEFAULT_WORKSPACE"
AGENT_NAME=""
AGENT_UUID=""
OUTPUT="table"
AGENTS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-w | --workspace)
		WORKSPACE="$2"
		shift 2
		;;
	-n | --name)
		AGENT_NAME="$2"
		shift 2
		;;
	-u | --uuid)
		AGENT_UUID="$2"
		shift 2
		;;
	-o | --output)
		OUTPUT="$2"
		shift 2
		;;
	-h | --help) usage ;;
	-*)
		echo "未知选项: $1" >&2
		usage
		;;
	*)
		AGENTS+=("$1")
		shift
		;;
	esac
done

# -n 和 -u 互斥
if [[ -n "$AGENT_NAME" && -n "$AGENT_UUID" ]]; then
	echo "错误: --name 和 --uuid 互斥" >&2
	usage
fi

# --name/--uuid 与批量位置参数互斥
if [[ -n "$AGENT_NAME" || -n "$AGENT_UUID" ]] && [[ ${#AGENTS[@]} -gt 0 ]]; then
	echo "错误: --name/--uuid 与批量模式（位置参数）互斥" >&2
	usage
fi

# 三者皆空报错
if [[ -z "$AGENT_NAME" && -z "$AGENT_UUID" && ${#AGENTS[@]} -eq 0 ]]; then
	echo "错误: 必须指定 --name、--uuid 或至少一个 agent（批量模式）" >&2
	usage
fi

if [[ "$OUTPUT" != "table" && "$OUTPUT" != "json" ]]; then
	echo "错误: --output 必须是 table 或 json" >&2
	usage
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------- [1/3] switch workspace ----------
echo "[1/3] 切换 workspace ..." >&2
multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
WORKSPACE_ID=$(multica workspace list --output json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    L=d if isinstance(d,list) else d.get('workspaces', d.get('items', []))
    slug=sys.argv[1]
    for w in L:
        if w.get('slug')==slug:
            print(w['id']); break
except Exception:
    pass
" "$WORKSPACE" 2>/dev/null)
echo "       workspace: $WORKSPACE → ${WORKSPACE_ID:-N/A}" >&2

# ---------- query_single_agent ----------
# $1=target (name or uuid), $2=match_field ("name"/"id"), $3=prefix (for batch temp files)
# Writes ${prefix}result.json + ${prefix}running_tasks.json; creates ${prefix}not_found on miss.
# Returns 0 on found, 1 on not found.
query_single_agent() {
	local target="$1" match_field="$2" prefix="${3:-}"
	local agents_file="$TMPDIR/agents.json"

	if [[ ! -f "$agents_file" ]]; then
		multica agent list --output json >"$agents_file" 2>&1 || true
	fi

	local agent_id
	agent_id=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
target = sys.argv[2]
field = sys.argv[3]
for a in data:
    if a.get(field) == target:
        out = {'id': a['id'], 'name': a['name'], 'status': a.get('status','unknown'), 'updated_at': a.get('updated_at', '')}
        json.dump(out, open(sys.argv[4] + 'result.json', 'w'), ensure_ascii=False)
        print(a['id'])
        sys.exit(0)
open(sys.argv[4] + 'not_found', 'w').write('')
" "$agents_file" "$target" "$match_field" "$TMPDIR/${prefix}" 2>/dev/null) || true

	if [[ -f "$TMPDIR/${prefix}not_found" ]] || [[ -z "$agent_id" ]]; then
		return 1
	fi

	# Query running tasks for this agent
	multica agent tasks "$agent_id" --output json >"$TMPDIR/${prefix}tasks.json" 2>&1 || true

	python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    running = [t for t in data if t.get('status') == 'running']
except Exception:
    running = []
json.dump(running, open(sys.argv[2], 'w'), indent=2, ensure_ascii=False)
" "$TMPDIR/${prefix}tasks.json" "$TMPDIR/${prefix}running_tasks.json" 2>/dev/null

	return 0
}

# ---------- [2/3] find agent ----------
echo "[2/3] 查找 agent ..." >&2

if [[ -n "$AGENT_NAME" ]]; then
	if ! query_single_agent "$AGENT_NAME" name ""; then
		echo "错误: 未找到 name 为 '$AGENT_NAME' 的 agent" >&2
		exit 1
	fi
	MODE="single"
elif [[ -n "$AGENT_UUID" ]]; then
	if ! query_single_agent "$AGENT_UUID" id ""; then
		echo "错误: 未找到 uuid 为 '$AGENT_UUID' 的 agent" >&2
		exit 1
	fi
	MODE="single"
else
	MODE="batch"
	for i in "${!AGENTS[@]}"; do
		agent="${AGENTS[$i]}"
		prefix="agent_${i}_"
		if [[ "$agent" =~ ^${UUID_RE}$ ]]; then
			match_field="id"
		else
			match_field="name"
		fi
		if ! query_single_agent "$agent" "$match_field" "$prefix"; then
			: # not_found marker file already created; continue
		fi
	done
fi

# ---------- [3/3] query tasks (done inside query_single_agent) ----------
echo "[3/3] 查询任务状态 ..." >&2

# ---------- output ----------
if [[ "$MODE" == "single" ]]; then
	AGENT_ID=$(python3 -c "import json; print(json.load(open('$TMPDIR/result.json'))['id'])")
	AGENT_NAME_OUT=$(python3 -c "import json; print(json.load(open('$TMPDIR/result.json'))['name'])")
	AGENT_STATUS=$(python3 -c "import json; print(json.load(open('$TMPDIR/result.json'))['status'])")
	AGENT_UPDATED=$(python3 -c "import json; print(json.load(open('$TMPDIR/result.json')).get('updated_at', ''))")
	RUNNING_COUNT=$(python3 -c "import json; print(len(json.load(open('$TMPDIR/running_tasks.json'))))")
	echo "       agent: $AGENT_NAME_OUT → $AGENT_ID (status: $AGENT_STATUS)" >&2

	if [[ "$OUTPUT" == "json" ]]; then
		python3 -c "
import json
agent = json.load(open('$TMPDIR/result.json'))
running = json.load(open('$TMPDIR/running_tasks.json'))
result = {
    'workspace': {'slug': '$WORKSPACE', 'id': '$WORKSPACE_ID'},
    'agent': agent,
    'running_tasks': running
}
print(json.dumps(result, indent=2, ensure_ascii=False))
"
	else
		echo ""
		echo "Agent: $AGENT_NAME_OUT ($AGENT_ID)"
		echo "状态: $AGENT_STATUS"
		if [[ -n "$AGENT_UPDATED" ]]; then
			echo "最后活跃: $AGENT_UPDATED"
		fi
		if [[ "$AGENT_STATUS" == "idle" ]]; then
			echo "无运行中任务"
		else
			if [[ "$RUNNING_COUNT" -gt 0 ]]; then
				echo "运行中任务 ($RUNNING_COUNT):"
				echo ""
				python3 -c "
import json
tasks = json.load(open('$TMPDIR/running_tasks.json'))
print(f'{\"TASK ID\":<40} {\"STATUS\":<12} {\"CREATED_AT\":<25}')
print('-' * 80)
for t in tasks:
    tid = t['id']
    st = t['status']
    ca = t.get('created_at', '')
    print(f'{tid:<40} {st:<12} {ca:<25}')
        "
				echo "---"
				echo "Total: $RUNNING_COUNT running tasks"
			else
				echo "无运行中任务（状态非 idle，但无 running 任务）"
			fi
		fi
	fi
else
	# batch mode output
	printf '%s\n' "${AGENTS[@]}" >"$TMPDIR/batch_agents.txt"
	python3 -c "
import json, os, sys

tmpdir = sys.argv[1]
workspace = sys.argv[2]
workspace_id = sys.argv[3]
agents = [line.strip() for line in open(os.path.join(tmpdir, 'batch_agents.txt')) if line.strip()]

results = []
idle_count = 0
busy_count = 0
not_found_count = 0

for i, agent in enumerate(agents):
    prefix = f'agent_{i}_'
    result_file = os.path.join(tmpdir, prefix + 'result.json')
    not_found_file = os.path.join(tmpdir, prefix + 'not_found')
    running_file = os.path.join(tmpdir, prefix + 'running_tasks.json')

    if os.path.exists(not_found_file):
        results.append({'query': agent, 'found': False, 'status': 'not_found'})
        not_found_count += 1
        continue

    agent_data = json.load(open(result_file))
    running = json.load(open(running_file)) if os.path.exists(running_file) else []
    status = agent_data.get('status', 'unknown')
    if status == 'idle':
        idle_count += 1
    else:
        busy_count += 1
    results.append({
        'query': agent,
        'found': True,
        'agent': agent_data,
        'running_count': len(running),
        'running_tasks': running
    })

output = {
    'workspace': {'slug': workspace, 'id': workspace_id},
    'agents': results,
    'idle_count': idle_count,
    'busy_count': busy_count,
    'not_found_count': not_found_count
}
print(json.dumps(output, indent=2, ensure_ascii=False))
" "$TMPDIR" "$WORKSPACE" "$WORKSPACE_ID"
fi
