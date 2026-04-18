#!/bin/bash
# Mix narration with original audio (ducked -18dB) + rsync package to macking.

set -euo pipefail

# .production.env 里 REVIEW_SERVER_URL/DISPATCHER_TOKEN/MACKING_* 都不带 export，
# 所以从 phase_c.sh `bash 子进程`调进来时拿不到——必须自己 source 一遍。
[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

TASK_ID="$1"
WORK_DIR="$2"

ffmpeg -y -i "$WORK_DIR/original.mp4" -vn -acodec libmp3lame -q:a 4 "$WORK_DIR/original_audio.mp3"

ffmpeg -y \
  -i "$WORK_DIR/original_audio.mp3" \
  -i "$WORK_DIR/narration.mp3" \
  -filter_complex "[0:a]volume=-18dB[orig];[1:a]volume=0dB[narr];[orig][narr]amix=inputs=2:duration=longest:normalize=0[out]" \
  -map "[out]" -acodec libmp3lame -q:a 4 \
  "$WORK_DIR/mixed_audio.mp3"

DELIVERY_DIR="$WORK_DIR/delivery"
mkdir -p "$DELIVERY_DIR"
cp "$WORK_DIR/original.mp4"    "$DELIVERY_DIR/original.mp4"
cp "$WORK_DIR/narration.mp3"   "$DELIVERY_DIR/narration.mp3"
cp "$WORK_DIR/mixed_audio.mp3" "$DELIVERY_DIR/mixed_audio.mp3"
cp "$WORK_DIR/script.json"     "$DELIVERY_DIR/script.json"
cp "$WORK_DIR/scenes.json"     "$DELIVERY_DIR/scenes.json"   2>/dev/null || true
cp "$WORK_DIR/subtitles.srt"   "$DELIVERY_DIR/subtitles.srt" 2>/dev/null || true

MACKING_HOST="${MACKING_HOST:-localhost}"
MACKING_USER="${MACKING_USER:-$USER}"
REMOTE_DIR="~/production/deliveries/$TASK_ID/commentary/"

if [[ "$MACKING_HOST" == "localhost" ]]; then
  LOCAL_DEST="$HOME/production/deliveries/$TASK_ID/commentary/"
  mkdir -p "$LOCAL_DEST"
  cp -r "$DELIVERY_DIR/." "$LOCAL_DEST/"
else
  for attempt in 1 2 3 4 5; do
    if rsync -av --mkpath "$DELIVERY_DIR/" "${MACKING_USER}@${MACKING_HOST}:${REMOTE_DIR}"; then
      echo "[package] macking rsync OK"
      break
    fi
    echo "[package] macking rsync attempt $attempt failed"
    sleep $((attempt * 5))
  done
fi

# Also upload to VPS so review-server can serve files via /api/commentary/deliveries.
# Workers can NOT scp to VPS (no SSH from worker to VPS in the GFW topology), but
# they DO have HTTP access via REVIEW_SERVER_URL (autossh -L 13000:localhost:3000).
# Push each file via multipart POST to the dedicated upload endpoint.
echo "[package] uploading to VPS via HTTP..."
upload_ok=0
upload_fail=0
for f in "$DELIVERY_DIR"/*; do
  fname=$(basename "$f")
  if curl -sf -X POST "${REVIEW_SERVER_URL}/api/commentary/deliveries/${TASK_ID}/upload" \
      -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
      -F "name=${fname}" \
      -F "file=@${f}" \
      --max-time 120 > /dev/null 2>&1; then
    upload_ok=$((upload_ok + 1))
  else
    upload_fail=$((upload_fail + 1))
    echo "[package]   ✗ upload $fname failed" >&2
  fi
done
echo "[package] VPS upload: $upload_ok ok / $upload_fail failed"

echo "[package] delivered"
