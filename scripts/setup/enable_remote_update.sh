#!/bin/bash
#
# ========================================
#   让天才能远程更新这台机器的脚本
#   俊武用：在每台 Mac Mini 上打开终端，粘贴执行即可
#
#   bash <(curl -sL https://raw.githubusercontent.com/zhiyunchen0213/tiancai-junwu-ai-worker/main/scripts/setup/enable_remote_update.sh)
#
#   或者直接复制这个脚本内容粘贴到终端
# ========================================

set +eu  # 宽松模式

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   启用远程更新 + 自动更新           ║"
echo "╚══════════════════════════════════════╝"
echo ""

# VPS 公钥（天才的控制服务器）
VPS_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIdzsU8Ff9nsHgWQFhwNo6KHCxJKg01RnvEv56K5N0tc root@racknerd-ad34366"

# ============ Step 1: 添加 VPS 公钥 ============
echo "=== [1/4] 添加远程控制公钥 ==="
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
AUTH_FILE="$HOME/.ssh/authorized_keys"

if grep -qF "racknerd-ad34366" "$AUTH_FILE" 2>/dev/null; then
    echo "  已存在，跳过"
else
    echo "$VPS_PUBKEY" >> "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo "  已添加"
fi

# ============ Step 2: 确保隧道在线 ============
echo "=== [2/4] 检查隧道状态 ==="
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")
LAST_OCTET=$(echo "$LOCAL_IP" | awk -F. '{print $4}')
TUNNEL_PORT=$((2220 + ${LAST_OCTET:-99}))
echo "  本机 IP: $LOCAL_IP, 隧道端口: $TUNNEL_PORT"

if pgrep -f "autossh.*$TUNNEL_PORT" >/dev/null 2>&1; then
    echo "  隧道运行中"
else
    echo "  隧道未运行，尝试启动..."
    launchctl load "$HOME/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist" 2>/dev/null || true
    sleep 2
    if pgrep -f "autossh" >/dev/null 2>&1; then
        echo "  隧道已启动"
    else
        echo "  ! 隧道启动失败，需要先运行安装脚本配置隧道"
    fi
fi

# ============ Step 3: 拉取最新代码 ============
echo "=== [3/4] 更新代码 ==="
CODE_DIR="$HOME/worker-code"

if [[ -d "$CODE_DIR/.git" ]]; then
    cd "$CODE_DIR"
    git pull origin main 2>&1 || echo "  ! git pull 失败，检查网络"
    echo "  代码已更新"
else
    echo "  代码目录不存在，克隆..."
    git clone https://github.com/zhiyunchen0213/tiancai-junwu-ai-worker.git "$CODE_DIR" 2>&1
    echo "  代码已克隆"
fi

# 确保 symlink
ln -sfn "$CODE_DIR" "$HOME/production/code" 2>/dev/null || true

# ============ Step 4: 重启 Worker ============
echo "=== [4/4] 重启 Worker ==="
OLD_PIDS=$(pgrep -f "worker_main.sh" 2>/dev/null || true)
if [[ -n "$OLD_PIDS" ]]; then
    echo "  停止旧进程: $OLD_PIDS"
    kill $OLD_PIDS 2>/dev/null || true
    sleep 3
    kill -9 $(pgrep -f "worker_main.sh" 2>/dev/null) 2>/dev/null || true
fi

source "$HOME/.production.env" 2>/dev/null || true
WORKER_ID="${WORKER_ID:-unknown}"
LOG_DIR="$HOME/production/logs"
mkdir -p "$LOG_DIR"

nohup bash "$CODE_DIR/scripts/worker/worker_main.sh" > "$LOG_DIR/worker.log" 2>&1 &
NEW_PID=$!
sleep 2

if kill -0 $NEW_PID 2>/dev/null; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "  Done! Worker $WORKER_ID running (PID: $NEW_PID)"
    echo "  Tunnel port: $TUNNEL_PORT"
    echo "  Auto-update: enabled (checks every 5 min)"
    echo "  Remote control: enabled"
    echo "╚══════════════════════════════════════════════════════╝"
else
    echo "  ! Worker 启动失败"
    tail -5 "$LOG_DIR/worker.log" 2>/dev/null
fi
