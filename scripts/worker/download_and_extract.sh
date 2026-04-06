#!/bin/bash

# 下载并提取视频脚本 - Phase A, Step 1
# 功能: 通过 yt-dlp 下载视频 (支持 YouTube/B站/TikTok/抖音/Facebook 等), 提取关键帧和音频, 获取元数据
# 依赖: yt-dlp, ffmpeg, ffprobe

set -euo pipefail

# 加载环境变量
if [[ -f ~/.production.env ]]; then
    source ~/.production.env
fi

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查参数
if [[ $# -lt 2 ]]; then
    echo -e "${RED}错误: 缺少必需参数${NC}"
    echo "用法: $0 <视频URL> <工作目录>"
    echo "示例: $0 'https://www.youtube.com/shorts/...' '/tmp/video_work'"
    exit 1
fi

URL="$1"
WORK_DIR="$2"
START_TIME=$(date +%s)

echo -e "${GREEN}=== 视频下载和提取开始 ===${NC}"
echo "时间戳: $(date '+%Y-%m-%d %H:%M:%S')"
echo "视频URL: $URL"
echo "工作目录: $WORK_DIR"

# 第1步: 创建工作目录
echo -e "${YELLOW}[1/5] 创建工作目录...${NC}"
if ! mkdir -p "$WORK_DIR"; then
    echo -e "${RED}错误: 无法创建工作目录 $WORK_DIR${NC}"
    exit 1
fi

# 第2步: 下载视频 (带重试逻辑)
echo -e "${YELLOW}[2/5] 下载视频...${NC}"
MAX_ATTEMPTS=3
ATTEMPT=1
DOWNLOAD_SUCCESS=0

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
    echo "下载尝试 $ATTEMPT/$MAX_ATTEMPTS..."

    # YouTube 下载策略：
    # - MACKING_HOST=localhost → 本机就是 macking，直接本地 yt-dlp
    # - MACKING_HOST=IP → SSH 到 macking 代理下载，fallback 到本机
    # MACKING_HOST 必须在 .production.env 中设置（已由 worker_main.sh 校验）
    MACKING_HOST="${MACKING_HOST:?MACKING_HOST not set}"
    MACKING_USER="${MACKING_USER:-zjw-mini}"
    DOWNLOAD_DONE=0

    # 构建 cookie 参数（优先 cookie 文件，fallback 到 Safari browser cookies）
    COOKIE_ARGS=""
    if [[ -n "${YT_COOKIES_FILE:-}" ]] && [[ -f "$YT_COOKIES_FILE" ]]; then
        COOKIE_ARGS="--cookies $YT_COOKIES_FILE"
    else
        COOKIE_ARGS="--cookies-from-browser safari"
    fi

    # 判断是否本机就是 macking（dev 环境）
    if [[ "$MACKING_HOST" == "localhost" || "$MACKING_HOST" == "127.0.0.1" ]]; then
        # 本机直接下载（开发机 = macking）
        echo "本机模式（MACKING_HOST=$MACKING_HOST），直接下载..."
        if yt-dlp $COOKIE_ARGS --merge-output-format mp4 -o "$WORK_DIR/original.mp4" "$URL" 2>"$WORK_DIR/download.log"; then
            DOWNLOAD_SUCCESS=1
            echo -e "${GREEN}✓ 视频下载成功（本机）${NC}"
            break
        fi
    else
        # 方案 1: SSH 到 macking 代理下载
        echo "[DEBUG] Testing SSH to macking: $MACKING_USER@$MACKING_HOST"
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST" true 2>&1; then
            echo "通过 macking ($MACKING_HOST) 代理下载..."
            REMOTE_DIR="/tmp/yt-dl-$$-${RANDOM}"
            if ssh -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST" \
                "export PATH=/opt/homebrew/bin:\$PATH; mkdir -p $REMOTE_DIR && yt-dlp --cookies-from-browser safari --merge-output-format mp4 -o '$REMOTE_DIR/video.%(ext)s' '$URL' && ls $REMOTE_DIR/*.mp4" \
                2>"$WORK_DIR/download.log"; then
                REMOTE_FILE=$(ssh -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST" "ls $REMOTE_DIR/*.mp4 2>/dev/null | head -1")
                if [[ -n "$REMOTE_FILE" ]]; then
                    if scp -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST:$REMOTE_FILE" "$WORK_DIR/original.mp4" 2>/dev/null; then
                        ssh "$MACKING_USER@$MACKING_HOST" "rm -rf '$REMOTE_DIR'" 2>/dev/null
                        DOWNLOAD_DONE=1
                        DOWNLOAD_SUCCESS=1
                        echo -e "${GREEN}✓ 视频下载成功（macking 代理）${NC}"
                        break
                    fi
                fi
            fi
            ssh "$MACKING_USER@$MACKING_HOST" "rm -rf '$REMOTE_DIR'" 2>/dev/null
            echo "macking 代理下载失败，尝试本机..."
        fi

        # 方案 2: 本机直接下载（fallback）
        if [[ $DOWNLOAD_DONE -eq 0 ]]; then
            if yt-dlp $COOKIE_ARGS --merge-output-format mp4 -o "$WORK_DIR/original.mp4" "$URL" 2>"$WORK_DIR/download.log"; then
                DOWNLOAD_SUCCESS=1
                echo -e "${GREEN}✓ 视频下载成功（本机）${NC}"
                break
            fi
        fi
    fi

    DOWNLOAD_ERROR=$(cat "$WORK_DIR/download.log" 2>/dev/null || echo "未知错误")
    if echo "$DOWNLOAD_ERROR" | grep -qE "(地理限制|年龄限制|不可用|私密|已删除)"; then
        echo -e "${RED}✗ 终端错误: $DOWNLOAD_ERROR${NC}"
        exit 1
    fi
    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
        WAIT=$((5 * ATTEMPT))
        echo "等待 $WAIT 秒后重试..."
        sleep $WAIT
    fi

    ((ATTEMPT++))
done

if [[ $DOWNLOAD_SUCCESS -eq 0 ]]; then
    echo -e "${RED}错误: 视频下载失败 (已尝试 $MAX_ATTEMPTS 次)${NC}"
    exit 1
fi

# 验证视频文件
if [[ ! -f "$WORK_DIR/original.mp4" ]]; then
    echo -e "${RED}错误: 视频文件不存在${NC}"
    exit 1
fi

VIDEO_SIZE=$(du -h "$WORK_DIR/original.mp4" | cut -f1)
echo "视频大小: $VIDEO_SIZE"

# 第3步: 提取关键帧
echo -e "${YELLOW}[3/5] 提取关键帧...${NC}"
mkdir -p "$WORK_DIR/frames"

if ! ffmpeg -i "$WORK_DIR/original.mp4" -vf "fps=1" "$WORK_DIR/frames/frame_%03d.jpg" \
    -loglevel error 2>"$WORK_DIR/frames.log"; then
    echo -e "${RED}错误: 关键帧提取失败${NC}"
    cat "$WORK_DIR/frames.log"
    exit 1
fi

FRAME_COUNT=$(ls -1 "$WORK_DIR/frames/"*.jpg 2>/dev/null | wc -l)
echo -e "${GREEN}✓ 提取了 $FRAME_COUNT 帧${NC}"

# 第4步: 提取音频
echo -e "${YELLOW}[4/5] 提取音频...${NC}"

if ! ffmpeg -i "$WORK_DIR/original.mp4" -vn -acodec pcm_s16le "$WORK_DIR/audio.wav" \
    -loglevel error 2>"$WORK_DIR/audio.log"; then
    echo -e "${RED}错误: 音频提取失败${NC}"
    cat "$WORK_DIR/audio.log"
    exit 1
fi

AUDIO_SIZE=$(du -h "$WORK_DIR/audio.wav" | cut -f1)
echo -e "${GREEN}✓ 音频提取成功 (大小: $AUDIO_SIZE)${NC}"

# 第5步: 获取视频元数据
echo -e "${YELLOW}[5/5] 获取视频元数据...${NC}"

# 使用ffprobe获取详细信息
METADATA=$(ffprobe -v error -select_streams v:0 -show_entries \
    stream=width,height,r_frame_rate,duration \
    -of default=noprint_wrappers=1:nokey=1:noprint_wrappers=1 \
    "$WORK_DIR/original.mp4" 2>/dev/null)

# 获取持续时间 (秒)
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$WORK_DIR/original.mp4" 2>/dev/null || echo "0")

# 获取分辨率
RESOLUTION=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=p=0 "$WORK_DIR/original.mp4" 2>/dev/null || echo "0,0")

# 获取比特率
BITRATE=$(ffprobe -v error -show_entries format=bit_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$WORK_DIR/original.mp4" 2>/dev/null || echo "0")

# 创建JSON元数据文件（用 python3 + 环境变量，避免 JSON 注入）
SOURCE_URL="$URL" \
DOWNLOAD_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
VIDEO_DUR="${DURATION:-0}" \
VIDEO_RES="$RESOLUTION" \
VIDEO_BR="${BITRATE:-0}" \
FCOUNT="$FRAME_COUNT" \
python3 -c "
import json, os
data = {
    'source_url': os.environ['SOURCE_URL'],
    'download_timestamp': os.environ['DOWNLOAD_TS'],
    'video_file': 'original.mp4',
    'duration_seconds': float(os.environ['VIDEO_DUR']),
    'resolution': os.environ['VIDEO_RES'],
    'bitrate_bps': int(os.environ['VIDEO_BR']),
    'frame_count': int(os.environ['FCOUNT']),
    'audio_file': 'audio.wav',
    'frames_directory': 'frames'
}
print(json.dumps(data, ensure_ascii=False, indent=2))
" > "$WORK_DIR/metadata.json"

echo -e "${GREEN}✓ 元数据已保存${NC}"

# 计算执行时间
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo -e "${GREEN}=== 下载和提取完成 ===${NC}"
echo "总耗时: ${MINUTES}m ${SECONDS}s"
echo "输出位置: $WORK_DIR"
echo ""

exit 0
