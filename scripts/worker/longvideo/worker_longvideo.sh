#!/bin/bash
#
# Long Video Worker Main Loop
# Polls for long video projects, claims them, runs phases, reports results.
# Managed by LaunchAgent: com.tiancai.worker-longvideo
#

set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# macOS fallback for timeout
if ! command -v timeout &>/dev/null; then
    timeout() { local t="$1"; shift; "$@"; }
fi

# Source environment
if [[ -f "$HOME/.production.env" ]]; then
    source "$HOME/.production.env"
else
    echo "Error: ~/.production.env not found" >&2
    exit 1
fi

# Required env vars
: "${WORKER_ID:?WORKER_ID not set}"
: "${REVIEW_SERVER_URL:?REVIEW_SERVER_URL not set}"
: "${DISPATCHER_TOKEN:?DISPATCHER_TOKEN not set}"
: "${SHARED_DIR:=/shared_pipeline}"
: "${POLL_INTERVAL:=15}"

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

log_info "Long video worker starting (poll interval: ${POLL_INTERVAL}s)"

# ============================================================================
# Heartbeat
# ============================================================================

HEARTBEAT_PID=""

start_heartbeat() {
    local project_id="$1"
    stop_heartbeat
    (
        while true; do
            api_call POST /heartbeat "{\"worker_id\":\"${WORKER_ID}\",\"project_id\":\"${project_id}\",\"status\":\"busy\"}" >/dev/null 2>&1 || true
            sleep 30
        done
    ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "$HEARTBEAT_PID" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null && wait "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ============================================================================
# Phase Execution
# ============================================================================

run_phase() {
    local project_id="$1" status="$2" work_dir="$3"

    case "$status" in
        phase_a)
            log_info "Running Phase A (script generation) for ${project_id}"
            if bash "${SCRIPT_DIR}/phase_a.sh" "$project_id" "$work_dir"; then
                log_info "Phase A completed for ${project_id}"
            else
                log_error "Phase A failed for ${project_id}"
                api_call POST /report "{\"project_id\":\"${project_id}\",\"event\":\"project_failed\"}" || true
            fi
            ;;
        phase_b)
            log_info "Running Phase B (asset generation) for ${project_id}"
            if [[ -f "${SCRIPT_DIR}/phase_b.sh" ]]; then
                bash "${SCRIPT_DIR}/phase_b.sh" "$project_id" "$work_dir"
            else
                log_warn "phase_b.sh not yet implemented, reporting complete"
                api_call POST /report "{\"project_id\":\"${project_id}\",\"event\":\"phase_b_complete\"}" || true
            fi
            ;;
        phase_c)
            log_info "Running Phase C (composition) for ${project_id}"
            if [[ -f "${SCRIPT_DIR}/phase_c.sh" ]]; then
                bash "${SCRIPT_DIR}/phase_c.sh" "$project_id" "$work_dir"
            else
                log_warn "phase_c.sh not yet implemented, reporting complete"
                api_call POST /report "{\"project_id\":\"${project_id}\",\"event\":\"phase_c_complete\"}" || true
            fi
            ;;
        *)
            log_error "Unknown phase status: ${status}"
            ;;
    esac
}

# ============================================================================
# Main Loop
# ============================================================================

cleanup() {
    stop_heartbeat
    log_info "Worker shutting down"
    exit 0
}
trap cleanup SIGTERM SIGINT

while true; do
    # Idle heartbeat
    api_call POST /heartbeat "{\"worker_id\":\"${WORKER_ID}\",\"status\":\"idle\"}" >/dev/null 2>&1 || true

    # Poll for work
    poll_resp=$(api_call GET "/poll?worker_id=${WORKER_ID}" 2>/dev/null || echo '{}')
    project_id=$(json_field "$poll_resp" "project.id")

    if [[ -z "$project_id" ]]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    project_status=$(json_field "$poll_resp" "project.status")
    log_info "Found project ${project_id} (status: ${project_status})"

    # Claim
    claim_resp=$(api_call POST /claim "{\"worker_id\":\"${WORKER_ID}\",\"project_id\":\"${project_id}\"}" 2>/dev/null || echo '{}')
    claimed=$(json_field "$claim_resp" "ok")

    if [[ "$claimed" != "true" && "$claimed" != "True" ]]; then
        log_warn "Failed to claim ${project_id}, skipping"
        sleep 5
        continue
    fi

    new_status=$(json_field "$claim_resp" "project.status")
    log_info "Claimed project ${project_id} → ${new_status}"

    # Setup
    work_dir=$(ensure_work_dir "$project_id")

    # Save project JSON for phase scripts to read
    echo "$claim_resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = d.get('project', {})
json.dump(p, open('${work_dir}/project.json', 'w'), indent=2)
" 2>/dev/null || true

    # Start heartbeat + run phase
    start_heartbeat "$project_id"
    run_phase "$project_id" "$new_status" "$work_dir" || true
    stop_heartbeat

    # Brief pause before next poll
    sleep 3
done
