#!/bin/bash
# deploy_auto_update.sh — 在 worker 上安装自动代码更新 LaunchAgent
#
# 用法: 在 worker 上执行
#   bash ~/worker-code/scripts/setup/deploy_auto_update.sh
#
# 效果:
#   每 10 分钟自动 git pull ~/worker-code
#   不依赖 SSH 隧道或局域网，只需要网络能访问 GitHub（VPN 下一定通）
#   日志写入 ~/production/logs/auto-update.log

set -euo pipefail

WORKER_CODE="$HOME/worker-code"
PLIST_NAME="com.tiancai.worker-auto-update"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
LOG_DIR="$HOME/production/logs"
LOG_FILE="$LOG_DIR/auto-update.log"

# 确保目录存在
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# 确保 worker-code 是 git 仓库
if [[ ! -d "$WORKER_CODE/.git" ]]; then
    echo "✗ $WORKER_CODE 不是 git 仓库，请先 git clone"
    exit 1
fi

# 创建更新脚本（LaunchAgent 不支持复杂 shell 命令）
UPDATE_SCRIPT="$HOME/bin/worker-auto-update.sh"
mkdir -p "$HOME/bin"
cat > "$UPDATE_SCRIPT" << 'SCRIPT'
#!/bin/bash
# worker-auto-update.sh — 自动拉取最新 worker 代码
LOG="$HOME/production/logs/auto-update.log"
REPO="$HOME/worker-code"

exec >> "$LOG" 2>&1

# 保持日志不超过 1000 行
if [[ -f "$LOG" ]] && [[ $(wc -l < "$LOG") -gt 1000 ]]; then
    tail -500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

cd "$REPO" || exit 1

# 确保 git 用 HTTP/1.1（GFW 兼容）
git config http.version HTTP/1.1

# 丢弃本地修改，强制同步远程
BEFORE=$(git rev-parse HEAD 2>/dev/null)
git fetch origin main --quiet 2>/dev/null
AFTER=$(git rev-parse origin/main 2>/dev/null)

if [[ "$BEFORE" != "$AFTER" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updating: $(git log --oneline $BEFORE..$AFTER | wc -l | tr -d ' ') new commits"
    git reset --hard origin/main --quiet 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated to: $(git log --oneline -1)"
fi
SCRIPT
chmod +x "$UPDATE_SCRIPT"

# 卸载旧的（如果存在）
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true

# 创建 LaunchAgent plist
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${UPDATE_SCRIPT}</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

# 加载
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH" 2>/dev/null

echo "✓ 自动更新已安装"
echo "  频率: 每 10 分钟"
echo "  日志: $LOG_FILE"
echo "  卸载: launchctl bootout gui/$(id -u)/$PLIST_NAME"

# 立即执行一次
bash "$UPDATE_SCRIPT"
echo "✓ 首次更新完成: $(cd "$WORKER_CODE" && git log --oneline -1)"
