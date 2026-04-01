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

log "Checking $TOTAL submit_ids..."

# --- Query each submit_id ---
ALL_RESULTS=""
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

print(json.dumps({
    'submit_id': '$submit_id',
    'status': status,
    'fail_reason': fail_reason,
    'video_url': video_url,
    'video_file': video_file
}))
" 2>/dev/null || echo '{"submit_id":"'"$submit_id"'","status":"unknown"}')

    ALL_RESULTS="${ALL_RESULTS}${result}\n"

    status=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))")

    case "$status" in
        success)    COMPLETED=$((COMPLETED + 1)) ;;
        fail)       FAILED=$((FAILED + 1)) ;;
        querying)   QUEUING=$((QUEUING + 1)) ;;
        generating|running) GENERATING=$((GENERATING + 1)) ;;
        *)          QUEUING=$((QUEUING + 1)) ;;  # unknown → treat as still pending
    esac

    log "  $submit_id: $status"
done <<< "$SUBMIT_IDS"

# --- Determine overall status ---
if [[ $COMPLETED -eq $TOTAL ]]; then
    OVERALL="complete"
elif [[ $FAILED -eq $TOTAL ]]; then
    OVERALL="failed"
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

# --- Update submit_state.json with harvest results ---
python3 - "$SUBMIT_STATE" "$OVERALL" "$COMPLETED" "$FAILED" << 'PYEOF'
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
    "last_checked_at": datetime.now(timezone.utc).isoformat()
}
state["updated_at"] = datetime.now(timezone.utc).isoformat()

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF

# --- Output JSON summary (always, for --check-only consumption) ---
python3 - "$OVERALL" "$TOTAL" "$COMPLETED" "$GENERATING" "$QUEUING" "$FAILED" "$VIDEOS_JSON" << 'PYEOF'
import sys, json

overall = sys.argv[1]
total = int(sys.argv[2])
completed = int(sys.argv[3])
generating = int(sys.argv[4])
queuing = int(sys.argv[5])
failed = int(sys.argv[6])
videos = json.loads(sys.argv[7])

summary = {
    "overall": overall,
    "total": total,
    "completed": completed,
    "generating": generating,
    "queuing": queuing,
    "failed": failed,
    "videos": videos
}

print(json.dumps(summary, ensure_ascii=False))
PYEOF

log "Status: $OVERALL ($COMPLETED/$TOTAL complete, $FAILED failed)"
exit 0
