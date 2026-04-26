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

# __skip_download__ 模式: 视频已存在于 WORK_DIR/original.mp4，只做帧提取/音频/metadata
if [[ "$URL" == "__skip_download__" ]]; then
    if [[ ! -f "$WORK_DIR/original.mp4" ]]; then
        echo -e "${RED}错误: skip_download 模式但 original.mp4 不存在${NC}"
        exit 1
    fi
    echo -e "${GREEN}=== 跳过下载，提取帧/音频/元数据 ===${NC}"
    # 跳到第3步（提取帧）— 用 exec 跳转到后半段
    VIDEO_SIZE=$(du -h "$WORK_DIR/original.mp4" | cut -f1)
    echo "视频大小: $VIDEO_SIZE"
    SKIP_DOWNLOAD=1
fi

if [[ "${SKIP_DOWNLOAD:-0}" -eq 0 ]]; then
# ── 多平台 cookie 策略 ──
# 核心: macking Safari 是所有平台 cookie 的权威源
#   - yt-dlp --cookies-from-browser safari 在 macOS 15+ 有 bug（容器化路径读不全）
#   - yt-dlp --cookies-from-browser chrome 在 SSH 下无法解密 Keychain
#   - 解决: safari_cookies_export.py 直接解析 binarycookies → 临时文件 → --cookies
#   - 每次下载实时提取，始终最新，不需要定期导出
#
# 要求: macking 的 Safari 登录各视频平台 (YouTube/抖音/TikTok/B站/Facebook)

# Safari binarycookies 路径 (macOS 15+ 容器化路径优先)
find_safari_cookies() {
    for p in \
        "$HOME/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies" \
        "$HOME/Library/Cookies/Cookies.binarycookies"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# 平台 → cookie 域名过滤 (用普通变量, 兼容 bash 3.x)
PLATFORM_DOMAINS_youtube="youtube.com|google.com|googlevideo.com|googleapis.com"
PLATFORM_DOMAINS_douyin="douyin.com|iesdouyin.com|bytedance.com|toutiao.com|snssdk.com|amemv.com"
PLATFORM_DOMAINS_tiktok="tiktok.com|bytedance.com|musical.ly"
PLATFORM_DOMAINS_bilibili="bilibili.com|bilivideo.com|b23.tv"
PLATFORM_DOMAINS_facebook="facebook.com|fbcdn.net|fb.com|instagram.com"

# 从 URL 识别平台
detect_platform() {
    local url="$1"
    case "$url" in
        *douyin.com*|*iesdouyin.com*)  echo "douyin"   ;;
        *tiktok.com*|*vt.tiktok.com*) echo "tiktok"   ;;
        *youtube.com*|*youtu.be*)     echo "youtube"   ;;
        *bilibili.com*|*b23.tv*)      echo "bilibili"  ;;
        *facebook.com*|*fb.watch*)    echo "facebook"  ;;
        *)                            echo "unknown"   ;;
    esac
}

# 从 Safari binarycookies 实时提取平台 cookie → 临时 Netscape 文件
# 返回: cookie 文件路径 (调用方负责清理; 文件名含 PID，进程退出后可 rm /tmp/safari_cookies_*)
extract_safari_cookies() {
    local platform="$1"
    local scripts_dir="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"

    local safari_bin
    safari_bin=$(find_safari_cookies) || return 1

    local export_script="$scripts_dir/safari_cookies_export.py"
    [[ -f "$export_script" ]] || return 1

    local tmp_bin="/tmp/safari_ck_$$.bin"
    local tmp_all="/tmp/safari_ck_all_$$.txt"
    local tmp_out="/tmp/safari_ck_${platform}_$$.txt"

    cp "$safari_bin" "$tmp_bin" 2>/dev/null || return 1
    python3 "$export_script" "$tmp_bin" "$tmp_all" 2>/dev/null || { rm -f "$tmp_bin"; return 1; }
    rm -f "$tmp_bin"

    # 按平台域名过滤
    local domains_var="PLATFORM_DOMAINS_${platform}"
    local domains="${!domains_var:-}"
    if [[ -z "$domains" ]]; then
        mv "$tmp_all" "$tmp_out"
    else
        local pattern
        pattern=$(echo "$domains" | tr '|' '\n' | sed 's/\./\\./g' | paste -sd'|' -)
        {
            echo "# Netscape HTTP Cookie File"
            grep -iE "($pattern)" "$tmp_all" || true
        } > "$tmp_out"
        rm -f "$tmp_all"
    fi

    local count
    count=$(grep -c $'\t' "$tmp_out" 2>/dev/null || echo 0)
    if [[ $count -le 1 ]]; then
        rm -f "$tmp_out"
        return 1
    fi

    echo "$tmp_out"
}

# 构建本机 yt-dlp cookie 参数
resolve_cookie_args() {
    local platform="$1"

    # 1. 平台专属环境变量 (向后兼容 YT_COOKIES_FILE)
    local env_file=""
    case "$platform" in
        youtube)  env_file="${YT_COOKIES_FILE:-}" ;;
        douyin)   env_file="${DOUYIN_COOKIES_FILE:-}" ;;
        tiktok)   env_file="${TIKTOK_COOKIES_FILE:-}" ;;
        bilibili) env_file="${BILIBILI_COOKIES_FILE:-}" ;;
        facebook) env_file="${FB_COOKIES_FILE:-}" ;;
    esac
    if [[ -n "$env_file" ]] && [[ -f "$env_file" ]]; then
        echo "--cookies $env_file"
        return
    fi

    # 2. macking 同步过来的 Netscape cookie 文件 (2026-04-21 起的新路径).
    # macking 端 refresh-youtube-cookie.sh 用 Chrome 导出, sync-cookies-to-workers.sh 每 5min 推到这里.
    # 纯文本不受 macOS 沙盒 TCC 挡, 比 Safari binarycookies 稳.
    # 目前只 YouTube 有这个 synced 文件; 其他平台继续走 Safari fallback.
    if [[ "$platform" == "youtube" ]]; then
        local synced="$HOME/.cache/worker-cookies/youtube.cookies.txt"
        if [[ -s "$synced" ]]; then
            echo "--cookies $synced"
            return
        fi
    fi

    # 3. 实时从 Safari binarycookies 提取 (其他平台主路径)
    local cookie_file
    if cookie_file=$(extract_safari_cookies "$platform" 2>/dev/null); then
        echo "--cookies $cookie_file"
        return
    fi

    # 4. 兜底: yt-dlp 自己尝试读浏览器
    echo "--cookies-from-browser safari"
}

PLATFORM=$(detect_platform "$URL")

echo -e "${GREEN}=== 视频下载和提取开始 ===${NC}"
echo "时间戳: $(date '+%Y-%m-%d %H:%M:%S')"
echo "视频URL: $URL"
echo "平台: $PLATFORM"
echo "工作目录: $WORK_DIR"

# 第1步: 创建工作目录
echo -e "${YELLOW}[1/5] 创建工作目录...${NC}"
if ! mkdir -p "$WORK_DIR"; then
    echo -e "${RED}错误: 无法创建工作目录 $WORK_DIR${NC}"
    exit 1
fi

# 第2步: 下载视频
# 下载器链: yt-dlp (通用) → lux (国内平台 fallback, 抖音/B站反爬绕过)
# 代理策略: 默认走系统代理 7890 (Clash/Verge 规则模式自己决定每个域名走代理还是直连)
echo -e "${YELLOW}[2/5] 下载视频...${NC}"

MACKING_HOST="${MACKING_HOST:?MACKING_HOST not set}"
MACKING_USER="${MACKING_USER:-zjw-mini}"

# 2026-04-26: 默认走系统代理 7890. 4-21 那次"东莞直连能通 + Clash MITM 触发 SSL EOF"的
# 假设今天不再成立 (东莞直连 YouTube TCP timeout, 走代理反而稳). Clash 规则模式自己
# 路由 douyin/bilibili 直连, youtube/google 走代理. 保留 DOWNLOAD_USE_PROXY=0 作为
# 强制直连的 escape hatch (测试 / 未来 GFW 政策变化时备用).
PROXY_ENV='HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890'
if [[ "${DOWNLOAD_USE_PROXY:-1}" == "0" ]]; then
    PROXY_ENV='no_proxy="*" http_proxy="" https_proxy="" HTTPS_PROXY="" HTTP_PROXY=""'
fi

# ── 本机下载函数 ──
try_download_local() {
    local cookie_args
    cookie_args=$(resolve_cookie_args "$PLATFORM")
    echo "[cookie] 本机策略: $cookie_args"

    # 尝试 1: yt-dlp
    echo "[下载器] yt-dlp..."
    if eval "$PROXY_ENV yt-dlp $cookie_args --merge-output-format mp4 -o '$WORK_DIR/original.mp4' '$URL'" 2>"$WORK_DIR/download.log"; then
        echo -e "${GREEN}✓ 下载成功（本机 yt-dlp）${NC}"
        return 0
    fi

    # 尝试 2: lux (国内平台 fallback，不支持 cookie 参数)
    if command -v lux >/dev/null 2>&1; then
        echo "[下载器] yt-dlp 失败，尝试 lux..."
        if eval "$PROXY_ENV lux -o '$WORK_DIR' -O original '$URL'" 2>>"$WORK_DIR/download.log"; then
            # lux 输出文件名可能带扩展名，统一重命名
            local lux_file
            lux_file=$(ls "$WORK_DIR"/original.* 2>/dev/null | head -1)
            if [[ -n "$lux_file" ]] && [[ "$lux_file" != "$WORK_DIR/original.mp4" ]]; then
                mv "$lux_file" "$WORK_DIR/original.mp4"
            fi
            if [[ -f "$WORK_DIR/original.mp4" ]]; then
                echo -e "${GREEN}✓ 下载成功（本机 lux）${NC}"
                return 0
            fi
        fi
    fi

    return 1
}

# ── macking 代理下载函数 ──
try_download_macking() {
    echo "[DEBUG] Testing SSH to macking: $MACKING_USER@$MACKING_HOST"
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST" true 2>&1 || return 1

    echo "通过 macking ($MACKING_HOST) 代理下载..."
    local remote_dir="/tmp/yt-dl-$$-${RANDOM}"

    # 在 macking 上执行: cookie 提取 → yt-dlp → lux fallback
    # 2026-04-26: 同步主流程, 默认走 macking 系统代理 7890. 4-21 的 ClashX MITM 问题不再出现,
    # 实测走代理稳定. Clash 自己按规则路由 (douyin/bilibili 直连, youtube 走代理).
    local remote_proxy_env='export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890'
    if [[ "${DOWNLOAD_USE_PROXY:-1}" == "0" ]]; then
        remote_proxy_env='export no_proxy="*" http_proxy="" https_proxy="" HTTPS_PROXY="" HTTP_PROXY=""'
    fi

    REMOTE_SCRIPT="
export PATH=/opt/homebrew/bin:\$PATH
$remote_proxy_env
mkdir -p $remote_dir
SCRIPTS=\$HOME/worker-code/scripts/worker
PLATFORM='$PLATFORM'

# Cookie 获取: YouTube 优先用 refresh 脚本刚导出的 Netscape 文件 (2026-04-21 之后),
# 其他平台继续走 Safari binarycookies 提取.
CK_FILE=''
CHROME_COOKIES=\"\$HOME/production/shared/cookies/youtube.cookies.txt\"
if [ \"\$PLATFORM\" = 'youtube' ] && [ -s \"\$CHROME_COOKIES\" ]; then
    CK_FILE=\"\$CHROME_COOKIES\"
fi

if [ -z \"\$CK_FILE\" ]; then
    SAFARI_BIN=''
    for p in \"\$HOME/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies\" \"\$HOME/Library/Cookies/Cookies.binarycookies\"; do
        [ -f \"\$p\" ] && SAFARI_BIN=\"\$p\" && break
    done
    if [ -n \"\$SAFARI_BIN\" ] && [ -f \"\$SCRIPTS/safari_cookies_export.py\" ]; then
        CK_TMP=\"/tmp/mck_dl_\${RANDOM}\"
        cp \"\$SAFARI_BIN\" \"\${CK_TMP}.bin\" 2>/dev/null
        python3 \"\$SCRIPTS/safari_cookies_export.py\" \"\${CK_TMP}.bin\" \"\${CK_TMP}.txt\" 2>/dev/null
        rm -f \"\${CK_TMP}.bin\"
        [ -s \"\${CK_TMP}.txt\" ] && CK_FILE=\"\${CK_TMP}.txt\"
    fi
fi

# 尝试 1: yt-dlp (用 = 连接 --cookies=FILE，避免 zsh 不做 word splitting)
CK_ARGS=''
[ -n \"\$CK_FILE\" ] && CK_ARGS=\"--cookies=\$CK_FILE\"
# Cleanup 只删 /tmp 临时文件, persistent Chrome cookie (\$HOME/production/...) 留着
cleanup_ck() {
    case \"\$CK_FILE\" in
        /tmp/*) rm -f \"\$CK_FILE\" ;;
    esac
}

echo \"[下载器] yt-dlp (cookie: \$CK_ARGS)\"
if yt-dlp \$CK_ARGS --merge-output-format mp4 -o '$remote_dir/video.%(ext)s' '$URL' 2>&1; then
    cleanup_ck
    ls $remote_dir/*.mp4
    exit 0
fi

# 尝试 2: lux (不支持 cookie 参数，仅用于国内平台 fallback)
if command -v lux >/dev/null 2>&1; then
    echo \"[下载器] yt-dlp 失败，尝试 lux...\"
    if lux -o '$remote_dir' -O video '$URL' 2>&1; then
        # lux 文件名可能带后缀，找到 mp4
        F=\$(ls $remote_dir/video.* 2>/dev/null | head -1)
        [ -n \"\$F\" ] && [ \"\$F\" != '$remote_dir/video.mp4' ] && mv \"\$F\" '$remote_dir/video.mp4'
        cleanup_ck
        ls $remote_dir/*.mp4
        exit 0
    fi
fi

cleanup_ck
exit 1
"
    if ssh -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST" "$REMOTE_SCRIPT" \
        2>"$WORK_DIR/download.log"; then
        REMOTE_FILE=$(ssh -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST" "ls $remote_dir/*.mp4 2>/dev/null | head -1")
        if [[ -n "$REMOTE_FILE" ]]; then
            if scp -o StrictHostKeyChecking=no "$MACKING_USER@$MACKING_HOST:$REMOTE_FILE" "$WORK_DIR/original.mp4" 2>/dev/null; then
                ssh "$MACKING_USER@$MACKING_HOST" "rm -rf '$remote_dir'" 2>/dev/null
                echo -e "${GREEN}✓ 下载成功（macking 代理）${NC}"
                return 0
            fi
        fi
    fi
    ssh "$MACKING_USER@$MACKING_HOST" "rm -rf '$remote_dir'" 2>/dev/null
    echo "macking 代理下载失败"
    return 1
}

# ── 下载主循环 ──
MAX_ATTEMPTS=3
ATTEMPT=1
DOWNLOAD_SUCCESS=0

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
    echo "下载尝试 $ATTEMPT/$MAX_ATTEMPTS..."

    if [[ "$MACKING_HOST" == "localhost" || "$MACKING_HOST" == "127.0.0.1" ]]; then
        echo "本机模式（MACKING_HOST=${MACKING_HOST}）"
        if try_download_local; then
            DOWNLOAD_SUCCESS=1
            break
        fi
    else
        # 远程 worker: 2026-04-26 翻转顺序为本机优先, macking 当 fallback.
        # 原因: (1) 本机更快, 不依赖反向 SSH; (2) macking 一挂全部 worker 瘫.
        # 现在每个 worker 自带 Clash, 本机能独立下载.
        if try_download_local; then
            DOWNLOAD_SUCCESS=1
            break
        fi
        echo "尝试 macking 代理 fallback..."
        if try_download_macking; then
            DOWNLOAD_SUCCESS=1
            break
        fi
    fi

    DOWNLOAD_ERROR=$(cat "$WORK_DIR/download.log" 2>/dev/null || echo "未知错误")

    # 终端错误: 不可重试
    if echo "$DOWNLOAD_ERROR" | grep -qiE "(地理限制|年龄限制|不可用|私密|已删除|geo.restricted|private|removed)"; then
        echo -e "${RED}✗ 终端错误: $DOWNLOAD_ERROR${NC}"
        exit 1
    fi
    # Cookie 错误提示
    if echo "$DOWNLOAD_ERROR" | grep -qiE "(cookie|Fresh cookies|login required|sign in)"; then
        echo -e "${YELLOW}⚠ ${PLATFORM} 需要 cookie — 请在 macking Safari 登录该平台${NC}"
    fi

    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
        WAIT=$((5 * ATTEMPT))
        echo "等待 $WAIT 秒后重试..."
        sleep $WAIT
    fi

    ((ATTEMPT++))
done

if [[ $DOWNLOAD_SUCCESS -eq 0 ]]; then
    echo -e "${RED}错误: 视频下载失败 (平台: ${PLATFORM}, 已尝试 $MAX_ATTEMPTS 次)${NC}"
    cat "$WORK_DIR/download.log" 2>/dev/null | tail -5
    exit 1
fi

# 验证视频文件
if [[ ! -f "$WORK_DIR/original.mp4" ]]; then
    echo -e "${RED}错误: 视频文件不存在${NC}"
    exit 1
fi

VIDEO_SIZE=$(du -h "$WORK_DIR/original.mp4" | cut -f1)
echo "视频大小: $VIDEO_SIZE"

fi  # end SKIP_DOWNLOAD guard

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
