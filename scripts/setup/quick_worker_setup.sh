#!/bin/bash
# quick_worker_setup.sh — Worker 快速部署（适合远程粘贴执行）
# 用法: curl -sL <url> | bash -s -- worker-m2 192.168.0.145 zjw-mini

set -euo pipefail

WORKER_ID="${1:-worker-m2}"
CONTROLLER_IP="${2:-192.168.0.145}"
CONTROLLER_USER="${3:-zjw-mini}"
VPS_URL="http://107.175.215.216"
DISPATCHER_TOKEN="kwR2m0GMdeGZu0fSvfcVRJGvWYS255qe"

echo ""
echo "═══════════════════════════════════════"
echo "  Worker 快速部署: $WORKER_ID"
echo "  中控: $CONTROLLER_USER@$CONTROLLER_IP"
echo "═══════════════════════════════════════"
echo ""

# Step 1: Homebrew
echo "[1/6] 检查 Homebrew..."
if ! command -v brew &>/dev/null; then
  echo "  安装 Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
echo "  ✅ Homebrew OK"

# Step 2: 工具链
echo "[2/6] 安装工具链..."
for tool in yt-dlp ffmpeg python3 node git; do
  if command -v $tool &>/dev/null; then
    echo "  ✅ $tool 已安装"
  else
    echo "  安装 $tool..."
    brew install $tool
  fi
done

if python3 -c "import whisper" &>/dev/null; then
  echo "  ✅ whisper 已安装"
else
  echo "  安装 whisper..."
  pip3 install openai-whisper --break-system-packages 2>/dev/null || pip3 install openai-whisper
fi

# Step 3: 挂载共享目录
echo "[3/6] 挂载共享目录..."
SHARED_DIR="/Volumes/shared"
if mount | grep -q "$SHARED_DIR"; then
  echo "  ✅ 已挂载"
else
  sudo mkdir -p "$SHARED_DIR"
  echo "  请输入中控 ($CONTROLLER_USER@$CONTROLLER_IP) 的密码:"
  mount_smbfs "//${CONTROLLER_USER}@${CONTROLLER_IP}/production" "$SHARED_DIR"
  if [ -d "$SHARED_DIR/tasks" ]; then
    echo "  ✅ 挂载成功"
  else
    echo "  ❌ 挂载失败"
    exit 1
  fi
fi

# Step 4: Worker 目录
echo "[4/6] 创建 Worker 目录..."
mkdir -p "$SHARED_DIR/tasks/running/$WORKER_ID"
mkdir -p "$SHARED_DIR/logs/$WORKER_ID"
echo "  ✅ 目录就绪"

# Step 5: 环境变量
echo "[5/6] 配置环境变量..."
ENV_FILE="$HOME/.production.env"
printf 'WORKER_ID=%s\nSHARED_DIR=%s\nCONTROLLER_IP=%s\nREVIEW_SERVER_URL=%s\nDISPATCHER_TOKEN=%s\nAI_AGENT=claude\nPOLL_INTERVAL=30\nCDP_PORT=18781\nJIMENG_CHROME_PROFILE=$HOME/.jimeng-chrome-profile\nLOG_LEVEL=info\n' \
  "$WORKER_ID" "$SHARED_DIR" "$CONTROLLER_IP" "$VPS_URL" "$DISPATCHER_TOKEN" > "$ENV_FILE"

grep -q "production.env" ~/.zprofile 2>/dev/null || echo '[ -f ~/.production.env ] && source ~/.production.env' >> ~/.zprofile
source "$ENV_FILE"
echo "  ✅ 环境变量写入 $ENV_FILE"

# Step 6: 验证
echo "[6/6] 验证..."
echo ""
OK=0; FAIL=0
for check in "yt-dlp:$(which yt-dlp 2>/dev/null)" "ffmpeg:$(which ffmpeg 2>/dev/null)" "node:$(which node 2>/dev/null)" "python3:$(which python3 2>/dev/null)"; do
  name="${check%%:*}"; path="${check#*:}"
  if [ -n "$path" ]; then echo "  ✅ $name"; ((OK++)); else echo "  ❌ $name 缺失"; ((FAIL++)); fi
done
if [ -d "$SHARED_DIR/tasks/pending" ]; then echo "  ✅ 共享目录可读"; ((OK++)); else echo "  ❌ 共享目录不可读"; ((FAIL++)); fi
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$VPS_URL/api/v1/tracks" -H "Authorization: Bearer $DISPATCHER_TOKEN" 2>/dev/null || echo "000")
if [ "$HTTP" = "200" ]; then echo "  ✅ VPS 可连通"; ((OK++)); else echo "  ❌ VPS 连不上 (HTTP $HTTP)"; ((FAIL++)); fi

echo ""
echo "═══════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ 全部通过 ($OK/$OK)"
else
  echo "  ⚠️  通过 $OK, 失败 $FAIL"
fi
echo ""
echo "  下一步:"
echo "  1. npm install -g @anthropic-ai/claude-code"
echo "  2. claude login"
echo "  3. bash ~/production/code/scripts/worker/worker_main.sh"
echo "═══════════════════════════════════════"
