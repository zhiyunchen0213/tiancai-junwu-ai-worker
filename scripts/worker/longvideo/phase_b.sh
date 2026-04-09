#!/bin/bash
#
# Long Video Worker — Phase B Orchestrator (Asset Generation)
# Usage: phase_b.sh <project_id> <work_dir>
#
# Steps:
# 1. TTS generation (all segments)
# 2. Opening digital human video (Jimeng) — needs TTS audio from step 1
# 3. Scene image generation (Apimart) — parallel with step 2
# 4. Cover base image (Apimart) — parallel with step 2+3
# 5. Report phase_b_complete
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ID="${1:?Usage: phase_b.sh <project_id> <work_dir>}"
WORK_DIR="${2:?Usage: phase_b.sh <project_id> <work_dir>}"

log_info "=== Phase B starting for ${PROJECT_ID} ==="

# Verify Phase A outputs exist
for f in segments.json master_script.txt; do
    if [[ ! -f "${WORK_DIR}/${f}" ]]; then
        log_error "Missing Phase A output: ${f}"
        exit 1
    fi
done

# ============================================================================
# Step 1: TTS Generation (serial — must finish before opening video)
# ============================================================================

log_info "Step 1: TTS generation..."
if ! node "${SCRIPT_DIR}/tts_generate.mjs" "$WORK_DIR"; then
    log_error "TTS generation failed"
    exit 1
fi

if [[ ! -f "${WORK_DIR}/audio_manifest.json" ]]; then
    log_error "No audio_manifest.json after TTS"
    exit 1
fi

TTS_COUNT=$(python3 -c "import json; m=json.load(open('${WORK_DIR}/audio_manifest.json')); print(len([x for x in m if x.get('path')]))" 2>/dev/null || echo "0")
log_info "TTS: ${TTS_COUNT} audio segments generated"

# ============================================================================
# Steps 2+3+4: Parallel asset generation
# ============================================================================

# Track background job PIDs
PIDS=()

# Step 2: Opening video (background)
log_info "Step 2: Starting opening video generation (background)..."
(
    bash "${SCRIPT_DIR}/jimeng_opening.sh" "$WORK_DIR" 2>&1 | while read -r line; do
        log_info "[jimeng] $line"
    done
) &
PIDS+=($!)

# Step 3: Scene images (background)
log_info "Step 3: Starting scene image generation (background)..."
(
    node "${SCRIPT_DIR}/generate_images.mjs" "$WORK_DIR" 2>&1 | while read -r line; do
        log_info "[images] $line"
    done
) &
PIDS+=($!)

# Step 4: Cover base image (background, using same Apimart API)
log_info "Step 4: Starting cover image generation (background)..."
(
    # Read cover description from titles_cover.json
    COVER_DESC=$(python3 -c "
import json, os
tc_path = '${WORK_DIR}/titles_cover.json'
if os.path.exists(tc_path):
    tc = json.load(open(tc_path))
    print(tc.get('cover_visual_desc', ''))
else:
    print('')
" 2>/dev/null || echo "")

    if [[ -n "$COVER_DESC" ]]; then
        APIMART_KEY="${APIMART_API_KEY:-${YUNWU_API_KEY:-}}"
        if [[ -n "$APIMART_KEY" ]]; then
            # Simple single-image generation
            COVER_DIR="${WORK_DIR}/cover"
            mkdir -p "$COVER_DIR"
            node -e "
const API_KEY = '${APIMART_KEY}';
const prompt = $(python3 -c "import json; print(json.dumps('${COVER_DESC}'))" 2>/dev/null || echo '""');
(async () => {
    const resp = await fetch('https://api.apimart.ai/v1/images/generations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + API_KEY },
        body: JSON.stringify({ model: 'gemini-3.1-flash-image-preview', prompt, n: 1, resolution: '1K' }),
    });
    const r = await resp.json();
    const taskId = r?.data?.[0]?.task_id;
    if (!taskId) { console.error('No task_id'); process.exit(1); }
    // Poll
    for (let i = 0; i < 80; i++) {
        await new Promise(r => setTimeout(r, 3000));
        const pr = await fetch('https://api.apimart.ai/v1/tasks/' + taskId, {
            headers: { 'Authorization': 'Bearer ' + API_KEY },
        });
        const pd = await pr.json();
        if (pd.status === 'completed' && pd.data?.images?.[0]?.url) {
            const img = await fetch(pd.data.images[0].url);
            const { createWriteStream } = await import('fs');
            const { Readable } = await import('stream');
            const { pipeline } = await import('stream/promises');
            await pipeline(Readable.fromWeb(img.body), createWriteStream('${COVER_DIR}/cover_base.jpg'));
            console.log('Cover image saved');
            process.exit(0);
        }
        if (pd.status === 'failed') { console.error('Failed'); process.exit(1); }
    }
    console.error('Timeout'); process.exit(1);
})();
" 2>&1 | while read -r line; do log_info "[cover] $line"; done
        fi
    fi
) &
PIDS+=($!)

# Wait for all background jobs
log_info "Waiting for parallel asset generation (${#PIDS[@]} jobs)..."
FAILED=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        ((FAILED++))
        log_warn "Background job $pid failed"
    fi
done

if [[ $FAILED -gt 0 ]]; then
    log_warn "${FAILED} background job(s) failed (non-fatal, continuing)"
fi

# ============================================================================
# Summary
# ============================================================================

IMG_COUNT=0
[[ -f "${WORK_DIR}/image_manifest.json" ]] && \
    IMG_COUNT=$(python3 -c "import json; m=json.load(open('${WORK_DIR}/image_manifest.json')); print(len([x for x in m if x.get('status')=='ok']))" 2>/dev/null || echo "0")

OPENING_EXISTS="no"
[[ -f "${WORK_DIR}/opening.mp4" ]] && OPENING_EXISTS="yes"

COVER_EXISTS="no"
[[ -f "${WORK_DIR}/cover/cover_base.jpg" ]] && COVER_EXISTS="yes"

log_info "Phase B Summary:"
log_info "  TTS segments: ${TTS_COUNT}"
log_info "  Scene images: ${IMG_COUNT}"
log_info "  Opening video: ${OPENING_EXISTS}"
log_info "  Cover image: ${COVER_EXISTS}"

# ============================================================================
# Report phase_b_complete
# ============================================================================

log_info "Reporting phase_b_complete..."

CHARACTER_REFS="[]"
[[ -f "${WORK_DIR}/character_refs.json" ]] && CHARACTER_REFS=$(cat "${WORK_DIR}/character_refs.json")

REPORT=$(python3 -c "
import json
report = {
    'project_id': '${PROJECT_ID}',
    'event': 'phase_b_complete',
    'payload': {
        'character_refs': json.dumps(${CHARACTER_REFS}),
    },
}
print(json.dumps(report))
" 2>/dev/null)

if ! api_call POST /report "$REPORT" >/dev/null; then
    log_error "Failed to report phase_b_complete"
    exit 1
fi

log_info "=== Phase B completed for ${PROJECT_ID} → l2_pending ==="
