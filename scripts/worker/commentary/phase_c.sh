#!/bin/bash
# Usage: phase_c.sh <task_id> <work_dir>
# Assumes: work_dir has original.mp4 + script.json (pulled from VPS after G1 approval)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f ~/.production.env ]] && source ~/.production.env
[[ -f ~/.dev-worker.env ]] && source ~/.dev-worker.env

# ── TTS provider token ────────────────────────────────────────────────────
source "$SCRIPT_DIR/fetch_provider.sh" tts
export KIE_API_URL="${PROVIDER_ENDPOINT:-${KIE_API_URL:-https://api.kie.ai}}"
# KIE_API_KEY is primary; fall back to ELEVENLABS_API_KEY if only that is set
export KIE_API_KEY="${PROVIDER_TOKEN:-${KIE_API_KEY:-${ELEVENLABS_API_KEY:-}}}"
# Admin-configurable model override (2026-04-16). Currently only one TTS model
# exists (elevenlabs/text-to-dialogue-v3), so this is forward-looking. The TTS
# node script reads TTS_MODEL env if set.
if [[ -n "${PROVIDER_MODEL:-}" ]]; then
  export TTS_MODEL="$PROVIDER_MODEL"
fi
unset PROVIDER_KIND PROVIDER_TOKEN PROVIDER_ENDPOINT PROVIDER_MODEL

TASK_ID="$1"
WORK_DIR="$2"

echo "[phase_c] task=$TASK_ID"

# Export per-task COMMENTARY_* overrides from video_metadata.commentary_params
# (worker_commentary.sh phase_c writes task.json from the VPS fetch response)
if [[ -f "$WORK_DIR/task.json" ]]; then
  _TASK_JSON_FILE="$WORK_DIR/task.json" source "$SCRIPT_DIR/lib/export_params.sh"
fi

# ── kindness-reversal-commentary: 9:16 assembly mode ────────────────────────
# Detect track from task.json. Must come BEFORE TTS call so commentary-remix
# path is unaffected.
TRACK=""
if [[ -f "$WORK_DIR/task.json" ]]; then
  TRACK=$(python3 -c "
import sys, json
try:
    print(json.load(open('$WORK_DIR/task.json')).get('track') or '')
except Exception as e:
    print('', file=sys.stderr)
    print('')
" 2>/dev/null || echo "")
fi

if [[ "$TRACK" == "kindness-reversal-commentary" ]]; then
  echo "[phase_c] kindness-reversal-commentary 9:16 assembly mode"

  # .production.env declares VOLC_TTS_API_KEY + REVIEW_SERVER_URL + DISPATCHER_TOKEN
  # + R2_* as bare vars (not exported). Child node processes (tts_narration.mjs,
  # upload_r2.mjs) need them via process.env. Export here.
  export VOLC_TTS_API_KEY REVIEW_SERVER_URL DISPATCHER_TOKEN \
         R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_PUBLIC_BASE

  # Use the default English Dacey voice (en_female_dacey_uranus_bigtts) — the only
  # voice currently seeded in the Doubao TTS resource cluster (per migration
  # 2026-05-22-doubao-tts-seed.sql). Narration is English (see
  # skills/tracks/kindness-reversal-commentary/narration_prompt.md) so the
  # English voice matches the narration language. No override needed; tts_narration.mjs
  # default cascade picks Dacey.

  # 1. TTS → narration.mp3 (豆包 seed-tts-2.0-expressive)
  node "$SCRIPT_DIR/tts_narration.mjs" "$WORK_DIR"

  # 2. Generate narration.srt from script.json segments (timestamps + text already there)
  # script.json = [{start_sec, end_sec, text}, ...] from Task 10's generate_script.mjs.
  # Using Whisper here was wrong: narration is Chinese (天才说书人 第三人称中文叙述),
  # and --language en would hallucinate English. Transcribing synthesized audio to
  # recover the source text is also wasteful + lossy. Pure Python, no external deps.
  NARRATION_SRT="$WORK_DIR/narration.srt"
  HAS_SRT=0
  if [[ -f "$WORK_DIR/script.json" ]]; then
    python3 <<PYEOF
import json
def sec_to_srt_time(s):
    h = int(s // 3600)
    m = int((s % 3600) // 60)
    sec = s % 60
    ms = int(round((sec - int(sec)) * 1000))
    return f"{h:02d}:{m:02d}:{int(sec):02d},{ms:03d}"

segs = json.load(open("$WORK_DIR/script.json"))
lines = []
idx = 1
for seg in segs:
    text = (seg.get("text") or "").strip()
    if not text:
        continue  # skip silent/留白 segments
    start = float(seg["start_sec"])
    end = float(seg["end_sec"])
    lines.append(str(idx))
    lines.append(f"{sec_to_srt_time(start)} --> {sec_to_srt_time(end)}")
    lines.append(text)
    lines.append("")
    idx += 1

with open("$NARRATION_SRT", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
PYEOF
    if [[ -f "$NARRATION_SRT" && -s "$NARRATION_SRT" ]]; then
      HAS_SRT=1
      echo "[phase_c:srt] narration.srt built from script.json ($(wc -l < "$NARRATION_SRT") lines)"
    else
      echo "[phase_c:srt] script.json → SRT produced empty file, skipping burn-in" >&2
    fi
  else
    echo "[phase_c:srt] script.json missing, cannot build SRT" >&2
  fi

  # 3. Fetch new YouTube metadata (Claude rewrite) via VPS endpoint. Synchronous so
  # metadata.json can go IN the zip. Non-fatal: if it fails we still ship the zip
  # without metadata.json (frontend can offer [重生 metadata] later).
  METADATA_JSON="$WORK_DIR/metadata.json"
  if curl -fsS -X POST -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
      "${REVIEW_SERVER_URL}/api/v1/internal/kindness-commentary-metadata/${TASK_ID}" \
      -o "$METADATA_JSON" 2>"$WORK_DIR/metadata.err"; then
    if [[ -s "$METADATA_JSON" ]]; then
      echo "[phase_c:metadata] fetched ($(wc -c < "$METADATA_JSON") bytes)"
    else
      echo "[phase_c:metadata] empty response, dropping from zip" >&2
      rm -f "$METADATA_JSON"
    fi
  else
    echo "[phase_c:metadata] fetch failed, dropping from zip: $(cat "$WORK_DIR/metadata.err" 2>/dev/null | head -1)" >&2
    rm -f "$METADATA_JSON"
  fi

  # 4. Build README.txt with employee instructions for the zip pack.
  cat > "$WORK_DIR/README.txt" <<'README'
真善美 → 解说赛道 剪辑包

文件清单
========
- published.mp4   : 你之前剪辑发布到 YouTube 的真善美短视频成片 (yt-dlp 抓取)
- narration.mp3   : AI 生成的英文解说配音 (天才说书人 voice, Dacey)
- narration.srt   : 解说字幕 (含时间戳 + 英文文本)
- metadata.json   : 推荐的新 YouTube 元数据 (title / description / tags / cover_overlay_text)
                    避免 reuse-content policy 命中, 标题/描述/标签都重新设计

剪辑建议 (剪映 / Premiere)
==========================
1. 把 published.mp4 拖进时间线
2. 把 narration.mp3 拖进音频轨道:
   - 原视频音轨降到 ~20% 音量 (-14dB)
   - narration 升到 ~150% 音量 (+3.5dB)
3. narration 时长可能超过视频:
   - 如果超 → 选用最关键的片段, 其它配重要画面
   - 或对原视频做 1.1-1.3x 加速来对齐 narration 节奏
4. 把 narration.srt 导入字幕轨道, 选你喜欢的字体/颜色/位置
5. 导出新成片
6. 上传 YouTube 时使用 metadata.json 里的 title/description/tags
   ⚠️ 重要: 不要用原 published 视频的标题或描述, YouTube reuse content policy 会判同质化

注意
====
- 同一条 source 真善美任务最多复用 2 次 (env cap)
- 必须推到跟原 channel 不同的 YouTube 频道, 避免账号关联触发同质化检测
README
  echo "[phase_c] README.txt written"

  # 5. Build commentary pack zip {published.mp4, narration.mp3, narration.srt, metadata.json?, README.txt}
  PACK_ZIP="$WORK_DIR/kindness-commentary-pack.zip"
  cp "$WORK_DIR/original.mp4" "$WORK_DIR/published.mp4"
  # Use stored zip (no compression) — mp4/mp3 are already compressed, gain ~0%.
  # -j: junk paths (don't include $WORK_DIR/ prefix in zip)
  ZIP_FILES=(-j "$WORK_DIR/published.mp4" "$WORK_DIR/narration.mp3")
  [[ -f "$NARRATION_SRT" ]] && ZIP_FILES+=("$NARRATION_SRT")
  [[ -f "$METADATA_JSON" ]] && ZIP_FILES+=("$METADATA_JSON")
  ZIP_FILES+=("$WORK_DIR/README.txt")
  rm -f "$PACK_ZIP"
  zip -0 "$PACK_ZIP" "${ZIP_FILES[@]}" > "$WORK_DIR/zip.log" 2>&1
  ZIP_SIZE=$(wc -c < "$PACK_ZIP" | tr -d ' ')
  ZIP_MB=$(( ZIP_SIZE / 1024 / 1024 ))
  echo "[phase_c] zip built: $PACK_ZIP (${ZIP_MB}MB, $(unzip -l "$PACK_ZIP" 2>/dev/null | tail -1 | awk '{print $2}') files)"

  # 6. Upload zip to R2 (also keep narration.mp3 + narration.srt as standalone files for inspection)
  node "$SCRIPT_DIR/upload_r2.mjs" "$WORK_DIR" "$TASK_ID"

  # 7. Report commentary_phase_c_complete with R2 manifest
  NARRATION_SEC=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 \
    "$WORK_DIR/narration.mp3" 2>/dev/null || echo "0")

  REPORT_PAYLOAD=$(python3 -c "
import json, sys
manifest = json.load(open('$WORK_DIR/r2_manifest.json'))
zip_r2_key = (manifest.get('pack_zip') or {}).get('r2_key', '')
try:
    script = json.load(open('$WORK_DIR/script.json'))
except Exception as e:
    print(f'[phase_c] WARNING: failed to read script.json: {e}', file=sys.stderr)
    script = []
payload = {
    'task_id': '$TASK_ID',
    'event': 'commentary_phase_c_complete',
    'payload': {
        'r2_manifest': manifest,
        'delivery_path': 'r2://' + zip_r2_key,
        'narration_duration_sec': float('$NARRATION_SEC' or 0),
        'script': script,
        'sub_track': 'kindness-reversal-commentary',
    },
}
print(json.dumps(payload))
")

  for attempt in 1 2 3; do
    if curl -fsS -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
        -d "$REPORT_PAYLOAD" > "$WORK_DIR/report_c.json"; then
      echo "[phase_c] reported (kindness-reversal-commentary)"
      exit 0
    fi
    echo "[phase_c] report attempt $attempt failed" >&2
    sleep $((attempt * 2))
  done
  echo "[phase_c] FAIL to report after 3 attempts" >&2
  exit 1
fi

# ── commentary-remix (16:9) path — unchanged ─────────────────────────────────

node "$SCRIPT_DIR/tts_narration.mjs" "$WORK_DIR"

# ── SRT subtitles from narration.mp3 ──────────────────────────────────────
# Generate a pure English SRT timed to narration playback so the reviewer can
# drop {original.mp4 + narration.mp3 + subtitles.srt} into 剪映 / CapCut / FCP
# without any extra work. Whisper writes <basename>.srt next to the output_dir;
# we rename it to subtitles.srt for a stable delivery filename.
# Resolve whisper binary: env override → PATH → common pip install paths
WHISPER_BIN="${WHISPER_BIN:-$(command -v whisper 2>/dev/null || true)}"
if [[ -z "$WHISPER_BIN" ]]; then
  for _wb in /opt/homebrew/bin/whisper ~/Library/Python/*/bin/whisper ~/.local/bin/whisper /usr/local/bin/whisper; do
    [[ -x "$_wb" ]] && WHISPER_BIN="$_wb" && break
  done
fi
if [[ -n "$WHISPER_BIN" && -x "$WHISPER_BIN" ]] && [[ -f "$WORK_DIR/narration.mp3" ]]; then
  echo "[srt] transcribing narration.mp3 for SRT subtitles"
  "$WHISPER_BIN" "$WORK_DIR/narration.mp3" \
    --model base.en \
    --language en \
    --output_format srt \
    --output_dir "$WORK_DIR" \
    --verbose False \
    2>&1 | tail -20 || {
      echo "[srt] whisper failed, continuing without SRT" >&2
    }
  if [[ -f "$WORK_DIR/narration.srt" ]]; then
    mv "$WORK_DIR/narration.srt" "$WORK_DIR/subtitles.srt"
    echo "[srt] subtitles.srt created ($(wc -l < "$WORK_DIR/subtitles.srt") lines)"
  else
    echo "[srt] whisper produced no narration.srt (continuing)" >&2
  fi
else
  echo "[srt] whisper binary not found at $WHISPER_BIN, skipping SRT" >&2
fi

bash "$SCRIPT_DIR/package_delivery.sh" "$TASK_ID" "$WORK_DIR"

NARRATION_SEC=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$WORK_DIR/narration.mp3" 2>/dev/null || echo "0")

DELIVERY_PATH="${MACKING_USER:-zjw-mini}@${MACKING_HOST:-localhost}:~/production/deliveries/commentary/${TASK_ID}/"
PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'task_id': '$TASK_ID',
  'event': 'commentary_phase_c_complete',
  'payload': {
    'delivery_path': '$DELIVERY_PATH',
    'narration_duration_sec': float('$NARRATION_SEC' or 0),
  },
}))
")

for attempt in 1 2 3; do
  if curl -fsS -X POST "${REVIEW_SERVER_URL}/api/v1/tasks/report" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
      -d "$PAYLOAD"; then
    echo "[phase_c] reported"
    exit 0
  fi
  sleep $((attempt * 3))
done
echo "[phase_c] report FAIL"
exit 1
