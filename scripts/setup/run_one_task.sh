#!/bin/bash
# run_one_task.sh — 单任务端到端测试
# 不依赖 worker_main.sh，直接跑一个任务的全流程
# 用法: curl -sL <url> | bash

set -euo pipefail
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true

VPS="http://107.175.215.216"
TOKEN="kwR2m0GMdeGZu0fSvfcVRJGvWYS255qe"
TASK_ID="task-e2e-$(date +%s)"
URL="https://www.youtube.com/shorts/Xo0zswJ3qZQ"
WORK="$HOME/work_${TASK_ID}"

echo "=== 单任务端到端测试 ==="
echo "Task: $TASK_ID"
echo "Video: $URL"
echo "Work dir: $WORK"
echo ""

# 0. 上报任务创建
echo "[0/5] 上报任务创建..."
curl -s -X POST "$VPS/api/v1/tasks/report" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"task_id\":\"$TASK_ID\",\"event\":\"task_created\",\"payload\":{\"video_url\":\"$URL\",\"synopsis\":\"巫毒娃娃校园短剧\",\"priority\":\"normal\",\"gate_mode\":\"full_review\"}}" \
  && echo " OK" || echo " FAIL"

# 1. 下载视频
echo ""
echo "[1/5] 下载视频..."
mkdir -p "$WORK/frames"
cd "$WORK"

if [ -f original.mp4 ]; then
  echo "  已有缓存，跳过下载"
else
  # 查找之前下载过的
  CACHED=$(find ~/production -name "original.mp4" -size +1M 2>/dev/null | head -1)
  if [ -n "$CACHED" ]; then
    echo "  复用缓存: $CACHED"
    cp "$CACHED" original.mp4
  else
    yt-dlp --merge-output-format mp4 --cookies-from-browser chrome -o original.mp4 "$URL" 2>&1 || {
      echo "  yt-dlp 失败，尝试不带 cookies..."
      yt-dlp --merge-output-format mp4 -o original.mp4 "$URL" 2>&1
    }
  fi
fi

if [ ! -f original.mp4 ]; then
  echo "❌ 视频下载失败"
  exit 1
fi
echo "  ✅ 视频: $(du -h original.mp4 | cut -f1)"

# 2. 提取帧 + 音频 + 元数据
echo ""
echo "[2/5] 提取帧和音频..."
ffmpeg -y -loglevel quiet -i original.mp4 -vf fps=1 -q:v 3 frames/frame_%04d.jpg
FRAME_COUNT=$(ls frames/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "  frames: $FRAME_COUNT"

ffmpeg -y -loglevel quiet -i original.mp4 -vn -ar 16000 -ac 1 -f wav audio.wav
echo "  audio: done"

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 original.mp4 2>/dev/null | cut -d. -f1)
RESOLUTION=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 original.mp4 2>/dev/null)
python3 -c "import json;json.dump({'duration_seconds':${DURATION:-60},'resolution':'${RESOLUTION:-1080,1920}','frame_count':${FRAME_COUNT:-60}},open('metadata.json','w'))"
echo "  metadata: ${DURATION}s"

# 3. Whisper 转录
echo ""
echo "[3/5] Whisper 转录..."
if command -v whisper &>/dev/null; then
  whisper audio.wav --model base --language zh --output_format txt --output_dir . 2>/dev/null
  mv audio.txt transcript.txt 2>/dev/null || echo "(无对白)" > transcript.txt
  echo "  ✅ 转录完成: $(wc -c < transcript.txt) 字节"
else
  echo "(无对白，whisper未安装)" > transcript.txt
  echo "  ⚠️ whisper 未安装，跳过"
fi

# 4. Kimi 分析
echo ""
echo "[4/5] Kimi 视频分析..."
if command -v kimi &>/dev/null; then
  KIMI_PROMPT="请分析这个短视频。输出：视频类型、叙事结构、角色、爆款元素、情绪曲线、镜头语言。"
  kimi -p "$KIMI_PROMPT" -f original.mp4 > kimi_analysis.md 2>/dev/null || echo "Kimi分析失败" > kimi_analysis.md
  echo "  ✅ 分析完成: $(wc -c < kimi_analysis.md) 字节"
else
  echo "无Kimi分析" > kimi_analysis.md
  echo "  ⚠️ kimi 未安装，跳过"
fi

# 5. 上报 Phase A 完成 + 调用 Brain API
echo ""
echo "[5/5] 上报到 VPS Brain API..."
TRANSCRIPT=$(cat transcript.txt)
KIMI=$(cat kimi_analysis.md)
METADATA=$(cat metadata.json)

# 上报 phase_a_complete
curl -s -X POST "$VPS/api/v1/tasks/report" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
print(json.dumps({
  'task_id':'$TASK_ID',
  'event':'phase_a_complete',
  'payload':{
    'transcript':open('transcript.txt').read(),
    'kimi_analysis':open('kimi_analysis.md').read(),
    'video_metadata':json.load(open('metadata.json'))
  }
}))
")" && echo "  ✅ Phase A 上报成功" || echo "  ❌ Phase A 上报失败"

# 调用 Brain API
echo ""
echo "  调用 Brain API（约2分钟）..."
RESULT=$(curl -s -X POST "$VPS/api/v1/judge" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 300 \
  -d "$(python3 -c "
import json
print(json.dumps({
  'task_id':'$TASK_ID',
  'track':'kpop-dance',
  'phase_a_result':{
    'transcript':open('transcript.txt').read(),
    'kimi_analysis':open('kimi_analysis.md').read(),
    'video_metadata':json.load(open('metadata.json')),
    'video_url':'$URL'
  }
}))
")")

echo "$RESULT" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  print('  ✅ Brain API 完成')
  print(f'  Track: {d.get(\"track\")}')
  print(f'  Phase: {d.get(\"phase_progress\")}')
  print(f'  耗时: {d.get(\"elapsed_seconds\")}s')
  print(f'  评分预览: {d.get(\"score_631\",\"\")[:100]}...')
except:
  print('  ❌ Brain API 失败')
  print(sys.stdin.read() if hasattr(sys.stdin,'read') else '')
"

echo ""
echo "=== 完成 ==="
echo "在看板查看: $VPS/"
echo "Task ID: $TASK_ID"
