#!/bin/bash
#
# Long Video Worker — Phase A Orchestrator
# Usage: phase_a.sh <project_id> <work_dir>
#
# Steps:
# 1. Extract subtitles (youtube_url mode) or use topic_text
# 2. Generate master script (Claude)
# 3. Segment script (Claude)
# 4. Generate character references
# 5. Generate titles + cover + suno prompt (Claude)
# 6. Report phase_a_complete with all outputs
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ID="${1:?Usage: phase_a.sh <project_id> <work_dir>}"
WORK_DIR="${2:?Usage: phase_a.sh <project_id> <work_dir>}"

log_info "=== Phase A starting for ${PROJECT_ID} ==="

# Read project.json
PROJECT_JSON="${WORK_DIR}/project.json"
if [[ ! -f "$PROJECT_JSON" ]]; then
    log_error "project.json not found in ${WORK_DIR}"
    exit 1
fi

INPUT_MODE=$(json_field "$(cat "$PROJECT_JSON")" "input_mode")
SOURCE_URL=$(json_field "$(cat "$PROJECT_JSON")" "source_url")
TOPIC_TEXT=$(json_field "$(cat "$PROJECT_JSON")" "topic_text")

# ============================================================================
# Step 1: Subtitle Extraction (youtube_url mode only)
# ============================================================================

if [[ "$INPUT_MODE" == "youtube_url" ]]; then
    if [[ -z "$SOURCE_URL" ]]; then
        log_error "No source_url for youtube_url mode"
        exit 1
    fi

    log_info "Step 1/5: Extracting subtitles from ${SOURCE_URL}"
    if ! bash "${SCRIPT_DIR}/extract_subtitles.sh" "$SOURCE_URL" "$WORK_DIR"; then
        log_error "Subtitle extraction failed"
        exit 1
    fi
elif [[ "$INPUT_MODE" == "topic_prompt" ]]; then
    log_info "Step 1/5: Topic mode — writing topic to subtitles.txt"
    echo "$TOPIC_TEXT" > "${WORK_DIR}/subtitles.txt"
else
    log_error "Unknown input_mode: ${INPUT_MODE}"
    exit 1
fi

if [[ ! -f "${WORK_DIR}/subtitles.txt" ]]; then
    log_error "No subtitles.txt after step 1"
    exit 1
fi

# ============================================================================
# Step 2: Generate Master Script
# ============================================================================

log_info "Step 2/5: Generating master script..."
if ! node "${SCRIPT_DIR}/generate_script.mjs" "$WORK_DIR"; then
    log_error "Script generation failed"
    exit 1
fi

if [[ ! -f "${WORK_DIR}/master_script.txt" ]]; then
    log_error "No master_script.txt after step 2"
    exit 1
fi

WORD_COUNT=$(wc -w < "${WORK_DIR}/master_script.txt" | tr -d ' ')
log_info "Master script: ${WORD_COUNT} words"

# ============================================================================
# Step 3: Segment Script
# ============================================================================

log_info "Step 3/5: Segmenting script..."
if ! node "${SCRIPT_DIR}/segment_script.mjs" "$WORK_DIR"; then
    log_error "Segmentation failed"
    exit 1
fi

if [[ ! -f "${WORK_DIR}/segments.json" ]]; then
    log_error "No segments.json after step 3"
    exit 1
fi

SEGMENT_COUNT=$(python3 -c "import json; print(len(json.load(open('${WORK_DIR}/segments.json'))))" 2>/dev/null || echo "0")
log_info "Segments: ${SEGMENT_COUNT}"

# ============================================================================
# Step 4: Generate Character References
# ============================================================================

log_info "Step 4/5: Generating character references..."
if ! node "${SCRIPT_DIR}/generate_character_refs.mjs" "$WORK_DIR"; then
    log_warn "Character ref generation failed (non-fatal)"
fi

# ============================================================================
# Step 5: Generate Titles, Cover, Suno Prompt
# ============================================================================

log_info "Step 5/5: Generating titles and cover..."
if ! node "${SCRIPT_DIR}/generate_titles_cover.mjs" "$WORK_DIR"; then
    log_error "Title/cover generation failed"
    exit 1
fi

if [[ ! -f "${WORK_DIR}/titles_cover.json" ]]; then
    log_error "No titles_cover.json after step 5"
    exit 1
fi

# ============================================================================
# Report phase_a_complete
# ============================================================================

log_info "Reporting phase_a_complete..."

# Read generated outputs
MASTER_SCRIPT=$(cat "${WORK_DIR}/master_script.txt")
SEGMENTS_JSON=$(cat "${WORK_DIR}/segments.json")
TITLES_COVER=$(cat "${WORK_DIR}/titles_cover.json")
CHARACTER_REFS="[]"
[[ -f "${WORK_DIR}/character_refs.json" ]] && CHARACTER_REFS=$(cat "${WORK_DIR}/character_refs.json")

# Build report payload using python3 (handles JSON escaping safely)
REPORT_PAYLOAD=$(python3 << PYEOF
import json, sys

payload = {
    "master_script": open("${WORK_DIR}/master_script.txt").read(),
    "segments_json": open("${WORK_DIR}/segments.json").read(),
    "character_refs": open("${WORK_DIR}/character_refs.json").read() if __import__('os').path.exists("${WORK_DIR}/character_refs.json") else "[]",
}

# Merge titles_cover fields
tc = json.load(open("${WORK_DIR}/titles_cover.json"))
payload["title_candidates"] = json.dumps(tc.get("titles", []))
payload["cover_visual_desc"] = tc.get("cover_visual_desc", "")
payload["description"] = tc["titles"][0]["description"] if tc.get("titles") else ""
payload["suno_prompt"] = tc.get("suno_prompt", "")

report = {
    "project_id": "${PROJECT_ID}",
    "event": "phase_a_complete",
    "payload": payload,
}

print(json.dumps(report))
PYEOF
)

if ! api_call POST /report "$REPORT_PAYLOAD" >/dev/null; then
    log_error "Failed to report phase_a_complete"
    exit 1
fi

log_info "=== Phase A completed for ${PROJECT_ID} ==="
log_info "  Script: ${WORD_COUNT} words"
log_info "  Segments: ${SEGMENT_COUNT}"
log_info "  Status: → l1_pending (awaiting review)"
