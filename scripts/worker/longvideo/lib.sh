#!/bin/bash
# Long Video Worker — Shared Library
# Source this file from other scripts: source "$(dirname "$0")/lib.sh"

# Logging
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${WORKER_ID:-lv}] [INFO] $1"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${WORKER_ID:-lv}] [ERROR] $1" >&2; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${WORKER_ID:-lv}] [WARN] $1"; }

# API call with retry (5 attempts, exponential backoff)
# Usage: api_call METHOD PATH [DATA]
# Returns: HTTP response body on stdout, exits non-zero on failure
api_call() {
    local method="$1" path="$2" data="${3:-}"
    local url="${REVIEW_SERVER_URL}/api/longvideo${path}"
    local attempt max_attempts=5

    for attempt in $(seq 1 $max_attempts); do
        local args=(-sf -X "$method" -H "Authorization: Bearer ${DISPATCHER_TOKEN}" -H "Content-Type: application/json")
        [[ -n "$data" ]] && args+=(-d "$data")

        local resp
        resp=$(curl "${args[@]}" "$url" 2>/dev/null) && {
            echo "$resp"
            return 0
        }

        local wait=$((attempt * 10))
        log_warn "API call failed: $method $path (attempt $attempt/$max_attempts, retry in ${wait}s)"
        sleep "$wait"
    done

    log_error "API call failed after $max_attempts attempts: $method $path"
    return 1
}

# JSON field extraction using python3
# Usage: json_field '{"key":"val"}' "key" → "val"
json_field() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d
    for k in '${field}'.split('.'):
        v = v[k] if isinstance(v, dict) else v[int(k)]
    print('' if v is None else v if isinstance(v, str) else json.dumps(v))
except: print('')
" 2>/dev/null
}

# Ensure work directory exists
ensure_work_dir() {
    local project_id="$1"
    local work_dir="${SHARED_DIR:-/tmp/lv_work}/${project_id}"
    mkdir -p "$work_dir"
    echo "$work_dir"
}
