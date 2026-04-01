#!/bin/bash
#
# ========================================
#   AI 视频 Worker 本机安装脚本
#   俊武用：在新 Mac Mini 上打开终端，粘贴下面一行命令即可
#
#   curl -sL https://raw.githubusercontent.com/... | bash
#   或者直接复制这个脚本内容粘贴到终端
# ========================================
#
# 安装前确认：
#   1. Mac 已联网
#   2. 已安装 Homebrew（如果没有，先运行: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"）
#   3. 知道这台机器的 Worker ID（问天才要）
#

set +eu  # 宽松模式，安装脚本不因非致命错误中断
# 注意：不用 set -e，因为 brew/pip 安装可能返回非零但不致命

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   AI 视频 Worker 安装程序           ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ============ 配置区 ============
REVIEW_SERVER_URL="http://107.175.215.216:3000"
MACKING_HOST="192.168.31.181"
MACKING_USER="zjw-mini"
CDP_PORT=9222

# 交互输入
read -p "请输入 Worker ID（问天才要，如 worker-m3）: " WORKER_ID
if [[ -z "$WORKER_ID" ]]; then
    echo "❌ Worker ID 不能为空"
    exit 1
fi

echo ""
echo "接下来需要输入一个密钥（问天才要，一串英文数字）"
read -p "请粘贴 DISPATCHER_TOKEN: " DISPATCHER_TOKEN
if [[ -z "$DISPATCHER_TOKEN" ]]; then
    echo "❌ DISPATCHER_TOKEN 不能为空，问天才要"
    exit 1
fi

CURRENT_USER=$(whoami)
HOME_DIR="/Users/$CURRENT_USER"
PRODUCTION_DIR="$HOME_DIR/production"

echo ""
echo "Worker ID: $WORKER_ID"
echo "用户: $CURRENT_USER"
echo "工作目录: $PRODUCTION_DIR"
echo ""
read -p "确认继续安装？(y/n) " -n 1 CONFIRM
echo ""
if [[ "$CONFIRM" != "y" ]]; then echo "取消安装"; exit 0; fi

# ============ Step 1: 安装软件 ============
echo ""
echo "=== [1/6] 安装必要软件 ==="
export PATH="/opt/homebrew/bin:$PATH"

brew install ffmpeg yt-dlp cloudflared autossh 2>/dev/null || true
echo "✅ 基础软件已安装"

# 安装 Node.js
if ! command -v node &>/dev/null; then
    brew install node 2>/dev/null || true
fi
echo "✅ Node.js: $(node --version 2>/dev/null || echo '未安装')"

# 安装 Kimi CLI
KIMI_PATH=$(find "$HOME_DIR/Library" "$HOME_DIR/.local" /opt/homebrew -name kimi -type f 2>/dev/null | head -1)
if [[ -n "$KIMI_PATH" ]]; then
    ln -sf "$KIMI_PATH" /opt/homebrew/bin/kimi 2>/dev/null || true
fi
if ! command -v kimi &>/dev/null; then
    pip3 install --user --break-system-packages kimi-cli 2>/dev/null || true
    KIMI_PATH=$(find "$HOME_DIR/Library" "$HOME_DIR/.local" /opt/homebrew -name kimi -type f 2>/dev/null | head -1)
    [[ -n "$KIMI_PATH" ]] && ln -sf "$KIMI_PATH" /opt/homebrew/bin/kimi 2>/dev/null || true
fi
echo "✅ Kimi: $(kimi --version 2>/dev/null || echo '未安装，需要手动安装')"

# ============ Step 2: 创建目录 ============
echo ""
echo "=== [2/6] 创建工作目录 ==="
mkdir -p "$PRODUCTION_DIR/tasks"/{pending,running/$WORKER_ID,harvesting,completed,failed}
mkdir -p "$PRODUCTION_DIR/logs"
mkdir -p "$PRODUCTION_DIR/code"
echo "✅ 目录结构已创建"

# ============ Step 3: 环境变量 ============
echo ""
echo "=== [3/6] 配置环境变量 ==="
cat > "$HOME_DIR/.production.env" << ENVEOF
export PATH=/opt/homebrew/bin:\$PATH
WORKER_ID=$WORKER_ID
SHARED_DIR=$PRODUCTION_DIR
REVIEW_SERVER_URL=$REVIEW_SERVER_URL
DISPATCHER_TOKEN=$DISPATCHER_TOKEN
MACKING_HOST=$MACKING_HOST
MACKING_USER=$MACKING_USER
CDP_PORT=$CDP_PORT
ENVEOF
echo "✅ 环境变量已写入 ~/.production.env"

# ============ Step 4: SSH 密钥 ============
echo ""
echo "=== [4/6] 配置 SSH ==="
if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "$HOME_DIR/.ssh/id_ed25519" -N "" -q
    echo "✅ SSH 密钥已生成"
else
    echo "✅ SSH 密钥已存在"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ⚠️  请将以下公钥发给天才，让他加到 VPS 上：        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
cat "$HOME_DIR/.ssh/id_ed25519.pub"
echo ""
read -p "公钥已发给天才并确认添加后，按 Enter 继续..."

# ============ Step 5: autossh 隧道 ============
echo ""
echo "=== [5/6] 配置持久隧道 ==="
# 计算隧道端口（基于IP最后一段）
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "0.0.0.99")
LAST_OCTET=$(echo "$LOCAL_IP" | awk -F. '{print $4}')
LAST_OCTET=${LAST_OCTET:-99}
TUNNEL_PORT=$((2220 + LAST_OCTET))
echo "本机 IP: $LOCAL_IP，隧道端口: $TUNNEL_PORT"

mkdir -p "$HOME_DIR/Library/LaunchAgents"
cat > "$HOME_DIR/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tiancai.autossh-tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/autossh</string>
    <string>-M</string><string>0</string>
    <string>-N</string>
    <string>-o</string><string>ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname ssh.createflow.art</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>StrictHostKeyChecking=no</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-i</string><string>$HOME_DIR/.ssh/id_ed25519</string>
    <string>-R</string><string>$TUNNEL_PORT:localhost:22</string>
    <string>root@ssh.createflow.art</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AUTOSSH_GATETIME</key><string>0</string>
    <key>HOME</key><string>$HOME_DIR</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$PRODUCTION_DIR/logs/autossh.log</string>
  <key>StandardErrorPath</key><string>$PRODUCTION_DIR/logs/autossh.log</string>
</dict>
</plist>
PLIST
launchctl load "$HOME_DIR/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist" 2>/dev/null
echo "✅ 隧道已配置（端口 $TUNNEL_PORT）"

# ============ Step 6: 完成 ============
echo ""
echo "=== [6/6] 安装完成！ ==="
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║               安装完成！                            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
echo "║  Worker ID: $WORKER_ID"
echo "║  隧道端口: $TUNNEL_PORT"
echo "║  本机 IP: $LOCAL_IP"
echo "║                                                      ║"
echo "║  还需要手动做两件事：                                ║"
echo "║                                                      ║"
echo "║  1. 打开 Chrome → 登录 jimeng.jianying.com          ║"
echo "║     然后关闭 Chrome，用以下命令重新打开：            ║"
echo "║                                                      ║"
echo '║  /Applications/Google\ Chrome.app/Contents/MacOS/    ║'
echo '║  Google\ Chrome --remote-debugging-port=9222         ║'
echo '║  --remote-allow-origins="*" &                        ║'
echo "║                                                      ║"
echo "║  2. 把 Worker 代码放到 ~/worker-code/ 目录            ║"
echo "║     （问天才要代码包或 git clone 地址）              ║"
echo "║                                                      ║"
echo "║  代码就位后，启动 Worker：                            ║"
echo "║  cd ~/production && bash ~/worker-code/scripts/      ║"
echo "║  worker/worker_main.sh                               ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
