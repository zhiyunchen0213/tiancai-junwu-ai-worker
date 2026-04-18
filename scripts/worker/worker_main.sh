#!/bin/bash
#
# Worker Main Loop Script - YouTube AI Video Production Line
# Core worker process running on each Mac mini
# Handles task claiming, phase execution, and error recovery
#

set -euo pipefail

# 确保 Homebrew + 用户工具可用（macOS Worker 必须）
export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# macOS 不自带 timeout（coreutils），提供 fallback
if ! command -v timeout &>/dev/null; then
    timeout() { local t="$1"; shift; "$@"; }
fi

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
: "${POLL_INTERVAL:=10}"
: "${MAX_RETRIES:=3}"
: "${CDP_PORT:=9222}"

# macking 连接参数（必须在 .production.env 中设置）
# dev 环境: MACKING_HOST=localhost  生产环境: MACKING_HOST=<macking LAN IP>
: "${MACKING_HOST:?MACKING_HOST not set — set to localhost (dev) or macking LAN IP (prod) in .production.env}"
: "${MACKING_USER:=zjw-mini}"

# 判断本机是否就是 macking（dev 模式：MACKING_HOST=localhost）
is_local_macking() {
    [[ "$MACKING_HOST" == "localhost" || "$MACKING_HOST" == "127.0.0.1" ]]
}

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
# 安全：通过环境变量传参，避免 shell 注入
update_task_json() {
    local task_file="$1"
    local field="$2"
    local value="$3"

    TASK_FILE="$task_file" FIELD="$field" VALUE="$value" \
    python3 << 'PYEOF'
import json, sys, os

try:
    task_file = os.environ["TASK_FILE"]
    field = os.environ["FIELD"]
    raw = os.environ.get("VALUE", "")

    with open(task_file, 'r') as f:
        data = json.load(f)

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

    data[field] = parsed
    with open(task_file, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'Error updating JSON: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
}

# 从任务 JSON 读取字段值 (Read field value from task JSON)
# 安全：通过环境变量传参
get_task_field() {
    local task_file="$1"
    local field="$2"

    TASK_FILE="$task_file" FIELD="$field" \
    python3 -c "
import json, os, sys
try:
    with open(os.environ['TASK_FILE'], 'r') as f:
        data = json.load(f)
    print(data.get(os.environ['FIELD'], ''))
except:
    print('')
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
    # 用法: report_event <task_id> <event> [payload_json]
    # 使用临时文件 + printf 保持 JSON 完整性（echo 会破坏引号）
    [[ -z "$REVIEW_SERVER_URL" ]] && return 0
    [[ -z "$DISPATCHER_TOKEN" ]] && return 0

    local task_id="$1"
    local event="$2"
    local payload="${3:-{}}"

    # task_failed 同步执行（确保错误信息可靠送达），其他事件后台执行
    local _run_sync=0
    [[ "$event" == "task_failed" ]] && _run_sync=1

    _do_report() {
        # 写 payload 到临时文件（printf 保留 JSON 原文，避免 echo 破坏引号）
        _tmp="/tmp/report_$$_${RANDOM}.json"
        printf '%s' "$payload" > "$_tmp" 2>/dev/null || printf '{}' > "$_tmp"

        # Python 通过 env 拿到 task_id/event/tmp 路径，而不是 bash 直接拼源码——
        # 之前用 f-string + $(cat ...) 把 JSON 字面量注入到源码里，JSON 的 `{}:` 会
        # 跟 f-string 自身的 `{}:` 撞（Python 报 SyntaxError: single '}' is not allowed），
        # 触发 task_created 事件 5 次重试全失败.
        _body=$(TASK_ID="$task_id" EVENT="$event" TMP_FILE="$_tmp" python3 -c '
import json, os, sys
try:
    with open(os.environ["TMP_FILE"]) as f:
        p = json.loads(f.read())
except Exception as e:
    with open(os.environ["TMP_FILE"]) as f:
        preview = f.read(200)
    print("[report] WARNING: JSON parse failed: " + str(e) + ", payload was: " + preview, file=sys.stderr)
    p = {}
print(json.dumps({"task_id": os.environ["TASK_ID"], "event": os.environ["EVENT"], "payload": p}))
' 2>&1)
        rm -f "$_tmp"

        # 如果 python 输出包含 WARNING，打印到 stderr 但继续（body 是最后一行）
        if echo "$_body" | grep -q '^\[report\] WARNING'; then
            echo "$_body" | grep '^\[report\] WARNING' >&2
            _body=$(echo "$_body" | grep -v '^\[report\] WARNING' | tail -1)
        fi

        [ -z "$_body" ] && _body="{\"task_id\":\"$task_id\",\"event\":\"$event\",\"payload\":{}}"

        for _i in 1 2 3 4 5; do
            if curl -sf -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                -d "$_body" --connect-timeout 10 --max-time 30 > /dev/null 2>&1; then
                echo "[report] $event OK (attempt $_i)"
                return 0
            fi
            _delay=$((_i * 10))
            echo "[report] $event attempt $_i failed, retrying in ${_delay}s"
            sleep "$_delay"
        done
        echo "[report] $event FAILED after 5 attempts" >&2
        return 1
    }

    if [[ $_run_sync -eq 1 ]]; then
        _do_report
    else
        (_do_report) &
    fi
}

# 轻量进度上报：推送到 VPS SSE，看板实时显示
# 用法: report_progress <task_id> <step> [detail]
report_progress() {
    [[ -z "$REVIEW_SERVER_URL" ]] && return 0
    [[ -z "$DISPATCHER_TOKEN" ]] && return 0
    local task_id="$1" step="$2" detail="${3:-}"
    (curl -sf -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/${task_id}/progress" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
        -d "{\"step\":\"${step}\",\"detail\":\"${detail}\"}" \
        --connect-timeout 5 --max-time 15 > /dev/null 2>&1) &
}

# 安全版 report：直接从文件读取数据构建 payload（用于大文本上报）
report_event_from_files() {
    # 用法: report_event_from_files <task_id> <event> <key1>=<file1> [key2=file2] ...
    [[ -z "$REVIEW_SERVER_URL" ]] && return 0
    [[ -z "$DISPATCHER_TOKEN" ]] && return 0

    local task_id="$1"
    local event="$2"
    shift 2

    (
        local tmp="/tmp/report_files_$$_${RANDOM}.json"
        # 用 Python 从文件读取并构建 JSON
        TASK_ID="$task_id" EVENT="$event" FILE_ARGS="$*" \
        REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
        python3 << 'PYEOF'
import json, os, urllib.request, time

payload = {}
for arg in os.environ.get("FILE_ARGS", "").split():
    if "=" in arg:
        key, path = arg.split("=", 1)
        try:
            with open(path, "r", errors="replace") as f:
                val = f.read(50000)
            # Try parsing as JSON (for metadata.json)
            try: payload[key] = json.loads(val)
            except: payload[key] = val
        except:
            payload[key] = ""

body = json.dumps({
    "task_id": os.environ["TASK_ID"],
    "event": os.environ["EVENT"],
    "payload": payload
}).encode("utf-8")

req = urllib.request.Request(
    os.environ["REVIEW_URL"].rstrip("/") + "/api/v1/tasks/report",
    data=body,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {os.environ['DTOK']}"}
)
for attempt in range(3):
    try:
        urllib.request.urlopen(req, timeout=30)
        break
    except Exception as e:
        if attempt < 2:
            delay = 10 * (2 ** attempt)
            print(f"[report] {os.environ['EVENT']} attempt {attempt+1} failed: {e}, retrying in {delay}s", flush=True)
            time.sleep(delay)
        else:
            print(f"[report] {os.environ['EVENT']} failed after 3 attempts: {e}", flush=True)
PYEOF
    ) &
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

        # Commentary track has its own pipeline — never resume via run_phase_a.
        local _rec_track_kind
        _rec_track_kind=$(get_task_field "$task_file" "track_kind")
        _rec_track_kind="${_rec_track_kind:-video_gen}"
        if [[ "$_rec_track_kind" == "commentary" ]]; then
            log_info "Recovery: commentary task detected; releasing to VPS so poll loop re-claims with commentary dispatch"
            local completed_c_dir="${SHARED_DIR}/tasks/completed"
            mkdir -p "$completed_c_dir"
            mv "$task_file" "$completed_c_dir/$(basename "$task_file")" 2>/dev/null || true
            continue
        fi

        case "$phase_progress" in
            "phase_a_running"|"")
                log_info "Resuming Phase A"
                run_phase_a "$(basename "$task_file")"
                ;;
            "phase_a_complete"|"calling_brain_api"|"waiting_brain_api"|"waiting_g1"|"waiting_g2")
                # Phase A 已完成，VPS 会自动驱动 Phase B/G1/G2
                # 不再本地等待，直接释放任务文件
                log_info "Phase A already done (progress: $phase_progress), releasing to VPS"
                local completed_a_dir="${SHARED_DIR}/tasks/completed"
                mkdir -p "$completed_a_dir"
                mv "$task_file" "$completed_a_dir/$(basename "$task_file")" 2>/dev/null || true
                ;;
            "phase_b_complete"|"phase_c_ready")
                # Phase C ready — 通过 poll-phase-c 认领，不在 recovery 里跑
                log_info "Phase C ready (progress: $phase_progress), will be claimed via poll-phase-c"
                local completed_a_dir="${SHARED_DIR}/tasks/completed"
                mkdir -p "$completed_a_dir"
                mv "$task_file" "$completed_a_dir/$(basename "$task_file")" 2>/dev/null || true
                ;;
            "phase_c_running")
                # Phase C 被中断（worker 重启）— 通知 VPS 释放，让其他 worker 重新认领
                log_warn "Phase C was interrupted (progress: phase_c_running), releasing back to VPS"
                # task.json 里通常没有 task_id 字段，直接从文件名派生（与 1426 行同模式）
                local _release_tid
                _release_tid=$(get_task_field "$task_file" "task_id")
                _release_tid="${_release_tid:-$(basename "$task_file" .json)}"
                if [[ -n "$_release_tid" ]]; then
                    if curl -sf -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
                        -H "Content-Type: application/json" \
                        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                        -d "{\"task_id\":\"$_release_tid\",\"event\":\"phase_c_interrupted\",\"payload\":{\"reason\":\"worker_restart\"}}" \
                        > /dev/null 2>&1; then
                        log_info "  Notified VPS: $_release_tid released"
                    else
                        log_warn "  Failed to notify VPS for $_release_tid (task may stay stuck)"
                    fi
                fi
                local completed_a_dir="${SHARED_DIR}/tasks/completed"
                mkdir -p "$completed_a_dir"
                mv "$task_file" "$completed_a_dir/$(basename "$task_file")" 2>/dev/null || true
                ;;
            "phase_c_complete")
                log_info "Resuming harvesting"
                finalize_task "$(basename "$task_file")"
                ;;
            *)
                log_warn "Unknown phase progress '${phase_progress}', restarting from Phase A"
                run_phase_a "$(basename "$task_file")"
                ;;
        esac
    done <<< "$tasks"
}

# ============================================================================
# 阶段执行函数 (Phase Execution Functions)
# ============================================================================

# ============================================================================
# 原视频上传 (Source Video Upload)
# ============================================================================

# 上传 Phase A 产出的 original.mp4 到 VPS，作为下游剪辑包的唯一真相源。
# 背景：commit a7bf2ec 后 Phase A worker 完成即释放任务，Harvest 由其他 worker
# 执行，Harvest worker 的 work_dir 里没有 original.mp4。所以必须在 Phase A
# 下载完成时立即把原视频上传到 VPS。
# 失败只 warn，不阻塞 Phase A（原视频是交付增强，不是关键路径）。
upload_source_video() {
    local task_id="$1"
    local src_file="$2"

    if [[ ! -f "$src_file" ]]; then
        log_warn "[PhaseA] $task_id: original.mp4 not found, skip source upload"
        return 0
    fi

    local size
    size=$(stat -f%z "$src_file" 2>/dev/null || stat -c%s "$src_file" 2>/dev/null || echo 0)
    if [[ "$size" -lt 10240 ]]; then
        log_warn "[PhaseA] $task_id: original.mp4 too small (${size}B), skip source upload"
        return 0
    fi

    local url="${REVIEW_SERVER_URL}/api/v1/tasks/${task_id}/upload-source-video"
    if curl -sf -X POST \
        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${src_file}" \
        --max-time 180 --retry 2 --retry-delay 3 --retry-max-time 180 \
        "$url" > /dev/null 2>&1; then
        log_info "[PhaseA] $task_id: source video uploaded (${size} bytes)"
    else
        log_warn "[PhaseA] $task_id: source video upload failed (non-fatal)"
    fi
    return 0
}

# Phase A: 下载、转录、分析视频 (Download, transcribe, analyze video)
run_phase_a() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"

    # 从任务 JSON 读取 URL（兼容 url 和 video_url 两种字段名）
    local video_url
    video_url=$(get_task_field "$task_path" "url")
    if [[ -z "$video_url" ]]; then
        video_url=$(get_task_field "$task_path" "video_url")
    fi
    if [[ -z "$video_url" ]]; then
        log_error "No URL found in task JSON (checked both 'url' and 'video_url')"
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

    local scripts_dir
    scripts_dir="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
    if [[ -z "$scripts_dir" ]] || [[ ! -d "$scripts_dir" ]]; then
        log_error "SCRIPTS_DIR resolution failed (BASH_SOURCE=${BASH_SOURCE[0]}); set SCRIPTS_DIR env var explicitly"
        return 1
    fi

    # Step 1: 获取视频
    # uploaded:// 前缀 = 用户已上传到 VPS，从 VPS 下载而非 yt-dlp
    if [[ "$video_url" == uploaded://* ]]; then
        log_info "Phase A Step 1/2: 从 VPS 下载已上传视频"
        report_progress "$task_id" "Phase A: 下载视频" "从 VPS 回拉已上传视频"
        local dl_url="${REVIEW_SERVER_URL}/api/v1/tasks/${task_id}/source-video"
        if curl -sf -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
            "$dl_url" -o "$work_dir/original.mp4" --connect-timeout 10 --max-time 300; then
            local dl_size
            dl_size=$(stat -f%z "$work_dir/original.mp4" 2>/dev/null || stat -c%s "$work_dir/original.mp4" 2>/dev/null || echo 0)
            log_info "已上传视频下载完成 (${dl_size} bytes)"
            # 还需要提取帧和音频（download_and_extract.sh 的后半段）
            bash "$scripts_dir/download_and_extract.sh" "__skip_download__" "$work_dir" || true
        else
            log_error "从 VPS 下载已上传视频失败"
            PHASE_A_FAIL_DETAIL="从VPS下载已上传视频失败"
            return 1
        fi
    else
        log_info "Phase A Step 1/2: download_and_extract.sh"
        report_progress "$task_id" "Phase A: 下载视频" "正在从 ${video_url%%\?*} 下载"
        if ! bash "$scripts_dir/download_and_extract.sh" "$video_url" "$work_dir"; then
            log_error "download_and_extract.sh failed"
            PHASE_A_FAIL_DETAIL="视频下载失败"
            return 1
        fi
        # 上传原视频到 VPS（下游 ZIP 下载 / macking 剪辑包的唯一真相源）
        report_progress "$task_id" "Phase A: 上传原视频" "同步到 VPS"
        upload_source_video "$task_id" "$work_dir/original.mp4" || true
    fi

    # Step 2: Kimi 视频分析 + 后台 Whisper 预备
    # Kimi 直接分析视频；同时后台跑 Whisper，如果 Kimi 失败可立即降级
    log_info "Phase A Step 2/2: analyze_video.sh (Kimi 直接分析视频)"
    report_progress "$task_id" "Phase A: 视频分析" "Kimi 分析视频内容 + Whisper 转写"

    # 后台启动 Whisper 转写（不阻塞 Kimi，仅在降级时使用）
    # 安全措施：timeout 300s 防止 Whisper 卡死，日志限 50MB 防爆盘
    local whisper_pid=""
    if [[ -f "$scripts_dir/transcribe.sh" ]]; then
        (timeout 300 bash "$scripts_dir/transcribe.sh" "$work_dir" 2>&1 | head -c 52428800 > "${work_dir}/whisper.log") &
        whisper_pid=$!
        log_info "Whisper 后台转写启动 (pid=$whisper_pid, timeout=300s, max_log=50MB)"
    fi
    local synopsis_args=()
    local synopsis_content
    synopsis_content=$(get_task_field "$task_path" "synopsis")
    if [[ -n "$synopsis_content" ]]; then
        # Synopsis 是文本内容，写到临时文件传给 analyze_video.sh
        local synopsis_file="${work_dir}/synopsis.txt"
        echo "$synopsis_content" > "$synopsis_file"
        synopsis_args=("--synopsis" "$synopsis_file")
        log_info "Using synopsis (${#synopsis_content} chars)"
    fi
    if ! bash "$scripts_dir/analyze_video.sh" "$work_dir" "${synopsis_args[@]+"${synopsis_args[@]}"}"; then
        log_warn "Kimi analysis failed, falling back to Whisper transcription + text analysis"
        report_progress "$task_id" "Phase A: 分析降级" "Kimi 失败，等待 Whisper 降级重试"
        # 降级方案: 等后台 Whisper 完成，然后用转写文本重试分析
        if [[ -n "$whisper_pid" ]]; then
            log_info "等待后台 Whisper 完成 (pid=$whisper_pid)..."
            wait "$whisper_pid" 2>/dev/null || true
            whisper_pid=""
        fi
        # 重试分析（这次 analyze_video.sh 会检测到 transcript.txt 存在并使用它）
        if ! bash "$scripts_dir/analyze_video.sh" "$work_dir" "${synopsis_args[@]+"${synopsis_args[@]}"}"; then
            log_error "Analysis failed even with fallback"
            PHASE_A_FAIL_DETAIL="视频分析失败(Kimi+Whisper均失败)"
            return 1
        fi
    fi

    # 清理后台 Whisper（如果还在跑；进程可能已结束，kill 会失败，需 || true）
    if [[ -n "$whisper_pid" ]]; then
        kill "$whisper_pid" 2>/dev/null || true
        wait "$whisper_pid" 2>/dev/null || true
    fi

    # 记录工作目录到任务 JSON，后续阶段使用
    update_task_json "$task_path" "work_dir" "$work_dir" || true

    if update_task_json "$task_path" "phase_progress" "phase_a_complete"; then
        log_info "Phase A completed successfully"
        # 上报到审核系统（用文件传输，避免环境变量截断中文大文本）
        WORK_DIR="$work_dir" TASK_ID="$task_id" \
        REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
        python3 << 'PYEOF'
import json, os, urllib.request, time, sys
work = os.environ["WORK_DIR"]
def rf(p, n=50000):
    try:
        with open(p, 'r', errors='replace') as f: return f.read(n)
    except: return ""
body = json.dumps({
    "task_id": os.environ["TASK_ID"],
    "event": "phase_a_complete",
    "payload": {
        "transcript": rf(os.path.join(work, "transcript.txt"), 10000),
        "kimi_analysis": rf(os.path.join(work, "kimi_analysis.md"), 30000),
        "video_metadata": json.loads(rf(os.path.join(work, "metadata.json"), 5000) or "{}")
    }
}).encode("utf-8")
url = os.environ["REVIEW_URL"].rstrip("/") + "/api/v1/tasks/report"
req = urllib.request.Request(url, data=body, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bearer {os.environ['DTOK']}"
})
ok = False
for attempt in range(3):
    try:
        urllib.request.urlopen(req, timeout=30)
        print(f"[report] phase_a_complete OK (attempt {attempt+1})", flush=True)
        ok = True
        break
    except Exception as e:
        if attempt < 2:
            delay = 10 * (2 ** attempt)
            print(f"[report] phase_a_complete attempt {attempt+1} failed: {e}, retrying in {delay}s", flush=True)
            time.sleep(delay)
        else:
            print(f"[report] phase_a_complete failed after 3 attempts: {e}", flush=True)
sys.exit(0 if ok else 1)
PYEOF
        local report_rc=$?
        if [[ $report_rc -ne 0 ]]; then
            log_warn "phase_a_complete report failed after retries — VPS may not have Phase A data"
        fi
        return 0
    else
        log_error "Failed to update phase progress"
        return 1
    fi
}

# ============================================================================
# Brain API 辅助函数 (Brain API Helper Functions)
# ============================================================================

# 调用 Brain API Phase B-1 (POST /api/v1/judge)
# 返回: 0=成功, 1=失败
call_brain_api() {
    local task_id="$1"
    local work_dir="$2"
    local track="${3:-kpop-dance}"

    if [[ -z "$REVIEW_SERVER_URL" ]] || [[ -z "$DISPATCHER_TOKEN" ]]; then
        log_error "REVIEW_SERVER_URL or DISPATCHER_TOKEN not set — cannot call Brain API"
        return 1
    fi

    log_info "Calling Brain API: POST /api/v1/judge (task: $task_id, track: $track)"

    # 用临时文件传输大文本（环境变量对中文/大文本不可靠）
    local tmp_payload="/tmp/brain_api_payload_$$.json"
    WORK_DIR="$work_dir" TASK_ID="$task_id" TRACK="$track" \
    python3 << 'PYEOF'
import json, os

work = os.environ["WORK_DIR"]
def read_file(path, max_bytes=50000):
    try:
        with open(path, 'r', errors='replace') as f:
            return f.read(max_bytes)
    except:
        return ""

payload = {
    "task_id": os.environ["TASK_ID"],
    "track": os.environ["TRACK"],
    "phase_a_result": {
        "transcript": read_file(os.path.join(work, "transcript.txt"), 10000),
        "kimi_analysis": read_file(os.path.join(work, "kimi_analysis.md"), 30000),
        "video_metadata": json.loads(read_file(os.path.join(work, "metadata.json"), 5000) or "{}"),
    }
}
with open(f"/tmp/brain_api_payload_{os.getpid()}.json", "w") as f:
    json.dump(payload, f, ensure_ascii=False)
PYEOF
    # Python 子进程的 PID 不同，需要 glob 找文件
    tmp_payload=$(ls -t /tmp/brain_api_payload_*.json 2>/dev/null | head -1)
    if [[ -z "$tmp_payload" ]] || [[ ! -f "$tmp_payload" ]]; then
        log_error "Failed to create Brain API payload"
        return 1
    fi

    local response http_code
    response=$(REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" PAYLOAD_FILE="$tmp_payload" \
        python3 << 'PYEOF'
import json, os, urllib.request, urllib.error

url = os.environ["REVIEW_URL"].rstrip("/") + "/api/v1/judge"
with open(os.environ["PAYLOAD_FILE"]) as f:
    body = f.read().encode("utf-8")

req = urllib.request.Request(url, data=body, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bearer {os.environ['DTOK']}"
})
try:
    resp = urllib.request.urlopen(req, timeout=300)  # 5min timeout for Claude
    data = json.loads(resp.read().decode("utf-8"))
    print(json.dumps({"ok": True, "http_code": resp.status, "data": data}))
except urllib.error.HTTPError as e:
    err_body = e.read().decode("utf-8", errors="replace")[:500]
    print(json.dumps({"ok": False, "http_code": e.code, "error": err_body}))
except Exception as e:
    print(json.dumps({"ok": False, "http_code": 0, "error": str(e)}))
PYEOF
    )

    local ok
    ok=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")

    if [[ "$ok" == "True" ]]; then
        rm -f /tmp/brain_api_payload_*.json 2>/dev/null
        log_info "Brain API responded successfully"
        # 保存 Brain API 返回的评分和改编建议到本地 phase_b/ 目录
        mkdir -p "$work_dir/phase_b"
        echo "$response" | python3 -c "
import json, sys, os
resp = json.load(sys.stdin)
data = resp.get('data', {})
work = '${work_dir}/phase_b'
if data.get('score_631'):
    with open(os.path.join(work, '631评分.md'), 'w') as f: f.write(data['score_631'])
if data.get('adaptation_plan'):
    with open(os.path.join(work, '改编建议.md'), 'w') as f: f.write(data['adaptation_plan'])
if data.get('jimeng_prompts'):
    with open(os.path.join(work, '即梦提示词.md'), 'w') as f: f.write(data['jimeng_prompts'])
if data.get('outline'):
    with open(os.path.join(work, '改编1_大纲与提示词.md'), 'w') as f: f.write(data['outline'])
print(data.get('phase_progress', 'unknown'))
" 2>/dev/null
        return 0
    else
        local err_msg
        err_msg=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown')[:200])" 2>/dev/null || echo "unknown")
        log_error "Brain API failed: $err_msg"
        return 1
    fi
}

# 轮询等待审核门通过 (Poll review gate until approved/rejected/timeout)
# 用法: wait_for_gate <task_id> <gate> [max_wait_seconds] [poll_interval]
# 返回: 0=approved, 1=rejected, 2=timeout
wait_for_gate() {
    local task_id="$1"
    local gate="$2"
    local max_wait="${3:-7200}"    # 默认最长等 2 小时
    local interval="${4:-10}"      # 默认 10 秒轮询一次

    if [[ -z "$REVIEW_SERVER_URL" ]] || [[ -z "$DISPATCHER_TOKEN" ]]; then
        log_error "REVIEW_SERVER_URL or DISPATCHER_TOKEN not set — cannot poll gate"
        return 1
    fi

    log_info "Waiting for gate ${gate} approval (task: $task_id, max: ${max_wait}s, interval: ${interval}s)"
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]] && [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
        local gate_status phase_progress
        local api_response
        api_response=$(REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" TASK_ID="$task_id" \
            python3 -c "
import json, os, urllib.request, urllib.error
url = os.environ['REVIEW_URL'].rstrip('/') + '/api/v1/tasks/' + os.environ['TASK_ID']
req = urllib.request.Request(url, headers={'Authorization': f\"Bearer {os.environ['DTOK']}\"})
try:
    resp = urllib.request.urlopen(req, timeout=30)
    data = json.loads(resp.read().decode('utf-8'))
    print(json.dumps({'gate': data.get('gate_${gate}',''), 'progress': data.get('phase_progress','')}))
except Exception as e:
    print(json.dumps({'gate': 'error', 'progress': '', 'error': str(e)}))
" 2>/dev/null || echo '{"gate":"error","progress":""}')

        gate_status=$(echo "$api_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('gate',''))" 2>/dev/null || echo "")
        phase_progress=$(echo "$api_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('progress',''))" 2>/dev/null || echo "")

        case "$gate_status" in
            approved|auto_approved)
                log_info "Gate ${gate} APPROVED (elapsed: ${elapsed}s)"
                return 0
                ;;
            rejected)
                log_warn "Gate ${gate} REJECTED (elapsed: ${elapsed}s)"
                return 1
                ;;
            error)
                log_warn "Failed to poll gate ${gate}, will retry..."
                ;;
            pending|"")
                # 特殊情况: G2 生成失败 → 立即返回失败，不等超时
                if [[ "$gate" == "g2" ]] && [[ "$phase_progress" == "g2_generation_failed" ]]; then
                    log_error "Phase B-2 generation FAILED — not waiting further"
                    return 1
                fi
                # G2 还在生成中
                if [[ "$gate" == "g2" ]] && [[ "$phase_progress" == "generating_g2" ]]; then
                    if [[ $((elapsed % 120)) -lt $interval ]]; then
                        log_info "Phase B-2 still generating... (elapsed: ${elapsed}s)"
                    fi
                fi
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [[ $SHUTDOWN_REQUESTED -ne 0 ]]; then
        log_warn "Gate wait interrupted by shutdown signal"
        return 2
    fi

    log_error "Gate ${gate} timed out after ${max_wait}s"
    return 2
}

# 从 review-server 下载最新的 jimeng_prompts (Phase B-2 生成)
download_prompts_from_server() {
    local task_id="$1"
    local work_dir="$2"

    log_info "Downloading latest jimeng_prompts from server..."
    mkdir -p "$work_dir/phase_b"

    # 直接用 Python 下载并写文件（不经过 shell 变量，避免截断/特殊字符问题）
    local dl_result
    dl_result=$(REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" TASK_ID="$task_id" \
        OUTPUT_PATH="$work_dir/phase_b/即梦提示词.md" \
        python3 -c "
import json, os, urllib.request, time
url = os.environ['REVIEW_URL'].rstrip('/') + '/api/v1/tasks/' + os.environ['TASK_ID']
req = urllib.request.Request(url, headers={'Authorization': f\"Bearer {os.environ['DTOK']}\"})
for attempt in range(5):
    try:
        resp = urllib.request.urlopen(req, timeout=60)
        data = json.loads(resp.read().decode('utf-8'))
        prompts = data.get('jimeng_prompts', '')
        if prompts:
            with open(os.environ['OUTPUT_PATH'], 'w', encoding='utf-8') as f:
                f.write(prompts)
            print(f'OK:{len(prompts)}')
        else:
            print('EMPTY')
        break
    except Exception as e:
        if attempt < 4:
            delay = 10 * (2 ** attempt)  # 10, 20, 40, 80s
            time.sleep(delay)
        else:
            print(f'FAIL:{e}')
" 2>&1)

    if [[ "$dl_result" == OK:* ]]; then
        local bytes="${dl_result#OK:}"
        log_info "Downloaded jimeng_prompts ($bytes chars) → phase_b/即梦提示词.md"
        return 0
    else
        log_error "Failed to download jimeng_prompts: $dl_result"
        return 1
    fi
}

# ============================================================================
# Phase B: Brain API + 审核等待 (Brain API judgment + gate waiting)
# ============================================================================

# Phase B: AI 判断 (Brain API → 等 G1 → 等 G2 → 下载 prompts)
run_phase_b() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"
    local work_dir
    work_dir=$(get_task_field "$task_path" "work_dir")
    local task_id
    task_id=$(get_task_field "$task_path" "id")
    task_id="${task_id:-$(basename "$task_file" .json)}"
    local track
    track=$(get_task_field "$task_path" "track")
    track="${track:-kpop-dance}"

    log_info "Starting Phase B for ${task_file} (Brain API mode)"
    update_task_json "$task_path" "phase" "phase_b" || true

    # -----------------------------------------------------------
    # Step 1: 调用 Brain API (Phase B-1 — 631评分 + 改编建议)
    # -----------------------------------------------------------
    local current_progress
    current_progress=$(get_task_field "$task_path" "phase_progress")

    # VPS 收到 phase_a_complete 后会自动触发 Phase B judge（本地调用，无网络延迟）
    # Worker 只需等待 G1 gate，不再主动调用 Brain API
    if [[ "$current_progress" != "waiting_g1" ]] && [[ "$current_progress" != "waiting_g2" ]]; then
        log_info "Waiting for VPS auto-judge to complete Phase B (no worker-side API call needed)"
        update_task_json "$task_path" "phase_progress" "waiting_brain_api" || true

        # 等待 VPS 完成 Phase B（轮询 review_g1 状态，最多等 10 分钟）
        local wait_start=$SECONDS
        local max_wait=1200  # B-1(~5min) + B-2(~4min) + RefGen(~2min) + buffer, 冲突时可达 15min
        while (( SECONDS - wait_start < max_wait )); do
            local server_progress
            server_progress=$(REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" TASK_ID="$task_id" \
                python3 -c "
import os, urllib.request, json
url = os.environ['REVIEW_URL'].rstrip('/') + '/api/v1/tasks/' + os.environ['TASK_ID']
req = urllib.request.Request(url, headers={'Authorization': f\"Bearer {os.environ['DTOK']}\"})
try:
    data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(data.get('phase_progress', ''))
except: print('')
" 2>/dev/null)
            if [[ "$server_progress" == "review_g1" ]] || [[ "$server_progress" == "review_g2" ]] \
               || [[ "$server_progress" == "review_g3" ]] || [[ "$server_progress" == "phase_c_ready" ]] \
               || [[ "$server_progress" == "phase_c_running" ]]; then
                log_info "VPS Phase B complete (progress: $server_progress)"
                break
            fi
            sleep 30
        done

        if (( SECONDS - wait_start >= max_wait )); then
            # 超时后再查一次 VPS——可能刚好在最后几秒完成
            local final_check
            final_check=$(REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" TASK_ID="$task_id" \
                python3 -c "
import os, urllib.request, json
url = os.environ['REVIEW_URL'].rstrip('/') + '/api/v1/tasks/' + os.environ['TASK_ID']
req = urllib.request.Request(url, headers={'Authorization': f\"Bearer {os.environ['DTOK']}\"})
try:
    data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(data.get('phase_progress', ''))
except: print('')
" 2>/dev/null || echo "")
            # 如果 VPS 已推进到 B-2 或更后面，继续等（不走 fallback）
            case "$final_check" in
                generating_g2|generating_refs|review_g2|review_g3|phase_c_ready|phase_c_running)
                    log_info "VPS still progressing ($final_check), extending wait..."
                    # 再等 10 分钟（B-2 + ref gen 可能还在跑）
                    local ext_start=$SECONDS
                    while (( SECONDS - ext_start < 600 )); do
                        local ext_progress
                        ext_progress=$(REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" TASK_ID="$task_id" \
                            python3 -c "
import os, urllib.request, json
url = os.environ['REVIEW_URL'].rstrip('/') + '/api/v1/tasks/' + os.environ['TASK_ID']
req = urllib.request.Request(url, headers={'Authorization': f\"Bearer {os.environ['DTOK']}\"})
try:
    data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(data.get('phase_progress', ''))
except: print('')
" 2>/dev/null || echo "")
                        if [[ "$ext_progress" == "phase_c_ready" ]] || [[ "$ext_progress" == "review_g1" ]] || [[ "$ext_progress" == "review_g2" ]]; then
                            log_info "VPS Phase B complete after extended wait (progress: $ext_progress)"
                            break 2  # 跳出两层循环（此 while + 外层 if）
                        fi
                        sleep 30
                    done
                    log_warn "Extended wait also timed out ($final_check)"
                    return 1
                    ;;
                phase_c_complete|review_g4|completed)
                    log_info "VPS already past Phase C ($final_check), skipping B wait"
                    ;;
                *)
                    log_warn "VPS auto-judge timed out after ${max_wait}s (last: $final_check)"
                    return 1
                    ;;
            esac
        fi

        update_task_json "$task_path" "phase_progress" "waiting_g1" || true
        log_info "Brain API complete — now waiting for G1 review"
    fi

    # -----------------------------------------------------------
    # Step 2: 等待 G1 审核通过
    # -----------------------------------------------------------
    current_progress=$(get_task_field "$task_path" "phase_progress")
    if [[ "$current_progress" == "waiting_g1" ]]; then
        local g1_result
        wait_for_gate "$task_id" "g1" 7200 30
        g1_result=$?

        if [[ $g1_result -eq 1 ]]; then
            log_error "G1 rejected — task will not proceed (terminal, no retry)"
            update_task_json "$task_path" "phase_progress" "g1_rejected" || true
            return 2  # exit code 2 = human rejected, do NOT retry
        elif [[ $g1_result -eq 2 ]]; then
            log_error "G1 wait timed out — leaving task in waiting_g1 for recovery"
            return 1
        fi

        update_task_json "$task_path" "phase_progress" "waiting_g2" || true
        log_info "G1 approved — Phase B-2 auto-triggered on server, waiting for G2"
    fi

    # -----------------------------------------------------------
    # Step 3: 等待 G2 审核通过 (Phase B-2 在 server 端自动生成)
    # -----------------------------------------------------------
    current_progress=$(get_task_field "$task_path" "phase_progress")
    if [[ "$current_progress" == "waiting_g2" ]]; then
        local g2_result
        wait_for_gate "$task_id" "g2" 7200 30
        g2_result=$?

        if [[ $g2_result -eq 1 ]]; then
            log_error "G2 rejected — task will not proceed (terminal, no retry)"
            update_task_json "$task_path" "phase_progress" "g2_rejected" || true
            return 2  # exit code 2 = human rejected, do NOT retry
        elif [[ $g2_result -eq 2 ]]; then
            log_error "G2 wait timed out — leaving task in waiting_g2 for recovery"
            return 1
        fi

        log_info "G2 approved — downloading final prompts from server"
    fi

    # -----------------------------------------------------------
    # Step 4: 从 server 下载审核后的 jimeng_prompts (可能被审核员编辑过)
    # -----------------------------------------------------------
    if ! download_prompts_from_server "$task_id" "$work_dir"; then
        log_error "Failed to download prompts after G2 approval"
        return 1
    fi

    update_task_json "$task_path" "phase_progress" "phase_b_complete" || true
    log_info "Phase B completed (Brain API → G1 → G2 → prompts downloaded)"
    return 0
}

# Phase C: 即梦提交 (Pre-submit check + jimeng CDP submit)
run_phase_c() {
    local task_file="$1"
    local task_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${task_file}"
    local work_dir
    work_dir=$(get_task_field "$task_path" "work_dir")
    local task_id
    task_id=$(get_task_field "$task_path" "id")
    task_id="${task_id:-$(basename "$task_file" .json)}"
    local scripts_dir
    scripts_dir="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
    if [[ -z "$scripts_dir" ]] || [[ ! -d "$scripts_dir" ]]; then
        log_error "SCRIPTS_DIR resolution failed (BASH_SOURCE=${BASH_SOURCE[0]}); set SCRIPTS_DIR env var explicitly"
        return 1
    fi

    log_info "Starting Phase C for ${task_file} (task_id: ${task_id})"
    update_task_json "$task_path" "phase" "phase_c" || true
    update_task_json "$task_path" "phase_progress" "phase_c_running" || true
    report_progress "$task_id" "Phase C: 准备参考图" "开始下载参考图并校验"

    # Step 0: 准备参考图（从 macking 中控机同步 IP 库参考图）
    local refs_dir="${work_dir}/参考图"
    mkdir -p "$refs_dir"
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
            return 1
        fi
    fi

    # 从 jimeng-config 中提取需要的参考图列表，从 macking 同步
    local track
    track=$(get_task_field "$task_path" "track")
    track="${track:-kpop-dance}"
    local ip_group
    ip_group=$(get_task_field "$task_path" "ip_characters")
    ip_group="${ip_group:-$track}"
    local is_per_story=false
    [[ "$ip_group" == "per-story" ]] && is_per_story=true

    # 提取 refs 中的文件名（如 Rumi.png, Mira.png）
    local ref_names
    ref_names=$(python3 -c "
import json, re
with open('${prompt_md}', 'r') as f: content = f.read()
m = re.search(r'<!--\s*jimeng-config\s*\n([\s\S]*?)\n\s*-->', content)
if m:
    cfg = json.loads(m.group(1))
    names = set()
    for b in cfg.get('batches', []):
        for r in b.get('refs', []): names.add(r)
    print(' '.join(names))
" 2>/dev/null || echo "")

    if [[ -n "$ref_names" ]]; then
        # per-story 模式下用 track 名作 IP library 目录（不是 'per-story'）
        local ip_dir_source="$ip_group"
        [[ "$is_per_story" == "true" ]] && ip_dir_source="$track"
        local ip_dir_upper
        ip_dir_upper=$(echo "$ip_dir_source" | sed 's/kpop/KPOP/;s/gta/GTA/' | tr '[:lower:]' '[:upper:]' | sed 's/-DANCE//')

        # VPS review-server URL（优先从 VPS HTTP 下载生成的参考图）
        local vps_url="${REVIEW_SERVER_URL:-https://studio.createflow.art}"
        log_info "Syncing refs (VPS: $vps_url, macking: ${MACKING_HOST:-none}): $ref_names"

        # 获取 ref_results（着装/场景参考图元数据）
        local ref_results_json=""
        ref_results_json=$(curl -sf -H "Authorization: Bearer ${DISPATCHER_TOKEN:-}" \
            "${vps_url}/api/review/tasks/${task_id}/gate/g2" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('ref_results',{})))" 2>/dev/null || echo "{}")

        for ref_file in $ref_names; do
            local char_name="${ref_file%.*}"
            local local_path="${refs_dir}/${ref_file}"
            [[ -f "$local_path" ]] && continue

            # 所有下载分支共用的临时文件路径（必须在 set -u 环境下无条件声明）
            local tmp_dl="${local_path}.tmp"

            # 1. 优先从 VPS HTTP 下载着装参考图
            # 注意：set -e 环境下 read < <(...) 空输出会退出脚本，改用 $(...) 安全提取
            local costume_fn="" costume_group_dir=""
            local _costume_line
            _costume_line=$(echo "$ref_results_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('costume', []):
    if c.get('character') == '${char_name}':
        print(c.get('filename', ''), c.get('groupDir', '')); break
" 2>/dev/null || echo "")
            if [[ -n "$_costume_line" ]]; then
                costume_fn="${_costume_line% *}"
                costume_group_dir="${_costume_line##* }"
                # 若 python 只输出了 filename（无 groupDir），上面的 cut 会得到相同值 → 清空 groupDir
                [[ "$costume_fn" == "$costume_group_dir" ]] && costume_group_dir=""
            fi

            # 如果 ref_results 没有 groupDir，回退到全局 ip_dir_upper
            local char_ip_dir="${costume_group_dir:-$ip_dir_upper}"

            local synced=false
            if [[ -n "$costume_fn" ]]; then
                local encoded_fn
                encoded_fn=$(python3 -c "from urllib.parse import quote; print(quote('${costume_fn}'))" 2>/dev/null || echo "$costume_fn")
                if [[ "$is_per_story" == "true" ]]; then
                    # per-story: 角色参考图在 /ref-images/{taskId}/
                    local encoded_tid
                    encoded_tid=$(python3 -c "from urllib.parse import quote; print(quote('${task_id}'))" 2>/dev/null || echo "$task_id")
                    local costume_url="${vps_url}/ref-images/${encoded_tid}/${encoded_fn}"
                    curl -sf -o "$tmp_dl" "$costume_url" 2>/dev/null && [[ -s "$tmp_dl" ]] && mv "$tmp_dl" "$local_path" && \
                        { log_info "  Downloaded per-story costume from VPS: $task_id/$costume_fn"; synced=true; }
                else
                    # 固定 IP: 角色参考图在 /ip-images/{GROUP}/{CharName}/
                    local encoded_char
                    encoded_char=$(python3 -c "from urllib.parse import quote; print(quote('${char_name}'))" 2>/dev/null || echo "$char_name")
                    local encoded_group
                    encoded_group=$(python3 -c "from urllib.parse import quote; print(quote('${char_ip_dir}'))" 2>/dev/null || echo "$char_ip_dir")
                    local costume_url="${vps_url}/ip-images/${encoded_group}/${encoded_char}/${encoded_fn}"
                    curl -sf -o "$tmp_dl" "$costume_url" 2>/dev/null && [[ -s "$tmp_dl" ]] && mv "$tmp_dl" "$local_path" && \
                        { log_info "  Downloaded costume from VPS: $char_ip_dir/$char_name/$costume_fn"; synced=true; }
                fi
            fi

            # 2. 降级：从 VPS 下载 Default.jpeg（仅固定 IP 模式）
            if [[ "$synced" != "true" ]] && [[ "$is_per_story" != "true" ]]; then
                local encoded_char_default
                encoded_char_default=$(python3 -c "from urllib.parse import quote; print(quote('${char_name}'))" 2>/dev/null || echo "$char_name")
                local encoded_group_default
                encoded_group_default=$(python3 -c "from urllib.parse import quote; print(quote('${char_ip_dir}'))" 2>/dev/null || echo "$char_ip_dir")
                local default_url="${vps_url}/ip-images/${encoded_group_default}/${encoded_char_default}/Default.jpeg"
                curl -sf -o "$tmp_dl" "$default_url" 2>/dev/null && [[ -s "$tmp_dl" ]] && mv "$tmp_dl" "$local_path" && \
                    { log_info "  Downloaded default from VPS: $ref_file"; synced=true; }
            fi

            # 3. 最后降级：从 macking 获取（仅固定 IP 模式）
            if [[ "$synced" != "true" ]] && [[ "$is_per_story" != "true" ]] && [[ -n "${MACKING_HOST:-}" ]]; then
                if is_local_macking; then
                    local default_local="$HOME/production/ip-library/${char_ip_dir}/${char_name}/Default.jpeg"
                    [[ -f "$default_local" ]] && cp "$default_local" "$local_path" 2>/dev/null && \
                        { log_info "  Copied local ref: $ref_file"; synced=true; } || \
                        log_warn "  Local ref not found: $default_local"
                else
                    local default_remote="${MACKING_USER}@${MACKING_HOST}:~/production/ip-library/${char_ip_dir}/${char_name}/Default.jpeg"
                    scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$default_remote" "$local_path" 2>/dev/null && \
                        { log_info "  Synced from macking: $ref_file"; synced=true; } || \
                        log_warn "  Failed to sync: $ref_file"
                fi
            fi

            if [[ "$synced" != "true" ]]; then
                log_warn "  MISSING ref: $ref_file — character consistency will be affected"
            fi
        done

        # 4. 场景参考图（从 VPS HTTP 下载）
        local scene_files=""
        scene_files=$(echo "$ref_results_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('scene', []):
    fn = s.get('filename', '')
    desc = s.get('desc', '')
    indoor = any(k in desc for k in ['教室','办公','卧室','厨房','走廊','图书','宿舍','室内','房间'])
    scene_type = '室内' if indoor else '户外'
    if fn: print(f'{scene_type}/{fn}')
" 2>/dev/null || echo "")

        for scene_path in $scene_files; do
            local scene_fn
            scene_fn=$(basename "$scene_path")
            local local_scene="${refs_dir}/${scene_fn}"
            if [[ ! -f "$local_scene" ]]; then
                local scene_url="${vps_url}/ip-images/场景/${scene_path}"
                curl -sf -o "$local_scene" "$scene_url" 2>/dev/null && \
                    log_info "  Downloaded scene from VPS: $scene_path" || \
                    log_warn "  Failed to download scene: $scene_path"
            fi
        done

        # 5. 道具参考图（从 VPS HTTP 下载）
        local prop_files=""
        prop_files=$(echo "$ref_results_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('props', []):
    fn = p.get('filename', '')
    if fn: print(fn)
" 2>/dev/null || echo "")

        for prop_fn in $prop_files; do
            local local_prop="${refs_dir}/${prop_fn}"
            if [[ ! -f "$local_prop" ]]; then
                local prop_url="${vps_url}/ip-images/道具/${prop_fn}"
                curl -sf -o "$local_prop" "$prop_url" 2>/dev/null && \
                    log_info "  Downloaded prop from VPS: $prop_fn" || \
                    log_warn "  Failed to download prop: $prop_fn"
            fi
        done
    fi

    # 在 phase_b/ 下创建符号链接（jimeng_cuihua 从 md 文件所在目录解析 refs 路径）
    # 同时为 .jpeg 文件创建 .png 别名（jimeng config 引用 .png 但实际文件可能是 .jpeg）
    for ref_file in "$refs_dir"/*.{png,jpg,jpeg} ; do
        [[ -f "$ref_file" ]] || continue
        local base_name
        base_name=$(basename "$ref_file")
        ln -sf "$ref_file" "${work_dir}/phase_b/${base_name}" 2>/dev/null || true
        # .jpeg → .png alias (jimeng config refs use .png)
        if [[ "$base_name" == *.jpeg ]]; then
            ln -sf "$ref_file" "${work_dir}/phase_b/${base_name%.jpeg}.png" 2>/dev/null || true
        fi
    done

    local ref_count
    ref_count=$(find "$refs_dir" -maxdepth 1 -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ref_count" -eq 0 ]]; then
        log_warn "参考图目录为空: $refs_dir — 即梦提交可能缺少参考图"
    else
        log_info "参考图目录包含 $ref_count 张图片"
    fi

    report_progress "$task_id" "Phase C: 双闸门校验" "${ref_count} 张参考图就绪"
    log_info "Phase C Step 1/2: pre_submit_check.mjs (双闸门校验)"
    if ! node "$scripts_dir/pre_submit_check.mjs" "$prompt_md" "$refs_dir"; then
        log_error "双闸门校验未通过"
        report_progress "$task_id" "Phase C: 校验失败" "双闸门校验未通过"
        return 1
    fi

    # Step 2: 即梦提交 (优先 dreamina CLI，fallback CDP)
    local submit_state="${work_dir}/phase_b/submit_state.json"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if command -v dreamina &>/dev/null; then
        # ── 新方案: dreamina CLI 直接 API 提交 ──
        log_info "Phase C Step 2/2: jimeng_submit_cli.sh (dreamina CLI 提交)"
        report_progress "$task_id" "Phase C: 即梦提交" "dreamina CLI 开始提交"
        if ! PROGRESS_URL="$REVIEW_SERVER_URL" PROGRESS_TOKEN="$DISPATCHER_TOKEN" \
            bash "$scripts_dir/jimeng/jimeng_submit_cli.sh" --prompt-md "$prompt_md" --refs-dir "$refs_dir" --task-id "$task_id"; then
            log_error "jimeng_submit_cli.sh failed"
            report_progress "$task_id" "Phase C: 提交失败" "dreamina CLI 提交出错"
            return 1
        fi
    else
        # ── Legacy fallback: Chrome CDP + Playwright ──
        log_warn "dreamina CLI not found, falling back to CDP submission"
        local cdp_port="${CDP_PORT:-9222}"
        if ! node "$scripts_dir/jimeng/jimeng_cuihua.mjs" --from-md "$prompt_md" --refs-dir "$refs_dir" --keep-browser --cdp-port "$cdp_port"; then
            log_error "jimeng_cuihua.mjs failed"
            return 1
        fi
    fi

    # 记录提交信息到任务 JSON
    update_task_json "$task_path" "jimeng_submitted_at" "$now" || true
    update_task_json "$task_path" "jimeng_submitted_by" "$WORKER_ID" || true

    # 从 submit_state.json 读取提交结果
    if [[ ! -f "$submit_state" ]]; then
        log_error "submit_state.json not found — Phase C 视为失败"
        return 1
    fi

    # 支持两种格式: CLI (submit_ids) 和 CDP (project_id)
    local submit_ids=""
    local project_id=""
    submit_ids=$(python3 -c "
import json
try:
    with open('${submit_state}', 'r') as f:
        data = json.load(f)
    if data.get('mode') == 'cli':
        ids = data.get('submit_ids', [])
        if ids:
            print(json.dumps(ids))
        else:
            print('')
    else:
        pid = data.get('project_id', '')
        print(pid if pid else '')
except:
    print('')
" 2>/dev/null || echo "")

    if [[ -z "$submit_ids" ]]; then
        log_error "submit_state.json 无有效提交 ID — Phase C 视为失败"
        return 1
    fi

    # 判断是 CLI 模式 (JSON array) 还是 CDP 模式 (单 ID)
    if [[ "$submit_ids" == "["* ]]; then
        # CLI 模式: submit_ids 是 JSON 数组
        update_task_json "$task_path" "jimeng_submit_ids" "$submit_ids" || true
        log_info "Recorded jimeng_submit_ids: $submit_ids"

        if update_task_json "$task_path" "phase_progress" "phase_c_complete"; then
            log_info "Phase C completed — dreamina CLI 提交成功，等待 Harvest"
            # 直接 curl 发送（绕过 report_event 的 subshell payload 传递问题）
            local _pc_tmp="/tmp/pc_report_$$.json"
            printf '{"task_id":"%s","event":"phase_c_complete","payload":{"jimeng_submit_ids":%s}}' "$task_id" "$submit_ids" > "$_pc_tmp"
            (curl -sf -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                -d @"$_pc_tmp" --connect-timeout 10 --max-time 30 > /dev/null 2>&1 \
                && echo "[report] phase_c_complete OK" \
                || echo "[report] phase_c_complete FAILED"
                rm -f "$_pc_tmp") &
            return 0
        fi
    else
        # CDP 模式: submit_ids 是单个 project_id
        project_id="$submit_ids"
        update_task_json "$task_path" "jimeng_project_id" "$project_id" || true
        log_info "Recorded jimeng_project_id: $project_id"

        if update_task_json "$task_path" "phase_progress" "phase_c_complete"; then
            log_info "Phase C completed — CDP 提交成功，等待 Harvest"
            report_event "$task_id" "phase_c_complete" "{\"jimeng_project_id\":\"${project_id}\"}"
            return 0
        fi
    fi

    log_error "Failed to update phase progress"
    return 1
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

    # 同步生成视频和产出文件到 macking 中控机统一存储
    if [[ -n "${MACKING_HOST:-}" ]] && [[ -d "$new_work_dir" ]]; then
        if is_local_macking; then
            local delivery_dir="$HOME/production/delivery/${task_id}/"
            log_info "Syncing deliverables locally: $delivery_dir"
            mkdir -p "$delivery_dir" && cp -a "$new_work_dir/"* "$delivery_dir" 2>/dev/null && \
                log_info "Deliverables synced locally" || \
                log_warn "Failed to sync locally (non-fatal, files remain in work dir)"
        else
            local delivery_dir="${MACKING_USER}@${MACKING_HOST}:~/production/delivery/${task_id}/"
            log_info "Syncing deliverables to macking: $delivery_dir"
            rsync -az -e "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no" \
                "$new_work_dir/" "$delivery_dir" 2>/dev/null && \
                log_info "Deliverables synced to macking" || \
                log_warn "Failed to sync to macking (non-fatal, files remain on worker)"
        fi
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

    # 后台心跳循环（每 30s 发一次 busy，任务结束时自动停止）
    local heartbeat_pid=""
    if [[ -n "$REVIEW_SERVER_URL" ]]; then
        (while true; do
            curl -s -X POST "${REVIEW_SERVER_URL}/api/v1/worker/heartbeat" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                -d "{\"worker_id\":\"${WORKER_ID}\",\"status\":\"busy\",\"current_task\":\"${task_file}\"}" \
                > /dev/null 2>&1
            sleep 30
        done) &
        heartbeat_pid=$!
    fi

    local task_id
    task_id=$(get_task_field "$task_path" "task_id")
    task_id="${task_id:-$(basename "$task_file" .json)}"

    # 上报任务认领（简单 JSON，不含大文本，直接构建安全）
    local video_url gate_mode
    video_url=$(get_task_field "$task_path" "video_url")
    gate_mode=$(get_task_field "$task_path" "gate_mode")
    report_event "$task_id" "task_created" \
        "{\"video_url\":\"${video_url}\",\"gate_mode\":\"${gate_mode:-full_review}\",\"worker_id\":\"${WORKER_ID}\"}" || true

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

    # ── 只执行 Phase A，完成后释放 worker ──
    # Phase B (评分+审核) 由 VPS 自动驱动，不阻塞 worker
    # Phase C (即梦提交) 通过 poll-phase-c 由空闲 worker 认领
    # 这样每台 Mac Mini 不再被审核等待锁死，可连续处理多个 Phase A

    # Dispatch by track_kind — commentary 赛道有自己的 Phase A/C 流程
    local track_kind
    track_kind=$(get_task_field "$task_path" "track_kind")
    track_kind="${track_kind:-video_gen}"
    if [[ "$track_kind" == "commentary" ]]; then
        log_info "Dispatching commentary Phase A for $task_id"
        local commentary_sh="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/commentary/worker_commentary.sh"
        if "$commentary_sh" "$task_path" phase_a; then
            log_info "Commentary Phase A done for $task_id — released to VPS"
        else
            log_error "Commentary Phase A failed for $task_id"
            report_event "$task_id" "task_failed" \
                "{\"error\":\"commentary_phase_a_failed\"}" || true
        fi
        # 停止后台心跳
        [[ -n "$heartbeat_pid" ]] && kill "$heartbeat_pid" 2>/dev/null && wait "$heartbeat_pid" 2>/dev/null
        local completed_dir="${SHARED_DIR}/tasks/completed"
        mkdir -p "$completed_dir"
        mv "$task_path" "$completed_dir/$(basename "$task_path")" 2>/dev/null || true
        return 0
    fi

    run_phase_a "$task_file"
    local phase_exit=$?

    # 停止后台心跳
    [[ -n "$heartbeat_pid" ]] && kill "$heartbeat_pid" 2>/dev/null && wait "$heartbeat_pid" 2>/dev/null

    if [[ $phase_exit -ne 0 ]]; then
        # Phase A 失败 — 可重试
        local retry_count
        retry_count=$(get_task_field "$task_path" "retry_count")
        retry_count=${retry_count:-0}
        retry_count=$((retry_count + 1))
        update_task_json "$task_path" "retry_count" "$retry_count" || true

        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log_warn "Phase A failed (attempt $retry_count/$MAX_RETRIES), re-queuing..."
            update_task_json "$task_path" "status" "pending" || true
            update_task_json "$task_path" "phase" "null" || true
            update_task_json "$task_path" "claimed_by" "null" || true
            local requeue_path="${SHARED_DIR}/tasks/pending/${task_file}"
            mv "$task_path" "$requeue_path" 2>/dev/null || true
        else
            log_error "Phase A exceeded max retries, moving to failed"
            local failed_path="${SHARED_DIR}/tasks/failed/${task_file}"
            mv "$task_path" "$failed_path" 2>/dev/null || true
            local fail_detail="${PHASE_A_FAIL_DETAIL:-未知}"
            # 根据失败原因选择更具体的错误码
            local error_code="phase_a_max_retries"
            case "$fail_detail" in
                *下载*) error_code="phase_a_download_failed" ;;
                *分析*) error_code="phase_a_analysis_failed" ;;
            esac
            report_event "$task_id" "task_failed" "{\"error\":\"$error_code\",\"detail\":\"$fail_detail (重试${retry_count}次)\",\"retry_count\":$retry_count}"
        fi
        return 1
    fi

    # Phase A 成功 — VPS 已收到 phase_a_complete，会自动驱动 Phase B
    # 清理本地任务文件（worker 不再持有此任务）
    log_info "Phase A complete, releasing worker (VPS handles Phase B → G1 → G2 → Phase C dispatch)"
    local completed_a_dir="${SHARED_DIR}/tasks/completed"
    mkdir -p "$completed_a_dir"
    mv "$task_path" "$completed_a_dir/${task_file}" 2>/dev/null || true
    return 0
}

# ============================================================================
# 信号处理 (Signal Handling)
# ============================================================================

# 优雅关闭：完成当前阶段，不中断任务 (Graceful shutdown)
cleanup() {
    log_info "Received shutdown signal, gracefully stopping..."
    SHUTDOWN_REQUESTED=1
    # 等待当前任务完成 (Wait for current task to complete)
    sleep 5
    log_info "Worker shutting down"
    exit 0
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

# ============================================================================
# Harvest: 检查 harvesting 目录中的任务，下载完成的视频
# 集成在主循环中，每轮空闲时检查一次（替代独立的 harvest_daemon.sh）
# ============================================================================
check_harvesting_tasks() {
    local harvesting_dir="${SHARED_DIR}/tasks/harvesting"
    [[ -d "$harvesting_dir" ]] || return 0

    local tasks
    tasks=$(find "$harvesting_dir" -maxdepth 1 -name "*.json" 2>/dev/null)
    [[ -z "$tasks" ]] && return 0

    local scripts_dir
    scripts_dir="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
    if [[ -z "$scripts_dir" ]] || [[ ! -d "$scripts_dir" ]]; then
        log_error "SCRIPTS_DIR resolution failed (BASH_SOURCE=${BASH_SOURCE[0]}); set SCRIPTS_DIR env var explicitly"
        return 1
    fi
    local monitor_script="$scripts_dir/jimeng/jimeng_monitor.mjs"

    while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue
        local task_id
        task_id=$(get_task_field "$task_file" "id")
        local project_id
        # 只处理自己提交的即梦任务（不同 worker 有不同即梦账号）
        local submitted_by
        submitted_by=$(get_task_field "$task_file" "jimeng_submitted_by")
        if [[ -n "$submitted_by" ]] && [[ "$submitted_by" != "$WORKER_ID" ]]; then
            continue  # 跳过别人提交的任务
        fi

        local work_dir
        work_dir=$(get_task_field "$task_file" "work_dir")
        [[ -z "$work_dir" ]] && work_dir="${harvesting_dir}/work_${task_id}"

        # 查状态: 优先 CLI (submit_ids)，fallback CDP (project_id)
        local raw=""
        local submit_ids=""
        submit_ids=$(get_task_field "$task_file" "jimeng_submit_ids")
        local submit_state_file="$work_dir/phase_b/submit_state.json"

        if [[ -n "$submit_ids" ]] && [[ -f "$submit_state_file" ]]; then
            # ── CLI 模式: 用 jimeng_harvest_cli.sh ──
            local harvest_script="$scripts_dir/jimeng/jimeng_harvest_cli.sh"
            if [[ -f "$harvest_script" ]]; then
                raw=$(timeout 120 bash "$harvest_script" \
                    --submit-state "$submit_state_file" \
                    --video-dir "$work_dir/videos" \
                    --check-only 2>/dev/null || echo "")
            fi
        else
            # ── Legacy CDP 模式 ──
            local project_id
            project_id=$(get_task_field "$task_file" "jimeng_project_id")
            [[ -z "$project_id" ]] && continue
            if [[ -f "$monitor_script" ]]; then
                raw=$(timeout 60 node "$monitor_script" --project "$project_id" --cdp-port "${CDP_PORT:-9222}" --check-only 2>/dev/null || echo "")
            fi
        fi

        local overall="unknown"
        if [[ -n "$raw" ]] && echo "$raw" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
            overall=$(echo "$raw" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('overall','unknown'))" 2>/dev/null)
        fi

        log_info "[Harvest] $task_id: status=$overall"

        # 计算等待时长（从 jimeng_submitted_at 起）
        local elapsed_text=""
        local submitted_at_for_detail
        submitted_at_for_detail=$(get_task_field "$task_file" "jimeng_submitted_at")
        if [[ -n "$submitted_at_for_detail" ]]; then
            local _elapsed
            _elapsed=$(python3 -c "from datetime import datetime; print(int((datetime.utcnow()-datetime.fromisoformat('${submitted_at_for_detail}'.replace('Z','+00:00').replace('+00:00',''))).total_seconds()))" 2>/dev/null || echo 0)
            if (( _elapsed > 0 )); then
                elapsed_text="已等待 $((_elapsed/3600))h$(((_elapsed%3600)/60))m"
            fi
        fi

        # 上报 harvest 轮询状态（合并聚合信息 + 等待时长为一条）
        if [[ -n "$raw" ]]; then
            local h_detail
            h_detail=$(echo "$raw" | ELAPSED_TEXT="$elapsed_text" python3 -c "
import sys, json, os
try:
    d = json.loads(sys.stdin.read())
    c, g, f, t = d.get('completed',0), d.get('generating',0), d.get('failed',0), d.get('total',0)
    q = d.get('queuing',0)
    parts = []
    if c: parts.append(f'{c}/{t}完成')
    if g: parts.append(f'{g}生成中')
    if q:
        qi = d.get('queue_info', {})
        pos = f' 排#{qi[\"queue_idx\"]}/{qi[\"queue_length\"]}' if qi.get('queue_idx') else ''
        parts.append(f'{q}排队{pos}')
    if f:
        frs = d.get('fail_reasons', [])
        fr_text = f' ({frs[0][:30]})' if frs else ''
        parts.append(f'{f}失败{fr_text}')
    base = ', '.join(parts) if parts else f'0/{t} 查询中'
    elapsed = os.environ.get('ELAPSED_TEXT', '')
    print(f'{base} · {elapsed}' if elapsed else base)
except: print('查询中')
" 2>/dev/null || echo "查询中")
            report_progress "$task_id" "Harvest: ${overall}" "$h_detail"
        else
            # 没拿到 raw（harvest cli 失败）也上报一下，避免看板失联
            report_progress "$task_id" "Harvest: 查询失败" "harvest cli 无返回${elapsed_text:+，$elapsed_text}"
        fi

        if [[ "$overall" == "complete" ]]; then
            log_info "[Harvest] $task_id: 即梦完成，收集视频..."
            local video_dir="$work_dir/videos"
            mkdir -p "$video_dir"

            # CLI 模式: query_result --download_dir 已下载视频到 video_dir
            # CDP 模式: 需要从 JSON 中提取 URL 并 curl 下载
            local dl_count=0
            if [[ -n "$raw" ]]; then
                dl_count=$(echo "$raw" | VIDEO_DIR="$video_dir" python3 -c "
import sys, json, subprocess, os, glob
d = json.loads(sys.stdin.read())
out = os.environ.get('VIDEO_DIR', '/tmp')

# Count existing local video files (CLI mode downloads directly)
local_videos = [f for f in glob.glob(os.path.join(out, '*.mp4'))
                if os.path.getsize(f) > 10000]
ok = len(local_videos)

# If no local files, try downloading from URLs (CDP mode)
if ok == 0:
    for i, v in enumerate(d.get('videos', [])):
        url = v.get('url', '')
        fn = v.get('filename', f'video_{i+1}.mp4')
        if not url or url.startswith('local:'): continue
        path = os.path.join(out, fn)
        if os.path.exists(path) and os.path.getsize(path) > 10000:
            ok += 1; continue
        r = subprocess.run(['curl', '-sL', '-o', path, url], timeout=120, capture_output=True)
        sz = os.path.getsize(path) if os.path.exists(path) else 0
        if r.returncode == 0 and sz > 10000: ok += 1
        elif os.path.exists(path): os.remove(path)
print(ok)
" 2>/dev/null || echo 0)
            fi

            if [[ "$dl_count" -gt 0 ]]; then
                log_info "[Harvest] $task_id: 下载了 $dl_count 个视频"

                # ── 上传视频到 VPS（主路径，通过已有 SSH 隧道 HTTP） ──
                local upload_ok=true
                log_info "[Harvest] $task_id: 上传视频到 VPS..."
                for vf in "$video_dir"/*.mp4; do
                    [[ -f "$vf" ]] || continue
                    local vfn=$(basename "$vf")
                    local vsize=$(stat -f%z "$vf" 2>/dev/null || stat -c%s "$vf" 2>/dev/null || echo 0)
                    if [[ "$vsize" -le 10000 ]]; then continue; fi
                    local upload_url="${REVIEW_SERVER_URL}/api/v1/tasks/${task_id}/upload-video?filename=${vfn}"
                    local http_code
                    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                        -X POST \
                        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                        -H "Content-Type: application/octet-stream" \
                        --data-binary "@${vf}" \
                        --max-time 120 \
                        "$upload_url" 2>/dev/null)
                    if [[ "$http_code" == "200" ]]; then
                        log_info "[Harvest] $task_id: 已上传 $vfn ($((vsize/1048576))MB)"
                    else
                        log_warn "[Harvest] $task_id: 上传 $vfn 失败 (HTTP $http_code)"
                        upload_ok=false
                    fi
                done
                if $upload_ok; then
                    log_info "[Harvest] $task_id: 全部视频已上传到 VPS"
                else
                    log_warn "[Harvest] $task_id: 部分视频上传失败，预览可能不完整"
                fi

                # ── 后台同步到 macking（剪辑团队用，非关键路径） ──
                if is_local_macking; then
                    # 本机就是 macking，本地 cp 即可
                    local macking_delivery="$HOME/production/deliveries/${task_id}"
                    (
                        mkdir -p "$macking_delivery/videos" "$macking_delivery/参考图"
                        cp -a "$video_dir/"* "$macking_delivery/videos/" 2>/dev/null
                        [[ -d "$work_dir/参考图" ]] && cp -a "$work_dir/参考图/"* "$macking_delivery/参考图/" 2>/dev/null
                        [[ -f "$work_dir/phase_b/即梦提示词.md" ]] && cp "$work_dir/phase_b/即梦提示词.md" "$macking_delivery/" 2>/dev/null
                        [[ -f "$work_dir/phase_b/submit_state.json" ]] && cp "$work_dir/phase_b/submit_state.json" "$macking_delivery/" 2>/dev/null
                        log_info "[Harvest] $task_id: 剪辑包已就绪（本地）"
                        # 自动整理剪辑包到桌面（含发布信息.txt）
                        if [[ -f "$SCRIPTS_DIR/prepare_editing_package.sh" ]]; then
                            bash "$SCRIPTS_DIR/prepare_editing_package.sh" "$task_id" 2>&1 | while read -r line; do log_info "[Package] $line"; done \
                                || log_warn "[Package] prepare_editing_package.sh 失败（不影响 harvest）"
                        fi
                        report_progress "$task_id" "剪辑包已就绪" "视频+参考图+提示词已保存到本地"
                    ) &
                else
                    local macking_delivery="/Users/${MACKING_USER}/production/deliveries/${task_id}"
                    (
                        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                            "${MACKING_USER}@${MACKING_HOST}" \
                            "mkdir -p '$macking_delivery/videos' '$macking_delivery/参考图'" 2>/dev/null \
                        && rsync -az -e "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no" \
                            "$video_dir/" "${MACKING_USER}@${MACKING_HOST}:$macking_delivery/videos/" 2>/dev/null \
                        && log_info "[Harvest] $task_id: 视频已同步到 macking" \
                        || log_warn "[Harvest] $task_id: macking 同步失败（不影响预览）"
                        # 同步参考图/提示词/原视频
                        [[ -d "$work_dir/参考图" ]] && rsync -az -e "ssh -o StrictHostKeyChecking=no" "$work_dir/参考图/" "${MACKING_USER}@${MACKING_HOST}:$macking_delivery/参考图/" 2>/dev/null
                        [[ -f "$work_dir/phase_b/即梦提示词.md" ]] && scp -q -o StrictHostKeyChecking=no "$work_dir/phase_b/即梦提示词.md" "${MACKING_USER}@${MACKING_HOST}:$macking_delivery/" 2>/dev/null
                        [[ -f "$work_dir/phase_b/submit_state.json" ]] && scp -q -o StrictHostKeyChecking=no "$work_dir/phase_b/submit_state.json" "${MACKING_USER}@${MACKING_HOST}:$macking_delivery/" 2>/dev/null
                        # 在 macking 上自动整理剪辑包到桌面（含发布信息.txt）
                        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                            "${MACKING_USER}@${MACKING_HOST}" \
                            "test -f ~/worker-code/scripts/worker/prepare_editing_package.sh" 2>/dev/null; then
                            ssh -o StrictHostKeyChecking=no "${MACKING_USER}@${MACKING_HOST}" \
                                "bash ~/worker-code/scripts/worker/prepare_editing_package.sh '$task_id'" 2>&1 \
                                | while read -r line; do log_info "[Package] $line"; done \
                                || log_warn "[Package] macking prepare_editing_package.sh 失败（不影响 harvest）"
                        fi
                        report_progress "$task_id" "剪辑包已就绪" "视频+参考图+提示词已同步到 macking"
                    ) &
                fi

                # ── 上报 harvest_complete ──
                TASK_ID="$task_id" VIDEO_DIR="$video_dir" HARVEST_RAW="$raw" \
                REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
                python3 << 'HARVEST_PYEOF'
import os, json, urllib.request, time, glob

task_id = os.environ["TASK_ID"]
video_dir = os.environ["VIDEO_DIR"]
url = os.environ["REVIEW_URL"].rstrip("/") + "/api/v1/tasks/report"

# 从 harvest_cli 输出提取 CDN URL 映射
cdn_urls = {}
try:
    harvest_data = json.loads(os.environ.get("HARVEST_RAW", "{}"))
    for v in harvest_data.get("videos", []):
        fn = v.get("filename", "")
        vu = v.get("video_url", v.get("url", ""))
        if fn and vu: cdn_urls[fn] = vu
except: pass

# 从 submit_state.json 读取 submit_id → (batch_num, model) 映射
sid_map = {}  # submit_id → {"batch_num": int, "model": str}
try:
    work_dir = os.path.dirname(video_dir)  # videos/ 的上级即 work_dir
    state_path = os.path.join(work_dir, "phase_b", "submit_state.json")
    if not os.path.exists(state_path):
        state_path = os.path.join(work_dir, "submit_state.json")
    with open(state_path) as f:
        state = json.load(f)
    if state.get("schema_version", 0) >= 2:
        for bkey, models in state.get("batches", {}).items():
            bn = int(bkey.replace("batch", ""))
            for model_name, info in models.items():
                sid = info.get("submit_id", "")
                if sid:
                    sid_map[sid] = {"batch_num": bn, "model": model_name}
    print(f"[Harvest] Loaded {len(sid_map)} submit_id mappings from submit_state.json")
except Exception as e:
    print(f"[Harvest] submit_state.json not available: {e}")

videos = sorted(glob.glob(os.path.join(video_dir, "*.mp4")))
video_list = []
for v in videos:
    sz = os.path.getsize(v)
    if sz <= 10000: continue
    fn = os.path.basename(v)
    # 从文件名提取 submit_id: {submit_id}_video_1.mp4
    sid = fn.split("_video_")[0] if "_video_" in fn else ""
    entry = {"filename": fn, "size": sz}
    if fn in cdn_urls: entry["video_url"] = cdn_urls[fn]
    entry["media_path"] = f"{task_id}/videos/{fn}"
    # 优先从 submit_state 获取正确的 batch_num 和 model
    if sid in sid_map:
        entry["batch_num"] = sid_map[sid]["batch_num"]
        entry["model"] = sid_map[sid]["model"]
    video_list.append(entry)

# 从 harvest summary 读取积分数据 + 失败任务
credits_charged = 0
credits_refunded = 0
failed_submissions = []
try:
    harvest_data_parsed = json.loads(os.environ.get("HARVEST_RAW", "{}"))
    harvest_info = state.get("harvest", {}) if 'state' in dir() else {}
    credits_charged = harvest_info.get("credits_charged", 0)
    credits_refunded = harvest_info.get("credits_refunded", 0)
except: pass

# 收集失败的 submit_id（有 sid_map 映射的才能知道批次号）
all_submit_ids = set(sid_map.keys())
success_sids = set()
for v in video_list:
    fn = v.get("filename", "")
    sid = fn.split("_video_")[0] if "_video_" in fn else ""
    if sid: success_sids.add(sid)

for sid in all_submit_ids - success_sids:
    info = sid_map.get(sid, {})
    # 从 harvest raw data 找 fail_reason
    fail_reason = ""
    try:
        for fr_line in (harvest_data_parsed.get("fail_reasons", []) or []):
            if fr_line: fail_reason = fr_line; break
    except: pass
    # 从 submit_state 读取更精确的状态
    try:
        for bkey, models in state.get("batches", {}).items():
            for mname, minfo in models.items():
                if minfo.get("submit_id") == sid:
                    fail_reason = fail_reason or minfo.get("fail_reason", "")
    except: pass
    failed_submissions.append({
        "submit_id": sid,
        "batch_num": info.get("batch_num", 0),
        "model": info.get("model", ""),
        "fail_reason": fail_reason or "generation failed or cancelled",
    })

if failed_submissions:
    print(f"[Harvest] {len(failed_submissions)} failed submissions: {[f['submit_id'][:8] for f in failed_submissions]}")

body = json.dumps({
    "task_id": task_id,
    "event": "harvest_complete",
    "payload": {
        "video_count": len(video_list),
        "videos": video_list,
        "failed_submissions": failed_submissions,
        "credits_charged": credits_charged,
        "credits_refunded": credits_refunded,
    }
}).encode("utf-8")

req = urllib.request.Request(url, data=body, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bearer {os.environ['DTOK']}"
})
for attempt in range(3):
    try:
        urllib.request.urlopen(req, timeout=30)
        print(f"[Harvest] harvest_complete reported OK ({len(video_list)} videos)")
        break
    except Exception as e:
        if attempt < 2: time.sleep(5 * (2 ** attempt))
        else: print(f"[Harvest] report failed: {e}")
HARVEST_PYEOF

                # 等后台同步参考图完成后再移动目录
                wait 2>/dev/null

                # 移到 completed
                local completed_dir="${SHARED_DIR}/tasks/completed"
                mkdir -p "$completed_dir"
                mv "$task_file" "$completed_dir/$(basename "$task_file")" 2>/dev/null
                [[ -d "$work_dir" ]] && mv "$work_dir" "$completed_dir/work_${task_id}" 2>/dev/null
                log_info "[Harvest] $task_id: 完成，已移到 completed"
                report_progress "$task_id" "Harvest: 完成" "${dl_count} 个视频已下载"
            else
                log_warn "[Harvest] $task_id: 视频下载失败 (count=$dl_count)"
                report_progress "$task_id" "Harvest: 下载失败" "视频文件下载失败"
            fi

        elif [[ "$overall" == "failed" ]]; then
            log_error "[Harvest] $task_id: 即梦生成失败"
            report_progress "$task_id" "Harvest: 生成失败" "即梦视频生成失败"
            report_event "$task_id" "task_failed" "{\"error\":\"jimeng_generation_failed\"}"
            mv "$task_file" "${SHARED_DIR}/tasks/failed/$(basename "$task_file")" 2>/dev/null

        elif [[ "$overall" == "generating" || "$overall" == "unknown" ]]; then
            # 24 小时硬超时检查（进度上报已在上面合并的 h_detail 里完成）
            local submitted_at
            submitted_at=$(get_task_field "$task_file" "jimeng_submitted_at")
            if [[ -n "$submitted_at" ]]; then
                local elapsed
                elapsed=$(python3 -c "from datetime import datetime; print(int((datetime.utcnow()-datetime.fromisoformat('${submitted_at}'.replace('Z','+00:00').replace('+00:00',''))).total_seconds()))" 2>/dev/null || echo 0)
                if (( elapsed > 86400 )); then
                    log_error "[Harvest] $task_id: 即梦超时 (${elapsed}s / 24h)"
                    report_event "$task_id" "harvest_timeout" "{\"error\":\"jimeng_generation_timeout_24h\",\"elapsed\":${elapsed}}"
                    mv "$task_file" "${SHARED_DIR}/tasks/failed/$(basename "$task_file")" 2>/dev/null
                fi
            fi
        fi
    done <<< "$tasks"
}

log_info "Worker started, entering main loop (POLL_INTERVAL=${POLL_INTERVAL}s)"

# 空闲日志节流：每 20 个轮询周期才打一次（约 10 分钟 @30s间隔）
IDLE_LOG_INTERVAL=20
idle_count=0

# harvest daemon 定期健康检查（每 10 轮 = ~5 分钟 @30s间隔）
HARVEST_CHECK_INTERVAL=10
harvest_check_count=0

# 主循环 (Main loop) — 方案 B: 从 VPS API 拉取任务
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do

    # 定期检查 harvesting 任务（下载即梦完成的视频）
    harvest_check_count=$((harvest_check_count + 1))
    if (( harvest_check_count >= HARVEST_CHECK_INTERVAL )); then
        harvest_check_count=0
        check_harvesting_tasks
    fi

    pending_task=""
    task_id=""

    # 优先检查本地 pending 目录（兼容旧方式手动放置）
    local_pending=$(ls -1 "$SHARED_DIR/tasks/pending/" 2>/dev/null | sort | head -1)
    if [[ -n "$local_pending" ]]; then
        pending_task="$local_pending"
        pending_path="${SHARED_DIR}/tasks/pending/${local_pending}"
        running_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${local_pending}"
        if mv "$pending_path" "$running_path" 2>/dev/null; then
            log_info "Claimed local task: ${local_pending}"
        else
            pending_task=""
        fi
    fi

    # 如果本地没有，从 VPS API 拉取
    if [[ -z "$pending_task" ]] && [[ -n "$REVIEW_SERVER_URL" ]] && [[ -n "$DISPATCHER_TOKEN" ]]; then
        poll_resp=$(curl -sf -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
            "${REVIEW_SERVER_URL}/api/v1/tasks/poll?worker_id=${WORKER_ID}" 2>/dev/null || echo '{}')
        task_id=$(echo "$poll_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('task'); print(t['id'] if t else '')" 2>/dev/null || echo "")

        if [[ -n "$task_id" ]]; then
            # 尝试认领
            claim_resp=$(curl -sf -X POST \
                -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"worker_id\":\"${WORKER_ID}\"}" \
                "${REVIEW_SERVER_URL}/api/v1/tasks/${task_id}/claim" 2>/dev/null || echo '{}')
            claimed=$(echo "$claim_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")

            if [[ "$claimed" == "True" ]]; then
                log_info "Claimed task from VPS: ${task_id}"
                # 写 JSON 到本地 running 目录
                task_json=$(echo "$claim_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); t['url']=t.get('video_url',''); print(json.dumps(t,indent=2))" 2>/dev/null || echo "{}")
                pending_task="${task_id}.json"
                running_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${pending_task}"
                echo "$task_json" > "$running_path"
            else
                task_id=""
            fi
        fi
    fi

    # 如果没有 pending 任务，检查是否有 Phase C ready 的任务
    if [[ -z "$pending_task" ]] && [[ -n "$REVIEW_SERVER_URL" ]] && [[ -n "$DISPATCHER_TOKEN" ]]; then
        phase_c_resp=$(curl -sf -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
            "${REVIEW_SERVER_URL}/api/v1/tasks/poll-phase-c?worker_id=${WORKER_ID}" 2>/dev/null || echo '{}')
        phase_c_id=$(echo "$phase_c_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('task'); print(t['id'] if t else '')" 2>/dev/null || echo "")

        if [[ -n "$phase_c_id" ]]; then
            # 检查是 phase_c_ready 还是 harvest_pending（stale recovery 释放的）
            claimed_progress=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(t.get('phase_progress',''))" 2>/dev/null || echo "")

            if [[ "$claimed_progress" == "packaging" ]]; then
                # ── Canvas 打包认领：运行 package_canvas_task.sh ──
                echo "[worker] Canvas packaging task: $phase_c_id"
                REVIEW_SERVER_URL="$REVIEW_SERVER_URL" DISPATCHER_TOKEN="$DISPATCHER_TOKEN" \
                MACKING_HOST="$MACKING_HOST" MACKING_USER="$MACKING_USER" \
                WORKER_ID="$WORKER_ID" \
                bash "${SCRIPTS_DIR}/package_canvas_task.sh" "$phase_c_id"
                pkg_rc=$?
                if [[ $pkg_rc -eq 0 ]]; then
                    echo "[worker] Canvas packaging complete for $phase_c_id"
                else
                    echo "[worker] Canvas packaging failed for $phase_c_id" >&2
                    curl -sf -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/${phase_c_id}/report" \
                        -H "Authorization: Bearer $DISPATCHER_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d '{"phase_progress":"packaging_failed"}' > /dev/null 2>&1 || true
                fi
                continue
            fi

            if [[ "$claimed_progress" == "harvesting" ]]; then
                # ── Harvest 认领：直接跑 harvest，不跑 Phase C ──
                log_info "Claimed HARVEST task from VPS: ${phase_c_id}"
                task_json=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(json.dumps(t,indent=2))" 2>/dev/null || echo "{}")
                pending_task="${phase_c_id}.json"
                local harvest_path="${SHARED_DIR}/tasks/harvesting/${pending_task}"
                local harvest_work="${SHARED_DIR}/tasks/harvesting/work_${phase_c_id}"
                mkdir -p "$harvest_work/phase_b" "$harvest_work/videos"
                echo "$task_json" > "$harvest_path"
                update_task_json "$harvest_path" "work_dir" "$harvest_work" || true
                # submit_state.json 需要从 jimeng_project_id 重建（里面存的是 submit_ids JSON）
                local project_id
                project_id=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(t.get('jimeng_project_id',''))" 2>/dev/null || echo "")
                if [[ -n "$project_id" ]] && [[ "$project_id" == "["* ]]; then
                    python3 -c "
import json, sys
ids = json.loads(sys.argv[1])
state = {'schema_version':2,'mode':'cli','submit_ids':ids,'batches':{}}
with open(sys.argv[2],'w') as f: json.dump(state,f,indent=2)
" "$project_id" "$harvest_work/phase_b/submit_state.json" 2>/dev/null
                    update_task_json "$harvest_path" "jimeng_submit_ids" "$project_id" || true
                fi
                log_info "Harvest task ready, will be checked in next harvest cycle"
                continue
            fi

            # Dispatch by track_kind — commentary tasks get their own Phase C pipeline
            pc_track_kind=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(t.get('track_kind') or 'video_gen')" 2>/dev/null || echo "video_gen")
            if [[ "$pc_track_kind" == "commentary" ]]; then
                log_info "Claimed Commentary Phase C task from VPS: ${phase_c_id}"
                tmp_task_file=$(mktemp -t "commentary-${phase_c_id}.XXXXXX.json")
                echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(json.dumps(t,indent=2))" > "$tmp_task_file" 2>/dev/null || echo '{}' > "$tmp_task_file"
                commentary_sh="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/commentary/worker_commentary.sh"
                if "$commentary_sh" "$tmp_task_file" phase_c; then
                    log_info "Commentary Phase C done for ${phase_c_id}"
                else
                    log_error "Commentary Phase C failed for ${phase_c_id}"
                    curl -sf -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
                        -H "Content-Type: application/json" \
                        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                        -d "{\"task_id\":\"${phase_c_id}\",\"event\":\"task_failed\",\"payload\":{\"error\":\"commentary_phase_c_failed\"}}" \
                        > /dev/null 2>&1 || true
                fi
                rm -f "$tmp_task_file"
                continue
            fi

            log_info "Claimed Phase C task from VPS: ${phase_c_id}"

            # 写 JSON 到本地 running 目录
            task_json=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); t['phase_progress']='phase_b_complete'; print(json.dumps(t,indent=2))" 2>/dev/null || echo "{}")
            pending_task="${phase_c_id}.json"
            running_path="${SHARED_DIR}/tasks/running/${WORKER_ID}/${pending_task}"
            echo "$task_json" > "$running_path"

            # 准备 work 目录
            work_dir="${SHARED_DIR}/tasks/running/${WORKER_ID}/work_${phase_c_id}"
            mkdir -p "$work_dir/phase_b" "$work_dir/参考图"
            update_task_json "$running_path" "work_dir" "$work_dir" || true

            # 从 Phase C poll response 直接提取 jimeng_prompts（无需额外 HTTP 请求）
            echo "$phase_c_resp" | python3 -c "
import sys, json
t = json.load(sys.stdin).get('task', {})
prompts = t.get('jimeng_prompts', '')
if prompts:
    with open(sys.argv[1], 'w', encoding='utf-8') as f:
        f.write(prompts)
    print(f'OK:{len(prompts)}')
else:
    print('EMPTY')
" "$work_dir/phase_b/即梦提示词.md" 2>&1 | while read line; do log_info "[Phase C] Prompts: $line"; done

            # Fallback: 如果 response 里没 prompts，从 server 下载
            if [[ ! -f "$work_dir/phase_b/即梦提示词.md" ]] || [[ ! -s "$work_dir/phase_b/即梦提示词.md" ]]; then
                log_warn "[Phase C] Prompts not in response, downloading from server..."
                download_prompts_from_server "$phase_c_id" "$work_dir"
            fi

            # 下载参考图（从 VPS G2 API 获取 ref_results，再逐个下载图片）
            log_info "[Phase C] Downloading reference images from VPS..."
            ip_group=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(t.get('ip_characters') or 'kpop')" 2>/dev/null || echo "kpop")
            # per-story 模式下用 track 名作 IP library 目录
            ip_dir_source="$ip_group"
            if [[ "$ip_group" == "per-story" ]]; then
                ip_dir_source=$(echo "$phase_c_resp" | python3 -c "import sys,json; t=json.load(sys.stdin).get('task',{}); print(t.get('track') or 'kpop-dance')" 2>/dev/null || echo "kpop-dance")
            fi
            ip_dir_upper=$(echo "$ip_dir_source" | tr '[:lower:]' '[:upper:]' | sed 's/-DANCE//')

            TASK_ID="$phase_c_id" REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
            REFS_DIR="$work_dir/参考图" IP_DIR="$ip_dir_upper" IP_GROUP="$ip_group" \
            python3 << 'PHASE_C_REFS_PYEOF'
import os, json, urllib.request, urllib.parse

task_id = os.environ["TASK_ID"]
url = os.environ["REVIEW_URL"].rstrip("/") + "/api/review/tasks/" + task_id + "/gate/g2"
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {os.environ['DTOK']}"})
try:
    data = json.loads(urllib.request.urlopen(req, timeout=30).read())
except Exception as e:
    print(f"[Phase C] Failed to fetch G2 data: {e}")
    exit(0)

refs = data.get("ref_results", {})
refs_dir = os.environ["REFS_DIR"]
base_url = os.environ["REVIEW_URL"].rstrip("/")
ip_dir = os.environ["IP_DIR"]
ip_group = os.environ.get("IP_GROUP", "")
is_per_story = ip_group == "per-story"
ok = 0

def dl(img_url, local_path):
    global ok
    if os.path.exists(local_path): ok += 1; return True
    try:
        urllib.request.urlretrieve(img_url, local_path)
        ok += 1; return True
    except Exception as e:
        print(f"  FAIL: {img_url} -> {e}")
        return False

def encode_url(url):
    """URL-encode 中文路径（保留协议和域名）"""
    from urllib.parse import urlparse, quote
    p = urlparse(url)
    encoded_path = quote(p.path, safe='/')
    return f"{p.scheme}://{p.netloc}{encoded_path}"

os.makedirs(refs_dir, exist_ok=True)

# Costume refs
# per-story: 保存在 data/refs/{taskId}/ → 下载走 /ref-images/{taskId}/{fn}
# 普通 IP: 保存在 ip-library/{TRACK}/{char}/ → 下载走 /ip-images/{IP_DIR}/{char}/{fn}
for c in refs.get("costume", []):
    fn = c.get("filename", "")
    char = c.get("character", "")
    if not fn or not char: continue
    local = os.path.join(refs_dir, fn)
    if is_per_story:
        img_url = encode_url(f"{base_url}/ref-images/{task_id}/{fn}")
    else:
        img_url = encode_url(f"{base_url}/ip-images/{ip_dir}/{char}/{fn}")
    dl(img_url, local) and print(f"  DL costume: {fn}")

# Scene refs
for s in refs.get("scene", []):
    fn = s.get("filename", "")
    st = s.get("sceneType", "户外")
    if not fn: continue
    local = os.path.join(refs_dir, fn)
    if is_per_story:
        img_url = encode_url(f"{base_url}/ref-images/{task_id}/{fn}")
    else:
        img_url = encode_url(f"{base_url}/ip-images/场景/{st}/{fn}")
    dl(img_url, local) and print(f"  DL scene: {fn}")

# Prop refs
for p in refs.get("props", []):
    fn = p.get("filename", "")
    if not fn: continue
    local = os.path.join(refs_dir, fn)
    if is_per_story:
        img_url = encode_url(f"{base_url}/ref-images/{task_id}/{fn}")
    else:
        img_url = encode_url(f"{base_url}/ip-images/道具/{fn}")
    dl(img_url, local) and print(f"  DL prop: {fn}")

print(f"[Phase C] Downloaded {ok} reference images" + (" (per-story)" if is_per_story else ""))
PHASE_C_REFS_PYEOF

            # 创建 symlink（jimeng_cuihua 从 phase_b/ 目录找参考图）
            # 1) 原始文件名 symlink
            for ref_file in "$work_dir/参考图"/*.{png,jpg,jpeg} ; do
                [[ -f "$ref_file" ]] || continue
                base_name=$(basename "$ref_file")
                ln -sf "$ref_file" "$work_dir/phase_b/${base_name}" 2>/dev/null || true
                if [[ "$base_name" == *.jpeg ]]; then
                    ln -sf "$ref_file" "$work_dir/phase_b/${base_name%.jpeg}.png" 2>/dev/null || true
                fi
            done
            # 2) 短名映射（per-story 模式: Marcus_脏旧...jpeg → Marcus.png）
            #    jimeng-config refs 用 "Marcus.png"，实际文件是 "Marcus_描述.jpeg"
            for ref_file in "$work_dir/参考图"/*.jpeg ; do
                [[ -f "$ref_file" ]] || continue
                base_name=$(basename "$ref_file" .jpeg)
                # 提取角色名（下划线前的部分）：Marcus_脏旧泛黄... → Marcus
                short_name="${base_name%%_*}"
                if [[ -n "$short_name" && "$short_name" != "$base_name" ]]; then
                    ln -sf "$ref_file" "$work_dir/phase_b/${short_name}.png" 2>/dev/null || true
                    ln -sf "$ref_file" "$work_dir/phase_b/${short_name}.jpeg" 2>/dev/null || true
                fi
            done

            # 执行 Phase C
            run_phase_c "$pending_task"
            if finalize_task "$pending_task"; then
                log_info "Phase C task finalized: ${pending_task}"
            fi
            continue
        fi
    fi

    if [[ -z "$pending_task" ]]; then
        ((idle_count++)) || true
        if [[ $((idle_count % IDLE_LOG_INTERVAL)) -eq 0 ]]; then
            log_info "No pending tasks (idle for ~$((idle_count * POLL_INTERVAL))s)"
        fi
        # 心跳上报
        if [[ -n "$REVIEW_SERVER_URL" ]]; then
            (curl -s -X POST "${REVIEW_SERVER_URL}/api/v1/worker/heartbeat" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
                -d "{\"worker_id\":\"${WORKER_ID}\",\"status\":\"idle\"}" \
                > /dev/null 2>&1) &
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    idle_count=0

    # 处理任务 (Process the task)
    if process_task "$pending_task"; then
        log_info "Task processing completed successfully: ${pending_task}"
    else
        log_warn "Task processing had issues: ${pending_task}"
    fi
done

log_info "Worker main loop exiting"
exit 0
