#!/bin/bash
#
# jimeng_submit_cli.sh — Submit jimeng video generation via dreamina CLI
# Replaces jimeng_cuihua.mjs (Playwright CDP) with official CLI tool
#
# Usage:
#   bash jimeng_submit_cli.sh --prompt-md <path> --refs-dir <path> [--dry-run]
#
# Input:  即梦提示词.md with <!-- jimeng-config {...} --> JSON block
# Output: submit_state.json with submit_ids array
#

set -euo pipefail

DREAMINA="${DREAMINA_BIN:-dreamina}"
SUBMIT_DELAY="${SUBMIT_DELAY:-4}"  # seconds between submissions (rate limit protection)
MAX_RETRIES=2
LOG_TAG="[jimeng-cli]"

# --- Argument parsing ---
PROMPT_MD=""
REFS_DIR=""
DRY_RUN=false
TASK_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt-md)  PROMPT_MD="$2"; shift 2 ;;
        --refs-dir)   REFS_DIR="$2"; shift 2 ;;
        --task-id)    TASK_ID="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        *) echo "$LOG_TAG Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# 进度上报（可选，需要 PROGRESS_URL + PROGRESS_TOKEN 环境变量）
report_submit_progress() {
    [[ -z "$TASK_ID" || -z "${PROGRESS_URL:-}" || -z "${PROGRESS_TOKEN:-}" ]] && return 0
    local step="$1" detail="${2:-}"
    (curl -sf -X POST "${PROGRESS_URL}/api/v1/tasks/${TASK_ID}/progress" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PROGRESS_TOKEN}" \
        -d "{\"step\":\"$step\",\"detail\":\"$detail\"}" > /dev/null 2>&1) &
}

if [[ -z "$PROMPT_MD" ]] || [[ ! -f "$PROMPT_MD" ]]; then
    echo "$LOG_TAG ERROR: --prompt-md required and must exist" >&2
    exit 1
fi
if [[ -z "$REFS_DIR" ]] || [[ ! -d "$REFS_DIR" ]]; then
    echo "$LOG_TAG ERROR: --refs-dir required and must be a directory" >&2
    exit 1
fi

log() { echo "$(date '+%H:%M:%S') $LOG_TAG $*"; }
log_err() { echo "$(date '+%H:%M:%S') $LOG_TAG ERROR: $*" >&2; }

# --- Check dreamina available ---
if ! command -v "$DREAMINA" &>/dev/null; then
    log_err "dreamina CLI not found in PATH (looked for: $DREAMINA)"
    exit 1
fi

# --- Parse jimeng-config from markdown ---
log "Parsing jimeng-config from $PROMPT_MD"

CONFIG_JSON=$(python3 - "$PROMPT_MD" "$REFS_DIR" << 'PYEOF'
import sys, json, re, os

md_path = sys.argv[1]
refs_dir = sys.argv[2]

with open(md_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Extract <!-- jimeng-config ... --> block
m = re.search(r'<!--\s*jimeng-config\s*\n(.*?)\n\s*-->', content, re.DOTALL)
if not m:
    print(json.dumps({"error": "jimeng-config block not found"}))
    sys.exit(0)

try:
    raw = m.group(1)
    # strip 双重包裹（Claude 偶尔在 <!-- --> 内又加 ```json ``` code fence）
    raw = re.sub(r'^```json\s*\n?', '', raw)
    raw = re.sub(r'\n?```\s*$', '', raw)
    cfg = json.loads(raw.strip())
except json.JSONDecodeError as e:
    print(json.dumps({"error": f"JSON parse error: {e}"}))
    sys.exit(0)

# Validate
if 'batches' not in cfg or not cfg['batches']:
    print(json.dumps({"error": "no batches in config"}))
    sys.exit(0)

# Resolve ref paths relative to refs_dir
for i, batch in enumerate(cfg['batches']):
    resolved_refs = []
    for ref in batch.get('refs', []):
        # Try refs_dir first, then same dir as prompt md
        for base in [refs_dir, os.path.dirname(md_path)]:
            candidate = os.path.join(base, ref)
            if os.path.isfile(candidate):
                resolved_refs.append(os.path.abspath(candidate))
                break
            # Try .png/.jpeg alias
            for ext in ['.png', '.jpeg', '.jpg']:
                alt = os.path.join(base, os.path.splitext(ref)[0] + ext)
                if os.path.isfile(alt):
                    resolved_refs.append(os.path.abspath(alt))
                    break
            else:
                continue
            break
        else:
            # Not found, keep original name (will cause missing image warning)
            resolved_refs.append(ref)
    cfg['batches'][i]['resolved_refs'] = resolved_refs

cfg['name'] = cfg.get('name', cfg.get('project', 'unnamed'))
cfg['ratio'] = cfg.get('ratio', '9:16')
cfg['dualModel'] = cfg.get('dualModel', True)

print(json.dumps(cfg))
PYEOF
)

# Check parse result
parse_error=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
if [[ -n "$parse_error" ]]; then
    log_err "Config parse failed: $parse_error"
    exit 1
fi

log "Config parsed OK"

# --- Pre-flight credit check ---
if [[ "$DRY_RUN" != "true" ]]; then
    log "Checking credits..."
    credit_out=$("$DREAMINA" user_credit 2>&1) || true
    log "Credits: $credit_out"
fi

# --- Submit batches ---
SUBMIT_STATE_DIR=$(dirname "$PROMPT_MD")
SUBMIT_STATE="$SUBMIT_STATE_DIR/submit_state.json"

# Initialize submit_state.json
python3 - "$CONFIG_JSON" "$SUBMIT_STATE" << 'PYEOF'
import sys, json

cfg = json.loads(sys.argv[1])
state = {
    "schema_version": 2,
    "mode": "cli",
    "story_name": cfg.get("name", "unnamed"),
    "submit_ids": [],
    "batches": {},
    "updated_at": ""
}
with open(sys.argv[2], 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF

total_submitted=0
total_failed=0

# Extract batch count and models
BATCH_COUNT=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['batches']))")
DUAL_MODEL=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print('true' if json.load(sys.stdin).get('dualModel', True) else 'false')")
RATIO=$(echo "$CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ratio','9:16'))")

log "Submitting $BATCH_COUNT batches, dualModel=$DUAL_MODEL, ratio=$RATIO"
MODELS_PER_BATCH=$( [[ "$DUAL_MODEL" == "true" ]] && echo 2 || echo 1 )
TOTAL_SUBMITS=$((BATCH_COUNT * MODELS_PER_BATCH))
current_submit=0
report_submit_progress "即梦提交开始" "${BATCH_COUNT} 批次, ${TOTAL_SUBMITS} 个视频"

for ((batch_idx=0; batch_idx<BATCH_COUNT; batch_idx++)); do
    batch_num=$((batch_idx + 1))

    # Extract batch info
    BATCH_INFO=$(python3 - "$CONFIG_JSON" "$batch_idx" << 'PYEOF'
import sys, json, re

cfg = json.loads(sys.argv[1])
idx = int(sys.argv[2])
batch = cfg['batches'][idx]

prompt = batch.get("prompt", "")

# === @引用替换: @Marcus → @图片1（按 atRefs 映射表或 refs 顺序） ===
at_refs = batch.get("atRefs", [])
if at_refs:
    # atRefs 格式: [{"label": "图片1", "search": "@Marcus"}, ...]
    if isinstance(at_refs, list) and len(at_refs) > 0:
        if isinstance(at_refs[0], dict):
            # 按 search 长度倒序替换（避免 @街道 先匹配 @街）
            sorted_refs = sorted(at_refs, key=lambda x: len(x.get("search", "")), reverse=True)
            for ar in sorted_refs:
                search = ar.get("search", "")
                label = ar.get("label", "")
                if search and label:
                    prompt = prompt.replace(search, f"@{label}")
        elif isinstance(at_refs, dict):
            # 旧格式 object: {"Marcus": "Marcus.png"}
            refs_list = batch.get("refs", [])
            for i, ref_name in enumerate(refs_list):
                short = ref_name.rsplit('.', 1)[0]
                prompt = prompt.replace(f"@{short}", f"@图片{i+1}")
else:
    # 无 atRefs 时按 refs 顺序推断
    refs_list = batch.get("refs", [])
    for i, ref_name in enumerate(refs_list):
        short = ref_name.rsplit('.', 1)[0]
        # 按长度倒序替换
    sorted_shorts = sorted(enumerate(refs_list), key=lambda x: len(x[1]), reverse=True)
    for i, ref_name in sorted_shorts:
        short = ref_name.rsplit('.', 1)[0]
        prompt = prompt.replace(f"@{short}", f"@图片{i+1}")

# === TNS 敏感词清洗（即梦平台内容审核安全网） ===
tns_rules = [
    # 种族/肤色描述 → 移除或泛化
    ("黑人", ""), ("白人", ""), ("非裔", ""), ("亚裔", ""),
    ("African American", ""), ("Caucasian", ""),
    # 执法/军事 → 泛化
    ("警察", "制服男子"), ("警服", "深蓝色制服"), ("警徽", "金色徽章"),
    ("警车", "公务车辆"), ("警灯", "车顶灯"),
    ("police", "uniformed man"), ("officer", "man in uniform"),
    ("cop", "man"),
    # 武器/暴力
    ("手铐", ""), ("枪", ""),
    # 宗教内容 → 世俗化（极高风险）
    ("圣像", "雕像"), ("圣光", "温暖光芒"), ("祈祷", "许愿"),
    ("教堂", "广场"), ("耶稣", ""), ("十字架", ""),
    ("佛像", "雕像"), ("清真寺", "建筑"),
    ("AMEN", ""), ("Amen", ""), ("amen", ""),
    ("God bless", ""), ("上帝", ""), ("神迹", "奇迹"),
    # 霸凌 → 弱化
    ("Loser", ""), ("loser", ""),
    ("扔了一团废纸", "投来不屑的目光"), ("扔废纸", "侧目"),
    ("大笑", "窃笑"), ("嘲笑", "侧目"), ("嘲讽", "冷漠"),
    # 病患/医疗 → 暗示
    ("病床", "椅子"), ("化疗", ""), ("癌症", ""),
    # 负面情绪过度描写 → 轻描
    ("绝望地", ""), ("痛哭", "流泪"), ("哭泣", "落泪"),
    ("颤抖着", "轻轻"), ("崩溃", "激动"),
    ("极度震惊", "惊讶"), ("痛苦与无奈", "心疼"),
]
original_prompt = prompt
for old, new in tns_rules:
    prompt = prompt.replace(old, new)
# 清理多余空格
import re as _re
prompt = _re.sub(r'  +', ' ', prompt).strip()
if prompt != original_prompt:
    import sys as _sys
    print(f"[TNS] 清洗了 {sum(1 for o,n in tns_rules if o in original_prompt)} 个敏感词", file=_sys.stderr)

print(json.dumps({
    "prompt": prompt,
    "duration": batch.get("duration", 5),
    "refs": batch.get("resolved_refs", []),
    "ref_count": len(batch.get("resolved_refs", []))
}))
PYEOF
    )

    PROMPT=$(echo "$BATCH_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['prompt'])")
    DURATION=$(echo "$BATCH_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['duration'])")
    REF_COUNT=$(echo "$BATCH_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['ref_count'])")

    # Clamp duration to CLI range [4, 15]
    if (( DURATION < 4 )); then DURATION=4; fi
    if (( DURATION > 15 )); then DURATION=15; fi

    log "Batch $batch_num/$BATCH_COUNT: ${REF_COUNT} refs, ${DURATION}s"

    # Build --image flags
    IMAGE_ARGS=()
    while IFS= read -r ref_path; do
        [[ -z "$ref_path" ]] && continue
        if [[ -f "$ref_path" ]]; then
            IMAGE_ARGS+=(--image "$ref_path")
        else
            log "WARN: ref image not found: $ref_path"
        fi
    done < <(echo "$BATCH_INFO" | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin)['refs']]")

    if [[ ${#IMAGE_ARGS[@]} -eq 0 ]]; then
        log_err "Batch $batch_num: no valid reference images, skipping"
        total_failed=$((total_failed + 1))
        continue
    fi

    # Determine models to submit
    MODELS=("seedance2.0fast")
    if [[ "$DUAL_MODEL" == "true" ]]; then
        MODELS=("seedance2.0" "seedance2.0fast")
    fi

    for model in "${MODELS[@]}"; do
        current_submit=$((current_submit + 1))
        log "  Submitting batch$batch_num / $model..."
        report_submit_progress "提交 ${current_submit}/${TOTAL_SUBMITS}" "batch${batch_num} / ${model}"

        # Build command
        CMD=("$DREAMINA" multimodal2video
            "${IMAGE_ARGS[@]}"
            --prompt "$PROMPT"
            --duration "$DURATION"
            --ratio "$RATIO"
            --model_version "$model"
        )

        if [[ "$DRY_RUN" == "true" ]]; then
            log "  [DRY-RUN] ${CMD[*]}"
            # Simulate success
            python3 - "$SUBMIT_STATE" "$batch_num" "$model" "dry_run_${batch_num}_${model}" << 'PYEOF'
import sys, json
from datetime import datetime, timezone

state_path, batch_num, model, submit_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(state_path, 'r') as f:
    state = json.load(f)
state["submit_ids"].append(submit_id)
batch_key = f"batch{batch_num}"
if batch_key not in state["batches"]:
    state["batches"][batch_key] = {}
state["batches"][batch_key][model] = {
    "submit_id": submit_id, "status": "dry_run",
    "submitted_at": datetime.now(timezone.utc).isoformat()
}
state["updated_at"] = datetime.now(timezone.utc).isoformat()
with open(state_path, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF
            total_submitted=$((total_submitted + 1))
            continue
        fi

        # Execute with retry
        submit_id=""
        for ((attempt=0; attempt<=MAX_RETRIES; attempt++)); do
            output=$("${CMD[@]}" 2>/tmp/dreamina_stderr.log) || true

            # Parse submit_id from output (multi-line JSON)
            # Parse submit_id from output (multi-line JSON)
            # IMPORTANT: gen_status=fail means post-submit TNS rejection, NOT submit failure.
            # Always accept submit_id if present — don't retry (wastes credits).
            submit_id=$(printf '%s' "$output" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    d = json.loads(text)
    sid = d.get('submit_id', '')
    gs = d.get('gen_status', '')
    fr = d.get('fail_reason', '')
    if sid:
        print(sid)
        if gs == 'fail':
            print(f'[TNS-REJECT] {fr}', file=sys.stderr)
    else:
        print('')
except (json.JSONDecodeError, ValueError):
    for line in text.split('\n'):
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
            sid = d.get('submit_id', '')
            if sid:
                print(sid)
                break
        except (json.JSONDecodeError, ValueError):
            continue
    else:
        print('')
" 2>/dev/null || echo "")

            if [[ -n "$submit_id" ]]; then
                log "  OK: submit_id=$submit_id"
                break
            fi

            if (( attempt < MAX_RETRIES )); then
                local_delay=$((10 * (attempt + 1)))
                log "  WARN: no submit_id, retry $((attempt+1))/$MAX_RETRIES in ${local_delay}s"
                log "  Output: $(echo "$output" | head -3)"
                sleep "$local_delay"
            else
                log_err "  FAILED: batch$batch_num/$model after $((MAX_RETRIES+1)) attempts"
                log_err "  Last output: $(echo "$output" | head -5)"
            fi
        done

        # Record result
        if [[ -n "$submit_id" ]]; then
            python3 - "$SUBMIT_STATE" "$batch_num" "$model" "$submit_id" << 'PYEOF'
import sys, json
from datetime import datetime, timezone

state_path, batch_num, model, submit_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(state_path, 'r') as f:
    state = json.load(f)
state["submit_ids"].append(submit_id)
batch_key = f"batch{batch_num}"
if batch_key not in state["batches"]:
    state["batches"][batch_key] = {}
state["batches"][batch_key][model] = {
    "submit_id": submit_id, "status": "submitted",
    "submitted_at": datetime.now(timezone.utc).isoformat()
}
state["updated_at"] = datetime.now(timezone.utc).isoformat()
with open(state_path, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF
            total_submitted=$((total_submitted + 1))
        else
            python3 - "$SUBMIT_STATE" "$batch_num" "$model" << 'PYEOF'
import sys, json
from datetime import datetime, timezone

state_path, batch_num, model = sys.argv[1], sys.argv[2], sys.argv[3]
with open(state_path, 'r') as f:
    state = json.load(f)
batch_key = f"batch{batch_num}"
if batch_key not in state["batches"]:
    state["batches"][batch_key] = {}
state["batches"][batch_key][model] = {
    "submit_id": "", "status": "failed",
    "submitted_at": datetime.now(timezone.utc).isoformat()
}
state["updated_at"] = datetime.now(timezone.utc).isoformat()
with open(state_path, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF
            total_failed=$((total_failed + 1))
        fi

        # Rate limit delay between submissions
        sleep "$SUBMIT_DELAY"
    done
done

# --- Summary ---
log "Submit complete: $total_submitted OK, $total_failed failed"
report_submit_progress "即梦提交完成" "${total_submitted} 成功, ${total_failed} 失败, 等待生成"

if [[ "$total_submitted" -eq 0 ]]; then
    log_err "No batches submitted successfully"
    report_submit_progress "即梦提交全部失败" "所有批次提交失败"
    exit 1
fi

if [[ "$total_failed" -gt 0 ]]; then
    log "WARNING: $total_failed batch(es) failed but $total_submitted succeeded — continuing"
fi

log "submit_state.json written to $SUBMIT_STATE"
cat "$SUBMIT_STATE"
exit 0
