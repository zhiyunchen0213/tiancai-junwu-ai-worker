#!/bin/bash
# Usage: phase_a.sh <task_file.json> <work_dir>
# Reads task metadata, fetches original.mp4, runs Gemini scenes + Claude script,
# reports commentary_phase_a_complete to VPS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

# ── Provider token: DB (VPS) → env fallback ───────────────────────────────
source "$SCRIPT_DIR/fetch_provider.sh" analysis_chat

# Gemini uses this token for video analysis
export GEMINI_PROVIDER="${PROVIDER_KIND:-${GEMINI_PROVIDER:-apimart}}"
export GEMINI_API_KEY="${PROVIDER_TOKEN:-${GEMINI_API_KEY:-}}"

# Claude uses the same token for script writing
if [[ "$GEMINI_PROVIDER" == "kie" ]]; then
  export CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE:-bearer}"
  export CLAUDE_ENDPOINT="${CLAUDE_ENDPOINT:-https://api.kie.ai/claude/v1/messages}"
else
  export CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE:-anthropic}"
  export CLAUDE_ENDPOINT="${CLAUDE_ENDPOINT:-https://api.apimart.ai/v1/messages}"
  export ANTHROPIC_VERSION="${ANTHROPIC_VERSION:-2023-06-01}"
fi
export ANTHROPIC_API_KEY="${PROVIDER_TOKEN:-${ANTHROPIC_API_KEY:-}}"
# Admin-configurable model override (2026-04-16): a single `model` field on the
# api_providers row covers both Gemini (video analysis) and Claude (script
# writing) for analysis_chat capability. We map it to CLAUDE_SCRIPT_MODEL only,
# since users most often want to bump Claude versions (e.g. sonnet → opus);
# Gemini model is still controlled by the GEMINI_VIDEO_MODEL env var on worker.
if [[ -n "${PROVIDER_MODEL:-}" ]]; then
  export CLAUDE_SCRIPT_MODEL="$PROVIDER_MODEL"
else
  export CLAUDE_SCRIPT_MODEL="${CLAUDE_SCRIPT_MODEL:-claude-sonnet-4-6}"
fi

# Clear temp vars so subsequent code sees clean env
unset PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL

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
