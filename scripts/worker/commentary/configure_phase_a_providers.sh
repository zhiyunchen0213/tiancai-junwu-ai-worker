#!/bin/bash
# Source-only helper for commentary Phase A provider configuration.
#
# Splits the old combined analysis_chat provider into explicit stages:
#   video_analysis  -> Gemini video analysis
#   text_generation -> Claude script/text generation
#
# Legacy analysis_chat remains supported by the VPS /providers/active route as
# a fallback, so old production DB rows keep working until operators migrate.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FETCH_PROVIDER_SCRIPT="${FETCH_PROVIDER_SCRIPT:-$SCRIPT_DIR/fetch_provider.sh}"

# Gemini video analysis provider: model maps to GEMINI_VIDEO_MODEL only.
source "$FETCH_PROVIDER_SCRIPT" video_analysis
export GEMINI_PROVIDER="${PROVIDER_KIND:-${GEMINI_PROVIDER:-apimart}}"
export GEMINI_API_KEY="${PROVIDER_TOKEN:-${GEMINI_API_KEY:-}}"
if [[ -n "${PROVIDER_MODEL:-}" ]]; then
  export GEMINI_VIDEO_MODEL="$PROVIDER_MODEL"
else
  export GEMINI_VIDEO_MODEL="${GEMINI_VIDEO_MODEL:-gemini-3-flash-preview-nothinking}"
fi
unset PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL

# Claude text generation provider: model maps to CLAUDE_SCRIPT_MODEL only.
source "$FETCH_PROVIDER_SCRIPT" text_generation
if [[ -n "${PROVIDER_KIND:-}" ]]; then
  if [[ "$PROVIDER_KIND" == "kie" ]]; then
    export CLAUDE_AUTH_MODE="bearer"
    export CLAUDE_ENDPOINT="${PROVIDER_ENDPOINT:-https://api.kie.ai/claude/v1/messages}"
  else
    export CLAUDE_AUTH_MODE="anthropic"
    export CLAUDE_ENDPOINT="${PROVIDER_ENDPOINT:-https://api.apimart.ai/v1/messages}"
    export ANTHROPIC_VERSION="${ANTHROPIC_VERSION:-2023-06-01}"
  fi
  export ANTHROPIC_API_KEY="$PROVIDER_TOKEN"
else
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
fi

if [[ -n "${PROVIDER_MODEL:-}" ]]; then
  export CLAUDE_SCRIPT_MODEL="$PROVIDER_MODEL"
else
  export CLAUDE_SCRIPT_MODEL="${CLAUDE_SCRIPT_MODEL:-claude-sonnet-4-6}"
fi
unset PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL
