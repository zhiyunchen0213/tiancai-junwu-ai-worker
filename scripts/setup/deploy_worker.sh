#!/bin/bash
#
# deploy_worker.sh — 一键部署 Worker 到新的 Mac Mini
# 使用方法: bash deploy_worker.sh <worker_ip> <worker_user> <worker_password>
#
# 前提: 运行此脚本的机器能 SSH 到目标 Worker（同一局域网）
#

set -euo pipefail

WORKER_IP="${1:?用法: bash deploy_worker.sh <IP> <用户名> <密码>}"
WORKER_USER="${2:?用法: bash deploy_worker.sh <IP> <用户名> <密码>}"
WORKER_PASS="${3:?用法: bash deploy_worker.sh <IP> <用户名> <密码>}"
WORKER_ID="${4:-worker-$(echo $WORKER_IP | tr '.' '-')}"

# 配置（按需修改）
VPS_HOST="107.175.215.216"
REVIEW_SERVER_URL="http://${VPS_HOST}:3000"
DISPATCHER_TOKEN="${DISPATCHER_TOKEN:?Set DISPATCHER_TOKEN env var}"
MACKING_HOST="192.168.31.181"
MACKING_USER="zjw-mini"
REPO_URL="https://github.com/zhiyunchen0213/tiancai-junwu-ai-worker.git"

SSH="sshpass -p '$WORKER_PASS' ssh -o StrictHostKeyChecking=no $WORKER_USER@$WORKER_IP"
SCP="sshpass -p '$WORKER_PASS' scp -o StrictHostKeyChecking=no"

echo "========================================="
echo "  AI Worker 一键部署"
echo "  目标: $WORKER_USER@$WORKER_IP"
echo "  Worker ID: $WORKER_ID"
echo "========================================="

# Step 1: 基础软件
echo ""
echo "=== Step 1/6: 安装基础软件 ==="
eval $SSH "
export PATH=/opt/homebrew/bin:\$PATH
brew install autossh ffmpeg yt-dlp python@3 2>/dev/null || true
pip3 install --user --break-system-packages whisper 2>/dev/null || true
echo 'Step 1 done'
"

# Step 2: 安装 Kimi CLI + cloudflared
echo ""
echo "=== Step 2/6: 安装 Kimi CLI + cloudflared ==="
eval $SSH "
export PATH=/opt/homebrew/bin:\$PATH
brew install cloudflared 2>/dev/null || true
# Kimi CLI (check if already installed)
which kimi || pip3 install --user --break-system-packages kimi-cli 2>/dev/null || true
# Symlink kimi to PATH
KIMI_PATH=\$(find ~/.local -name kimi -type f 2>/dev/null | head -1)
[ -n \"\$KIMI_PATH\" ] && ln -sf \"\$KIMI_PATH\" /opt/homebrew/bin/kimi
echo 'Step 2 done'
"

# Step 3: 创建目录结构 + 环境变量
echo ""
echo "=== Step 3/6: 配置环境 ==="
eval $SSH "
mkdir -p ~/production/tasks/{pending,running/$WORKER_ID,harvesting,completed,failed}
mkdir -p ~/production/logs ~/production/code

cat > ~/.production.env << 'ENVEOF'
export PATH=/opt/homebrew/bin:\$PATH
WORKER_ID=$WORKER_ID
SHARED_DIR=/Users/$WORKER_USER/production
REVIEW_SERVER_URL=$REVIEW_SERVER_URL
DISPATCHER_TOKEN=$DISPATCHER_TOKEN
MACKING_HOST=$MACKING_HOST
MACKING_USER=$MACKING_USER
CDP_PORT=9222
ENVEOF

echo 'Step 3 done'
"

# Step 4: 拉取代码
echo ""
echo "=== Step 4/6: 拉取 Worker 代码 ==="
eval $SSH "
export PATH=/opt/homebrew/bin:\$PATH
if [ -d ~/worker-code/.git ]; then
  cd ~/worker-code && git pull
else
  git clone $REPO_URL ~/worker-code 2>/dev/null || echo 'Clone failed, manual copy needed'
fi
# Install node dependencies
cd ~/worker-code/scripts/worker/jimeng && npm install 2>/dev/null || true
echo 'Step 4 done'
"

# Step 5: SSH 密钥 + autossh 隧道
echo ""
echo "=== Step 5/6: 配置 SSH 隧道 ==="
eval $SSH "
export PATH=/opt/homebrew/bin:\$PATH
# Generate SSH key if not exists
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -q
cat ~/.ssh/id_ed25519.pub
"
echo ""
echo ">>> 请将上面的公钥添加到 VPS 的 ~/.ssh/authorized_keys"
echo ">>> 添加后按 Enter 继续..."
read -r

# Set up autossh launchd
NEXT_PORT=$((2222 + $(echo $WORKER_IP | awk -F. '{print $4}') % 100))
echo "使用 VPS 反向隧道端口: $NEXT_PORT"
eval $SSH "
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist << PLIST
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
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
    <string>-i</string><string>/Users/$WORKER_USER/.ssh/id_ed25519</string>
    <string>-R</string><string>$NEXT_PORT:localhost:22</string>
    <string>root@ssh.createflow.art</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AUTOSSH_GATETIME</key><string>0</string>
    <key>HOME</key><string>/Users/$WORKER_USER</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/$WORKER_USER/production/logs/autossh.log</string>
  <key>StandardErrorPath</key><string>/Users/$WORKER_USER/production/logs/autossh.log</string>
</dict>
</plist>
PLIST
launchctl load ~/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist
echo 'Step 5 done'
"

# Step 6: 启动 Chrome CDP
echo ""
echo "=== Step 6/6: 完成 ==="
echo ""
echo "========================================="
echo "  部署完成！"
echo "========================================="
echo ""
echo "还需要手动操作："
echo "  1. 在 Worker 上打开 Chrome 并登录即梦 (jimeng.jianying.com)"
echo "  2. 关闭 Chrome，然后用以下命令重新打开（启用 CDP）："
echo "     /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome --remote-debugging-port=9222 --remote-allow-origins=\"*\" &"
echo "  3. 启动 Worker 主循环："
echo "     cd ~/production && nohup bash ~/worker-code/scripts/worker/worker_main.sh > ~/production/logs/worker.log 2>&1 &"
echo ""
echo "VPS 反向隧道端口: $NEXT_PORT"
echo "Worker ID: $WORKER_ID"
