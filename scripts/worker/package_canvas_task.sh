#!/bin/bash
# package_canvas_task.sh — Download completed canvas videos and build an editing package
#
# 用法: bash package_canvas_task.sh <task_id>
#
# Required env vars:
#   REVIEW_SERVER_URL  — VPS review server base URL
#   DISPATCHER_TOKEN   — worker auth token
#   MACKING_HOST       — localhost (dev) or macking LAN IP (prod)
#   MACKING_USER       — macking SSH user (default: zjw-mini)
#
# Flow:
#   1. Fetch canvas generations from GET /api/canvas/:taskId/generations
#   2. Parse video URLs and metadata (batch_num, round, model, is_recommended)
#   3. Fetch task metadata from GET /api/v1/tasks/:taskId
#   4. Download all completed videos via curl
#   5. Generate production log (markdown)
#   6. Copy/rsync to macking
#   7. Report completion via POST /api/v1/tasks/:taskId/report
#   8. Cleanup temp dir

set -euo pipefail

TASK_ID="${1:?Usage: bash package_canvas_task.sh <task_id>}"

# ── 必需环境变量 ──
: "${REVIEW_SERVER_URL:?REVIEW_SERVER_URL not set}"
: "${DISPATCHER_TOKEN:?DISPATCHER_TOKEN not set}"
: "${MACKING_HOST:?MACKING_HOST not set}"
: "${MACKING_USER:=zjw-mini}"

REVIEW_URL="${REVIEW_SERVER_URL%/}"
DTOK="$DISPATCHER_TOKEN"
WORKER_ID="${WORKER_ID:-unknown-worker}"

# ── 临时工作目录 ──
TMP_DIR="/tmp/canvas_pkg_${TASK_ID}_$$"
META_FILE="$TMP_DIR/generations_meta.json"
mkdir -p "$TMP_DIR/videos"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[canvas-pkg] Starting packaging for task: $TASK_ID"

# ─────────────────────────────────────────────
# Step 1: Fetch canvas generations
# ─────────────────────────────────────────────
echo "[canvas-pkg][1/7] Fetching generations list..."
GENERATIONS_JSON=$(curl -sf \
    -H "Authorization: Bearer $DTOK" \
    "${REVIEW_URL}/api/canvas/${TASK_ID}/generations" 2>/dev/null || echo '{"generations":[]}')

GEN_COUNT=$(echo "$GENERATIONS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
completed = [g for g in d.get('generations', []) if g.get('gen_status') == 'completed' and g.get('video_url')]
print(len(completed))
" 2>/dev/null || echo "0")

echo "[canvas-pkg] Found $GEN_COUNT completed generation(s)"

if [[ "$GEN_COUNT" == "0" ]]; then
    echo "[canvas-pkg] WARNING: No completed generations to package" >&2
fi

# ─────────────────────────────────────────────
# Step 2: Fetch task metadata
# ─────────────────────────────────────────────
echo "[canvas-pkg][2/7] Fetching task metadata..."
TASK_JSON=$(curl -sf \
    -H "Authorization: Bearer $DTOK" \
    "${REVIEW_URL}/api/v1/tasks/${TASK_ID}" 2>/dev/null || echo '{}')

TRACK=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('track','unknown'))" 2>/dev/null || echo "unknown")
SYNOPSIS=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('synopsis',''))" 2>/dev/null || echo "")

echo "[canvas-pkg]   Track: $TRACK"
echo "[canvas-pkg]   Synopsis: ${SYNOPSIS:0:60}"

# ─────────────────────────────────────────────
# Step 3 & 4: Parse generations, write meta, and download videos
# ─────────────────────────────────────────────
echo "[canvas-pkg][3/7] Downloading videos..."

# Write generations JSON to file to avoid shell quoting issues
echo "$GENERATIONS_JSON" > "$TMP_DIR/generations_raw.json"

# Parse + download via Python (reads from file, writes meta)
TASK_ID="$TASK_ID" VIDEOS_DIR="$TMP_DIR/videos" \
META_OUT="$META_FILE" GENS_FILE="$TMP_DIR/generations_raw.json" \
python3 << 'PYEOF'
import sys, json, os, urllib.request, urllib.error

task_id    = os.environ["TASK_ID"]
videos_dir = os.environ["VIDEOS_DIR"]
meta_out   = os.environ["META_OUT"]
gens_file  = os.environ["GENS_FILE"]

with open(gens_file, encoding='utf-8') as f:
    d = json.load(f)

gens      = d.get('generations', [])
completed = [g for g in gens if g.get('gen_status') == 'completed' and g.get('video_url')]
failed    = [g for g in gens if g.get('gen_status') == 'failed']

meta = {'completed': completed, 'failed': failed, 'all': gens}
with open(meta_out, 'w', encoding='utf-8') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)

ok = 0
for g in completed:
    batch_num = g.get('batch_num', 1)
    round_num = g.get('round', 1)
    model     = g.get('model', 'unknown')
    is_rec    = g.get('is_recommended', 0)
    video_url = g.get('video_url', '')

    # Video naming: batch{N}_R{round}_{model}_RECOMMENDED.mp4
    suffix   = '_RECOMMENDED' if is_rec else ''
    filename = f"batch{batch_num}_R{round_num}_{model}{suffix}.mp4"
    local_path = os.path.join(videos_dir, filename)

    if os.path.exists(local_path):
        print(f"  SKIP (exists): {filename}", flush=True)
        ok += 1
        continue

    try:
        req = urllib.request.Request(
            video_url,
            headers={'User-Agent': 'Mozilla/5.0 canvas-packager/1.0'}
        )
        print(f"  DL: {filename}", flush=True)
        urllib.request.urlretrieve(video_url, local_path)
        ok += 1
    except Exception as e:
        print(f"  FAIL: {filename} — {e}", file=sys.stderr, flush=True)

print(f"Downloaded {ok}/{len(completed)} videos", flush=True)
PYEOF

DL_COUNT=$(ls "$TMP_DIR/videos"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
echo "[canvas-pkg] Downloaded: $DL_COUNT video(s)"

# ─────────────────────────────────────────────
# Step 5: Generate production log (markdown)
# ─────────────────────────────────────────────
echo "[canvas-pkg][4/7] Generating production log..."

TASK_ID="$TASK_ID" META_FILE="$META_FILE" LOG_OUT="$TMP_DIR/生产日志.md" \
python3 << 'PYEOF'
import sys, json, os

task_id  = os.environ["TASK_ID"]
meta_file = os.environ["META_FILE"]
log_path  = os.environ["LOG_OUT"]

with open(meta_file, encoding='utf-8') as f:
    meta = json.load(f)

all_gens = meta.get('all', [])

# Model credits map (approximate Dreamina pricing)
CREDITS = {'fast': 65, 'pro': 130}

# Group by batch_num
batches = {}
for g in all_gens:
    bn = g.get('batch_num', 1)
    if bn not in batches:
        batches[bn] = []
    batches[bn].append(g)

lines = [f"# 生产日志 — {task_id}", ""]
total_videos  = 0
total_credits = 0

for bn in sorted(batches.keys()):
    lines.append(f"## 批次 {bn}")
    for g in sorted(batches[bn], key=lambda x: (x.get('round', 1), x.get('model', ''))):
        status    = g.get('gen_status', 'unknown')
        model     = g.get('model', '?')
        round_num = g.get('round', 1)
        is_rec    = g.get('is_recommended', 0)
        credits   = g.get('credits_charged', 0) or CREDITS.get(model, 0)
        annotation  = g.get('annotation', '') or ''
        fail_reason = g.get('fail_reason', '') or ''

        if status == 'completed':
            status_icon = '✅'
            total_videos  += 1
            total_credits += credits
        elif status == 'failed':
            status_icon = '❌'
        else:
            status_icon = '⏳'

        rec_tag    = ' ⭐推荐' if is_rec else ''
        credit_str = f' | {credits}积分' if credits else ''
        note_str   = f' | 备注: {annotation}' if annotation else ''
        fail_str   = f' | 失败原因: {fail_reason}' if fail_reason else ''

        lines.append(f"- R{round_num} {model} {status_icon}{rec_tag}{credit_str}{note_str}{fail_str}")
    lines.append("")

lines.append(f"## 总计: {total_videos} 个视频 / {total_credits} 积分")

with open(log_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print(f"Production log: {total_videos} videos, {total_credits} credits", flush=True)
PYEOF

# ─────────────────────────────────────────────
# Step 6: Copy/rsync to macking
# ─────────────────────────────────────────────
echo "[canvas-pkg][5/7] Delivering to macking..."

DEST_DIR="$HOME/production/canvas_deliveries/${TASK_ID}"

is_local_macking() {
    [[ "$MACKING_HOST" == "localhost" || "$MACKING_HOST" == "127.0.0.1" ]]
}

if is_local_macking; then
    # Local copy (dev mode: this machine IS macking)
    mkdir -p "$DEST_DIR/videos"
    if ls "$TMP_DIR/videos/"*.mp4 > /dev/null 2>&1; then
        cp "$TMP_DIR/videos/"*.mp4 "$DEST_DIR/videos/"
    fi
    if [[ -f "$TMP_DIR/生产日志.md" ]]; then
        cp "$TMP_DIR/生产日志.md" "$DEST_DIR/"
    fi
    echo "[canvas-pkg] Copied to local macking: $DEST_DIR"
else
    # Remote rsync over SSH
    ssh "${MACKING_USER}@${MACKING_HOST}" "mkdir -p '${DEST_DIR}/videos'" 2>/dev/null || true
    if ls "$TMP_DIR/videos/"*.mp4 > /dev/null 2>&1; then
        rsync -avz --progress \
            "$TMP_DIR/videos/" \
            "${MACKING_USER}@${MACKING_HOST}:${DEST_DIR}/videos/" 2>&1 | \
            while IFS= read -r line; do echo "[canvas-pkg]   rsync: $line"; done
    fi
    if [[ -f "$TMP_DIR/生产日志.md" ]]; then
        rsync -avz \
            "$TMP_DIR/生产日志.md" \
            "${MACKING_USER}@${MACKING_HOST}:${DEST_DIR}/" 2>&1 | \
            while IFS= read -r line; do echo "[canvas-pkg]   rsync: $line"; done
    fi
    echo "[canvas-pkg] Synced to macking (${MACKING_HOST}): ${DEST_DIR}"
fi

# ─────────────────────────────────────────────
# Step 7: Report completion to VPS
# ─────────────────────────────────────────────
echo "[canvas-pkg][6/7] Reporting completion..."

TOTAL_VIDEOS=$(ls "$TMP_DIR/videos/"*.mp4 2>/dev/null | wc -l | tr -d ' ')

REPORT_PAYLOAD=$(python3 -c "
import json, os
print(json.dumps({
    'phase_progress': 'packaging_complete',
    'delivery_path':  os.path.expanduser('${DEST_DIR}'),
    'video_count':    ${TOTAL_VIDEOS},
    'worker_id':      '${WORKER_ID}'
}))
" 2>/dev/null || echo '{"phase_progress":"packaging_complete"}')

for attempt in 1 2 3; do
    if curl -sf -X POST "${REVIEW_URL}/api/v1/tasks/${TASK_ID}/report" \
        -H "Authorization: Bearer $DTOK" \
        -H "Content-Type: application/json" \
        -d "$REPORT_PAYLOAD" \
        --connect-timeout 10 --max-time 30 > /dev/null 2>&1; then
        echo "[canvas-pkg] Reported packaging_complete to VPS (attempt $attempt)"
        break
    else
        if [[ $attempt -lt 3 ]]; then
            echo "[canvas-pkg] Report attempt $attempt failed, retrying in $((attempt * 5))s..." >&2
            sleep $((attempt * 5))
        else
            echo "[canvas-pkg] ERROR: Failed to report completion after 3 attempts" >&2
            exit 1
        fi
    fi
done

# ─────────────────────────────────────────────
# Step 8: Cleanup (via trap EXIT)
# ─────────────────────────────────────────────
echo "[canvas-pkg][7/7] Done. Delivery: $DEST_DIR ($TOTAL_VIDEOS videos)"
