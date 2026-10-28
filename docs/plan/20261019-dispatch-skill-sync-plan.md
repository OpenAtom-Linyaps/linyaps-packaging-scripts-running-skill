# 同步计划：上游 c444129 + 03df31d → linyaps-packaging-scripts-running-skill（type 字段过滤版）

## 0. 目标与范围

将上游 `linyaps-app-packaging-script-generator.master` dev 分支最后两次提交（c444129 `feat(dispatch): random tie-break for candidate selection`、03df31d `feat(for-multica): switch agent dispatch to uuid-based`）的**可移植概念**同步到本仓库 `skills/linyaps-multica-packer-dispatch`，并按用户指令**反转核心设计**：agent 选择主体由 LLM 运行时决策改为**脚本端候选池选择**。

**用户指令关键点**（含最新修正）：
1. 「此项目dispatch统一LLM改为脚本」= 脚本接管 agent 选择决策。
2. 「当前方案不适用于上游变更, 因为存在src、binary init两类agent, 不能直接迁移随机random dispatch方案, 研究是否有更优方案」= 研究更优方案（非纯随机）。
3. 「能力不基于cli_name, 而是精确type类」= 按 `type` 精确类型类过滤，不引入 `cli_name`。
4. **最新修正**：「type应设置到agent信息中, 和uuid并级, config直接看到agent对应uuid+binary/src」= config 每个 agent 顶层加 `type` 字段（`"binary"`/`"source"`，与 `uuid` 并级），过滤条件简化为 `agent.type == $TYPE`。**移除 `--type`→capability（`project_init`/`src_project_init`）映射**，移除 `TARGET_CAPABILITY` 中间变量，移除 capabilities[] 过滤分支。
5. 身份标识 = **uuid-based**（03df31d 核心）：config `uuid` 字段填**真实 multica agent UUID**（非空串），脚本直查 multica。

**研究结论**：
- 用户「两类 agent」顾虑**已被 `type` 字段过滤解决**——每个 agent 顶层声明自己是 `binary` 还是 `source` 类，脚本按 `--type` 直选同类 agent，idle 优先/负载感知决胜只在同类池内运行，不跨类。
- **更优方案（负载感知，优于上游纯随机）**：无 idle 候选时，选 `running_tasks` 最少的 agent，并列随机，避免压垮已繁忙 agent。
- **config↔multica 配对**：config `uuid` 填真实 multica agent UUID（用户决策 §1.0），脚本 `-u <uuid>` 直查 multica，无需 name 桥接。config 中文 `name` 仅作展示，不参与 multica 查询。
- **type 字段与 capabilities 共存**：保留现有 `capabilities` 数组（其他 agent 如 upstream-tracker、packer-1/2 仍用），只对 init 类 agent 加 `type` 字段作 dispatch 过滤键。非 init 类 agent（packer）`type` 字段可省略（dispatch 不选它们）。

| 维度 | 参考仓库 `linyaps-binary-init-dispatch` | 本仓库 `linyaps-multica-packer-dispatch`（新设计） |
|------|----------------------------------------|----------------------------------------------------|
| Action 数 | 2（`update_issue_status`、`dispatch_git_commit_success`） | 4（`detect_init_source`、`dispatch_project_not_found`、`update_issue_status`、`post_fix_log`） |
| Agent 选择主体 | 脚本内多候选池 + idle 优先 + 随机决胜 | **脚本内多候选池 + idle 优先 + 负载感知决胜**（旧：LLM 运行时单 agent） |
| 候选过滤键 | `linyaps_packaging` capability（单类） | **`agent.type == $TYPE`**（binary/source 两类，config 顶层 `type` 字段，移除 capability 映射） |
| 配置字段 | `assignment.agents[].uuid`（03df31d，空串→name 回退） | `assignment.agents[].uuid`（**填真实值**，非空）+ `assignment.agents[].type`（binary/source） |
| check-agent-status | 支持 `-n/-u` + `AGENTS` 批量（03df31d 后） | 仅 `-n/--name`（技能副本 + 根副本均旧版）→ 升级三模式 |
| UUID 解析 | config uuid 优先 → `resolve_agent` 名称回退 | config uuid 必填非空 → 直查 multica；`--agent-name` 覆盖路径走 `get_agent_uuid_by_name` |
| 决胜策略 | idle 优先 + 纯随机（无负载感知） | idle 优先 + **负载感知**（最少 running 优先，并列随机） |

## 1. 概念可移植性分析

### 1.0 关键决策：config `uuid` + `type` 字段（用户决策，含最新修正）

**问题**：脚本端候选过滤需将匹配的 config agent 解析为 multica 实体才能查状态。本仓库 config 现状：
- `init-tracker`: `id:"init-tracker"`, `name:"二進制打包初始化適配智能體"`（中文展示名，**非** multica CLI name），`capabilities:["project_init",...]`
- `linyaps-src-init-1/2`: `id:"linyaps-src-init-1/2"`, `name:"源码構建初始化智能體"`，`capabilities:["src_project_init",...]`

multica `agent list` 返回的 `name` 是 CLI 真实名（与 config `id`/`name` 均不匹配），且**不返回 `capabilities`/`type` 字段**。故脚本无法：
- 从 multica 按能力/类型过滤（无该字段）；
- 用 config `name` 调 `resolve_agent`/`get_agent_uuid_by_name`（中文 name ≠ multica CLI name）。

**用户决策（uuid_source=config uuid 填真实值 + type 字段过滤）**：
- config `assignment.agents[]` 新增 `uuid` 字段填**真实 multica agent UUID**（非 03df31d 的空串）。脚本拿 config 候选的 `uuid` 直接 `check-agent-status.sh -u <uuid>` 查状态，无需 name 桥接。
- config `assignment.agents[]` **init 类 agent 新增 `type` 字段**（`"binary"`/`"source"`，与 `uuid` 并级），过滤条件简化为 `agent.type == $TYPE`。脚本不再做 `--type`→capability 映射，不再过滤 `capabilities`。
- config 中文 `name` 仅作展示。

**候选池容量（candidate_count=config 同 type 实际成员数）**：`agent_candidates()` 按 `--type` 过滤 config `agent.type`，池内成员数即实际候选数。binary 池 = `[init-tracker]`（1 个，无决胜空间，但 load-aware 仍适用无 idle 路径），source 池 = `[linyaps-src-init-1, linyaps-src-init-2]`（2 个，决胜可触发）。

**实现**：
- `for-multica/agent-config.json`：init 类 agent 加 `uuid` + `type` 字段；packer 类 agent 加 `uuid`（非 dispatch 目标，type 可省）。**真实 UUID 需部署后 `multica agent list` 查得回填**；实施时先用占位 UUID（符合 `UUID_RE` 格式）保证脚本逻辑可测，并在 SKILL.md 标注「部署时回填真实 UUID」。
- `dispatch.sh` `agent_candidates()`：按 `$TYPE` 过滤 `agent.type`，emit `cfg_id<TAB>cfg_uuid<TAB>cfg_name`（cfg_name 仅作展示/指派 mention，cfg_uuid 是 multica 查询键）。
- 候选循环：`is_uuid(cfg_uuid)` 校验 → 成功进 `valid_list`（查状态 `check-agent-status.sh -u "$cfg_uuid"`）；失败进 `invalid_uuid_list`（仅记录 `cfg_id<TAB>cfg_name`，不查状态——uuid 无效无法查询）。**id fallback（用户最新修正）**：`valid_list` 为空且 `invalid_uuid_list` 非空时，从 `invalid_uuid_list` 随机选一个，用 `cfg_id` 直接作 `--to-id` 值指派（`mention://agent/<cfg_id>`）。正常路径（valid_list 非空）走 uuid，不触发 fallback。
- **`--agent-name` 覆盖路径**仍走 `get_agent_uuid_by_name`（LLM 传入的是 multica CLI name，可解析），与脚本选择路径分离。


### 1.0.1 id fallback 决策（用户修正 3，最新）

**触发条件**：候选循环中所有候选的 `cfg_uuid` 都 `is_uuid` 失败（`valid_list` 为空），但 `invalid_uuid_list` 非空（即 config `type` 匹配的候选存在，只是 uuid 字段全部无效/空）。

**fallback 行为**：从 `invalid_uuid_list` 随机选一个（`idx=$((RANDOM % ${#invalid_uuid_list[@]}))`），用该候选的 `cfg_id` 直接作 multica `--to-id` 值指派，mention 用 `[@${cfg_name}](mention://agent/${cfg_id})`。**不查状态**（uuid 无效，`check-agent-status.sh -u` 无法查询；id 非 multica name，`-n` 也无法查询——fallback 路径无状态感知，纯随机降级）。

**设计依据（用户选定「id 直传 --to-id」）**：假设 multica `--to-id` 接受非 UUID 的 agent 标识（如 agent slug/id）。此假设未由本仓库代码或测试 mock 证实——测试 mock `assign` 分支直接 `exit 0` 不校验 `--to-id` 值（test_dispatch_uuid.py L75），故测试可通过；真实 multica 行为需部署时验证。

**与 issue-68 约束的冲突标注**：`docs/issue-68-agent-skills-impact-plan.md:43` 明确「指派必须使用 `--to-id <uuid>`，mention 必须使用 `mention://agent/<uuid>`」。id fallback 违反此 UUID-only 约束，作为**紧急降级路径**存在——当所有 config uuid 都失败时，宁可尝试 id 直传也不放弃指派。SKILL.md 需标注此降级路径的约束冲突与部署验证要求。

**config `id` 字段保留**：config `assignment.agents[]` 的 `id` 字段不删除（用户明确「id字段需要保留」）。正常路径不使用 `id`（用 `uuid`）；仅 fallback 路径使用。`agent_candidates()` emit 仍含 `cfg_id`（`cfg_id<TAB>cfg_uuid<TAB>cfg_name`），fallback 时从 `invalid_uuid_list` 取 `cfg_id`。

**测试覆盖**：`test_id_fallback_when_uuid_invalid`——mock config 所有候选 uuid 为空串/无效，验证 dispatch 用 cfg_id 作 `--to-id`、mention 含 cfg_id，输出 `assigned:true, reason:id_fallback`。
### 1.1 c444129 — 随机决胜候选选择 ✅ 可移植（升级为负载感知）

**参考行为**：`agent_candidates()` 收集所有具备 `linyaps_packaging` 能力的 agent，两阶段构建 `valid_list[]`/`idle_list[]`（元素 `name<TAB>uuid<TAB>status`），`pool = idle_list || valid_list`，`idx=$((RANDOM % ${#pool[@]}))`。

**新设计为何可移植**：脚本端构建候选池后，c444129 两阶段（valid/idle）+ 池内决胜可移植。用户「两类 agent」顾虑已被 `agent.type == $TYPE` 过滤解决：随机只在同类池内运行，不跨类。

**更优方案（负载感知，优于上游纯随机）**：无 idle 候选时，上游从 `valid_list` 全体随机抽；本仓库改为按 `running_count` 升序取最小值组，组内随机。check-agent-status.sh `-u` 模式返回 `running_tasks` 数组，复用现有数据，零额外 API 往返。

### 1.2 c444129 — f-string SyntaxError 修复 ❌ 不适用

本仓库 f-string 无大括号内反斜杠，无可修复对象。

### 1.3 03df31d — `check-agent-status.sh` 增加 `-u/--uuid` + `AGENTS` 批量 ✅ 可移植

**参考行为**：新增 `-u/--uuid`（与 `-n` 互斥）；抽取 `query_single_agent(target, match_field, prefix)`；三模式（`-n`/`-u`/`AGENTS`）；批量输出 glob 过滤辅助文件。

**本仓库适配**：保留 workspace 解析的 `switch || true` + `list` 双保险（热备非阻断），**不**照搬参考 `exit 1` 硬失败。升级技能副本 + 根副本两份避免漂移。

### 1.4 03df31d — config `agent_file:null` → `uuid:""` ✅ 可移植（升级为真实值 + type 字段）

**参考行为**：`agent_file:null` → `uuid:""`（空串回退 name 解析）。

**本仓库适配**：init 类 agent `agent_file:null` → `uuid:"<真实 multica UUID>"` + `type:"binary"/"source"`（**非空**，因 config name 非 CLI name，回退必失败）。packer 类 agent 加 `uuid`（type 省略，非 dispatch 目标）。upstream-tracker 的 `agent_file` 有路径，保留不动（非 dispatch 目标）。**不新增 `cli_name`**（用户禁止）。

### 1.5 03df31d — `dispatch.sh` UUID 优先 + `-u` 调用 ✅ 可移植

**本仓库适配**：候选循环 `is_uuid(cfg_uuid)` 校验（config uuid 非空真实值），`check-agent-status.sh -u "$cfg_uuid"` 查状态。无 name 回退（config name 非 CLI name）。`--agent-name` 覆盖路径独立走 `get_agent_uuid_by_name`。

### 1.6 03df31d — SKILL.md 文档 ✅ 可移植

反转 §约束 5：脚本决策（`type` 字段过滤 + idle 优先 + 负载感知决胜，`--agent-name` 可选覆盖）。

## 2.5 范围决策

**纳入本次**：步骤 A-F（技能内部 dispatch 概念同步 + config `uuid`+`type` 字段 + 负载感知决胜）。

**显式延后**：根 `scripts/common.sh` / 根 `scripts/` 目录去留——属独立设计决策。本次根副本 `check-agent-status.sh` 同步升级避免漂移，不删。

## 2. 实施步骤（按依赖序）

### 步骤 A：升级 `check-agent-status.sh`（技能副本 + 根副本）

**文件**：
- `skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh`
- `scripts/check-agent-status.sh`（根副本同步升级避免漂移）

**改动**（对齐参考 03df31d，保留本仓库 workspace 双保险语义）：
1. 顶部加 `AGENTS=()` 数组 + `AGENT_UUID=""` 变量 + 注释。
2. `usage()` 增加 `-u/--uuid` 选项说明、批量模式示例、描述改「一个或多个 agent」。
3. 参数解析加 `-u|--uuid) AGENT_UUID="$2"; shift 2 ;;`。
4. 模式判断：`-n`/`-u`/`AGENTS` 三选一，`-n`+`-u` 互斥报错；三者皆空报错。
5. 抽取 `query_single_agent(target, match_field, prefix)`，写 result.json + running_tasks.json，not-found 返回 1。
6. `[2/3]` 分三支：`-n` → `query_single_agent name`；`-u` → `query_single_agent id`；无参数 → 遍历 `AGENTS` 批量。
7. 输出分单 agent / 批量两路；批量 JSON 含 `idle_count`/`busy_count`，glob 过滤 `_tasks.json`/`_running_tasks.json`。
8. **保留**本仓库 workspace 解析的 `switch || true` + `list` 双保险，不采用参考 `exit 1`。

**验证**：`bash -n` 两份；`-n` 模式回归（现有测试）；新增 `-u` 模式冒烟。

### 步骤 B：迁移 `agent-config.json`（`uuid` + `type` 字段）

**文件**：`for-multica/agent-config.json`

**改动**（init 类 agent 加 `uuid`+`type`，packer 类只加 `uuid`）：
1. `init-tracker` → 加 `"uuid":"<binary init agent UUID 占位>", "type":"binary"`（保留 `capabilities` 不动）。
2. `linyaps-src-init-1` → 加 `"uuid":"<source init agent UUID 1 占位>", "type":"source"`。
3. `linyaps-src-init-2` → 加 `"uuid":"<source init agent UUID 2 占位>", "type":"source"`。
4. `linyaps-packer-1` → 加 `"uuid":"<packer agent UUID 1 占位>"`（不加 `type`，非 dispatch 目标）。
5. `linyaps-packer-2` → 加 `"uuid":"<packer agent UUID 2 占位>"`（同上）。
6. `upstream-tracker` 的 `agent_file` 保留不动（非 dispatch 目标）。
7. **不新增 `cli_name`**（用户禁止）。占位 UUID 符合 `UUID_RE` 格式，部署时回填真实值。
8. SKILL.md 标注「部署时回填真实 multica agent UUID」。

**验证**：`python3 -c "import json; json.load(open('for-multica/agent-config.json'))"`。

### 步骤 C（核心重构）：`dispatch.sh` 脚本端候选选择 + 负载感知决胜

**文件**：`skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh`（`dispatch_project_not_found` L112-150 重构）

**改动**：

1. **移除 `--type`→capability 映射**（L112-116 删除）：
   ```bash
   # 旧：if [[ "$TYPE" == "binary" ]]; then TARGET_CAPABILITY="project_init"; else TARGET_CAPABILITY="src_project_init"; fi
   # 新：直接用 $TYPE 作过滤键，无中间变量
   ```

2. **`--agent-name` 覆盖路径**（保留，L139-150 改为覆盖分支）：传了 `--agent-name` 跳过候选选择，直接用该 agent（兼容现有 8 个测试均传 `--agent-name`）。走 `get_agent_uuid_by_name "$TARGET_AGENT_NAME"` 解析 UUID，`check-agent-status.sh -u "$uuid"` 查状态。

3. **`--agent-name` 未传 → 脚本端候选选择**（新增分支，替换 L118-143）：
   ```bash
   # agent_candidates() 按 $TYPE 过滤 config agent.type，emit cfg_id<TAB>cfg_uuid<TAB>cfg_name
   agent_candidates() { python3 -c '
   import json,sys
   c=json.load(open(sys.argv[1])); t=sys.argv[2]
   for a in c.get("assignment",{}).get("agents",[]):
     if a.get("type")==t:
       print("{}\t{}\t{}".format(a.get("id",""), a.get("uuid",""), a.get("name","")))' "$CONFIG_FILE" "$TYPE"; }

   mapfile -t candidates < <(agent_candidates)
   if ((${#candidates[@]}==0)); then
     output_json "{\"assigned\":false,\"target_agent\":\"\",\"reason\":\"no_candidate\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
     exit 0
   fi

   idle_list=()           # 元素: cfg_id<TAB>cfg_uuid<TAB>cfg_name<TAB>status<TAB>running_count
   valid_list=()          # uuid 校验成功 + 状态查询后的候选（含 idle/busy/unknown）
   invalid_uuid_list=()   # 元素: cfg_id<TAB>cfg_name  ← uuid 校验失败的候选（id fallback 池）
   for line in "${candidates[@]}"; do
     cfg_id="${line%%$'\t'*}"; rest="${line#*$'\t'}"
     cfg_uuid="${rest%%$'\t'*}"; cfg_name="${rest#*$'\t'}"
     if ! is_uuid "$cfg_uuid"; then
       echo "warning: invalid/empty uuid in config for $cfg_id; queued for id fallback" >&2
       invalid_uuid_list+=("$cfg_id"$'\t'"$cfg_name")
       continue
     fi
     status="unknown"; running_count=0
     if status_json=$(bash "$SCRIPT_DIR/check-agent-status.sh" ${WORKSPACE:+-w "$WORKSPACE"} -u "$cfg_uuid" -o json 2>/dev/null); then
       status=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("agent",{}).get("status","unknown"))' <<<"$status_json" 2>/dev/null) || status=unknown
       running_count=$(python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("running_tasks",[])))' <<<"$status_json" 2>/dev/null) || running_count=0
     fi
     valid_list+=("$cfg_id"$'\t'"$cfg_uuid"$'\t'"$cfg_name"$'\t'"$status"$'\t'"$running_count")
     [[ "$status" == idle ]] && idle_list+=("$cfg_id"$'\t'"$cfg_uuid"$'\t'"$cfg_name"$'\t'"$status"$'\t'"$running_count")
   done

   # 决胜路径选择：valid_list 非空 → 负载感知；全空 + invalid_uuid_list 非空 → id fallback
   if ((! ${#valid_list[@]})); then
     if ((${#invalid_uuid_list[@]})); then
       # id fallback：所有候选 uuid 都无效 → 用 cfg_id 直传 --to-id（无状态感知，纯随机）
       idx=$((RANDOM % ${#invalid_uuid_list[@]}))
       fb="${invalid_uuid_list[$idx]}"
       cfg_id="${fb%%$'\t'*}"; cfg_name="${fb#*$'\t'}"
       TARGET_AGENT_UUID="$cfg_id"          # 非 UUID，直接作 --to-id 值
       TARGET_AGENT_NAME="$cfg_name"        # 展示名，用于 mention
       AGENT_STATUS="unknown"               # 无状态感知
       ID_FALLBACK=1                        # 标记后续 mention/assign 走 id 路径
     else
       output_json "{\"assigned\":false,\"target_agent\":\"\",\"reason\":\"no_candidate\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
       exit 0
     fi
   else
     # 负载感知决胜：idle 优先；无 idle 选最少 running，并列随机
     if ((${#idle_list[@]})); then
       pool=("${idle_list[@]}"); idx=$((RANDOM % ${#pool[@]}))
     else
       min_count=$(printf '%s\n' "${valid_list[@]}" | awk -F'\t' '{print $5}' | sort -n | head -1)
       mapfile -t min_pool < <(printf '%s\n' "${valid_list[@]}" | awk -F'\t' -v mc="$min_count" '$5==mc')
       pool=("${min_pool[@]}"); idx=$((RANDOM % ${#pool[@]}))
     fi
     chosen="${pool[$idx]}"
     cfg_id="${chosen%%$'\t'*}"; rest="${chosen#*$'\t'}"
     TARGET_AGENT_UUID="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
     cfg_name="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
     AGENT_STATUS="${rest%%$'\t'*}"
     TARGET_AGENT_NAME="$cfg_name"  # 展示名，用于 mention
     ID_FALLBACK=0
   fi
   ```

4. 指派逻辑（L182-212）按 `ID_FALLBACK` 分支：
   - `ID_FALLBACK==0`（正常路径）：`mention://agent/${TARGET_AGENT_UUID}`（UUID），`--to-id "$TARGET_AGENT_UUID"`。
   - `ID_FALLBACK==1`（id fallback）：`mention://agent/${TARGET_AGENT_UUID}`（此处 `TARGET_AGENT_UUID` 实为 cfg_id，非 UUID），`--to-id "$TARGET_AGENT_UUID"`。**约束冲突**：违反 issue-68 `--to-id <uuid>` 约束，作为紧急降级路径存在，SKILL.md 需标注。
   - 输出 JSON 加 `"reason":"id_fallback"`（仅 `ID_FALLBACK==1`）或 `"reason":"load_aware"`/`"idle_first"`（正常路径），便于审计。

**验证**：`bash -n`；现有 8 测试全过（均传 `--agent-name` → 走覆盖路径，行为不变）；新增 `test_script_selection_load_aware`、`test_script_selection_idle_first`、`test_no_candidate_reports`、`test_type_filter_excludes_wrong_type`、`test_id_fallback_when_uuid_invalid`。


### 步骤 D：反转 `SKILL.md`

**文件**：`skills/linyaps-multica-packer-dispatch/SKILL.md`

**改动**：
1. §约束 5（L231-234）：「slug→CLI name 由 LLM 决策」→「脚本决策（`type` 字段过滤 + idle 优先 + 负载感知决胜，`--agent-name` 可选覆盖）」。
2. §Action 2 输入（L74-79）：「`agent_name` 必填」→「可选覆盖（传则跳过脚本选择直接用，不传则脚本按 `--type` 过滤 config `agent.type` 候选池 + idle 优先 + 负载感知决胜）」。
3. §Action 2 执行逻辑第 2 步（L93-96）：重写为脚本端候选筛选（`agent.type == $TYPE`）+ 决胜。
4. §Action 2 调用示例（L98-103）：`-n "<CLI name>"` → `-u "<uuid>"`。
5. §指派目标配置（L177-191）：`agent_file`/`capabilities` 列 → `uuid` + `type`（填真实 multica UUID，部署时回填）。表格行更新为 `init-tracker | type:binary | uuid:<...>` 等。

### 步骤 E：测试更新

**文件**：`tests/test_dispatch_uuid.py`

**改动**：
1. 现有 8 测试**全保留**（均传 `--agent-name` → 走覆盖路径，行为不变）。**例外**：`test_missing_agent_name_reports_and_skips`（L149-154）当前断言 `agent_name_required`——新设计下未传 `--agent-name` 走脚本选择，需改为断言脚本选择路径行为（mock 单候选 idle → assigned:true）。
2. 扩展 `_write_config` mock：init 类 agent 加 `uuid` + `type` 字段（真实 UUID 值，非空），支持 source 多候选场景（2 个 src-init agent，均 `type:"source"`）。
3. 扩展 `_write_multica` mock：`agent list` 返回多 agent + 不同 status（idle/busy）+ `agent tasks` 返回不同 running_count 以支持负载感知。
4. 新增 `test_script_selection_load_aware`：mock 2 候选均非 idle，running_count 不同 → 选最少的。
5. 新增 `test_script_selection_idle_first`：mock 2 候选（1 idle + 1 busy）→ 选 idle 的。
6. 新增 `test_no_candidate_reports`：mock config 无匹配 `type` agent → 验证 `no_candidate`。
7. 新增 `test_type_filter_excludes_wrong_type`：config 含 `type:binary` + `type:source` agent，传 `--type=source` → 只选 source 类，binary 类不被选。
8. 新增 `test_check_agent_status_uuid_mode`：`-u <uuid> -o json` 返回正确 agent 结构。
9. 新增 `test_id_fallback_when_uuid_invalid`：mock config 所有候选 `uuid` 为空串/无效，验证 dispatch 用 cfg_id 作 `--to-id`、mention 含 cfg_id、输出 `assigned:true, reason:id_fallback`。

**验证**：`python3 -m pytest -q tests/test_dispatch_uuid.py` 全绿。

### 步骤 F：根副本 `check-agent-status.sh` 同步升级

**文件**：`scripts/check-agent-status.sh`

**改动**：与步骤 A 技能副本同步升级（避免漂移）。不删根 `scripts/`。

### 步骤 G：导出实施方案到 docs

**文件**：`docs/20261019-dispatch-skill-sync-plan.md`

**改动**：将 `local://dispatch-skill-sync-plan.md`（本计划工件，312 行）原样复制到 `docs/20261019-dispatch-skill-sync-plan.md`（归档备份，不做改写）。命名遵循仓库 `docs/` 约定（`YYYYMMDD-<slug>-plan.md`，参考 `docs/20260909-agent-skills-token-optimization-implementation-plan.md`）。

**验证**：`diff <(cat local://dispatch-skill-sync-plan.md) docs/20261019-dispatch-skill-sync-plan.md` 无差异（或 `cmp` 退出码 0）。

## 3. 验证清单

```bash
# 语法
bash -n skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh
bash -n skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh
bash -n scripts/check-agent-status.sh

# 配置合法
python3 -c "import json; json.load(open('for-multica/agent-config.json'))"

# 全测试
python3 -m pytest -q tests/test_dispatch_uuid.py

# -u 模式冒烟（mock multica）
bash skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh -u <uuid> -o json

# 负载感知冒烟
python3 -m pytest -q tests/test_dispatch_uuid.py::test_script_selection_load_aware

# docs 导出归档验证
diff <(cat local://dispatch-skill-sync-plan.md) docs/20261019-dispatch-skill-sync-plan.md
```

## 4. 风险与回退

| 风险 | 缓解 |
|------|------|
| `test_missing_agent_name_reports_and_skips` 断言与新设计冲突 | 改测试断言：未传 `--agent-name` → 脚本选择路径（不再 `agent_name_required`） |
| config `uuid` 真实值未知（需部署环境 multica agent UUID） | 实施时填占位 UUID（符合格式），SKILL.md 标注部署回填；`--agent-name` 覆盖路径不受影响 |
| check-agent-status 批量模式 `AGENTS` 数组默认空，无 `-n/-u` 报错 | 与参考一致；现有调用方均传 `-n`/`-u`，不受影响 |
| 根副本与技能副本漂移 | 步骤 A + F 同步升级两份 |
| workspace 解析硬失败破坏热备非阻断 | **不**采用参考 `exit 1`，保留 `switch || true` + `list` 双保险 |
| 负载感知 `awk` 解析 `running_count` 失败 | `running_count` 默认 0（`|| running_count=0`），降级为 valid_list 全体随机 |
| 非 init 类 agent（packer）无 `type` 字段被误过滤 | packer 非 dispatch 目标，`type` 字段省略即不匹配 `$TYPE`，不会被选；符合预期 |
| multica `--to-id` 是否接受非 UUID 的 cfg_id 未经验证（id fallback 路径） | 测试 mock `assign` 不校验 `--to-id` 值，测试可通过；部署环境实测真实 multica 行为。若拒绝非 UUID，fallback 路径失败 → 需改 `get_agent_uuid_by_name(cfg_id)` 解析或回退 `no_candidate`，SKILL.md 标注此约束冲突 |
| id fallback 违反 issue-68 `--to-id <uuid>` 约束 | 作为紧急降级路径存在（所有 uuid 失败时触发）；输出 JSON `reason:id_fallback` 便于审计；SKILL.md 标注约束冲突与部署验证要求 |

## 5. 不移植项明示

- **c444129 f-string 修复**：无可修复对象。
- **c444129 `query_upstream.sh` 重排**：纯装饰性重格式化，无行为变更。
- **参考 `exit 1` workspace 硬失败**：与本仓库热备非阻断约定冲突，保留双保险。
- **上游纯随机无 idle 决胜**：用负载感知替代（用户选定更优方案）。
- **config `cli_name` 字段**：用户明确禁止，不引入。
- **config `uuid:""` 空串 + name 回退**：本仓库 config name 非 CLI name，回退必失败；改为 `uuid` 填真实值。
- **`--type`→capability（`project_init`/`src_project_init`）映射**：用户最新修正要求 `type` 字段直接放 agent 上，移除中间映射，改为 `agent.type == $TYPE` 直过滤。
