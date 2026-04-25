#!/usr/bin/env bash
# scripts/worker/material-ingest/main.sh
# Worker 主循环 (material-ingest 任务类型).
#
# 轮询 /api/material-library/worker/tasks → claim → 依据 phase 调 download/analyze →
# report back → loop.

set -euo pipefail

: "${WORKER_ID:?}"
: "${REVIEW_SERVER_URL:?}"
: "${DISPATCHER_TOKEN:?}"
: "${SCRIPTS_DIR:?}"
: "${HEARTBEAT_INTERVAL:=30}"

SCRIPT_DIR="${SCRIPTS_DIR}/worker/material-ingest"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$WORKER_ID] $*" >&2
}

claim_task() {
  curl -sS --max-time 30 \
    -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    -X POST "${REVIEW_SERVER_URL}/api/material-library/worker/claim" \
    -d "{\"worker_id\": \"${WORKER_ID}\", \"task_types\": [\"download\", \"analyze\"]}" \
    -H "Content-Type: application/json"
}

report_success() {
  local material_id="$1"
  local phase="$2"
  local payload="$3"
  curl -sS --max-time 60 \
    -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${REVIEW_SERVER_URL}/api/material-library/worker/report" \
    -d "{\"material_id\": ${material_id}, \"phase\": \"${phase}\", \"status\": \"success\", \"payload\": ${payload}}"
}

report_failure() {
  local material_id="$1"
  local phase="$2"
  local error_msg="$3"
  curl -sS --max-time 30 \
    -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${REVIEW_SERVER_URL}/api/material-library/worker/report" \
    -d "$(jq -n --argjson mid "$material_id" --arg p "$phase" --arg e "$error_msg" '{material_id:$mid, phase:$p, status:"failure", error:$e}')"
}

handle_download() {
  local material_id="$1"
  local source_url="$2"
  local channel_handle="$3"
  local video_id="$4"

  log "download $material_id: $source_url"
  if raw_path=$("${SCRIPT_DIR}/download.sh" "$source_url" "$channel_handle" "$video_id" 2>/tmp/dl-err.log); then
    report_success "$material_id" "download" "$(jq -n --arg p "$raw_path" '{raw_path: $p}')"
  else
    local err
    err=$(cat /tmp/dl-err.log | tail -c 500)
    report_failure "$material_id" "download" "$err"
  fi
}

handle_analyze() {
  local material_id="$1"
  local source_url="$2"
  log "analyze $material_id: $source_url"
  if analysis=$("${SCRIPT_DIR}/analyze.sh" "$source_url" 2>/tmp/an-err.log); then
    report_success "$material_id" "analyze" "$(jq -n --argjson a "$analysis" '{analysis: $a}')"
  else
    local err
    err=$(cat /tmp/an-err.log | tail -c 500)
    report_failure "$material_id" "analyze" "$err"
  fi
}

main_loop() {
  while true; do
    local task_json
    task_json=$(claim_task || echo '{}')
    local task_count
    task_count=$(echo "$task_json" | jq -r '.tasks | length // 0')

    if [[ "$task_count" -eq 0 ]]; then
      sleep 10
      continue
    fi

    local i=0
    while [[ $i -lt $task_count ]]; do
      local task
      task=$(echo "$task_json" | jq -r ".tasks[$i]")
      local material_id source_url channel_handle video_id phase
      material_id=$(echo "$task" | jq -r '.material_id')
      source_url=$(echo "$task" | jq -r '.source_url')
      channel_handle=$(echo "$task" | jq -r '.channel_handle // "manual"')
      video_id=$(echo "$task" | jq -r '.video_id // (.source_url | split("/")[-1])')
      phase=$(echo "$task" | jq -r '.phase')

      case "$phase" in
        download) handle_download "$material_id" "$source_url" "$channel_handle" "$video_id" ;;
        analyze)  handle_analyze "$material_id" "$source_url" ;;
        *)        log "unknown phase: $phase"; report_failure "$material_id" "$phase" "unknown phase" ;;
      esac
      i=$((i+1))
    done
  done
}

main_loop
