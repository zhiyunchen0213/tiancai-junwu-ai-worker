#!/bin/bash
# Mix narration with original audio (ducked -18dB) + rsync package to macking.

set -euo pipefail

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
# Worker → VPS goes through the SSH tunnel (REVIEW_SERVER_URL = localhost:13000 on worker,
# but scp goes through the reverse tunnel ssh port). Use REVIEW_SERVER_SSH or "brain".
VPS_SSH="${REVIEW_SERVER_SSH:-brain}"
VPS_DELIVERY_DIR="~/production/deliveries/$TASK_ID/commentary/"
echo "[package] uploading to VPS ($VPS_SSH)..."
if ssh "$VPS_SSH" "mkdir -p $VPS_DELIVERY_DIR" 2>/dev/null && \
   scp -q "$DELIVERY_DIR"/* "${VPS_SSH}:${VPS_DELIVERY_DIR}" 2>/dev/null; then
  echo "[package] VPS upload OK"
else
  echo "[package] VPS upload failed (non-fatal, files stay on worker)" >&2
fi

echo "[package] delivered"
