#!/bin/bash

# 语音转文本脚本 - Phase A, Step 2
# 功能: 使用Whisper进行中文语音识别
# 依赖: whisper, python3

set -euo pipefail

# 加载环境变量
if [[ -f ~/.production.env ]]; then
    source ~/.production.env
fi

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查参数
if [[ $# -lt 1 ]]; then
    echo -e "${RED}错误: 缺少必需参数${NC}"
    echo "用法: $0 <工作目录>"
    echo "示例: $0 '/tmp/video_work'"
    exit 1
fi

WORK_DIR="$1"
START_TIME=$(date +%s)

echo -e "${GREEN}=== 语音转文本开始 ===${NC}"
echo "时间戳: $(date '+%Y-%m-%d %H:%M:%S')"
echo "工作目录: $WORK_DIR"

# 第1步: 检查音频文件
echo -e "${YELLOW}[1/4] 检查音频文件...${NC}"

AUDIO_FILE="$WORK_DIR/audio.wav"

if [[ ! -f "$AUDIO_FILE" ]]; then
    echo -e "${RED}错误: 音频文件不存在: $AUDIO_FILE${NC}"
    exit 1
fi

AUDIO_SIZE=$(du -h "$AUDIO_FILE" | cut -f1)
AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of \
    default=noprint_wrappers=1:nokey=1 "$AUDIO_FILE" 2>/dev/null || echo "unknown")

echo -e "${GREEN}✓ 音频文件有效${NC}"
echo "  大小: $AUDIO_SIZE"
echo "  时长: $AUDIO_DURATION 秒"

# 第2步: 运行Whisper (带模型回退)
echo -e "${YELLOW}[2/4] 运行Whisper语音识别...${NC}"

WHISPER_MODEL="base"
TRANSCRIBE_SUCCESS=0
TRANSCRIBE_LOG="$WORK_DIR/whisper.log"

# 尝试base模型
echo "尝试使用 $WHISPER_MODEL 模型..."

if whisper "$AUDIO_FILE" \
    --model "$WHISPER_MODEL" \
    --language zh \
    --output_dir "$WORK_DIR/" \
    --output_format txt \
    > "$TRANSCRIBE_LOG" 2>&1; then
    TRANSCRIBE_SUCCESS=1
    echo -e "${GREEN}✓ 使用 $WHISPER_MODEL 模型转录成功${NC}"
else
    # 如果是内存不足,尝试tiny模型
    if grep -qi "out of memory\|cuda.*allocation\|memory" "$TRANSCRIBE_LOG"; then
        echo -e "${YELLOW}检测到内存不足,回退到 tiny 模型...${NC}"
        WHISPER_MODEL="tiny"

        if whisper "$AUDIO_FILE" \
            --model "$WHISPER_MODEL" \
            --language zh \
            --output_dir "$WORK_DIR/" \
            --output_format txt \
            > "$TRANSCRIBE_LOG" 2>&1; then
            TRANSCRIBE_SUCCESS=1
            echo -e "${GREEN}✓ 使用 $WHISPER_MODEL 模型转录成功${NC}"
        fi
    fi
fi

if [[ $TRANSCRIBE_SUCCESS -eq 0 ]]; then
    echo -e "${RED}错误: Whisper转录失败${NC}"
    cat "$TRANSCRIBE_LOG"
    exit 1
fi

# 第3步: 重命名输出文件
echo -e "${YELLOW}[3/4] 处理转录文本...${NC}"

# Whisper输出的文件名基于音频文件名
AUDIO_BASENAME=$(basename "$AUDIO_FILE" .wav)
WHISPER_OUTPUT="$WORK_DIR/${AUDIO_BASENAME}.txt"
FINAL_OUTPUT="$WORK_DIR/transcript.txt"

if [[ -f "$WHISPER_OUTPUT" ]]; then
    mv "$WHISPER_OUTPUT" "$FINAL_OUTPUT"
    echo -e "${GREEN}✓ 转录文件已保存: $FINAL_OUTPUT${NC}"
else
    echo -e "${RED}错误: Whisper输出文件不存在${NC}"
    exit 1
fi

# 第4步: 验证内容并处理空转录
echo -e "${YELLOW}[4/4] 验证转录内容...${NC}"

# 检查文件是否为空或只包含空白
if [[ ! -s "$FINAL_OUTPUT" ]] || grep -q "^[[:space:]]*$" "$FINAL_OUTPUT"; then
    echo -e "${BLUE}⚠ 转录结果为空${NC}"
    echo "无语音内容" > "$WORK_DIR/transcript_note.txt"
    echo -e "${GREEN}✓ 已创建标记: 无语音内容${NC}"
else
    # 计算转录词数
    WORD_COUNT=$(wc -w < "$FINAL_OUTPUT")
    LINE_COUNT=$(wc -l < "$FINAL_OUTPUT")

    echo -e "${GREEN}✓ 转录成功${NC}"
    echo "  行数: $LINE_COUNT"
    echo "  词数: $WORD_COUNT"

    # 显示前几行
    echo -e "${BLUE}预览 (前3行):${NC}"
    head -3 "$FINAL_OUTPUT" | sed 's/^/  /'
fi

# 创建转录元数据
cat > "$WORK_DIR/transcribe_metadata.json" << EOF
{
  "transcription_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "audio_file": "$AUDIO_FILE",
  "audio_duration_seconds": "${AUDIO_DURATION}",
  "whisper_model": "$WHISPER_MODEL",
  "language": "zh",
  "transcript_file": "$FINAL_OUTPUT",
  "transcript_exists": $([ -f "$FINAL_OUTPUT" ] && echo "true" || echo "false"),
  "has_content": $([ -s "$FINAL_OUTPUT" ] && ! grep -q "^[[:space:]]*$" "$FINAL_OUTPUT" && echo "true" || echo "false")
}
EOF

# 计算执行时间
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo -e "${GREEN}=== 语音转文本完成 ===${NC}"
echo "总耗时: ${MINUTES}m ${SECONDS}s"
echo "输出位置: $WORK_DIR"
echo ""

exit 0
