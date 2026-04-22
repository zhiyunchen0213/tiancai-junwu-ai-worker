#!/bin/bash
# Package commentary narration + metadata for delivery (NO server-side mixing).

set -euo pipefail
[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

TASK_ID="$1"
WORK_DIR="$2"

# Determine pov mode + protagonist from task.json / script.json
POV_MODE=$(python3 -c "
import json, sys
try:
    t = json.load(open('$WORK_DIR/task.json'))
    print(t.get('video_metadata',{}).get('commentary_params',{}).get('pov_mode','third_person'))
except: print('third_person')
")
PROTAGONIST_NAME=""
if [[ "$POV_MODE" == "first_person" ]]; then
  PROTAGONIST_NAME=$(python3 -c "
import json, re, sys
try:
    s = json.load(open('$WORK_DIR/script.json'))
    n = (s.get('protagonist') or {}).get('name','')
    n = re.sub(r'\s+','_', n or '')
    n = re.sub(r'[^A-Za-z0-9_]','_', n)[:40] or 'protagonist'
    print(n)
except: print('protagonist')
")
fi

DELIVERY_DIR="$WORK_DIR/delivery"
mkdir -p "$DELIVERY_DIR"

# File naming: third_person uses canonical names; first_person adds -<name>-pov suffix
if [[ "$POV_MODE" == "first_person" ]]; then
  NARR_MP3="narration-${PROTAGONIST_NAME}-pov.mp3"
  TRANS_TXT="transcript-${PROTAGONIST_NAME}-pov.txt"
  SUBS_SRT="subtitles-${PROTAGONIST_NAME}-pov.srt"
else
  NARR_MP3="narration.mp3"
  TRANS_TXT="transcript.txt"
  SUBS_SRT="subtitles.srt"
fi

cp "$WORK_DIR/original.mp4"    "$DELIVERY_DIR/original.mp4"
cp "$WORK_DIR/narration.mp3"   "$DELIVERY_DIR/${NARR_MP3}"
cp "$WORK_DIR/script.json"     "$DELIVERY_DIR/script.json"
[[ -f "$WORK_DIR/transcript.txt"  ]] && cp "$WORK_DIR/transcript.txt"  "$DELIVERY_DIR/${TRANS_TXT}"
[[ -f "$WORK_DIR/subtitles.srt"   ]] && cp "$WORK_DIR/subtitles.srt"   "$DELIVERY_DIR/${SUBS_SRT}"
[[ -f "$WORK_DIR/scenes.json"     ]] && cp "$WORK_DIR/scenes.json"     "$DELIVERY_DIR/scenes.json"

# first_person: extra protagonist_card.json
if [[ "$POV_MODE" == "first_person" ]]; then
  python3 -c "
import json
s = json.load(open('$WORK_DIR/script.json'))
t = json.load(open('$WORK_DIR/task.json'))
p = s.get('protagonist') or {}
card = {
  'pov_mode': 'first_person',
  'task_id': t.get('task_id') or t.get('id'),
  'protagonist': {
    'name': p.get('name'),
    'voice_id': p.get('voice_id'),
    'gender': (t.get('pov_details') or {}).get('protagonist_gender'),
    'age_band': (t.get('pov_details') or {}).get('protagonist_age_band'),
    'appearance': (t.get('pov_details') or {}).get('protagonist_appearance'),
    'role_tagline': (t.get('pov_details') or {}).get('protagonist_role_tagline'),
    'emotion_arc': (t.get('pov_details') or {}).get('protagonist_emotion_arc'),
  },
}
open('$DELIVERY_DIR/protagonist_card.json','w').write(json.dumps(card, ensure_ascii=False, indent=2))
"
fi

# rsync to macking
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
      echo "[package] macking rsync OK"; break
    fi
    echo "[package] macking rsync attempt $attempt failed"; sleep $((attempt * 5))
  done
fi

# HTTP upload to VPS
echo "[package] uploading to VPS via HTTP..."
for f in "$DELIVERY_DIR"/*; do
  fname=$(basename "$f")
  curl -sf -X POST "${REVIEW_SERVER_URL}/api/commentary/deliveries/${TASK_ID}/upload" \
      -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
      -F "name=${fname}" -F "file=@${f}" --max-time 120 > /dev/null \
    && echo "[package]   ✓ $fname" \
    || echo "[package]   ✗ $fname failed" >&2
done

echo "[package] delivered (pov_mode=${POV_MODE})"
