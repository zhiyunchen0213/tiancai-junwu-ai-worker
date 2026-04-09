#!/bin/bash
#
# Long Video Worker — Digital Human Opening Video (Jimeng/Dreamina T2V)
# Usage: jimeng_opening.sh <work_dir>
#
# Input: work_dir/segments.json (reads first digital_human segment)
#        work_dir/audio/segment_000.mp3 (opening audio)
#        work_dir/character_refs/ (reference images)
# Output: work_dir/opening.mp4
#
# Uses: dreamina CLI (~/bin/dreamina or DREAMINA_BIN env)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

WORK_DIR="${1:?Usage: jimeng_opening.sh <work_dir>}"
DREAMINA="${DREAMINA_BIN:-dreamina}"

# Check dreamina CLI exists
if ! command -v "$DREAMINA" &>/dev/null && [[ ! -f "$HOME/bin/dreamina" ]]; then
    log_error "Dreamina CLI not found (tried: $DREAMINA, ~/bin/dreamina)"
    exit 1
fi
[[ ! -x "$DREAMINA" ]] && DREAMINA="$HOME/bin/dreamina"

# Extract opening segment prompt from segments.json
OPENING_PROMPT=$(python3 -c "
import json
segs = json.load(open('${WORK_DIR}/segments.json'))
dh = next((s for s in segs if s.get('segment_type') == 'digital_human'), None)
print(dh['visual_prompt'] if dh else '')
" 2>/dev/null || echo "")

if [[ -z "$OPENING_PROMPT" ]]; then
    log_warn "No digital_human segment found, skipping opening video"
    exit 0
fi

log_info "Generating opening video with Dreamina..."
log_info "Prompt: ${OPENING_PROMPT:0:100}..."

# Find reference image
REF_IMAGE=""
if [[ -d "${WORK_DIR}/character_refs" ]]; then
    REF_IMAGE=$(find "${WORK_DIR}/character_refs" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) | head -1)
fi

# Find opening audio
OPENING_AUDIO=""
if [[ -f "${WORK_DIR}/audio/segment_000.mp3" ]]; then
    OPENING_AUDIO="${WORK_DIR}/audio/segment_000.mp3"
fi

OUTPUT="${WORK_DIR}/opening.mp4"

# Build dreamina command
DREAMINA_ARGS=(
    generate-video
    --prompt "$OPENING_PROMPT"
    --duration 10
    --ratio "16:9"
)

[[ -n "$REF_IMAGE" ]] && DREAMINA_ARGS+=(--ref-image "$REF_IMAGE")
[[ -n "$OPENING_AUDIO" ]] && DREAMINA_ARGS+=(--audio "$OPENING_AUDIO")

# Dreamina CLI generates video and writes to --output
DREAMINA_ARGS+=(--output "$OUTPUT")

# Submit and wait (dreamina CLI handles polling internally)
log_info "Running: $DREAMINA ${DREAMINA_ARGS[*]:0:6}..."

# Dreamina may need multiple 10s clips for 30s total
# For MVP: generate one 10s clip as the opening
if "$DREAMINA" "${DREAMINA_ARGS[@]}" 2>&1; then
    if [[ -f "$OUTPUT" ]]; then
        local size
        size=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT" 2>/dev/null || echo "0")
        log_info "Opening video generated: ${OUTPUT} ($(( size / 1024 ))KB)"
    else
        log_warn "Dreamina completed but no output file at ${OUTPUT}"
        exit 1
    fi
else
    log_error "Dreamina CLI failed"
    # Non-fatal: Phase B can continue without opening video
    # The composition step will use a still image fallback
    exit 0
fi
