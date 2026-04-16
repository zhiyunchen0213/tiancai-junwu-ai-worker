#!/bin/bash
# Source-able helper: parse a task JSON file's `video_metadata.commentary_params`
# and export as COMMENTARY_* env vars so downstream node scripts pick them up.
#
# Usage: _TASK_JSON_FILE=<path> source lib/export_params.sh
#
# task JSON may carry video_metadata as either a JSON string (queue file shape)
# or a nested object (api/v1/tasks/<id> response shape). Both are handled.
#
# Exported vars (only when present & valid):
#   COMMENTARY_VOICE
#   COMMENTARY_LANGUAGE_CODE
#   COMMENTARY_CTA_TEMPLATE_ID
#   COMMENTARY_STABILITY
#   COMMENTARY_CORRECTION     (reviewer-supplied hint for Phase A re-analysis)

if [[ -z "${_TASK_JSON_FILE:-}" || ! -f "${_TASK_JSON_FILE}" ]]; then
  return 0
fi

_CP_EXPORTS=$(python3 - <<'PY'
import json, os, sys, shlex

path = os.environ.get("_TASK_JSON_FILE", "")
if not path or not os.path.exists(path):
    sys.exit(0)

try:
    with open(path) as f:
        task = json.load(f)
except Exception:
    sys.exit(0)

vm = task.get("video_metadata")
if isinstance(vm, str) and vm.strip():
    try:
        vm = json.loads(vm)
    except Exception:
        vm = {}
if not isinstance(vm, dict):
    sys.exit(0)

cp = vm.get("commentary_params") or {}
if not isinstance(cp, dict):
    sys.exit(0)

def emit(key, val):
    if val is None or val == "":
        return
    print(f"export {key}={shlex.quote(str(val))}")

voice = cp.get("voice")
if isinstance(voice, str) and voice.strip():
    emit("COMMENTARY_VOICE", voice.strip())

lang = cp.get("language_code")
if isinstance(lang, str) and lang.strip():
    emit("COMMENTARY_LANGUAGE_CODE", lang.strip())

cta = cp.get("cta_template_id")
if isinstance(cta, str) and cta.strip():
    emit("COMMENTARY_CTA_TEMPLATE_ID", cta.strip())

stab = cp.get("stability")
if isinstance(stab, (int, float)):
    emit("COMMENTARY_STABILITY", stab)

corr = cp.get("correction")
if isinstance(corr, str) and corr.strip():
    emit("COMMENTARY_CORRECTION", corr.strip())
PY
)

if [[ -n "$_CP_EXPORTS" ]]; then
  eval "$_CP_EXPORTS"
  echo "[commentary_params] exported: ${COMMENTARY_VOICE:+voice=$COMMENTARY_VOICE }${COMMENTARY_LANGUAGE_CODE:+lang=$COMMENTARY_LANGUAGE_CODE }${COMMENTARY_CTA_TEMPLATE_ID:+cta=$COMMENTARY_CTA_TEMPLATE_ID }${COMMENTARY_STABILITY:+stability=$COMMENTARY_STABILITY}"
  if [[ -n "${COMMENTARY_CORRECTION:-}" ]]; then
    echo "[commentary_params] correction provided ($(printf '%s' "$COMMENTARY_CORRECTION" | wc -c | tr -d ' ') chars)"
  fi
fi

unset _CP_EXPORTS
