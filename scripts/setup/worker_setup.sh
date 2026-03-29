#!/bin/bash
# ============================================================
# worker_setup.sh — Worker Mac mini 一键部署脚本（VPS 架构版）
#
# 在新的 Mac mini 上打开终端，粘贴执行：
#
#   bash <(curl -sL https://raw.githubusercontent.com/zhiyunchen0213/tiancai-junwu-ai-worker/main/scripts/setup/worker_setup.sh)
#
# 或者如果 GitHub 被墙，先从 VPS 拉：
#   scp root@ssh.createflow.art:/opt/worker-repo/scripts/setup/worker_setup.sh /tmp/ && bash /tmp/worker_setup.sh
#
# 会自动完成：
#   1. 安装所有依赖（brew, yt-dlp, ffmpeg, python3, whisper, node, autossh, cloudflared）
#   2. 克隆 Worker 代码（GitHub 优先，VPS rsync 备用）
#   3. 配置环境变量
#   4. 配置 autossh 反向隧道（远程管理用）
#   5. 添加 VPS 公钥（允许远程控制）
#   6. 配置 Chrome 即梦 profile
#   7. 启动 Worker
# ============================================================

set +eu  # 宽松模式，避免交互式执行时意外退出

# === 颜色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================================
# 参数收集
# ============================================================

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      Worker Mac mini 一键部署（VPS 架构）           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# 自动检测本机用户名和 IP
LOCAL_USER=$(whoami)
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")

# Worker ID：如果已有 .production.env 则读取，否则询问
if [[ -f "$HOME/.production.env" ]] && grep -q "WORKER_ID=" "$HOME/.production.env"; then
    WORKER_ID=$(grep "^WORKER_ID=" "$HOME/.production.env" | cut -d= -f2)
    echo "检测到已有 Worker ID: $WORKER_ID"
    echo -n "使用此 ID？(Y/n): "
    read -r confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        WORKER_ID=""
    fi
fi

if [[ -z "${WORKER_ID:-}" ]]; then
    echo "当前用户: $LOCAL_USER, IP: $LOCAL_IP"
    echo -n "请输入 Worker ID (如 worker-m1, worker-m2): "
    read -r WORKER_ID
    if [[ -z "$WORKER_ID" ]]; then
        log_error "Worker ID 不能为空"
        exit 1
    fi
fi

# 隧道端口：基于 IP 末位自动计算，或手动指定
LAST_OCTET=$(echo "$LOCAL_IP" | awk -F. '{print $4}')
AUTO_PORT=$((2200 + ${LAST_OCTET:-99}))
echo -n "反向隧道端口 (默认 $AUTO_PORT，直接回车确认): "
read -r TUNNEL_PORT
TUNNEL_PORT="${TUNNEL_PORT:-$AUTO_PORT}"

# VPS 配置
REVIEW_SERVER_URL="https://brain.createflow.art"
DISPATCHER_TOKEN="kwR2m0GMdeGZu0fSvfcVRJGvWYS255qe"
VPS_SSH_HOST="ssh.createflow.art"
VPS_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIdzsU8Ff9nsHgWQFhwNo6KHCxJKg01RnvEv56K5N0tc root@racknerd-ad34366"
CDP_PORT=9222

echo ""
log_info "Worker ID: $WORKER_ID"
log_info "隧道端口: $TUNNEL_PORT"
log_info "本机 IP: $LOCAL_IP"
echo ""

# ============================================================
# Step 1: Homebrew + 工具链
# ============================================================

log_info "=== [1/7] 安装工具链 ==="

# Homebrew
if ! command -v brew &>/dev/null; then
    log_warn "安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
log_ok "Homebrew"

# 核心工具
for tool in yt-dlp ffmpeg python3 node git autossh cloudflared; do
    if command -v "$tool" &>/dev/null; then
        log_ok "$tool 已安装"
    else
        log_info "安装 $tool..."
        brew install "$tool"
        log_ok "$tool"
    fi
done

# whisper
if python3 -c "import whisper" &>/dev/null 2>&1; then
    log_ok "openai-whisper 已安装"
else
    log_info "安装 openai-whisper..."
    pip3 install openai-whisper --break-system-packages 2>/dev/null || pip3 install openai-whisper
    log_ok "openai-whisper"
fi

# playwright-core
if npm list -g playwright-core &>/dev/null 2>&1; then
    log_ok "playwright-core 已安装"
else
    log_info "安装 playwright-core..."
    npm install -g playwright-core 2>/dev/null || true
fi

# ============================================================
# Step 2: 克隆 Worker 代码
# ============================================================

log_info "=== [2/7] 获取 Worker 代码 ==="

CODE_DIR="$HOME/worker-code"

if [[ -d "$CODE_DIR/.git" ]]; then
    log_ok "代码目录已存在，更新中..."
    cd "$CODE_DIR"
    git pull origin main 2>&1 || log_warn "git pull 失败，使用现有代码"
    cd - >/dev/null
else
    log_info "从 GitHub 克隆..."
    if git clone https://github.com/zhiyunchen0213/tiancai-junwu-ai-worker.git "$CODE_DIR" 2>&1; then
        log_ok "GitHub 克隆成功"
    else
        log_warn "GitHub 不可达，从 VPS 同步..."
        mkdir -p "$CODE_DIR"
        if command -v cloudflared &>/dev/null; then
            rsync -az --delete \
                -e "ssh -o ProxyCommand='cloudflared access ssh --hostname $VPS_SSH_HOST' -o StrictHostKeyChecking=no" \
                "root@${VPS_SSH_HOST}:/opt/worker-repo/" "$CODE_DIR/" 2>&1
            log_ok "VPS rsync 成功"
        else
            log_error "cloudflared 未安装，无法从 VPS 同步"
            exit 1
        fi
    fi
fi

# 创建 symlink
mkdir -p "$HOME/production"
rm -f "$HOME/production/code" 2>/dev/null
rm -rf "$HOME/production/code" 2>/dev/null
ln -sfn "$CODE_DIR" "$HOME/production/code"
log_ok "symlink: ~/production/code -> ~/worker-code"

# ============================================================
# Step 3: 配置环境变量
# ============================================================

log_info "=== [3/7] 配置环境变量 ==="

ENV_FILE="$HOME/.production.env"

# 保留已有的 API keys
OLD_YUNWU_KEY=""
OLD_KIMI_KEY=""
if [[ -f "$ENV_FILE" ]]; then
    OLD_YUNWU_KEY=$(grep "^YUNWU_API_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    OLD_KIMI_KEY=$(grep "^KIMI_API_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
fi

cat > "$ENV_FILE" << EOF
# === Worker 环境配置 ($WORKER_ID) ===
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')

WORKER_ID=$WORKER_ID
SHARED_DIR=$HOME/production
REVIEW_SERVER_URL=$REVIEW_SERVER_URL
DISPATCHER_TOKEN=$DISPATCHER_TOKEN
CDP_PORT=$CDP_PORT
AI_AGENT=claude
POLL_INTERVAL=30
JIMENG_CHROME_PROFILE=\$HOME/.jimeng-chrome-profile
LOG_LEVEL=info

# API Keys（手动填写）
YUNWU_API_KEY=${OLD_YUNWU_KEY:-}
KIMI_API_KEY=${OLD_KIMI_KEY:-}
EOF

# 加入 shell profile
grep -q "production.env" ~/.zprofile 2>/dev/null || echo '[ -f ~/.production.env ] && source ~/.production.env' >> ~/.zprofile
source "$ENV_FILE"
log_ok "环境变量写入 $ENV_FILE"

# ============================================================
# Step 4: 配置 autossh 反向隧道
# ============================================================

log_info "=== [4/7] 配置反向隧道 ==="

mkdir -p "$HOME/production/logs"

PLIST_FILE="$HOME/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist"
AUTOSSH_BIN=$(which autossh)
CLOUDFLARED_BIN=$(which cloudflared)
SSH_KEY="$HOME/.ssh/id_ed25519"

# 确保 SSH key 存在
if [[ ! -f "$SSH_KEY" ]]; then
    log_info "生成 SSH 密钥..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    log_ok "密钥已生成"
    echo ""
    log_warn "=== 重要：请把以下公钥发给天才 ==="
    cat "${SSH_KEY}.pub"
    echo ""
    log_warn "天才需要把这个公钥加到 VPS 的 authorized_keys"
    echo -n "公钥已发给天才了吗？(按回车继续): "
    read -r
fi

# 创建 launchd plist
cat > "$PLIST_FILE" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tiancai.autossh-tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>${AUTOSSH_BIN}</string>
    <string>-M</string><string>0</string>
    <string>-N</string>
    <string>-o</string><string>ProxyCommand ${CLOUDFLARED_BIN} access ssh --hostname ${VPS_SSH_HOST}</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>StrictHostKeyChecking=no</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-i</string><string>${SSH_KEY}</string>
    <string>-R</string><string>${TUNNEL_PORT}:localhost:22</string>
    <string>root@${VPS_SSH_HOST}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AUTOSSH_GATETIME</key><string>0</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/production/logs/autossh.log</string>
  <key>StandardErrorPath</key><string>${HOME}/production/logs/autossh.log</string>
</dict>
</plist>
PLISTEOF

# 停止旧的，启动新的
launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load "$PLIST_FILE"
sleep 3

if pgrep -f "autossh" >/dev/null 2>&1; then
    log_ok "autossh 隧道已启动 (端口 $TUNNEL_PORT)"
else
    log_warn "autossh 启动失败，检查 ~/production/logs/autossh.log"
    tail -5 "$HOME/production/logs/autossh.log" 2>/dev/null
fi

# ============================================================
# Step 5: 添加 VPS 公钥（远程管理用）
# ============================================================

log_info "=== [5/7] 配置远程管理 ==="

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
AUTH_FILE="$HOME/.ssh/authorized_keys"

if grep -qF "racknerd-ad34366" "$AUTH_FILE" 2>/dev/null; then
    log_ok "VPS 公钥已存在"
else
    echo "$VPS_PUBKEY" >> "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    log_ok "VPS 公钥已添加"
fi

# ============================================================
# Step 6: Chrome 即梦配置
# ============================================================

log_info "=== [6/7] 配置 Chrome ==="

CHROME_PROFILE="$HOME/.jimeng-chrome-profile"
mkdir -p "$CHROME_PROFILE"

CHROME_LAUNCHER="$HOME/start_jimeng_chrome.sh"
cat > "$CHROME_LAUNCHER" << 'CHREOF'
#!/bin/bash
source ~/.production.env 2>/dev/null
CHROME_APP="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -f "$CHROME_APP" ]; then echo "Google Chrome 未安装"; exit 1; fi
echo "启动即梦 Chrome (CDP: ${CDP_PORT:-9222})..."
"$CHROME_APP" \
  --remote-debugging-port=${CDP_PORT:-9222} \
  --remote-allow-origins="*" \
  --user-data-dir="${JIMENG_CHROME_PROFILE:-$HOME/.jimeng-chrome-profile}" \
  --no-first-run --no-default-browser-check \
  "https://jimeng.jianying.com" &
echo "Chrome PID: $!"
echo "验证: curl http://localhost:${CDP_PORT:-9222}/json/version"
CHREOF
chmod +x "$CHROME_LAUNCHER"
log_ok "Chrome 启动脚本: ~/start_jimeng_chrome.sh"

# ============================================================
# Step 7: 启动 Worker
# ============================================================

log_info "=== [7/7] 启动 Worker ==="

# 停止旧进程
OLD_PIDS=$(pgrep -f "worker_main.sh" 2>/dev/null || true)
if [[ -n "$OLD_PIDS" ]]; then
    log_info "停止旧 Worker 进程: $OLD_PIDS"
    kill $OLD_PIDS 2>/dev/null || true
    sleep 3
    kill -9 $(pgrep -f "worker_main.sh" 2>/dev/null) 2>/dev/null || true
fi

source "$HOME/.production.env" 2>/dev/null || true
LOG_DIR="$HOME/production/logs"
mkdir -p "$LOG_DIR"

nohup bash "$CODE_DIR/scripts/worker/worker_main.sh" > "$LOG_DIR/worker.log" 2>&1 &
NEW_PID=$!
sleep 3

if kill -0 $NEW_PID 2>/dev/null; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              部署完成!                               ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║                                                      ║"
    echo "║  Worker ID:  $WORKER_ID"
    echo "║  隧道端口:    $TUNNEL_PORT"
    echo "║  本机 IP:     $LOCAL_IP"
    echo "║  Worker PID:  $NEW_PID"
    echo "║                                                      ║"
    echo "║  自动更新:    已启用（每 5 分钟检查）               ║"
    echo "║  远程管理:    已启用                                ║"
    echo "║                                                      ║"
    echo "║  还需要手动做:                                      ║"
    echo "║  1. 运行 ~/start_jimeng_chrome.sh 启动 Chrome      ║"
    echo "║  2. 在 Chrome 中登录 jimeng.jianying.com           ║"
    echo "║                                                      ║"
    echo "║  日常命令:                                           ║"
    echo "║  · 日志: tail -f ~/production/logs/worker.log       ║"
    echo "║  · 停止: pkill -f worker_main.sh                    ║"
    echo "║  · 启动: nohup bash ~/worker-code/scripts/worker/   ║"
    echo "║          worker_main.sh > ~/production/logs/         ║"
    echo "║          worker.log 2>&1 &                           ║"
    echo "╚══════════════════════════════════════════════════════╝"
else
    log_error "Worker 启动失败"
    tail -10 "$LOG_DIR/worker.log" 2>/dev/null
fi
