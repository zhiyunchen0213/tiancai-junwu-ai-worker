#!/bin/bash
#
# jimeng_harvest_cli.sh — Query jimeng task status and download videos via dreamina CLI
# Replaces jimeng_monitor.mjs (Playwright CDP) with official CLI tool
#
# Usage:
#   bash jimeng_harvest_cli.sh --submit-state <path> --video-dir <path> [--check-only]
#
# Input:  submit_state.json with submit_ids array (schema_version 2)
# Output: JSON status summary to stdout (when --check-only)
#         Downloaded videos in --video-dir
#

set -euo pipefail

DREAMINA="${DREAMINA_BIN:-dreamina}"
LOG_TAG="[harvest-cli]"

# --- Argument parsing ---
SUBMIT_STATE=""
VIDEO_DIR=""
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --submit-state) SUBMIT_STATE="$2"; shift 2 ;;
        --video-dir)    VIDEO_DIR="$2"; shift 2 ;;
        --check-only)   CHECK_ONLY=true; shift ;;
        *) echo "$LOG_TAG Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SUBMIT_STATE" ]] || [[ ! -f "$SUBMIT_STATE" ]]; then
    echo "$LOG_TAG ERROR: --submit-state required and must exist" >&2
    exit 1
fi

if [[ -z "$VIDEO_DIR" ]]; then
    VIDEO_DIR="$(dirname "$SUBMIT_STATE")/videos"
fi
mkdir -p "$VIDEO_DIR"

log() { echo "$(date '+%H:%M:%S') $LOG_TAG $*" >&2; }

# --- Check dreamina available ---
if ! command -v "$DREAMINA" &>/dev/null; then
    log "ERROR: dreamina CLI not found"
    exit 1
fi

# --- Read submit_ids ---
SUBMIT_IDS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
ids = state.get('submit_ids', [])
for sid in ids:
    if sid: print(sid)
" "$SUBMIT_STATE" 2>/dev/null)

if [[ -z "$SUBMIT_IDS" ]]; then
    log "ERROR: No submit_ids found in $SUBMIT_STATE"
    echo '{"overall":"unknown","total":0,"completed":0,"generating":0,"queuing":0,"failed":0,"videos":[]}'
    exit 1
fi

TOTAL=$(echo "$SUBMIT_IDS" | wc -l | tr -d ' ')
COMPLETED=0
GENERATING=0
QUEUING=0
FAILED=0
VIDEOS_JSON="[]"
MAX_QUEUE_IDX=0
MAX_QUEUE_LEN=0
FAIL_REASONS=""
CREDITS_CHARGED=0
CREDITS_REFUNDED=0

log "Checking $TOTAL submit_ids..."

# --- Load cached status from submit_state.json (防止终态回退) ---
# 从 batches 里提取每个 submit_id 的上次缓存状态
CACHED_STATUS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
cache = {}
for bk, models in state.get('batches', {}).items():
    for mk, info in models.items():
        sid = info.get('submit_id', '')
        st = info.get('cached_gen_status', '')
        if sid and st:
            cache[sid] = st
print(json.dumps(cache))
" "$SUBMIT_STATE" 2>/dev/null || echo '{}')

# --- Query each submit_id ---
ALL_RESULTS=""
STATUS_UPDATES=""  # collect sid:status pairs to write back
while IFS= read -r submit_id; do
    [[ -z "$submit_id" ]] && continue

    output=$("$DREAMINA" query_result --submit_id="$submit_id" --download_dir="$VIDEO_DIR" 2>&1) || true

    # Parse result (dreamina outputs multi-line JSON)
    result=$(echo "$output" | python3 -c "
import sys, json

text = sys.stdin.read()
status = 'unknown'
fail_reason = ''
video_url = ''
video_file = ''

# Try parsing entire output as JSON first
d = None
try:
    d = json.loads(text)
except (json.JSONDecodeError, ValueError):
    # Fallback: try line by line
    for line in text.split('\n'):
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
            break
        except (json.JSONDecodeError, ValueError):
            continue

if d:
    gs = d.get('gen_status', '')
    if gs == 'success':
        status = 'success'
        # dreamina query_result 返回 result_json.videos[] 或 results[]
        rj = d.get('result_json', {})
        vids = rj.get('videos', []) if isinstance(rj, dict) else []
        if not vids:
            vids = d.get('results', d.get('result', []))
            if isinstance(vids, dict): vids = [vids]
        for r in (vids if isinstance(vids, list) else []):
            if isinstance(r, dict):
                video_url = r.get('video_url', r.get('url', ''))
                video_file = r.get('filename', r.get('path', '').split('/')[-1] if r.get('path') else '')
    elif gs == 'fail':
        status = 'fail'
        fail_reason = d.get('fail_reason', 'unknown')
    elif gs == 'querying':
        status = 'querying'
    elif gs:
        status = gs

qi = d.get('queue_info', {}) if d else {}
ci = d.get('commerce_info', {}) if d else {}
credit_count = ci.get('credit_count', 0)
trips = ci.get('triplets', [])
model = trips[0].get('benefit_type', '').replace('dreamina_', '') if trips else ''
print(json.dumps({
    'submit_id': '$submit_id',
    'status': status,
    'fail_reason': fail_reason,
    'video_url': video_url,
    'video_file': video_file,
    'queue_idx': qi.get('queue_idx', 0),
    'queue_length': qi.get('queue_length', 0),
    'credit_count': credit_count,
    'model': model,
}))
" 2>/dev/null || echo '{"submit_id":"'"$submit_id"'","status":"unknown"}')

    ALL_RESULTS="${ALL_RESULTS}${result}\n"

    status=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))")

    # --- 终态保护：已完成/已失败的 submit_id 不允许回退 ---
    cached=$(echo "$CACHED_STATUS" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('$submit_id',''))" 2>/dev/null)
    if [[ "$cached" == "success" && "$status" != "success" ]]; then
        log "  $submit_id: API returned '$status' but cached='success' → keeping success (防止回退)"
        status="success"
    elif [[ "$cached" == "fail" && "$status" != "fail" && "$status" != "success" ]]; then
        log "  $submit_id: API returned '$status' but cached='fail' → keeping fail (防止回退)"
        status="fail"
    fi
    # 记录本次状态，稍后写回 submit_state.json
    STATUS_UPDATES="${STATUS_UPDATES}${submit_id}:${status}\n"

    case "$status" in
        success)    COMPLETED=$((COMPLETED + 1)) ;;
        fail)       FAILED=$((FAILED + 1)) ;;
        querying)   QUEUING=$((QUEUING + 1)) ;;
        generating|running) GENERATING=$((GENERATING + 1)) ;;
        *)          QUEUING=$((QUEUING + 1)) ;;  # unknown → treat as still pending
    esac

    # Track max queue position
    qi=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('queue_idx',0))" 2>/dev/null || echo 0)
    ql=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('queue_length',0))" 2>/dev/null || echo 0)
    [[ "$qi" -gt "${MAX_QUEUE_IDX:-0}" ]] 2>/dev/null && MAX_QUEUE_IDX=$qi
    [[ "$ql" -gt "${MAX_QUEUE_LEN:-0}" ]] 2>/dev/null && MAX_QUEUE_LEN=$ql

    # Track fail reasons
    fr=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fail_reason',''))" 2>/dev/null)
    [[ -n "$fr" ]] && FAIL_REASONS="${FAIL_REASONS}${fr}\n"

    # Track credits
    cc=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('credit_count',0))" 2>/dev/null || echo 0)
    if [[ "$status" == "success" ]]; then
        CREDITS_CHARGED=$((CREDITS_CHARGED + cc))
    elif [[ "$status" == "fail" ]]; then
        CREDITS_REFUNDED=$((CREDITS_REFUNDED + cc))
    fi

    log "  $submit_id: $status (${cc}分)"
done <<< "$SUBMIT_IDS"

# --- Determine overall status ---
if [[ $COMPLETED -eq $TOTAL ]]; then
    OVERALL="complete"
elif [[ $FAILED -eq $TOTAL ]]; then
    OVERALL="failed"
elif [[ $((COMPLETED + FAILED)) -eq $TOTAL ]]; then
    # 所有任务都有最终状态（部分成功部分失败），视为完成
    OVERALL="complete"
elif [[ $COMPLETED -gt 0 ]] && [[ $((GENERATING + QUEUING)) -gt 0 ]]; then
    # 有完成的也有未完成的——检查是否超时（提交超过 2 小时仍有 querying/generating 视为降级完成）
    # 读 submit_state.json 里 batches 最早的 submitted_at（字段内容，不是文件 mtime — mtime 每次轮询都会被更新）
    SUBMIT_AGE_MIN=0
    if [[ -f "$SUBMIT_STATE" ]]; then
        SUBMIT_AGE_MIN=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    with open('$SUBMIT_STATE') as f: d = json.load(f)
    ts = []
    for b in d.get('batches', {}).values():
        for m in b.values() if isinstance(b, dict) else []:
            if isinstance(m, dict) and 'submitted_at' in m:
                ts.append(m['submitted_at'])
    if not ts: print(0); sys.exit(0)
    earliest = min(ts)
    dt = datetime.fromisoformat(earliest.replace('Z','+00:00'))
    now = datetime.now(timezone.utc)
    print(int((now - dt).total_seconds() / 60))
except Exception as e: print(0, file=sys.stderr); print(0)
" 2>/dev/null || echo 0)
    fi
    if [[ $SUBMIT_AGE_MIN -ge 120 ]] && [[ $COMPLETED -ge $((TOTAL / 2)) ]]; then
        log "Downgrade: ${SUBMIT_AGE_MIN}min since first submit, $COMPLETED/$TOTAL complete — treating as complete (remaining stuck)"
        OVERALL="complete"
    else
        OVERALL="generating"
    fi
elif [[ $((GENERATING + QUEUING)) -gt 0 ]]; then
    OVERALL="generating"
else
    OVERALL="unknown"
fi

# --- Collect downloaded video files ---
VIDEOS_JSON=$(python3 - "$VIDEO_DIR" "$SUBMIT_STATE" << 'PYEOF'
import os, json, glob

video_dir = os.sys.argv[1]
state_path = os.sys.argv[2]

# Find all downloaded video files
videos = []
for ext in ['*.mp4', '*.webm', '*.mov']:
    for f in sorted(glob.glob(os.path.join(video_dir, ext))):
        sz = os.path.getsize(f)
        if sz > 10000:  # skip corrupt/empty files
            videos.append({
                "filename": os.path.basename(f),
                "size": sz,
                "path": f
            })

# Try to map videos to batches using submit_state
try:
    with open(state_path) as f:
        state = json.load(f)
    for batch_key, models in state.get("batches", {}).items():
        batch_num = int(batch_key.replace("batch", ""))
        for model, info in models.items():
            for v in videos:
                sid = info.get("submit_id", "")
                if sid and sid in v["filename"]:
                    v["batch_num"] = batch_num
                    v["model"] = model
except:
    pass

# Assign batch_num by order if not mapped
for i, v in enumerate(videos):
    if "batch_num" not in v:
        v["batch_num"] = (i // 2) + 1
    if "model" not in v:
        v["model"] = "seedance2.0" if i % 2 == 0 else "seedance2.0fast"

print(json.dumps(videos))
PYEOF
)

# --- Update submit_state.json with harvest results + cached_gen_status ---
echo -e "$STATUS_UPDATES" | python3 - "$SUBMIT_STATE" "$OVERALL" "$COMPLETED" "$FAILED" "$CREDITS_CHARGED" "$CREDITS_REFUNDED" << 'PYEOF'
import sys, json
from datetime import datetime, timezone

state_path = sys.argv[1]
overall = sys.argv[2]
completed = int(sys.argv[3])
failed = int(sys.argv[4])

with open(state_path, 'r') as f:
    state = json.load(f)

state["harvest"] = {
    "overall": overall,
    "completed_count": completed,
    "failed_count": failed,
    "last_checked_at": datetime.now(timezone.utc).isoformat(),
    "credits_charged": int(sys.argv[5]) if len(sys.argv) > 5 else 0,
    "credits_refunded": int(sys.argv[6]) if len(sys.argv) > 6 else 0,
}
state["updated_at"] = datetime.now(timezone.utc).isoformat()

# Write cached_gen_status per submit_id into batches (终态保护)
status_lines = sys.stdin.read().strip().split('\n')
status_map = {}
for line in status_lines:
    if ':' in line:
        sid, st = line.split(':', 1)
        status_map[sid.strip()] = st.strip()

for bk, models in state.get('batches', {}).items():
    for mk, info in models.items():
        sid = info.get('submit_id', '')
        if sid in status_map:
            info['cached_gen_status'] = status_map[sid]

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF

# --- Output JSON summary ---
python3 -c "
import json
summary = {
    'overall': '$OVERALL',
    'total': $TOTAL,
    'completed': $COMPLETED,
    'generating': $GENERATING,
    'queuing': $QUEUING,
    'failed': $FAILED,
    'credits_charged': $CREDITS_CHARGED,
    'credits_refunded': $CREDITS_REFUNDED,
    'videos': json.loads('$VIDEOS_JSON'),
}
if $MAX_QUEUE_IDX > 0:
    summary['queue_info'] = {'queue_idx': $MAX_QUEUE_IDX, 'queue_length': $MAX_QUEUE_LEN}
fail_reasons = '''$FAIL_REASONS'''.strip()
if fail_reasons:
    summary['fail_reasons'] = [r for r in fail_reasons.split('\n') if r.strip()]
print(json.dumps(summary, ensure_ascii=False))
"

log "Status: $OVERALL ($COMPLETED/$TOTAL complete, $FAILED failed)"
exit 0
