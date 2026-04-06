#!/bin/bash
#
# Long Video Worker — Subtitle Extraction
# Usage: extract_subtitles.sh <youtube_url> <work_dir>
#
# Strategy: yt-dlp auto-sub (free, fast) → fallback to local whisper
# Output: $work_dir/subtitles.txt
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

URL="${1:?Usage: extract_subtitles.sh <youtube_url> <work_dir>}"
WORK_DIR="${2:?Usage: extract_subtitles.sh <youtube_url> <work_dir>}"

OUTPUT_FILE="${WORK_DIR}/subtitles.txt"

log_info "Extracting subtitles from: ${URL}"

# ============================================================================
# Strategy 1: yt-dlp auto-generated subtitles (free, fast, no download)
# ============================================================================

extract_with_ytdlp() {
    log_info "Trying yt-dlp auto-sub..."

    local sub_dir="${WORK_DIR}/subs"
    mkdir -p "$sub_dir"

    # Try auto-generated subtitles first, then manual subtitles
    if yt-dlp \
        --write-auto-sub \
        --sub-lang "en" \
        --sub-format "vtt" \
        --skip-download \
        --no-warnings \
        -o "${sub_dir}/%(id)s" \
        "$URL" 2>/dev/null; then

        # Find the downloaded subtitle file
        local sub_file
        sub_file=$(find "$sub_dir" -name "*.vtt" -o -name "*.srt" | head -1)

        if [[ -n "$sub_file" && -s "$sub_file" ]]; then
            # Convert VTT/SRT to plain text (strip timestamps, tags, duplicate lines)
            python3 -c "
import re, sys

with open('${sub_file}', 'r') as f:
    content = f.read()

# Remove VTT header
content = re.sub(r'^WEBVTT.*?\n\n', '', content, flags=re.DOTALL)

# Remove timestamps and position tags
content = re.sub(r'\d{2}:\d{2}:\d{2}[\.,]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[\.,]\d{3}.*\n', '', content)
content = re.sub(r'<[^>]+>', '', content)  # strip HTML tags
content = re.sub(r'^\d+\s*$', '', content, flags=re.MULTILINE)  # strip SRT sequence numbers

# Deduplicate consecutive identical lines (common in auto-subs)
lines = [l.strip() for l in content.split('\n') if l.strip()]
deduped = []
for line in lines:
    if not deduped or line != deduped[-1]:
        deduped.append(line)

result = ' '.join(deduped)
print(result)
" > "$OUTPUT_FILE" 2>/dev/null

            local word_count
            word_count=$(wc -w < "$OUTPUT_FILE" | tr -d ' ')
            if [[ "$word_count" -gt 50 ]]; then
                log_info "yt-dlp auto-sub succeeded: ${word_count} words"
                return 0
            else
                log_warn "yt-dlp subtitles too short (${word_count} words), trying fallback"
                rm -f "$OUTPUT_FILE"
            fi
        fi
    fi

    log_warn "yt-dlp auto-sub failed or no subtitles available"
    return 1
}

# ============================================================================
# Strategy 2: Local whisper transcription (slower but reliable)
# ============================================================================

extract_with_whisper() {
    log_info "Falling back to local whisper transcription..."

    local audio_file="${WORK_DIR}/audio.mp3"

    # Download audio only
    log_info "Downloading audio..."
    if ! yt-dlp \
        -x --audio-format mp3 \
        --audio-quality 5 \
        --no-warnings \
        -o "$audio_file" \
        "$URL" 2>/dev/null; then
        log_error "Failed to download audio"
        return 1
    fi

    if [[ ! -f "$audio_file" ]]; then
        # yt-dlp may add extension
        audio_file=$(find "$WORK_DIR" -name "audio.*" -o -name "*.mp3" | head -1)
        if [[ -z "$audio_file" ]]; then
            log_error "Audio file not found after download"
            return 1
        fi
    fi

    # Run whisper
    log_info "Running whisper transcription (this may take 10-30 minutes)..."

    if command -v whisper &>/dev/null; then
        # OpenAI whisper CLI
        whisper "$audio_file" \
            --model medium \
            --language en \
            --output_format txt \
            --output_dir "$WORK_DIR" 2>/dev/null

        local whisper_out="${WORK_DIR}/audio.txt"
        if [[ -f "$whisper_out" && -s "$whisper_out" ]]; then
            mv "$whisper_out" "$OUTPUT_FILE"
        fi
    elif command -v whisper-cpp &>/dev/null || [[ -f "$HOME/bin/whisper-cpp" ]]; then
        # whisper.cpp (faster on Mac)
        local whisper_bin
        whisper_bin=$(command -v whisper-cpp 2>/dev/null || echo "$HOME/bin/whisper-cpp")
        local model_path="${WHISPER_MODEL:-$HOME/.cache/whisper/ggml-medium.en.bin}"

        "$whisper_bin" \
            -m "$model_path" \
            -f "$audio_file" \
            -otxt \
            -of "${WORK_DIR}/transcript" 2>/dev/null

        if [[ -f "${WORK_DIR}/transcript.txt" && -s "${WORK_DIR}/transcript.txt" ]]; then
            mv "${WORK_DIR}/transcript.txt" "$OUTPUT_FILE"
        fi
    else
        log_error "No whisper installation found (tried: whisper, whisper-cpp)"
        return 1
    fi

    if [[ -f "$OUTPUT_FILE" && -s "$OUTPUT_FILE" ]]; then
        local word_count
        word_count=$(wc -w < "$OUTPUT_FILE" | tr -d ' ')
        log_info "Whisper transcription succeeded: ${word_count} words"
        # Cleanup audio
        rm -f "$audio_file"
        return 0
    else
        log_error "Whisper transcription produced no output"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

mkdir -p "$WORK_DIR"

if extract_with_ytdlp; then
    exit 0
fi

if extract_with_whisper; then
    exit 0
fi

log_error "All subtitle extraction methods failed for: ${URL}"
exit 1
