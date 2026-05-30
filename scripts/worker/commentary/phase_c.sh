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

# ── kindness-reversal-commentary: 9:16 assembly mode ────────────────────────
# Detect track from task.json. Must come BEFORE TTS call so commentary-remix
# path is unaffected.
TRACK=""
if [[ -f "$WORK_DIR/task.json" ]]; then
  TRACK=$(python3 -c "
import sys, json
try:
    print(json.load(open('$WORK_DIR/task.json')).get('track') or '')
except Exception as e:
    print('', file=sys.stderr)
    print('')
" 2>/dev/null || echo "")
fi

if [[ "$TRACK" == "kindness-reversal-commentary" ]]; then
  echo "[phase_c] kindness-reversal-commentary 9:16 assembly mode"

  # 1. TTS → narration.mp3 (豆包 seed-tts-2.0-expressive)
  node "$SCRIPT_DIR/tts_narration.mjs" "$WORK_DIR"

  # 2. Generate narration.srt from script.json segments (timestamps + text already there)
  # script.json = [{start_sec, end_sec, text}, ...] from Task 10's generate_script.mjs.
  # Using Whisper here was wrong: narration is Chinese (天才说书人 第三人称中文叙述),
  # and --language en would hallucinate English. Transcribing synthesized audio to
  # recover the source text is also wasteful + lossy. Pure Python, no external deps.
  NARRATION_SRT="$WORK_DIR/narration.srt"
  HAS_SRT=0
  if [[ -f "$WORK_DIR/script.json" ]]; then
    python3 <<PYEOF
import json
def sec_to_srt_time(s):
    h = int(s // 3600)
    m = int((s % 3600) // 60)
    sec = s % 60
    ms = int(round((sec - int(sec)) * 1000))
    return f"{h:02d}:{m:02d}:{int(sec):02d},{ms:03d}"

segs = json.load(open("$WORK_DIR/script.json"))
lines = []
idx = 1
for seg in segs:
    text = (seg.get("text") or "").strip()
    if not text:
        continue  # skip silent/留白 segments
    start = float(seg["start_sec"])
    end = float(seg["end_sec"])
    lines.append(str(idx))
    lines.append(f"{sec_to_srt_time(start)} --> {sec_to_srt_time(end)}")
    lines.append(text)
    lines.append("")
    idx += 1

with open("$NARRATION_SRT", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
PYEOF
    if [[ -f "$NARRATION_SRT" && -s "$NARRATION_SRT" ]]; then
      HAS_SRT=1
      echo "[phase_c:srt] narration.srt built from script.json ($(wc -l < "$NARRATION_SRT") lines)"
    else
      echo "[phase_c:srt] script.json → SRT produced empty file, skipping burn-in" >&2
    fi
  else
    echo "[phase_c:srt] script.json missing, cannot build SRT" >&2
  fi

  # 3. Detect whether original.mp4 has an audio stream (真善美 videos always do,
  # but guard defensively — ffmpeg filter [0:a] errors out if track is absent)
  ORIG_HAS_AUDIO=0
  if ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
      -of default=nw=1:nk=1 "$WORK_DIR/original.mp4" 2>/dev/null | grep -q "audio"; then
    ORIG_HAS_AUDIO=1
  fi

  # 4. ffmpeg assemble: 9:16 original video (stream copy, no re-encode) + narration.mp3 audio mix.
  # NOTE: subtitle burn-in deliberately removed (2026-05-30). The worker ffmpeg build does NOT
  # have libass/libfreetype enabled (brew ffmpeg 8.0.1 slim build), so subtitles= filter would
  # fail at runtime. Sidecar SRT delivery is also consistent with commentary-remix flow — the
  # employee imports narration.srt into 剪映/Premiere for styled subtitle burn-in at edit time
  # (gives them control over font/color/position for each video). SRT is still uploaded to R2
  # alongside final.mp4 by upload_r2.mjs.
  if [[ $ORIG_HAS_AUDIO -eq 1 ]]; then
    # Mix original audio at -10dB (volume=0.2) with narration at +3.5dB (volume=1.5)
    FILTER_COMPLEX="[0:a]volume=0.2[orig_a];[1:a]volume=1.5[narr_a];[orig_a][narr_a]amix=inputs=2:duration=longest[a_out]"
  else
    # No original audio — just narration boosted
    echo "[phase_c] original.mp4 has no audio track, using narration only" >&2
    FILTER_COMPLEX="[1:a]volume=1.5[a_out]"
  fi

  echo "[phase_c] running ffmpeg assembly (has_audio=${ORIG_HAS_AUDIO}, has_srt=${HAS_SRT}, srt=sidecar)"
  ffmpeg -y \
    -i "$WORK_DIR/original.mp4" \
    -i "$WORK_DIR/narration.mp3" \
    -filter_complex "$FILTER_COMPLEX" \
    -map 0:v -map "[a_out]" \
    -c:v copy \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$WORK_DIR/final.mp4"
  echo "[phase_c] ffmpeg assembly done: $WORK_DIR/final.mp4 (SRT sidecar: $NARRATION_SRT)"

  # 5. Upload final.mp4 (+ narration.srt if present) to R2
  node "$SCRIPT_DIR/upload_r2.mjs" "$WORK_DIR" "$TASK_ID"

  # 6. Report commentary_phase_c_complete with R2 manifest
  NARRATION_SEC=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 \
    "$WORK_DIR/narration.mp3" 2>/dev/null || echo "0")
  R2_MANIFEST=$(cat "$WORK_DIR/r2_manifest.json")

  REPORT_PAYLOAD=$(python3 -c "
import json, sys
manifest = json.load(open('$WORK_DIR/r2_manifest.json'))
final_r2_key = (manifest.get('final_mp4') or {}).get('r2_key', '')
# Include script.json so VPS metadata hook can extract narration text.
# script.json = [{start_sec, end_sec, text}, ...] from Task 10's generate_script.mjs.
# The file is guaranteed to exist here (step 2 SRT generation already read it).
try:
    script = json.load(open('$WORK_DIR/script.json'))
except Exception as e:
    print(f'[phase_c] WARNING: failed to read script.json: {e}', file=sys.stderr)
    script = []
payload = {
    'task_id': '$TASK_ID',
    'event': 'commentary_phase_c_complete',
    'payload': {
        'r2_manifest': manifest,
        'delivery_path': 'r2://' + final_r2_key,
        'narration_duration_sec': float('$NARRATION_SEC' or 0),
        'script': script,
        'sub_track': 'kindness-reversal-commentary',
    },
}
print(json.dumps(payload))
")

  for attempt in 1 2 3; do
    if curl -fsS -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
        -d "$REPORT_PAYLOAD" > "$WORK_DIR/report_c.json"; then
      echo "[phase_c] reported (kindness-reversal-commentary)"
      exit 0
    fi
    echo "[phase_c] report attempt $attempt failed" >&2
    sleep $((attempt * 2))
  done
  echo "[phase_c] FAIL to report after 3 attempts" >&2
  exit 1
fi

# ── commentary-remix (16:9) path — unchanged ─────────────────────────────────

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

DELIVERY_PATH="${MACKING_USER:-zjw-mini}@${MACKING_HOST:-localhost}:~/production/deliveries/commentary/${TASK_ID}/"
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
