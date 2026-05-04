#!/usr/bin/env bash
# scripts/worker/cookies/start-cookie-refresh-chrome.sh
# 启动 cookie-refresh 专用 Chrome instance (端口 9224, 独立 user-data-dir).
# 由 LaunchAgent com.tiancai.cookie-refresh-chrome 在 GUI 登录时拉起.
# 抖音 anti-bot 加强后, 用 yt-dlp 下载已不可行, material-ingest worker 通过
# CDP 拿真实 mp4 URL + curl 下载. 这个 Chrome 必须长期跑.
#
# 不复用 jimeng 的 9222 CDP Chrome, 因为它跟 jimeng 登录态绑定, 共用会污染.

set -uo pipefail  # 不要 -e, 已经存在的进程让 exit 0

CDP_PORT=9224
USER_DATA_DIR="$HOME/chrome-cookie-refresh-profile"
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
LOG_TAG="[cookie-refresh-chrome]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG $*"; }

if [ "${1:-}" = "--wait" ]; then
    log "Waiting 12s for GUI session..."
    sleep 12
fi

# 1. 已经在跑就退出
if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    log "CDP already active on port $CDP_PORT"
    exit 0
fi

# 2. 杀掉孤儿进程 (端口被占但 health check 失败的情况)
if pgrep -f "chrome-cookie-refresh-profile" > /dev/null 2>&1; then
    log "Killing stale chrome-cookie-refresh-profile process..."
    pkill -f "chrome-cookie-refresh-profile" 2>/dev/null || true
    sleep 3
fi

mkdir -p "$USER_DATA_DIR"

# 3. 启 Chrome, GUI 模式 (Aqua session 必需). 不 headless 是因为抖音 anti-bot 检测 webdriver.
log "Starting Chrome with CDP on port $CDP_PORT..."
"$CHROME" \
    --remote-debugging-port="$CDP_PORT" \
    --user-data-dir="$USER_DATA_DIR" \
    --no-first-run \
    --no-default-browser-check \
    --disable-features=ChromeWhatsNewUI \
    --window-size=1280,800 \
    > /tmp/cookie-refresh-chrome.log 2>&1 &

# 4. 等 CDP 起来
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
        log "CDP ready after ${i}s"
        exit 0
    fi
done
log "ERROR: CDP did not come up after 10s"
exit 1
