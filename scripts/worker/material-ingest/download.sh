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

if [[ -z "$CHANNEL_HANDLE" ]] || [[ "$CHANNEL_HANDLE" == "manual" ]]; then
  SUB_DIR="manual-uploads/general"
else
  SUB_DIR="youtube-channels/${CHANNEL_HANDLE}/raw"
fi

REL_PATH="${SUB_DIR}/${VIDEO_ID}.mp4"
TARGET_DIR_ABS="${MATERIAL_LIBRARY_PATH}/${SUB_DIR}"
TARGET_ABS="${MATERIAL_LIBRARY_PATH}/${REL_PATH}"

download_local() {
  mkdir -p "$TARGET_DIR_ABS"
  local args=(
    --no-warnings
    --no-progress
    -f 'bv*[height<=720]+ba/b[height<=720]'
    --merge-output-format mp4
    -o "$TARGET_ABS"
  )
  # Cookie strategy (统一用 cookies 文件, 不依赖浏览器 GUI):
  # - douyin / tiktok: YT_DLP_DOUYIN_COOKIES_PATH (浏览器扩展导出的 Netscape txt)
  # - 其他 (youtube etc): YT_DLP_COOKIES_PATH (cookie-export LaunchAgent 自动刷新)
  if [[ "$SOURCE_URL" =~ douyin\.com|tiktok\.com ]]; then
    if [[ -n "${YT_DLP_DOUYIN_COOKIES_PATH:-}" ]] && [[ -f "$YT_DLP_DOUYIN_COOKIES_PATH" ]]; then
      args+=(--cookies "$YT_DLP_DOUYIN_COOKIES_PATH")
    else
      echo "[download.sh] WARN: YT_DLP_DOUYIN_COOKIES_PATH 未设置或文件不存在, 尝试无 cookie 下载" >&2
    fi
  elif [[ -n "${YT_DLP_COOKIES_PATH:-}" ]] && [[ -f "$YT_DLP_COOKIES_PATH" ]]; then
    args+=(--cookies "$YT_DLP_COOKIES_PATH")
  fi
  yt-dlp "${args[@]}" "$SOURCE_URL" >&2
}

download_remote() {
  local ssh_target="${MACKING_USER:-zjw-mini}@${MACKING_HOST}"
  local cookies_flag=""
  if [[ "$SOURCE_URL" =~ douyin\.com|tiktok\.com ]]; then
    if [[ -n "${YT_DLP_DOUYIN_COOKIES_PATH:-}" ]]; then
      cookies_flag="--cookies ${YT_DLP_DOUYIN_COOKIES_PATH}"
    fi
  elif [[ -n "${YT_DLP_COOKIES_PATH:-}" ]]; then
    cookies_flag="--cookies ${YT_DLP_COOKIES_PATH}"
  fi
  ssh "$ssh_target" bash -c "'
    set -euo pipefail
    mkdir -p ${TARGET_DIR_ABS@Q}
    yt-dlp --no-warnings --no-progress \
      -f \"bv*[height<=720]+ba/b[height<=720]\" \
      --merge-output-format mp4 \
      $cookies_flag \
      -o ${TARGET_ABS@Q} \
      ${SOURCE_URL@Q}
  '" >&2
}

if [[ "$MACKING_HOST" == "localhost" ]] || [[ "$MACKING_HOST" == "127.0.0.1" ]]; then
  download_local
else
  download_remote
fi

echo "$REL_PATH"
