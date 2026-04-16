#!/bin/bash
# Usage: phase_c.sh <task_id> <work_dir>
# Assumes: work_dir has original.mp4 + script.json (pulled from VPS after G1 approval)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

# ── TTS provider token ────────────────────────────────────────────────────
source "$SCRIPT_DIR/fetch_provider.sh" tts
export KIE_API_URL="${PROVIDER_ENDPOINT:-${KIE_API_URL:-https://api.kie.ai}}"
# KIE_API_KEY is primary; fall back to ELEVENLABS_API_KEY if only that is set
export KIE_API_KEY="${PROVIDER_TOKEN:-${KIE_API_KEY:-${ELEVENLABS_API_KEY:-}}}"
# Admin-configurable model override (2026-04-16). Currently only one TTS model
# exists (elevenlabs/text-to-dialogue-v3), so this is forward-looking. The TTS
# node script reads TTS_MODEL env if set.
if [[ -n "${PROVIDER_MODEL:-}" ]]; then
  export TTS_MODEL="$PROVIDER_MODEL"
fi
unset PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL

TASK_ID="$1"
WORK_DIR="$2"

echo "[phase_c] task=$TASK_ID"

# Export per-task COMMENTARY_* overrides from video_metadata.commentary_params
# (worker_commentary.sh phase_c writes task.json from the VPS fetch response)
if [[ -f "$WORK_DIR/task.json" ]]; then
  _TASK_JSON_FILE="$WORK_DIR/task.json" source "$SCRIPT_DIR/lib/export_params.sh"
fi

node "$SCRIPT_DIR/tts_narration.mjs" "$WORK_DIR"

# ── SRT subtitles from narration.mp3 ──────────────────────────────────────
# Generate a pure English SRT timed to narration playback so the reviewer can
# drop {original.mp4 + narration.mp3 + subtitles.srt} into 剪映 / CapCut / FCP
# without any extra work. Whisper writes <basename>.srt next to the output_dir;
# we rename it to subtitles.srt for a stable delivery filename.
# Resolve whisper binary: env override → PATH → common pip install paths
WHISPER_BIN="${WHISPER_BIN:-$(command -v whisper 2>/dev/null || true)}"
if [[ -z "$WHISPER_BIN" ]]; then
  for _wb in /opt/homebrew/bin/whisper ~/Library/Python/*/bin/whisper ~/.local/bin/whisper /usr/local/bin/whisper; do
    [[ -x "$_wb" ]] && WHISPER_BIN="$_wb" && break
  done
fi
if [[ -n "$WHISPER_BIN" && -x "$WHISPER_BIN" ]] && [[ -f "$WORK_DIR/narration.mp3" ]]; then
  echo "[srt] transcribing narration.mp3 for SRT subtitles"
  "$WHISPER_BIN" "$WORK_DIR/narration.mp3" \
    --model base.en \
    --language en \
    --output_format srt \
    --output_dir "$WORK_DIR" \
    --verbose False \
    2>&1 | tail -20 || {
      echo "[srt] whisper failed, continuing without SRT" >&2
    }
  if [[ -f "$WORK_DIR/narration.srt" ]]; then
    mv "$WORK_DIR/narration.srt" "$WORK_DIR/subtitles.srt"
    echo "[srt] subtitles.srt created ($(wc -l < "$WORK_DIR/subtitles.srt") lines)"
  else
    echo "[srt] whisper produced no narration.srt (continuing)" >&2
  fi
else
  echo "[srt] whisper binary not found at $WHISPER_BIN, skipping SRT" >&2
fi

bash "$SCRIPT_DIR/package_delivery.sh" "$TASK_ID" "$WORK_DIR"

NARRATION_SEC=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$WORK_DIR/narration.mp3" 2>/dev/null || echo "0")

DELIVERY_PATH="${MACKING_USER:-zjw-mini}@${MACKING_HOST:-localhost}:~/production/deliveries/${TASK_ID}/commentary/"
PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'task_id': '$TASK_ID',
  'event': 'commentary_phase_c_complete',
  'payload': {
    'delivery_path': '$DELIVERY_PATH',
    'narration_duration_sec': float('$NARRATION_SEC' or 0),
  },
}))
")

for attempt in 1 2 3; do
  if curl -fsS -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
      -d "$PAYLOAD"; then
    echo "[phase_c] reported"
    exit 0
  fi
  sleep $((attempt * 3))
done
echo "[phase_c] report FAIL"
exit 1
