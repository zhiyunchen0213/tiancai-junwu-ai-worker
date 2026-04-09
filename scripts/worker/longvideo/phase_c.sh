#!/bin/bash
#
# Long Video Worker — Phase C Orchestrator (Composition)
# Usage: phase_c.sh <project_id> <work_dir>
#
# Steps:
# 1. Install Remotion deps (if needed)
# 2. Render 16:9 landscape video
# 3. Render 9:16 portrait video (Shorts)
# 4. Render thumbnail
# 5. Report phase_c_complete
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ID="${1:?Usage: phase_c.sh <project_id> <work_dir>}"
WORK_DIR="${2:?Usage: phase_c.sh <project_id> <work_dir>}"

REMOTION_DIR="${SCRIPT_DIR}/remotion"

log_info "=== Phase C starting for ${PROJECT_ID} ==="

# Verify Phase B outputs
for f in segments.json audio_manifest.json; do
    if [[ ! -f "${WORK_DIR}/${f}" ]]; then
        log_error "Missing Phase B output: ${f}"
        exit 1
    fi
done

# ============================================================================
# Step 1: Ensure Remotion dependencies are installed
# ============================================================================

if [[ ! -d "${REMOTION_DIR}/node_modules" ]]; then
    log_info "Step 1: Installing Remotion dependencies..."
    (cd "$REMOTION_DIR" && npm install --production 2>&1) || {
        log_error "npm install failed in remotion directory"
        exit 1
    }
else
    log_info "Step 1: Remotion deps already installed"
fi

# ============================================================================
# Step 2: Render landscape (16:9) video
# ============================================================================

log_info "Step 2: Rendering 16:9 landscape video..."
if node "${SCRIPT_DIR}/render_video.mjs" "$WORK_DIR" landscape; then
    log_info "Landscape video rendered ✓"
else
    log_error "Landscape render failed"
    exit 1
fi

# ============================================================================
# Step 3: Render portrait (9:16) video for Shorts
# ============================================================================

log_info "Step 3: Rendering 9:16 portrait video (Shorts)..."
if node "${SCRIPT_DIR}/render_video.mjs" "$WORK_DIR" portrait; then
    log_info "Portrait video rendered ✓"
else
    log_warn "Portrait render failed (non-fatal, landscape is primary)"
fi

# ============================================================================
# Step 4: Render thumbnail
# ============================================================================

log_info "Step 4: Rendering thumbnail..."
node "${SCRIPT_DIR}/render_cover.mjs" "$WORK_DIR" || log_warn "Thumbnail render failed (non-fatal)"

# ============================================================================
# Step 5: Report phase_c_complete
# ============================================================================

log_info "Reporting phase_c_complete..."

# Read selected title from titles_cover.json
SELECTED_TITLE=""
if [[ -f "${WORK_DIR}/titles_cover.json" ]]; then
    SELECTED_TITLE=$(python3 -c "
import json
tc = json.load(open('${WORK_DIR}/titles_cover.json'))
titles = tc.get('titles', [])
print(titles[0]['title'] if titles else '')
" 2>/dev/null || echo "")
fi

REPORT=$(python3 -c "
import json
report = {
    'project_id': '${PROJECT_ID}',
    'event': 'phase_c_complete',
    'payload': {
        'selected_title': $(python3 -c "import json; print(json.dumps('${SELECTED_TITLE}'))" 2>/dev/null || echo '""'),
    },
}
print(json.dumps(report))
" 2>/dev/null)

if ! api_call POST /report "$REPORT" >/dev/null; then
    log_error "Failed to report phase_c_complete"
    exit 1
fi

# Summary
LANDSCAPE="${WORK_DIR}/output/draft_landscape.mp4"
PORTRAIT="${WORK_DIR}/output/draft_portrait.mp4"
THUMB="${WORK_DIR}/output/thumbnail.jpg"

log_info "=== Phase C completed for ${PROJECT_ID} ==="
log_info "  Landscape: $([ -f "$LANDSCAPE" ] && echo "✓ $(du -h "$LANDSCAPE" | cut -f1)" || echo "✗")"
log_info "  Portrait:  $([ -f "$PORTRAIT" ] && echo "✓ $(du -h "$PORTRAIT" | cut -f1)" || echo "✗")"
log_info "  Thumbnail: $([ -f "$THUMB" ] && echo "✓" || echo "✗")"
log_info "  Status: → l3_pending (awaiting final review)"
