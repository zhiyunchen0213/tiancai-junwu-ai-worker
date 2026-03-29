#!/bin/bash
# 配置 autossh 反向隧道（一行命令执行）
# 用法: bash <(curl -sL https://raw.githubusercontent.com/zhiyunchen0213/tiancai-junwu-ai-worker/main/scripts/setup/setup_tunnel.sh)
set +eu
echo ""
echo "=== 配置 autossh 反向隧道 ==="
echo ""
which autossh >/dev/null 2>&1 || { echo "安装 autossh..."; brew install autossh; }
which cloudflared >/dev/null 2>&1 || { echo "安装 cloudflared..."; brew install cloudflared; }
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")
LAST_OCTET=$(echo "$LOCAL_IP" | awk -F. '{print $4}')
AUTO_PORT=$((2200 + ${LAST_OCTET:-99}))
echo "本机 IP: $LOCAL_IP"
echo -n "隧道端口 (默认 $AUTO_PORT): "
read -r PORT
PORT="${PORT:-$AUTO_PORT}"
AUTOSSH_BIN=$(which autossh)
CLOUDFLARED_BIN=$(which cloudflared)
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY" ]]; then
ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
echo "公钥（发给天才）:"
cat "${SSH_KEY}.pub"
echo -n "按回车继续..."
read -r
fi
mkdir -p ~/production/logs ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist << EOF
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
<string>-o</string><string>ProxyCommand ${CLOUDFLARED_BIN} access ssh --hostname ssh.createflow.art</string>
<string>-o</string><string>ServerAliveInterval=30</string>
<string>-o</string><string>ServerAliveCountMax=3</string>
<string>-o</string><string>StrictHostKeyChecking=no</string>
<string>-o</string><string>ExitOnForwardFailure=yes</string>
<string>-i</string><string>${SSH_KEY}</string>
<string>-R</string><string>${PORT}:localhost:22</string>
<string>root@ssh.createflow.art</string>
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
EOF
launchctl unload ~/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist
sleep 3
if pgrep -f autossh >/dev/null 2>&1; then
echo ""
echo "=== 隧道已启动 (端口 $PORT) ==="
else
echo ""
echo "=== 启动失败，日志: ==="
cat ~/production/logs/autossh.log 2>/dev/null
fi
