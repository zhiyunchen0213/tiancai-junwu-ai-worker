#!/bin/bash
# Usage: source fetch_provider.sh <capability>
# Queries VPS for the active provider of the given capability and exports:
#   PROVIDER_KIND, PROVIDER_TOKEN, PROVIDER_ENDPOINT (may be empty), PROVIDER_MODEL (may be empty)
# On 404 / network error / decrypt failure: leaves env alone (caller's fallback applies).

# Note: this script is meant to be `source`-d, not executed.
# Do NOT set -e — would propagate to caller.

__fp_capability="${1:-}"
if [[ -z "$__fp_capability" ]]; then
  echo "[fetch_provider] missing capability arg" >&2
  return 1 2>/dev/null || exit 1
fi

unset PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL

__fp_resp=$(curl -fsS --max-time 5 \
  "${REVIEW_SERVER_URL}/api/v1/providers/active?capability=${__fp_capability}" \
  -H "Authorization: Bearer ${DISPATCHER_TOKEN}" 2>/dev/null || true)

if [[ -n "$__fp_resp" ]]; then
  PROVIDER_KIND=$(printf '%s' "$__fp_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('provider_kind',''))" 2>/dev/null || echo "")
  PROVIDER_TOKEN=$(printf '%s' "$__fp_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
  PROVIDER_ENDPOINT=$(printf '%s' "$__fp_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('endpoint') or '')" 2>/dev/null || echo "")
  # model (2026-04-16): admin-configurable override. Empty = use worker default.
  PROVIDER_MODEL=$(printf '%s' "$__fp_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('model') or '')" 2>/dev/null || echo "")
  if [[ -n "$PROVIDER_KIND" && -n "$PROVIDER_TOKEN" ]]; then
    export PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL
    if [[ -n "$PROVIDER_MODEL" ]]; then
      echo "[fetch_provider] $__fp_capability: using VPS-configured $PROVIDER_KIND provider (model=$PROVIDER_MODEL)"
    else
      echo "[fetch_provider] $__fp_capability: using VPS-configured $PROVIDER_KIND provider"
    fi
  else
    echo "[fetch_provider] $__fp_capability: response malformed, will use env fallback" >&2
  fi
else
  echo "[fetch_provider] $__fp_capability: no active record on VPS, will use env fallback"
fi

unset __fp_capability __fp_resp
