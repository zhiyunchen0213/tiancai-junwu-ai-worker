#!/bin/bash
#
# Worker Main Loop Script - YouTube AI Video Production Line
# Core worker process running on each Mac mini
# Handles task claiming, phase execution, and error recovery
#

set -euo pipefail

# 源环境变量配置 (Source environment configuration)
if [[ -f "$HOME/.production.env" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.production.env"
else
    echo "Error: ~/.production.env not found" >&2
    exit 1
fi

# 验证必需的环境变量 (Validate required environment variables)
: "${SHARED_DIR:?SHARED_DIR not set}"
: "${WORKER_ID:?WORKER_ID not set}"
: "${POLL_INTERVAL:=30}"
: "${MAX_RETRIES:=3}"

# ============================================================================
# 日志函数 (Logging Functions)
# ============================================================================

log_info() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${WORKER_ID}] [INFO] ${message}"
}

log_error() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${WORKER_ID}] [ERROR] ${message}" >&2
}

log_warn() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${WORKER_ID}] [WARN] ${message}"
}

# ============================================================================
# JSON 操作辅助函数 (JSON Helper Functions)
# ============================================================================

# 使用 python3 更新任务 JSON 字段（自动推断类型）
# 修复：整数/null/布尔值不再被强制转为字符串
update_task_json() {
    local task_file="$1"
    local field="$2"
    local value="$3"

    TJ_FILE="$task_file" TJ_FIELD="$field" TJ_VALUE="$value" \
    python3 << 'PYEOF'
import json, sys, os

try:
    tf = os.environ['TJ_FILE']
    with open(tf, 'r') as f:
        data = json.load(f)
    raw = os.environ['TJ_VALUE']
    # 自动类型推断：整数、null、布尔值
    if raw == '':
        parsed = None
    elif raw.isdigit():
        parsed = int(raw)
    elif raw.lower() in ('null', 'none'):
        parsed = None
    elif raw.lower() == 'true':
        parsed = True
    elif raw.lower() == 'false':
        parsed = False
    else:
        parsed = raw
    data[os.environ['TJ_FIELD']] = parsed
    with open(tf, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'Error updating JSON: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
}

# 从任务 JSON 读取字段值 (Read field value from task JSON)
get_task_field() {
    local task_file="$1"
    local field="$2"

    TJ_FILE="$task_file" TJ_FIELD="$field" \
    python3 -c "
import json, os
try:
    with open(os.environ['TJ_FILE'], 'r') as f:
        data = json.load(f)
    print(data.get(os.environ['TJ_FIELD'], ''))
except Exception as e:
    print('', file=__import__('sys').stderr)
"
}

# ============================================================================
# 告警函数 (Alert Functions)
# ============================================================================

send_alert() {
    local alert_type="$1"
    local message="$2"
    local task_file="${3:-}"

    local alert_file
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    alert_file="${SHARED_DIR}/alerts/$(date +%s)_${WORKER_ID}_${alert_type}.json"

    # 使用环境变量传参避免 shell 注入（单引号等特殊字符安全）
    ALERT_TIMESTAMP="$timestamp" \
    ALERT_WORKER_ID="$WORKER_ID" \
    ALERT_TYPE="$alert_type" \
    ALERT_MESSAGE="$message" \
    ALERT_TASK_FILE="$task_file" \
    ALERT_OUTPUT="$alert_file" \
    python3 << 'PYEOF'
import json, os

alert = {
    "timestamp": os.environ["ALERT_TIMESTAMP"],
    "worker_id": os.environ["ALERT_WORKER_ID"],
    "alert_type": os.environ["ALERT_TYPE"],
    "message": os.environ["ALERT_MESSAGE"],
}
task_file = os.environ.get("ALERT_TASK_FILE", "")
if task_file:
    alert["task_file"] = task_file
with open(os.environ["ALERT_OUTPUT"], "w") as f:
    json.dump(alert, f, indent=2, ensure_ascii=False)
PYEOF
    log_warn "Alert sent: ${alert_type} - ${message}"
}

# ============================================================================
# Review Server 上报 (Report events to review dashboard)
# ============================================================================

# 环境变量: REVIEW_SERVER_URL, DISPATCHER_TOKEN（可选，不设则跳过上报）
: "${REVIEW_SERVER_URL:=}"
: "${DISPATCHER_TOKEN:=}"

report_event() {
    # 用法: report_event <task_id> <event> <payload_json>
    # 如果未配置 REVIEW_SERVER_URL 则静默跳过
    [[ -z "$REVIEW_SERVER_URL" ]] && return 0
    [[ -z "$DISPATCHER_TOKEN" ]] && return 0

    local task_id="$1"
    local event="$2"
    local payload="${3:-{}}"

    # 后台异步上报，不阻塞主流程
    (
        TASK_ID="$task_id" EVENT="$event" PAYLOAD="$payload" \
        REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
        python3 << 'PYEOF'
import json, os, urllib.request, urllib.error

url = os.environ["REVIEW_URL"].rstrip("/") + "/api/v1/tasks/report"
body = json.dumps({
    "task_id": os.environ["TASK_ID"],
    "event": os.environ["EVENT"],
    "payload": json.loads(os.environ["PAYLOAD"])
}).encode("utf-8")

req = urllib.request.Request(url, data=body, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bearer {os.environ['DTOK']}"
})
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f"[review-server] report failed: {e}", flush=True)
PYEOF
    ) &
}

# ============================================================================
# Worker 心跳上报 (Worker Heartbeat)
# ============================================================================

# 心跳间隔（秒），默认 60 秒
: "${HEARTBEAT_INTERVAL:=60}"
LAST_HEARTBEAT_TIME=0
CURRENT_WORKER_STATUS="idle"
CURRENT_TASK_ID_FOR_HB=""
TASKS_COMPLETED_COUNT=0

send_heartbeat() {
    [[ -z "$REVIEW_SERVER_URL" ]] && return 0
    [[ -z "$DISPATCHER_TOKEN" ]] && return 0

    local now
    now=$(date +%s)
    local elapsed=$((now - LAST_HEARTBEAT_TIME))

    # 节流：未到间隔则跳过
    [[ $elapsed -lt $HEARTBEAT_INTERVAL ]] && return 0

    LAST_HEARTBEAT_TIME=$now

    (
        W_ID="$WORKER_ID" W_STATUS="$CURRENT_WORKER_STATUS" \
        W_COMPLETED="$TASKS_COMPLETED_COUNT" W_TASK="$CURRENT_TASK_ID_FOR_HB" \
        REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
        python3 << 'PYEOF'
import json, os, urllib.request, urllib.error

url = os.environ["REVIEW_URL"].rstrip("/") + "/api/v1/worker/heartbeat"
body = json.dumps({
    "worker_id": os.environ["W_ID"],
    "status": os.environ["W_STATUS"],
    "tasks_completed": int(os.environ.get("W_COMPLETED", "0")),
    "current_task": os.environ.get("W_TASK") or None,
}).encode("utf-8")

req = urllib.request.Request(url, data=body, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bearer {os.environ['DTOK']}"
})
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f"[heartbeat] failed: {e}", flush=True)
PYEOF
    ) &
}

# ============================================================================
# VPS 任务拉取 (Poll VPS for tasks submitted via dashboard)
# ============================================================================

poll_vps_task() {
    # 如果未配置 REVIEW_SERVER_URL 则跳过
    [[ -z "$REVIEW_SERVER_URL" ]] && return 1
    [[ -z "$DISPATCHER_TOKEN" ]] && return 1

    local result
    result=$(W_ID="$WORKER_ID" REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
        python3 << 'PYEOF'
import json, os, urllib.request, urllib.error

base = os.environ["REVIEW_URL"].rstrip("/")
wid = os.environ["W_ID"]
tok = os.environ["DTOK"]
headers = {"Content-Type": "application/json", "Authorization": f"Bearer {tok}"}

# Step 1: Poll for pending task
poll_url = f"{base}/api/v1/tasks/poll?worker_id={wid}"
req = urllib.request.Request(poll_url, headers=headers)
try:
    resp = urllib.request.urlopen(req, timeout=10)
    data = json.loads(resp.read())
except Exception as e:
    print(f"POLL_ERROR:{e}", flush=True)
    exit(1)

task = data.get("task")
if not task:
    print("NO_TASK", flush=True)
    exit(0)

task_id = task["id"]

# Step 2: Claim it
claim_url = f"{base}/api/v1/tasks/{task_id}/claim"
body = json.dumps({"worker_id": wid}).encode("utf-8")
req2 = urllib.request.Request(claim_url, data=body, headers=headers, method="POST")
try:
    resp2 = urllib.request.urlopen(req2, timeout=10)
    claim_data = json.loads(resp2.read())
except urllib.error.HTTPError as e:
    print(f"CLAIM_CONFLICT:{task_id}", flush=True)
    exit(1)
except Exception as e:
    print(f"CLAIM_ERROR:{e}", flush=True)
    exit(1)

claimed = claim_data.get("task", task)

# Step 3: Write task JSON to local pending dir
task_json = {
    "id": task_id,
    "task_id": task_id,
    "url": claimed.get("video_url", ""),
    "video_url": claimed.get("video_url", ""),
    "synopsis": claimed.get("synopsis"),
    "track": claimed.get("track", "kpop-dance"),
    "ip_characters": claimed.get("ip_characters"),
    "gate_mode": claimed.get("gate_mode", "full_review"),
    "status": "pending",
}
print(f"CLAIMED:{task_id}|" + json.dumps(task_json), flush=True)
PYEOF
    ) 2>/dev/null

    if [[ "$result" == NO_TASK ]]; then
        return 1
    elif [[ "$result" == POLL_ERROR:* ]] || [[ "$result" == CLAIM_ERROR:* ]]; then
        log_warn "VPS poll failed: $result"
        return 1
    elif [[ "$result" == CLAIM_CONFLICT:* ]]; then
        log_warn "VPS task already claimed: $result"
        return 1
    elif [[ "$result" == CLAIMED:* ]]; then
        local task_id="${result#CLAIMED:}"
        task_id="${task_id%%|*}"
        local task_json="${result#*|}"
        local task_file="${task_id}.json"

        # 直接写到 running 目录（已在 VPS 上 claim 了）
        local running_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"
        echo "$task_json" > "$running_path"
        log_info "VPS task claimed and written: $task_file"
        echo "$task_file"
        return 0
    fi

    return 1
}

# 辅助: 读取文件内容用于上报（截断到 max_chars）
read_for_report() {
    local file="$1"
    local max_chars="${2:-50000}"
    if [[ -f "$file" ]]; then
        head -c "$max_chars" "$file"
    else
        echo ""
    fi
}

# ============================================================================
# 恢复机制 (Recovery Functions)
# ============================================================================

# 启动时扫描并恢复未完成的任务 (Startup recovery: scan for leftover running tasks)
run_recovery_check() {
    log_info "Running startup recovery check..."

    local running_dir="${SHARED_DIR}/tasks/running/${WORKER_ID}"

    if [[ ! -d "$running_dir" ]]; then
        log_info "No running directory found, recovery check complete"
        return 0
    fi

    local tasks
    tasks=$(find "$running_dir" -maxdepth 1 -type f -name "*.json" 2>/dev/null | sort)

    if [[ -z "$tasks" ]]; then
        log_info "No leftover tasks found"
        return 0
    fi

    log_warn "Found $(echo "$tasks" | wc -l) leftover task(s), resuming..."

    while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue

        local phase_progress
        phase_progress=$(get_task_field "$task_file" "phase_progress")

        log_info "Resuming task from phase: ${phase_progress:-unknown}"

        case "$phase_progress" in
            "phase_a_complete")
                log_info "Resuming from Phase B"
                run_phase_b "$(basename "$task_file")"
                ;;
            "phase_b_complete")
                log_info "Resuming from Phase C"
                run_phase_c "$(basename "$task_file")"
                ;;
            "phase_c_complete")
                log_info "Resuming harvesting"
                finalize_task "$(basename "$task_file")"
                ;;
            *)
                log_warn "Unknown phase progress, restarting from Phase A"
                run_phase_a "$(basename "$task_file")"
                ;;
        esac
    done <<< "$tasks"
}

# ============================================================================
# 阶段执行函数 (Phase Execution Functions)
# ============================================================================

# Phase A: 下载、转录、分析视频 (Download, transcribe, analyze video)
run_phase_a() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"

    # 从任务 JSON 读取 URL
    local video_url
    video_url=$(get_task_field "$task_path" "url")
    if [[ -z "$video_url" ]]; then
        log_error "No URL found in task JSON"
        return 1
    fi

    # 创建任务工作目录（与任务文件同级）
    local task_id
    task_id=$(get_task_field "$task_path" "id")
    local work_dir="${SHARED_DIR}/tasks/running/${WORKER_ID}/work_${task_id}"
    mkdir -p "$work_dir"

    log_info "Starting Phase A for ${task_file} (URL: ${video_url})"
    update_task_json "$task_path" "phase" "phase_a" || true
    update_task_json "$task_path" "phase_progress" "phase_a_running" || true

    local scripts_dir="${SHARED_DIR}/code/scripts/worker"

    # Step 1: 下载视频 + 帧提取 + 音频分离
    log_info "Phase A Step 1/3: download_and_extract.sh"
    if ! bash "$scripts_dir/download_and_extract.sh" "$video_url" "$work_dir"; then
        log_error "download_and_extract.sh failed"
        return 1
    fi

    # Step 2: Whisper 语音识别
    log_info "Phase A Step 2/3: transcribe.sh"
    if ! bash "$scripts_dir/transcribe.sh" "$work_dir"; then
        log_error "transcribe.sh failed"
        return 1
    fi

    # Step 3: Kimi 视频分析（如果任务 JSON 中有 synopsis 字段，传给 Kimi 做分析锚点）
    log_info "Phase A Step 3/3: analyze_video.sh"
    local synopsis_args=()
    local synopsis_path
    synopsis_path=$(get_task_field "$task_path" "synopsis")
    if [[ -n "$synopsis_path" ]] && [[ -f "$synopsis_path" ]]; then
        synopsis_args=("--synopsis" "$synopsis_path")
        log_info "Using synopsis file: $synopsis_path"
    fi
    if ! bash "$scripts_dir/analyze_video.sh" "$work_dir" "${synopsis_args[@]+"${synopsis_args[@]}"}"; then
        log_error "analyze_video.sh failed"
        return 1
    fi

    # 记录工作目录到任务 JSON，后续阶段使用
    update_task_json "$task_path" "work_dir" "$work_dir" || true

    if update_task_json "$task_path" "phase_progress" "phase_a_complete"; then
        log_info "Phase A completed successfully"
        # 上报到审核系统
        local transcript_text kimi_text metadata_text
        transcript_text=$(read_for_report "$work_dir/transcript.txt" 10000)
        kimi_text=$(read_for_report "$work_dir/kimi_analysis.md" 30000)
        metadata_text=$(read_for_report "$work_dir/metadata.json" 5000)
        TRANSCRIPT="$transcript_text" KIMI="$kimi_text" META="$metadata_text" \
        report_event "$task_id" "phase_a_complete" "$(python3 -c "
import json, os
print(json.dumps({
    'transcript': os.environ.get('TRANSCRIPT',''),
    'kimi_analysis': os.environ.get('KIMI',''),
    'video_metadata': json.loads(os.environ.get('META','{}') or '{}')
}))" 2>/dev/null || echo '{}')"
        return 0
    else
        log_error "Failed to update phase progress"
        return 1
    fi
}

# Phase B: AI 判断 (AI judgment — 631评分、改编建议、提示词生成)
run_phase_b() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"
    local work_dir
    work_dir=$(get_task_field "$task_path" "work_dir")
    local script_path="${SHARED_DIR}/code/scripts/worker/ai_judgment.sh"

    log_info "Starting Phase B for ${task_file}"
    update_task_json "$task_path" "phase" "phase_b" || true
    update_task_json "$task_path" "phase_progress" "phase_b_running" || true

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    # ai_judgment.sh 接收工作目录，读取 Phase A 产出，调用 AI 生成改编方案
    log_info "Executing ai_judgment.sh (work_dir: ${work_dir})"
    if ! bash "$script_path" "$work_dir"; then
        log_error "ai_judgment.sh failed"
        return 1
    fi

    if update_task_json "$task_path" "phase_progress" "phase_b_complete"; then
        log_info "Phase B completed successfully"
        # 上报到审核系统
        local score_text plan_text prompt_text
        score_text=$(read_for_report "$work_dir/phase_b/631评分.md" 5000)
        plan_text=$(read_for_report "$work_dir/phase_b/改编建议.md" 10000)
        prompt_text=$(read_for_report "$work_dir/phase_b/即梦提示词.md" 30000)
        SCORE="$score_text" PLAN="$plan_text" PROMPT="$prompt_text" \
        report_event "$task_id" "phase_b_complete" "$(python3 -c "
import json, os
print(json.dumps({
    'score_631': os.environ.get('SCORE',''),
    'adaptation_plan': os.environ.get('PLAN',''),
    'jimeng_prompts': os.environ.get('PROMPT','')
}))" 2>/dev/null || echo '{}')"
        return 0
    else
        log_error "Failed to update phase progress"
        return 1
    fi
}

# Phase C: 即梦提交 (Pre-submit check + jimeng CDP submit)
run_phase_c() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"
    local work_dir
    work_dir=$(get_task_field "$task_path" "work_dir")
    local scripts_dir="${SHARED_DIR}/code/scripts/worker"

    log_info "Starting Phase C for ${task_file}"
    update_task_json "$task_path" "phase" "phase_c" || true
    update_task_json "$task_path" "phase_progress" "phase_c_running" || true

    # Step 0: 确保参考图目录存在（可能由 character-ref-generator 或手动创建）
    local refs_dir="${work_dir}/参考图"
    mkdir -p "$refs_dir"

    # Step 1: 双闸门校验
    # pre_submit_check.mjs 接收: (即梦提示词.md路径, 参考图目录)
    local prompt_md="${work_dir}/phase_b/即梦提示词.md"

    # 兼容: 如果 即梦提示词.md 不存在，尝试查找 Phase B 生成的改编提示词文件
    if [[ ! -f "$prompt_md" ]]; then
        local alt_prompt
        alt_prompt=$(find "${work_dir}/phase_b" -maxdepth 1 -name "*提示词*" -o -name "*即梦*" 2>/dev/null | head -1)
        if [[ -n "$alt_prompt" ]]; then
            log_warn "即梦提示词.md not found, using alternative: $(basename "$alt_prompt")"
            prompt_md="$alt_prompt"
        else
            log_error "即梦提示词.md not found at: ${work_dir}/phase_b/"
            log_error "Phase B should generate this file. Available files in phase_b/:"
            ls -la "${work_dir}/phase_b/" 2>/dev/null | while read -r line; do log_error "  $line"; done
            return 1
        fi
    fi

    # 检查参考图目录是否为空（警告但不阻塞，部分场景可能无参考图）
    local ref_count
    ref_count=$(find "$refs_dir" -maxdepth 1 -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ref_count" -eq 0 ]]; then
        log_warn "参考图目录为空: $refs_dir — 即梦提交可能缺少参考图"
    else
        log_info "参考图目录包含 $ref_count 张图片"
    fi

    log_info "Phase C Step 1/2: pre_submit_check.mjs (双闸门校验)"
    if ! node "$scripts_dir/pre_submit_check.mjs" "$prompt_md" "$refs_dir"; then
        log_error "双闸门校验未通过"
        return 1
    fi

    # Step 2: 即梦 CDP 提交
    # jimeng_cuihua.mjs 接收: --from-md <提示词路径> --refs-dir <参考图目录>
    # 输出: submit_state.json 包含 project_id 等信息
    log_info "Phase C Step 2/2: jimeng_cuihua.mjs (即梦提交)"
    if ! node "$scripts_dir/jimeng_cuihua.mjs" --from-md "$prompt_md" --refs-dir "$refs_dir"; then
        log_error "jimeng_cuihua.mjs failed"
        return 1
    fi

    # 记录提交信息到任务 JSON
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    update_task_json "$task_path" "jimeng_submitted_at" "$now" || true
    update_task_json "$task_path" "jimeng_submitted_by" "$WORKER_ID" || true

    # 从 submit_state.json 中读取 jimeng_project_id（harvest_daemon.sh 依赖此字段）
    local submit_state="${work_dir}/phase_b/submit_state.json"
    if [[ -f "$submit_state" ]]; then
        local project_id
        project_id=$(python3 -c "
import json
try:
    with open('${submit_state}', 'r') as f:
        data = json.load(f)
    pid = data.get('project_id', '')
    print(pid if pid else '')
except:
    print('')
" 2>/dev/null || echo "")
        if [[ -n "$project_id" ]]; then
            update_task_json "$task_path" "jimeng_project_id" "$project_id" || true
            log_info "Recorded jimeng_project_id: $project_id"
        else
            log_warn "submit_state.json found but no project_id — harvest daemon won't be able to monitor this task"
        fi
    else
        log_warn "submit_state.json not found at $submit_state — jimeng_project_id not recorded"
    fi

    if update_task_json "$task_path" "phase_progress" "phase_c_complete"; then
        log_info "Phase C completed — 已提交即梦，等待 Harvest Daemon 收割"
        report_event "$task_id" "phase_c_complete" "{\"jimeng_project_id\":\"${project_id:-}\"}"
        return 0
    else
        log_error "Failed to update phase progress"
        return 1
    fi
}

# ============================================================================
# 任务完成处理 (Task Finalization)
# ============================================================================

# 将任务移至 harvesting 目录，由收割守护进程处理 Phase D
finalize_task() {
    local task_file="$1"
    local running_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"
    local harvesting_path="${SHARED_DIR}/tasks/harvesting/${task_file}"

    if [[ ! -f "$running_path" ]]; then
        log_error "Task file not found: $running_path"
        return 1
    fi

    log_info "Moving task to harvesting queue: ${task_file}"

    # 同时移动工作目录到 harvesting/
    local task_id
    task_id=$(get_task_field "$running_path" "id")
    local old_work_dir="${SHARED_DIR}/tasks/running/${WORKER_ID}/work_${task_id}"
    local new_work_dir="${SHARED_DIR}/tasks/harvesting/work_${task_id}"

    if [[ -d "$old_work_dir" ]]; then
        if mv "$old_work_dir" "$new_work_dir"; then
            log_info "Work directory moved to harvesting: work_${task_id}"
            # 更新 JSON 中的 work_dir 路径（先更新再移动 JSON）
            update_task_json "$running_path" "work_dir" "$new_work_dir" || true
        else
            log_warn "Failed to move work directory, harvest may need manual intervention"
        fi
    else
        log_warn "Work directory not found: $old_work_dir (may be OK for re-submitted tasks)"
    fi

    # 移动任务 JSON
    if mv "$running_path" "$harvesting_path"; then
        log_info "Task successfully moved to harvesting"
        return 0
    else
        log_error "Failed to move task JSON to harvesting"
        return 1
    fi
}

# ============================================================================
# 执行任务处理流程 (Execute task processing)
# ============================================================================

process_task() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"

    log_info "Processing task: ${task_file}"

    local task_id
    task_id=$(get_task_field "$task_path" "task_id")
    task_id="${task_id:-$(basename "$task_file" .json)}"

    # 上报任务认领
    local video_url synopsis gate_mode
    video_url=$(get_task_field "$task_path" "video_url")
    synopsis=$(get_task_field "$task_path" "synopsis")
    gate_mode=$(get_task_field "$task_path" "gate_mode")
    VIDEO_URL="$video_url" SYNOPSIS="$synopsis" GATE_MODE="${gate_mode:-full_review}" \
    report_event "$task_id" "task_created" "$(python3 -c "
import json, os
print(json.dumps({
    'video_url': os.environ.get('VIDEO_URL',''),
    'synopsis': os.environ.get('SYNOPSIS',''),
    'gate_mode': os.environ.get('GATE_MODE','full_review')
}))" 2>/dev/null || echo '{}')"

    # 更新任务 JSON：设置 claimed_by 和 claimed_at
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if ! update_task_json "$task_path" "claimed_by" "$WORKER_ID"; then
        log_error "Failed to update claimed_by"
        return 1
    fi

    if ! update_task_json "$task_path" "claimed_at" "$timestamp"; then
        log_error "Failed to update claimed_at"
        return 1
    fi

    if ! update_task_json "$task_path" "status" "running"; then
        log_error "Failed to update status to running"
        return 1
    fi

    # 执行各个阶段 (Execute phases in sequence)
    local phase_results=(0 0 0)

    if ! run_phase_a "$task_file"; then
        log_error "Phase A failed for ${task_file}"
        phase_results[0]=1
    fi

    if [[ ${phase_results[0]} -eq 0 ]]; then
        if ! run_phase_b "$task_file"; then
            log_error "Phase B failed for ${task_file}"
            phase_results[1]=1
        fi
    fi

    if [[ ${phase_results[0]} -eq 0 ]] && [[ ${phase_results[1]} -eq 0 ]]; then
        if ! run_phase_c "$task_file"; then
            log_error "Phase C failed for ${task_file}"
            phase_results[2]=1
        fi
    fi

    # 处理失败情况 (Handle failures)
    if [[ ${phase_results[0]} -ne 0 ]] || [[ ${phase_results[1]} -ne 0 ]] || [[ ${phase_results[2]} -ne 0 ]]; then
        local retry_count
        retry_count=$(get_task_field "$task_path" "retry_count")
        retry_count=${retry_count:-0}
        retry_count=$((retry_count + 1))

        if ! update_task_json "$task_path" "retry_count" "$retry_count"; then
            log_error "Failed to update retry count"
        fi

        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log_warn "Task failed (attempt $retry_count/$MAX_RETRIES), re-queuing to pending..."
            # 重置状态并移回 pending，让任何 Worker（包括自己）都能重新抢取
            update_task_json "$task_path" "status" "pending" || true
            update_task_json "$task_path" "phase" "null" || true
            update_task_json "$task_path" "claimed_by" "null" || true
            update_task_json "$task_path" "claimed_at" "null" || true
            local requeue_path="${SHARED_DIR}/tasks/pending/${task_file}"
            if mv "$task_path" "$requeue_path" 2>/dev/null; then
                log_info "Task re-queued successfully: ${task_file}"
            else
                log_error "Failed to re-queue task, leaving in running/"
            fi
            return 1
        else
            log_error "Task exceeded max retries, moving to failed directory"
            local failed_path="${SHARED_DIR}/tasks/failed/${task_file}"
            if mv "$task_path" "$failed_path"; then
                send_alert "TASK_FAILED" "Task exceeded max retries: ${task_file}" "$task_file"
                report_event "$task_id" "task_failed" "{\"error\":\"max_retries_exceeded\",\"retry_count\":$retry_count}"
            fi
            return 1
        fi
    fi

    # 成功：将任务移至收割队列 (Success: finalize and move to harvesting)
    if finalize_task "$task_file"; then
        log_info "Task successfully finalized: ${task_file}"
        return 0
    else
        log_error "Failed to finalize task: ${task_file}"
        return 1
    fi
}

# ============================================================================
# 信号处理 (Signal Handling)
# ============================================================================

# ============================================================================
# 自动更新 (Auto Update)
# ============================================================================

LAST_UPDATE_CHECK=0
UPDATE_CHECK_INTERVAL=300  # 每 5 分钟检查一次

check_and_auto_update() {
    local now
    now=$(date +%s)
    if (( now - LAST_UPDATE_CHECK < UPDATE_CHECK_INTERVAL )); then
        return 0
    fi
    LAST_UPDATE_CHECK=$now

    # 找到代码目录（脚本所在的 git 仓库根目录）
    local code_dir
    code_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [[ ! -d "$code_dir/.git" ]]; then
        return 0
    fi

    # 静默检查远端是否有更新
    if ! git -C "$code_dir" fetch origin main --quiet 2>/dev/null; then
        return 0  # 网络问题，跳过
    fi

    local local_hash remote_hash
    local_hash=$(git -C "$code_dir" rev-parse HEAD 2>/dev/null)
    remote_hash=$(git -C "$code_dir" rev-parse origin/main 2>/dev/null)

    if [[ "$local_hash" == "$remote_hash" ]]; then
        return 0  # 已是最新
    fi

    log_info "[AutoUpdate] New code detected (${local_hash:0:7} → ${remote_hash:0:7}), updating..."

    # 拉取最新代码
    if ! git -C "$code_dir" pull origin main --quiet 2>/dev/null; then
        log_warn "[AutoUpdate] git pull failed, skipping"
        return 0
    fi

    log_info "[AutoUpdate] Code updated, restarting worker..."

    # 发送离线心跳
    CURRENT_WORKER_STATUS="offline"
    LAST_HEARTBEAT_TIME=0
    send_heartbeat
    sleep 1

    # 用 exec 重启自身（替换当前进程，保留 PID）
    exec bash "${BASH_SOURCE[0]}"
}

# ============================================================================
# 信号处理 (Signal Handling)
# ============================================================================

# 优雅关闭：完成当前阶段，不中断任务 (Graceful shutdown)
cleanup() {
    log_info "Received shutdown signal, gracefully stopping..."
    SHUTDOWN_REQUESTED=1
    # 发送离线心跳 (Send offline heartbeat)
    CURRENT_WORKER_STATUS="offline"
    LAST_HEARTBEAT_TIME=0  # 强制发送
    send_heartbeat
    # 不再强制退出，让主循环检测 SHUTDOWN_REQUESTED 后自然退出
    # 当前任务会跑完再停 (Let main loop exit naturally after current task completes)
}

trap cleanup SIGTERM SIGINT

# ============================================================================
# 主循环 (Main Loop)
# ============================================================================

SHUTDOWN_REQUESTED=0

# 确保必需的目录存在 (Ensure required directories exist)
mkdir -p "${SHARED_DIR}/tasks/pending"
mkdir -p "${SHARED_DIR}/tasks/running/${WORKER_ID}"
mkdir -p "${SHARED_DIR}/tasks/harvesting"
mkdir -p "${SHARED_DIR}/tasks/failed"
mkdir -p "${SHARED_DIR}/alerts"

# 启动恢复检查 (Run recovery check)
run_recovery_check

log_info "Worker started, entering main loop (POLL_INTERVAL=${POLL_INTERVAL}s)"

# 空闲日志节流：每 20 个轮询周期才打一次（约 10 分钟 @30s间隔）
IDLE_LOG_INTERVAL=20
idle_count=0

# 启动时立即发一次心跳 (Send initial heartbeat on startup)
CURRENT_WORKER_STATUS="idle"
send_heartbeat

# 主循环关闭 strict error mode：phase 函数返回值由调用方显式检查
# 初始化阶段保留 set -euo pipefail 以捕获配置错误
set +e

# 主循环 (Main loop)
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
    # 每次循环尝试心跳（函数内部自带节流）
    send_heartbeat

    # 扫描待处理任务目录 (Scan for pending tasks)
    pending_task=$(ls -1 "$SHARED_DIR/tasks/pending/" 2>/dev/null | sort | head -1)

    if [[ -z "$pending_task" ]]; then
        # 本地没任务，尝试从 VPS 拉取看板提交的任务
        vps_task_file=$(poll_vps_task 2>/dev/null) || true
        if [[ -n "$vps_task_file" ]]; then
            log_info "Got task from VPS: ${vps_task_file}"
            idle_count=0

            # 更新心跳状态为 busy
            CURRENT_WORKER_STATUS="busy"
            CURRENT_TASK_ID_FOR_HB="$(basename "$vps_task_file" .json)"
            send_heartbeat

            # 处理任务
            if process_task "$vps_task_file"; then
                log_info "VPS task completed: ${vps_task_file}"
                ((TASKS_COMPLETED_COUNT++)) || true
            else
                log_warn "VPS task had issues: ${vps_task_file}"
            fi

            # 恢复 idle 状态
            CURRENT_WORKER_STATUS="idle"
            CURRENT_TASK_ID_FOR_HB=""
            send_heartbeat
            continue
        fi

        CURRENT_WORKER_STATUS="idle"
        CURRENT_TASK_ID_FOR_HB=""
        ((idle_count++)) || true
        if [[ $((idle_count % IDLE_LOG_INTERVAL)) -eq 0 ]]; then
            log_info "No pending tasks (idle for ~$((idle_count * POLL_INTERVAL))s)"
        fi

        # 空闲时检查代码更新（有新版本会自动 pull + 重启）
        check_and_auto_update

        sleep "$POLL_INTERVAL"
        continue
    fi
    idle_count=0

    log_info "Found pending task: ${pending_task}"

    # 原子性地尝试认领任务 (Attempt atomic task claim via mv)
    pending_path="${SHARED_DIR}/tasks/pending/${pending_task}"
    running_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${pending_task}"

    if ! mv "$pending_path" "$running_path" 2>/dev/null; then
        log_warn "Failed to claim task (race condition), skipping: ${pending_task}"
        continue
    fi

    log_info "Successfully claimed task: ${pending_task}"

    # 更新心跳状态为 busy
    CURRENT_WORKER_STATUS="busy"
    CURRENT_TASK_ID_FOR_HB="$(basename "$pending_task" .json)"
    send_heartbeat

    # 处理任务 (Process the task)
    if process_task "$pending_task"; then
        log_info "Task processing completed successfully: ${pending_task}"
        ((TASKS_COMPLETED_COUNT++)) || true
    else
        log_warn "Task processing had issues: ${pending_task}"
    fi

    # 任务结束，恢复 idle 状态
    CURRENT_WORKER_STATUS="idle"
    CURRENT_TASK_ID_FOR_HB=""
    send_heartbeat
done

log_info "Worker main loop exiting"
exit 0
