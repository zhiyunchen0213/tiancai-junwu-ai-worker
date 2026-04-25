#!/usr/bin/env bash
# scripts/worker/rough-cut/main.sh
# 粗剪 Worker 主循环. 轮询 rough_cut_queued 任务 → assemble → 回报.

set -euo pipefail

: "${WORKER_ID:?}"
: "${REVIEW_SERVER_URL:?}"
: "${DISPATCHER_TOKEN:?}"
: "${DELIVERY_BASE_DIR:?}"
: "${MATERIAL_LIBRARY_PATH:?}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

log() { echo "[$(date '+%H:%M:%S')] [$WORKER_ID] $*" >&2; }

claim_rough_cut() {
  curl -sS --max-time 30 \
    -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${REVIEW_SERVER_URL}/api/commentary-remix/worker/claim" \
    -d "{\"worker_id\": \"${WORKER_ID}\"}"
}

report_rough_cut() {
  local task_id="$1" phase="$2" payload="$3"
  curl -sS --max-time 60 \
    -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${REVIEW_SERVER_URL}/api/commentary-remix/worker/report" \
    -d "{\"task_id\": ${task_id}, \"phase\": \"${phase}\", \"payload\": ${payload}}"
}

main_loop() {
  while true; do
    local resp task_id task_external_id
    resp=$(claim_rough_cut || echo '{}')
    task_id=$(echo "$resp" | jq -r '.task.id // empty')
    if [ -z "$task_id" ]; then
      sleep 15; continue
    fi
    task_external_id=$(echo "$resp" | jq -r '.task.external_id')
    log "claimed rough_cut task ${task_id} (${task_external_id})"

    local plan_json="/tmp/rough-cut-plan-${task_id}.json"
    echo "$resp" | jq '.plan' > "$plan_json"

    local delivery_dir="${DELIVERY_BASE_DIR}/${task_external_id}"
    local mp3_url
    mp3_url=$(echo "$resp" | jq -r '.narration_mp3_url // empty')
    if [ -n "$mp3_url" ]; then
      mkdir -p "$delivery_dir"
      curl -sSL --max-time 120 -o "${delivery_dir}/NARRATION.mp3" "$mp3_url"
    fi

    if "${SCRIPT_DIR}/assemble.sh" "${task_external_id}" "$plan_json" 2>/tmp/rc-err.log; then
      local draft_path="${task_external_id}/draft.mp4"
      local clips_count size_bytes
      clips_count=$(find "${delivery_dir}/clips" -name '*.mp4' | wc -l | tr -d ' ')
      size_bytes=$(find "${delivery_dir}" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s}')
      report_rough_cut "$task_id" "rough_cut_ready" "$(jq -n \
        --arg p "$draft_path" \
        --argjson c "$clips_count" \
        --argjson s "${size_bytes:-0}" \
        '{draft_mp4_path: $p, clips_count: $c, total_size_bytes: $s}')"
      log "rough_cut_ready task ${task_id}"
    else
      local err
      err=$(cat /tmp/rc-err.log | tail -c 500)
      report_rough_cut "$task_id" "failed_rough_cut" "$(jq -n --arg e "$err" '{error: $e}')"
      log "failed_rough_cut task ${task_id}: ${err}"
    fi
  done
}

main_loop
