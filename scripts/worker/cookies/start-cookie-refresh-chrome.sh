#!/usr/bin/env bash
# scripts/worker/cookies/start-cookie-refresh-chrome.sh
# 启动 cookie-refresh 专用 Chrome instance (端口 9224, 独立 user-data-dir).
# 由 LaunchAgent com.tiancai.cookie-refresh-chrome 在 GUI 登录时拉起.
# 抖音 anti-bot 加强后, 用 yt-dlp 下载已不可行, material-ingest worker 通过
# CDP 拿真实 mp4 URL + curl 下载. 这个 Chrome 必须长期跑.
#
# 不复用 jimeng 的 9222 CDP Chrome, 因为它跟 jimeng 登录态绑定, 共用会污染.
#
# 2026-05-17 fix: CDP check 失败 + 进程存在时不再无脑 kill, 给 30s 恢复窗口.
# 之前 KeepAlive + ThrottleInterval=30 让脚本每 30s 跑一次, CDP 偶发抖动 (Chrome
# GC pause / macOS sleep-wake / CDP 启动期) 就触发 pkill+restart Chrome → 实测
# Chrome 应用窗口每 30s 闪一次, 影响 macking GUI 使用 + 浪费 CPU/IO.
# 修法: 双层重试 (step 1 curl 3 次容忍瞬时, step 2 进程活着时再等 30s 恢复).

set -uo pipefail  # 不要 -e, 已经存在的进程让 exit 0

CDP_PORT=9224
USER_DATA_DIR="$HOME/chrome-cookie-refresh-profile"
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
LOG_TAG="[cookie-refresh-chrome]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG $*"; }

# CDP 健康检查 retry helper. max_tries 次, 每次间隔 1s.
# 返回 0=healthy, 1=unhealthy.
cdp_healthy() {
    local max_tries="${1:-1}"
    local i
    for ((i=1; i<=max_tries; i++)); do
        if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
            return 0
        fi
        [ "$i" -lt "$max_tries" ] && sleep 1
    done
    return 1
}

if [ "${1:-}" = "--wait" ]; then
    log "Waiting 12s for GUI session..."
    sleep 12
fi

# 1. 快速健康检查 (3 次容忍瞬时抖动)
if cdp_healthy 3; then
    log "CDP active on port $CDP_PORT"
    exit 0
fi

# 2. CDP 暂时不响应, 但 Chrome 进程在 → 给 30s 恢复窗口, 不无脑 pkill.
#    错杀 Chrome 是导致每 30s 反复重启的根因.
if pgrep -f "chrome-cookie-refresh-profile" > /dev/null 2>&1; then
    log "Chrome process alive but CDP unresponsive, waiting up to 30s for recovery..."
    if cdp_healthy 30; then
        log "CDP recovered without restart"
        exit 0
    fi
    log "Still unresponsive after 30s, killing stale process..."
    pkill -f "chrome-cookie-refresh-profile" 2>/dev/null || true
    sleep 3
fi

mkdir -p "$USER_DATA_DIR"

# 3. 启 Chrome, GUI 模式 (Aqua session 必需). 不 headless 是因为抖音 anti-bot 检测 webdriver.
#    nohup + < /dev/null + disown 三连让 Chrome 脱离脚本进程组, 否则脚本 exit
#    时 launchd 把整个 process group SIGTERM, 把 Chrome 也带走 — 实测这是
#    "Chrome 每 30s 反复重启" 的真正根因 (5/17 修复). pgrep 看进程消失 = 验证.
log "Starting Chrome with CDP on port $CDP_PORT..."
nohup "$CHROME" \
    --remote-debugging-port="$CDP_PORT" \
    --user-data-dir="$USER_DATA_DIR" \
    --no-first-run \
    --no-default-browser-check \
    --disable-features=ChromeWhatsNewUI \
    --window-size=1280,800 \
    < /dev/null > /tmp/cookie-refresh-chrome.log 2>&1 &
disown

# 4. 等 CDP 起来
if cdp_healthy 10; then
    log "CDP ready"
    exit 0
fi
log "ERROR: CDP did not come up after 10s"
exit 1
