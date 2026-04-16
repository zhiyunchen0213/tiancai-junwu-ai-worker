#!/bin/bash
# Usage: worker_commentary.sh <task_file.json> phase_a|phase_c
#
# Invoked by worker_main.sh when a task's track_kind is "commentary".
# Dispatches to phase_a.sh / phase_c.sh with a per-task work dir.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

TASK_FILE="$1"
PHASE="${2:-phase_a}"

TASK_ID=$(TASK_FILE="$TASK_FILE" python3 -c "
import json, os, sys
try:
    t = json.load(open(os.environ['TASK_FILE']))
    print(t.get('task_id') or t.get('id') or '')
except Exception as e:
    print('', end=''); sys.exit(0)
")
if [[ -z "$TASK_ID" ]]; then
  echo "[commentary] could not extract task_id from $TASK_FILE" >&2
  exit 2
fi

WORK_BASE="${COMMENTARY_WORK_DIR:-$HOME/commentary_work}"
WORK_DIR="$WORK_BASE/$TASK_ID"
mkdir -p "$WORK_DIR"

case "$PHASE" in
  phase_a)
    "$SCRIPT_DIR/phase_a.sh" "$TASK_FILE" "$WORK_DIR"
    ;;
  phase_c)
    # Fetch script + video metadata from VPS (authoritative after G1 approval)
    FETCH_RESP=$(curl -fsS "${REVIEW_SERVER_URL}/api/v1/tasks/${TASK_ID}" \
      -H "Authorization: Bearer ${DISPATCHER_TOKEN}")
    # Save full task row so phase_c can read video_metadata.commentary_params
    echo "$FETCH_RESP" > "$WORK_DIR/task.json"
    echo "$FETCH_RESP" | python3 -c "
import sys, json
t = json.load(sys.stdin)
print(t.get('story_document') or '', end='')
" > "$WORK_DIR/script.json"
    if [[ ! -s "$WORK_DIR/script.json" ]]; then
      echo "[commentary] no story_document on task $TASK_ID; cannot run phase_c" >&2
      exit 2
    fi
    if [[ ! -f "$WORK_DIR/original.mp4" ]]; then
      VIDEO_URL=$(echo "$FETCH_RESP" | python3 -c "
import sys, json
t = json.load(sys.stdin)
print(t.get('video_url', ''))
")
      if [[ "$VIDEO_URL" == uploaded://* ]]; then
        curl -fsS -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
          "${REVIEW_SERVER_URL}/api/v1/tasks/${TASK_ID}/source-video" \
          -o "$WORK_DIR/original.mp4"
      else
        "$SCRIPT_DIR/../download_and_extract.sh" "$VIDEO_URL" "$WORK_DIR"
      fi
    fi
    "$SCRIPT_DIR/phase_c.sh" "$TASK_ID" "$WORK_DIR"
    ;;
  *)
    echo "[commentary] unknown phase: $PHASE (expected phase_a|phase_c)" >&2
    exit 2
    ;;
esac
