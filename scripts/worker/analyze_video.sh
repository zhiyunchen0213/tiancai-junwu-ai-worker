#!/bin/bash

# 视频内容分析脚本 - Phase A, Step 3
# 功能: 使用Kimi CLI进行视频内容分析和元数据提取
# 依赖: kimi (Kimi CLI), ffprobe

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

# 解析参数（支持 --synopsis 可选参数）
WORK_DIR=""
SYNOPSIS_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --synopsis)
            SYNOPSIS_FILE="$2"
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

read -r -d '' ANALYSIS_PROMPT << EOF || true
${SYNOPSIS_CONTEXT}请详细分析这个视频内容，并以markdown格式输出以下信息：

## 视频类型和主题
描述视频的类型、主要主题和核心内容

## 角色列表
列出视频中的所有角色（如果有），包含：
- 角色名称
- 外观描述
- 角色类型（主角/配角/旁白等）

## 时序故事大纲（极其重要，不可省略！）
按时间顺序用表格列出完整剧情，必须用这个格式：

| 时间段 | 场景 | 角色 | 内容描述 | 对白/旁白 |
|--------|------|------|----------|-----------|
| 0-5s | 教室 | 女主、女反派 | 开场画面... | "台词..." |

要求：
- 每 5 秒一行，覆盖视频全部时长
- 场景列要写具体地点（教室、走廊、户外等）
- 角色列要列出该时段出现的所有角色
- 对白列记录原声对白（如有）
- 这是后续改编的核心依据，必须详细准确

## 叙事结构
分析视频的故事结构：
- 开场Hook：如何吸引观众注意力
- 发展：故事如何推进
- 高潮：最重要的时刻
- 结尾：如何收场

## 情绪曲线
描述视频的情感节奏：
- 开始阶段的情绪
- 中段情绪变化
- 结束阶段的情绪
- 整体情绪趋势

## 爆款元素分析
分析视频可能成为爆款的要素：
- 新奇性：是否具有新颖性
- 情感代入：观众共鸣点
- 视觉冲击力：画面吸引力
- 节奏感：内容节奏是否紧凑
- 转发价值：用户分享的可能性

请确保输出清晰、结构化，便于后续内容策划和制作。
EOF

# 第3步: 调用Kimi API (带重试)
echo -e "${YELLOW}[3/4] 调用Kimi进行分析...${NC}"

OUTPUT_FILE="$WORK_DIR/kimi_analysis.md"
ANALYSIS_LOG="$WORK_DIR/kimi_analysis.log"
MAX_RETRIES=2
ATTEMPT=1
ANALYSIS_SUCCESS=0

while [[ $ATTEMPT -le $MAX_RETRIES ]]; do
    echo "分析尝试 $ATTEMPT/$MAX_RETRIES..."

    # Kimi CLI v1.26+: --print 启用非交互模式，--quiet = --print --final-message-only
    if kimi -p "$ANALYSIS_PROMPT

请分析工作目录中的视频文件 original.mp4，输出结构化分析报告。" \
        -w "$WORK_DIR" \
        --quiet \
        > "$OUTPUT_FILE" 2>"$ANALYSIS_LOG"; then
        ANALYSIS_SUCCESS=1
        echo -e "${GREEN}✓ Kimi分析成功${NC}"
        break
    else
        ANALYSIS_ERROR=$(cat "$ANALYSIS_LOG" 2>/dev/null || echo "未知错误")
        echo -e "${YELLOW}分析尝试失败: $ANALYSIS_ERROR${NC}"

        if [[ $ATTEMPT -lt $MAX_RETRIES ]]; then
            WAIT=$((5 * ATTEMPT))
            echo "等待 $WAIT 秒后重试..."
            sleep $WAIT
        fi
    fi

    ((ATTEMPT++))
done

if [[ $ANALYSIS_SUCCESS -eq 0 ]]; then
    echo -e "${RED}错误: Kimi分析失败 (已尝试 $MAX_RETRIES 次)${NC}"
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
  "analysis_model": "kimi",
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
