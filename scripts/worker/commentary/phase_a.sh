#!/bin/bash
# Usage: phase_a.sh <task_file.json> <work_dir>
# Reads task metadata, fetches original.mp4, runs Gemini scenes + Claude script,
# reports commentary_phase_a_complete to VPS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

# ── Provider token/model: DB (VPS) → env fallback ─────────────────────────
source "$SCRIPT_DIR/configure_phase_a_providers.sh"

TASK_FILE="$1"
WORK_DIR="$2"

mkdir -p "$WORK_DIR"
TASK_ID=$(python3 -c "import sys,json;print(json.load(open('$TASK_FILE')).get('task_id') or json.load(open('$TASK_FILE'))['id'])")
VIDEO_URL=$(python3 -c "import sys,json;print(json.load(open('$TASK_FILE')).get('video_url',''))")
SOURCE_TYPE=$(python3 -c "import sys,json;print(json.load(open('$TASK_FILE')).get('source_type','url'))")

echo "[phase_a] task=$TASK_ID source_type=$SOURCE_TYPE url=$VIDEO_URL"

cp "$TASK_FILE" "$WORK_DIR/task.json"

# Export per-task COMMENTARY_* overrides from video_metadata.commentary_params
_TASK_JSON_FILE="$TASK_FILE" source "$SCRIPT_DIR/lib/export_params.sh"

SOURCE_TASK_ID=$(python3 -c "import sys,json;print(json.load(open('$TASK_FILE')).get('source_task_id') or '')")
TRACK=$(python3 -c "import sys,json;print(json.load(open('$TASK_FILE')).get('track') or '')")

if [[ "$TRACK" == "kindness-reversal-commentary" ]]; then
  echo "[phase_a] kindness-reversal-commentary mode, source_task_id=$SOURCE_TASK_ID"

  if [[ -z "$SOURCE_TASK_ID" ]]; then
    echo "[phase_a] FATAL: kindness-reversal-commentary task missing source_task_id" >&2
    exit 1
  fi

  # 1. Fetch source video from VPS (R2-backed via /source-video).
  # IMPORTANT: source video is stored at SOURCE_TASK_ID's R2 prefix (the original
  # kindness-reversal task), not our commentary task's prefix. The /source-video
  # endpoint only knows about ${pathTaskId}'s own storage, so we must request by
  # source_task_id.
  curl -fsS -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    "${REVIEW_SERVER_URL}/api/v1/tasks/${SOURCE_TASK_ID}/source-video" \
    -o "$WORK_DIR/original.mp4"
  if [[ ! -s "$WORK_DIR/original.mp4" ]]; then
    echo "[phase_a] failed to fetch source video for source_task_id=$SOURCE_TASK_ID" >&2
    exit 1
  fi

  # .production.env declares REVIEW_SERVER_URL + DISPATCHER_TOKEN as bare vars (not exported),
  # so child node processes can't see them. Explicitly export here for doubao_video_analyzer.mjs
  # (which reads process.env.REVIEW_SERVER_URL + DISPATCHER_TOKEN). The other vars used by
  # generate_script.mjs (ANTHROPIC_API_KEY, CLAUDE_*) are exported by configure_phase_a_providers.sh.
  export REVIEW_SERVER_URL DISPATCHER_TOKEN

  # Pin Claude endpoint to apimart /v1/messages (Anthropic-style response) for
  # ClaudeClient compatibility. configure_phase_a_providers.sh may return the
  # Apimart-Claude-ChatCompletions row which sets CLAUDE_ENDPOINT to
  # /v1/chat/completions — that returns OpenAI shape (choices[0].message.content)
  # but ClaudeClient.generateScript() only parses Anthropic shape (content[].text).
  # Pinning to /v1/messages + bearer auth works regardless of which DB row
  # fetch_provider returned. This is consistent with feedback_apimart_chat_completions_translate_unreliable
  # — caller-side override to bypass the chat-completions endpoint.
  export CLAUDE_ENDPOINT="https://api.apimart.ai/v1/messages"
  export CLAUDE_AUTH_MODE=bearer

  # 2. Doubao video analysis (non-fatal on failure)
  node "$SCRIPT_DIR/doubao_video_analyzer.mjs" "$WORK_DIR" "$TASK_ID" || true

  # 3. Generate script
  node "$SCRIPT_DIR/generate_script.mjs" "$WORK_DIR"
  if [[ ! -s "$WORK_DIR/script.json" ]]; then
    echo "[phase_a] script.json missing or empty" >&2
    exit 1
  fi

  # 4. Report phase_a_complete (same shape as commentary-remix)
  REPORT_PAYLOAD=$(python3 -c "
import json, sys
script = json.load(open('$WORK_DIR/script.json'))
doubao_analysis_path = '$WORK_DIR/doubao_analysis.json'
import os
doubao = json.load(open(doubao_analysis_path)) if os.path.exists(doubao_analysis_path) else None
payload = {
  'task_id': '$TASK_ID',
  'event': 'commentary_phase_a_complete',
  'payload': {
    'script': script,
    'sub_track': 'kindness-reversal-commentary',
    'doubao_analysis_available': doubao is not None and not doubao.get('_skip_reason'),
  },
}
print(json.dumps(payload))
")

  for attempt in 1 2 3; do
    if curl -fsS -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
        -d "$REPORT_PAYLOAD" > "$WORK_DIR/report_a.json"; then
      echo "[phase_a] OK reported"
      exit 0
    fi
    echo "[phase_a] report attempt $attempt failed"
    sleep $((attempt * 2))
  done
  echo "[phase_a] FAIL to report after 3 attempts"
  exit 1
fi

# Existing commentary-remix path follows...
if [[ "$VIDEO_URL" == uploaded://* ]]; then
  # Pull via HTTP API — works for localhost dev and remote VPS alike.
  curl -fsS -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    "${REVIEW_SERVER_URL}/api/v1/tasks/${TASK_ID}/source-video" \
    -o "$WORK_DIR/original.mp4"
  if [[ ! -s "$WORK_DIR/original.mp4" ]]; then
    echo "[phase_a] failed to fetch uploaded video from VPS" >&2
    exit 1
  fi
else
  "$WORKER_ROOT/download_and_extract.sh" "$VIDEO_URL" "$WORK_DIR"
fi

# 当前 video_analysis provider (apimart Gemini) 走 inline 上传，硬上限 20MB。
# 超限就在 worker 端用 Mac 硬件 H.264 编码器降到 ~15MB。video_gen 走 Kimi 没这个限制。
ORIGINAL_BYTES=$(wc -c < "$WORK_DIR/original.mp4" | tr -d ' ')
ORIGINAL_MB=$(( ORIGINAL_BYTES / 1024 / 1024 ))
echo "[phase_a] original.mp4 size: ${ORIGINAL_MB}MB"

if (( ORIGINAL_BYTES > 18 * 1024 * 1024 )); then
  echo "[phase_a] >18MB → transcoding via h264_videotoolbox (target ~15MB)"
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK_DIR/original.mp4" 2>/dev/null || echo "")
  if [[ -z "$DURATION" ]] || [[ "$DURATION" == "N/A" ]]; then
    echo "[phase_a] ffprobe failed to read duration; aborting" >&2
    exit 1
  fi
  # 15MB = 120000 kbit·s 总预算，扣 128 kbps 给音频；clamp 300-3000 kbps 防极端
  TARGET_VIDEO_KBPS=$(python3 -c "v = int(120000 / float('$DURATION') - 128); print(max(300, min(3000, v)))")
  echo "[phase_a] duration=${DURATION}s → target video ${TARGET_VIDEO_KBPS}kbps"

  if ffmpeg -hide_banner -loglevel warning -y \
      -i "$WORK_DIR/original.mp4" \
      -c:v h264_videotoolbox -b:v "${TARGET_VIDEO_KBPS}k" \
      -c:a aac -b:a 128k \
      -movflags +faststart \
      "$WORK_DIR/original.transcoded.mp4"; then
    NEW_BYTES=$(wc -c < "$WORK_DIR/original.transcoded.mp4" | tr -d ' ')
    NEW_MB=$(( NEW_BYTES / 1024 / 1024 ))
    if (( NEW_BYTES > 19 * 1024 * 1024 )); then
      echo "[phase_a] transcoded still ${NEW_MB}MB (>19MB safety cap); aborting" >&2
      exit 1
    fi
    mv "$WORK_DIR/original.transcoded.mp4" "$WORK_DIR/original.mp4"
    echo "[phase_a] transcoded ${ORIGINAL_MB}MB → ${NEW_MB}MB"
  else
    echo "[phase_a] ffmpeg transcode failed" >&2
    exit 1
  fi
fi

cat > "$WORK_DIR/source.json" <<EOF
{
  "video_url": "${VIDEO_URL}",
  "local_mp4_path": "${WORK_DIR}/original.mp4"
}
EOF

node "$SCRIPT_DIR/analyze_video_gemini.mjs" "$WORK_DIR"
node "$SCRIPT_DIR/generate_script.mjs" "$WORK_DIR"

REPORT_PAYLOAD=$(python3 -c "
import json, sys
script = json.load(open('$WORK_DIR/script.json'))
scenes = json.load(open('$WORK_DIR/scenes.json'))
payload = {
  'task_id': '$TASK_ID',
  'event': 'commentary_phase_a_complete',
  'payload': {
    'script': script,
    'gemini_model': scenes.get('model'),
    'scenes_summary': f\"{len(scenes.get('scenes', []))} scenes, {scenes.get('video_duration_sec', 0)}s\",
  },
}
print(json.dumps(payload))
")

for attempt in 1 2 3; do
  if curl -fsS -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
      -d "$REPORT_PAYLOAD" > "$WORK_DIR/report_a.json"; then
    echo "[phase_a] OK reported"
    exit 0
  fi
  echo "[phase_a] report attempt $attempt failed"
  sleep $((attempt * 2))
done
echo "[phase_a] FAIL to report after 3 attempts"
exit 1
