#!/usr/bin/env bash
# scripts/worker/material-ingest/download.sh
# 下载单条视频到 MATERIAL_LIBRARY_PATH 下.
# 本地 (MACKING_HOST=localhost) 直接 yt-dlp.
# 远程 worker 则 SSH 代理到 macking.
#
# Usage:
#   download.sh <source_url> <channel_handle_or_manual> <video_id>
# Output:
#   stdout: 相对路径 (e.g. "youtube-channels/@catdramatv/raw/abc.mp4")
#   非 0 exit code 视为失败

set -euo pipefail

SOURCE_URL="$1"
CHANNEL_HANDLE="$2"
VIDEO_ID="$3"

: "${MACKING_HOST:?MACKING_HOST required}"
: "${MATERIAL_LIBRARY_PATH:?MATERIAL_LIBRARY_PATH required}"
: "${YT_DLP_COOKIES_PATH:=}"
: "${YT_DLP_DOUYIN_COOKIES_PATH:=}"
# CDP-based downloader for douyin (yt-dlp 抖音 extractor 在 anti-bot 加强后已废,
# 用 CDP Chrome 直接拿真实 mp4 CDN URL + curl 下载替代). 9224 是 cookie-refresh
# 专用 Chrome 的端口, 不影响 jimeng CDP (9222).
: "${CDP_PORT_DOUYIN:=9224}"
: "${CDP_EXTRACT_SCRIPT:=$(dirname "${BASH_SOURCE[0]}")/cdp-extract-douyin-url.mjs}"

if [[ -z "$CHANNEL_HANDLE" ]] || [[ "$CHANNEL_HANDLE" == "manual" ]]; then
  SUB_DIR="manual-uploads/general"
else
  SUB_DIR="youtube-channels/${CHANNEL_HANDLE}/raw"
fi

REL_PATH="${SUB_DIR}/${VIDEO_ID}.mp4"
TARGET_DIR_ABS="${MATERIAL_LIBRARY_PATH}/${SUB_DIR}"
TARGET_ABS="${MATERIAL_LIBRARY_PATH}/${REL_PATH}"

download_local_yt_dlp() {
  mkdir -p "$TARGET_DIR_ABS"
  local args=(
    --no-warnings
    --no-progress
    -f 'bv*[height<=720]+ba/b[height<=720]'
    --merge-output-format mp4
    -o "$TARGET_ABS"
  )
  # Cookie strategy (统一用 cookies 文件, 不依赖浏览器 GUI):
  # - tiktok: YT_DLP_DOUYIN_COOKIES_PATH (浏览器扩展导出的 Netscape txt) — 沿用历史 env 名
  # - 其他 (youtube etc): YT_DLP_COOKIES_PATH (cookie-export LaunchAgent 自动刷新)
  if [[ "$SOURCE_URL" =~ tiktok\.com ]]; then
    if [[ -n "${YT_DLP_DOUYIN_COOKIES_PATH:-}" ]] && [[ -f "$YT_DLP_DOUYIN_COOKIES_PATH" ]]; then
      args+=(--cookies "$YT_DLP_DOUYIN_COOKIES_PATH")
    fi
  elif [[ -n "${YT_DLP_COOKIES_PATH:-}" ]] && [[ -f "$YT_DLP_COOKIES_PATH" ]]; then
    args+=(--cookies "$YT_DLP_COOKIES_PATH")
  fi
  yt-dlp "${args[@]}" "$SOURCE_URL" >&2
}

# 抖音专用: CDP 拿真实 mp4 CDN URL → curl 下载.
# yt-dlp 的 douyin extractor 在抖音 anti-bot 加强后废了, 即使带完整登录态 cookies
# 也会因为缺 X-Bogus / msToken signature 被拒.
download_local_douyin_cdp() {
  mkdir -p "$TARGET_DIR_ABS"
  if ! command -v node >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/node ]]; then
    echo "[download.sh] ERROR: node not found, douyin CDP path needs node 22+" >&2
    return 1
  fi
  local NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
  command -v node >/dev/null 2>&1 && NODE_BIN="$(command -v node)"

  echo "[download.sh] douyin: extracting mp4 URL via CDP (port $CDP_PORT_DOUYIN)..." >&2
  local mp4_url
  mp4_url="$(CDP_PORT="$CDP_PORT_DOUYIN" "$NODE_BIN" "$CDP_EXTRACT_SCRIPT" "$SOURCE_URL")" || {
    echo "[download.sh] ERROR: CDP extract failed (exit $?). Cookie-refresh Chrome on port $CDP_PORT_DOUYIN running?" >&2
    return 1
  }
  if [[ -z "$mp4_url" ]]; then
    echo "[download.sh] ERROR: CDP returned empty URL" >&2
    return 1
  fi
  echo "[download.sh] douyin: got mp4 URL, curl downloading..." >&2
  curl -sf -L \
    -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0 Safari/537.36' \
    -e 'https://www.douyin.com/' \
    -o "$TARGET_ABS" \
    "$mp4_url" || {
    echo "[download.sh] ERROR: curl download failed (exit $?)" >&2
    return 1
  }
  # sanity check: 至少 50KB, 否则可能是错误页或被 redirect 到 anti-bot 验证
  local size
  size="$(stat -f%z "$TARGET_ABS" 2>/dev/null || stat -c%s "$TARGET_ABS" 2>/dev/null || echo 0)"
  if [[ "$size" -lt 50000 ]]; then
    echo "[download.sh] ERROR: downloaded file too small ($size bytes), likely anti-bot block" >&2
    rm -f "$TARGET_ABS"
    return 1
  fi
  echo "[download.sh] douyin: downloaded $size bytes" >&2
}

download_local() {
  if [[ "$SOURCE_URL" =~ douyin\.com ]]; then
    download_local_douyin_cdp
  else
    download_local_yt_dlp
  fi
}

download_remote() {
  local ssh_target="${MACKING_USER:-zjw-mini}@${MACKING_HOST}"
  # 远程 worker 不重复实现下载逻辑, 直接 SSH 到 macking 让它本地跑同款 download.sh.
  # macking 上的 download.sh 通过 worker-repo git pull 跟主仓库同步 (10 分钟一次).
  # 强制 MACKING_HOST=localhost 让 macking 走 download_local 分支.
  local remote_script="${REMOTE_DOWNLOAD_SCRIPT:-\$HOME/worker-code/scripts/worker/material-ingest/download.sh}"
  ssh "$ssh_target" \
    "MACKING_HOST=localhost MATERIAL_LIBRARY_PATH=${MATERIAL_LIBRARY_PATH@Q} \
     YT_DLP_COOKIES_PATH=${YT_DLP_COOKIES_PATH:-} \
     YT_DLP_DOUYIN_COOKIES_PATH=${YT_DLP_DOUYIN_COOKIES_PATH:-} \
     CDP_PORT_DOUYIN=${CDP_PORT_DOUYIN} \
     bash $remote_script ${SOURCE_URL@Q} ${CHANNEL_HANDLE@Q} ${VIDEO_ID@Q}" >&2
}

if [[ "$MACKING_HOST" == "localhost" ]] || [[ "$MACKING_HOST" == "127.0.0.1" ]]; then
  download_local
else
  download_remote
fi

# 下载完顺便跑 ffprobe 实测 duration, 写到 .duration sidecar 文件 + stderr 显示一行.
# main.sh 读 sidecar 文件拿 duration. 必须在 macking 端跑 (mp4 在 macking 本地).
# ffprobe 不在 PATH 时 fallback 到 /opt/homebrew/bin (brew 安装路径).
FFPROBE=""
if command -v ffprobe >/dev/null 2>&1; then
  FFPROBE="ffprobe"
elif [[ -x /opt/homebrew/bin/ffprobe ]]; then
  FFPROBE="/opt/homebrew/bin/ffprobe"
elif [[ -x /usr/local/bin/ffprobe ]]; then
  FFPROBE="/usr/local/bin/ffprobe"
fi
if [[ -n "$FFPROBE" ]] && [[ -f "$TARGET_ABS" ]]; then
  if [[ "$MACKING_HOST" == "localhost" ]] || [[ "$MACKING_HOST" == "127.0.0.1" ]]; then
    # macking 本地: 直接跑 ffprobe
    DUR_VAL=$("$FFPROBE" -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$TARGET_ABS" 2>/dev/null || true)
  else
    # 远程: 走 SSH 让 macking 上的 ffprobe 跑 (这条路实际不会触发, 因为 download_remote
    # 已经 ssh 到 macking 调 macking 自己的 download.sh, 那次会走 localhost 分支)
    DUR_VAL=""
  fi
  if [[ -n "$DUR_VAL" ]] && [[ "$DUR_VAL" != "N/A" ]]; then
    echo "$DUR_VAL" > "${TARGET_ABS}.duration"
    echo "[download.sh] ffprobe duration: ${DUR_VAL}s" >&2
  fi
fi

echo "$REL_PATH"
