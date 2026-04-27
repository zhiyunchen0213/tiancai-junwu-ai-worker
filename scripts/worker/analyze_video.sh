#!/bin/bash

# 视频内容分析脚本 - Phase A, Step 3
# 2026-04-26: 从 Kimi CLI 切到 VPS Gemini 3 Flash (apimart). Worker 不再本地调 LLM,
# 改成 curl POST /api/v1/tasks/:tid/analyze-source-video. source video 早就上传 VPS,
# 拿回 markdown 写入 kimi_analysis.md (文件名保留, 下游 ai_judgment.sh / worker_main.sh
# 还在用这个文件名).
# 依赖: ffprobe, curl, jq

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

# 解析参数（支持 --synopsis / --video-url 可选参数）
WORK_DIR=""
SYNOPSIS_FILE=""
VIDEO_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --synopsis)
            SYNOPSIS_FILE="$2"
            shift 2
            ;;
        --video-url)
            # YouTube URL 时 server 会走 fileData URL 直传 (跳过本地文件读+ffmpeg压缩),
            # 非 YouTube 时 server 自动 fallback 到本地 source video.
            VIDEO_URL="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}未知参数: $1${NC}"
            exit 1
            ;;
        *)
            if [[ -z "$WORK_DIR" ]]; then
                WORK_DIR="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$WORK_DIR" ]]; then
    echo -e "${RED}错误: 缺少必需参数${NC}"
    echo "用法: $0 <工作目录> [--synopsis <故事大纲文件>]"
    echo "示例: $0 '/tmp/video_work'"
    echo "示例: $0 '/tmp/video_work' --synopsis '/tmp/synopsis.txt'"
    exit 1
fi

START_TIME=$(date +%s)

echo -e "${GREEN}=== 视频内容分析开始 ===${NC}"
echo "时间戳: $(date '+%Y-%m-%d %H:%M:%S')"
echo "工作目录: $WORK_DIR"
if [[ -n "$SYNOPSIS_FILE" ]]; then
    echo "故事大纲: $SYNOPSIS_FILE"
fi

# 第1步: 检查视频文件
echo -e "${YELLOW}[1/4] 检查视频文件...${NC}"

VIDEO_FILE="$WORK_DIR/original.mp4"

if [[ ! -f "$VIDEO_FILE" ]]; then
    echo -e "${RED}错误: 视频文件不存在: $VIDEO_FILE${NC}"
    exit 1
fi

VIDEO_SIZE=$(du -h "$VIDEO_FILE" | cut -f1)
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration -of \
    default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null || echo "unknown")

echo -e "${GREEN}✓ 视频文件有效${NC}"
echo "  大小: $VIDEO_SIZE"
echo "  时长: $VIDEO_DURATION 秒"

# 第2步: 构造Kimi分析提示词
echo -e "${YELLOW}[2/4] 准备分析提示词...${NC}"

# 如果提供了故事大纲，读取内容作为分析锚点
SYNOPSIS_CONTEXT=""
if [[ -n "$SYNOPSIS_FILE" ]] && [[ -f "$SYNOPSIS_FILE" ]]; then
    SYNOPSIS_CONTENT=$(cat "$SYNOPSIS_FILE")
    SYNOPSIS_CONTEXT="
## 参考故事大纲（请以此为分析锚点）

以下是用户提供的故事大纲/剧情概要。请基于这个大纲来理解视频内容，
确保你的分析与大纲描述的核心叙事一致，不要偏离大纲中的关键情节和人物关系。

---
${SYNOPSIS_CONTENT}
---

"
    echo -e "${GREEN}✓ 已加载故事大纲 ($(wc -c < "$SYNOPSIS_FILE") bytes)${NC}"
elif [[ -n "$SYNOPSIS_FILE" ]]; then
    echo -e "${YELLOW}⚠ 指定的故事大纲文件不存在: $SYNOPSIS_FILE${NC}"
fi

# Prompt 已经移到 server 端 (server.js endpoint), worker 只传 synopsis 文本
# 第3步: 调 VPS Gemini endpoint
echo -e "${YELLOW}[3/4] 调用 VPS Gemini 进行分析...${NC}"

OUTPUT_FILE="$WORK_DIR/kimi_analysis.md"
ANALYSIS_LOG="$WORK_DIR/kimi_analysis.log"
MAX_RETRIES=2
ATTEMPT=1
ANALYSIS_SUCCESS=0

# WORK_DIR 形如 .../work_<task_id>, 提取出 task_id 给 endpoint 路径用
TASK_ID=$(basename "$WORK_DIR" | sed 's/^work_//')
if [[ -z "$TASK_ID" || "$TASK_ID" == "$WORK_DIR" ]]; then
    echo -e "${RED}错误: 无法从 WORK_DIR ($WORK_DIR) 解析 task id${NC}"
    exit 1
fi

if [[ -z "${REVIEW_SERVER_URL:-}" || -z "${DISPATCHER_TOKEN:-}" ]]; then
    echo -e "${RED}错误: REVIEW_SERVER_URL / DISPATCHER_TOKEN 未配置 (~/.production.env)${NC}"
    exit 1
fi

# 构造 JSON body — synopsis / videoUrl 走 jq 转义 (避免引号 / 多行 / unicode 把 JSON 打坏)
SYNOPSIS_TEXT=""
if [[ -n "$SYNOPSIS_FILE" ]] && [[ -f "$SYNOPSIS_FILE" ]]; then
    SYNOPSIS_TEXT=$(cat "$SYNOPSIS_FILE")
fi
PAYLOAD=$(jq -n --arg s "$SYNOPSIS_TEXT" --arg u "$VIDEO_URL" '{synopsis: $s, videoUrl: $u}')

while [[ $ATTEMPT -le $MAX_RETRIES ]]; do
    echo "分析尝试 $ATTEMPT/$MAX_RETRIES..."

    # 注: source video 必须早就上传到 VPS (worker_main.sh 在 download_and_extract 后跑 upload).
    # 端点超时给 5 分钟 (Gemini 视频分析最长见过 90s, 5 分钟兜底安全).
    HTTP_CODE=$(curl --silent --output "$ANALYSIS_LOG.raw" --write-out '%{http_code}' \
        --max-time 300 \
        -X POST \
        -H "Authorization: Bearer $DISPATCHER_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$REVIEW_SERVER_URL/api/v1/tasks/$TASK_ID/analyze-source-video" 2>"$ANALYSIS_LOG.curlerr") || HTTP_CODE=000

    if [[ "$HTTP_CODE" == "200" ]]; then
        # 抽 markdown 字段写入 OUTPUT_FILE
        if jq -er '.markdown' "$ANALYSIS_LOG.raw" > "$OUTPUT_FILE" 2>"$ANALYSIS_LOG"; then
            ANALYSIS_SUCCESS=1
            MODEL=$(jq -r '.model // "unknown"' "$ANALYSIS_LOG.raw")
            TOKENS=$(jq -r '.tokenUsage // 0' "$ANALYSIS_LOG.raw")
            ANALYZE_MODE=$(jq -r '.mode // "unknown"' "$ANALYSIS_LOG.raw")
            echo -e "${GREEN}✓ Gemini 分析成功 (mode=$ANALYZE_MODE, model=$MODEL, tokens=$TOKENS)${NC}"
            rm -f "$ANALYSIS_LOG.raw" "$ANALYSIS_LOG.curlerr"
            break
        else
            echo -e "${YELLOW}分析尝试失败: HTTP 200 但 markdown 字段解析失败${NC}"
            cat "$ANALYSIS_LOG.raw" | head -200 >> "$ANALYSIS_LOG"
        fi
    else
        ERR_MSG=$(jq -r '.error // empty' "$ANALYSIS_LOG.raw" 2>/dev/null || echo "")
        echo -e "${YELLOW}分析尝试失败: HTTP $HTTP_CODE${ERR_MSG:+ — $ERR_MSG}${NC}"
        cat "$ANALYSIS_LOG.raw" 2>/dev/null | head -200 >> "$ANALYSIS_LOG"
        cat "$ANALYSIS_LOG.curlerr" 2>/dev/null >> "$ANALYSIS_LOG"
    fi

    if [[ $ATTEMPT -lt $MAX_RETRIES ]]; then
        WAIT=$((5 * ATTEMPT))
        echo "等待 $WAIT 秒后重试..."
        sleep $WAIT
    fi

    ((ATTEMPT++))
done

if [[ $ANALYSIS_SUCCESS -eq 0 ]]; then
    echo -e "${RED}错误: Gemini 分析失败 (已尝试 $MAX_RETRIES 次)${NC}"
    cat "$ANALYSIS_LOG"
    exit 1
fi

# 第4步: 验证和处理输出
echo -e "${YELLOW}[4/4] 验证分析结果...${NC}"

# 检查输出文件是否存在且不为空
if [[ ! -s "$OUTPUT_FILE" ]]; then
    echo -e "${RED}错误: 分析输出为空${NC}"
    exit 1
fi

# 检查是否包含预期的关键部分
EXPECTED_SECTIONS=("视频类型和主题" "角色列表" "场景列表" "叙事结构" "情绪曲线" "爆款元素分析")
MISSING_SECTIONS=()

for section in "${EXPECTED_SECTIONS[@]}"; do
    if ! grep -q "$section" "$OUTPUT_FILE"; then
        MISSING_SECTIONS+=("$section")
    fi
done

if [[ ${#MISSING_SECTIONS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚠ 警告: 缺少以下部分:${NC}"
    printf '  - %s\n' "${MISSING_SECTIONS[@]}"
    echo -e "${BLUE}(分析可能不完整, 但输出已保存)${NC}"
else
    echo -e "${GREEN}✓ 分析结果包含所有预期部分${NC}"
fi

# 计算分析内容大小
ANALYSIS_SIZE=$(wc -c < "$OUTPUT_FILE")
ANALYSIS_LINES=$(wc -l < "$OUTPUT_FILE")

echo "  文件大小: $ANALYSIS_SIZE bytes"
echo "  行数: $ANALYSIS_LINES"

# 显示前几行
echo -e "${BLUE}预览 (前5行):${NC}"
head -5 "$OUTPUT_FILE" | sed 's/^/  /'

# 创建分析元数据
cat > "$WORK_DIR/analyze_metadata.json" << EOF
{
  "analysis_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "video_file": "$VIDEO_FILE",
  "video_duration_seconds": "${VIDEO_DURATION}",
  "analysis_model": "${MODEL:-gemini-3-flash-preview-nothinking}",
  "analysis_language": "zh",
  "analysis_file": "$OUTPUT_FILE",
  "analysis_size_bytes": $ANALYSIS_SIZE,
  "analysis_lines": $ANALYSIS_LINES,
  "synopsis_provided": $([ -n "$SYNOPSIS_FILE" ] && [ -f "$SYNOPSIS_FILE" ] && echo "true" || echo "false"),
  "analysis_complete": true,
  "sections_found": [
    "视频类型和主题",
    "角色列表",
    "场景列表",
    "叙事结构",
    "情绪曲线",
    "爆款元素分析"
  ]
}
EOF

# 计算执行时间
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo -e "${GREEN}=== 视频分析完成 ===${NC}"
echo "总耗时: ${MINUTES}m ${SECONDS}s"
echo "输出位置: $WORK_DIR"
echo ""

exit 0
