#!/bin/bash
# scripts/worker/cookies/refresh-cookies.sh
# 用 yt-dlp 从 Chrome (Profile 1) 导出多个站点的 cookie 到 Netscape txt 文件.
# 由 macking 的 LaunchAgent (com.tiancai.cookie-refresh) 跑, 必须 LimitLoadToSessionType=Aqua
# 才有 Keychain 上下文解密 Chrome cookies.
#
# 首次运行会弹 Keychain 授权对话框 → 在 macking GUI Terminal 手动跑一次点 "Always Allow".
#
# 设计要点: yt-dlp MozillaCookieJar 在 cookie 载入后立即 save 到 --cookies 文件,
# 之后不管 extractor 报啥错 (反爬 / authcheck / SSL EOF), cookie 都已经持久化.
# 只检查产物文件行数, 不 care yt-dlp exit code.

set -u  # 不要 -e, 一个站点失败不影响另一个

COOKIE_DIR="$HOME/production/shared/cookies"
YT_DLP="/opt/homebrew/bin/yt-dlp"
SYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$COOKIE_DIR"

refresh_one() {
    local site_name="$1"
    local url="$2"
    local out="$COOKIE_DIR/${site_name}.cookies.txt"
    local tmp="$COOKIE_DIR/.${site_name}.cookies.txt.tmp"
    local err="$COOKIE_DIR/.${site_name}.refresh.err"

    printf '# Netscape HTTP Cookie File\n' > "$tmp"

    # --playlist-end 1: 首页只取第一条 entry, 避免 yt-dlp 爬整个 home feed
    #   (爬全部要 10+ 分钟, cookies 在 cookie jar finalize 时才落盘 → 限量也照样拿到 cookies)
    "$YT_DLP" \
        --cookies-from-browser 'chrome:Profile 1' \
        --cookies "$tmp" \
        --skip-download \
        --simulate \
        --playlist-end 1 \
        --extractor-args 'youtubetab:skip=authcheck' \
        --no-warnings \
        --quiet \
        "$url" 2>"$err" || true

    local lines
    lines=$(grep -cv '^#' "$tmp" 2>/dev/null || echo 0)
    lines=${lines:-0}

    if [[ "$lines" -lt 5 ]]; then
        echo "[$(date)] $site_name cookie export failed: only $lines entries in $tmp" >&2
        echo "[$(date)] yt-dlp stderr:" >&2
        cat "$err" >&2
        return 1
    fi

    mv "$tmp" "$out"
    echo "[$(date)] $site_name cookie refreshed → $out ($lines entries)"
    return 0
}

# Refresh each site. 失败一个不影响其他.
refresh_one youtube 'https://www.youtube.com/' || true
refresh_one douyin  'https://www.douyin.com/'  || true

# 推送到所有 worker
bash "$SYNC_SCRIPT_DIR/sync-cookies-to-workers.sh"
