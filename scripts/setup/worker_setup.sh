#!/bin/bash
set -euo pipefail

# ============================================================
# worker_setup.sh — Worker Mac mini 一键部署脚本
#
# 在新的 Mac mini 上运行此脚本，自动完成：
# 1. 检查系统环境
# 2. 安装所有依赖工具
# 3. 挂载主控共享目录
# 4. 配置环境变量
# 5. 配置 Chrome 即梦 profile
# 6. 注册为 Worker
#
# 用法:
#   bash worker_setup.sh --worker-id worker-1 --controller-ip 192.168.1.100
#
# ============================================================

# === 颜色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[✅]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[⚠️]${NC} $*"; }
log_error() { echo -e "${RED}[❌]${NC} $*"; }

# ============================================================
# 参数解析
# ============================================================

WORKER_ID=""
CONTROLLER_IP=""
CONTROLLER_USER="$(whoami)"
CONTROLLER_PASS=""
SHARED_MOUNT="/Volumes/shared"
CDP_PORT=18781
SKIP_INSTALL=false

print_usage() {
  echo "用法: bash worker_setup.sh [选项]"
  echo ""
  echo "必填参数:"
  echo "  --worker-id ID         Worker 标识 (如 worker-1)"
  echo "  --controller-ip IP     主控 Mac mini 的 IP 地址"
  echo ""
  echo "可选参数:"
  echo "  --controller-user USER SMB 用户名 (默认: 当前用户)"
  echo "  --controller-pass PASS SMB 密码 (不填则交互输入)"
  echo "  --mount-point PATH     共享目录挂载点 (默认: /Volumes/shared)"
  echo "  --cdp-port PORT        Chrome CDP 端口 (默认: 18781)"
  echo "  --skip-install         跳过工具安装 (已安装过的机器)"
  echo ""
  echo "示例:"
  echo "  bash worker_setup.sh --worker-id worker-1 --controller-ip 192.168.1.100"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --worker-id)       WORKER_ID="$2"; shift 2 ;;
    --controller-ip)   CONTROLLER_IP="$2"; shift 2 ;;
    --controller-user) CONTROLLER_USER="$2"; shift 2 ;;
    --controller-pass) CONTROLLER_PASS="$2"; shift 2 ;;
    --mount-point)     SHARED_MOUNT="$2"; shift 2 ;;
    --cdp-port)        CDP_PORT="$2"; shift 2 ;;
    --skip-install)    SKIP_INSTALL=true; shift ;;
    --help|-h)         print_usage; exit 0 ;;
    *)                 log_error "未知参数: $1"; print_usage; exit 1 ;;
  esac
done

if [ -z "$WORKER_ID" ] || [ -z "$CONTROLLER_IP" ]; then
  log_error "缺少必填参数 --worker-id 和 --controller-ip"
  print_usage
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Worker Mac mini 一键部署"
echo "  Worker ID:     $WORKER_ID"
echo "  Controller IP: $CONTROLLER_IP"
echo "═══════════════════════════════════════════════════════"
echo ""

# ============================================================
# Step 1: 系统环境检查
# ============================================================

log_info "Step 1/6: 检查系统环境..."

# 检查 macOS
if [[ "$(uname)" != "Darwin" ]]; then
  log_error "此脚本仅支持 macOS"
  exit 1
fi
log_ok "macOS $(sw_vers -productVersion)"

# 检查 Homebrew
if ! command -v brew &>/dev/null; then
  log_warn "Homebrew 未安装，正在安装..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Apple Silicon 需要添加 PATH
  if [[ "$(uname -m)" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  fi
fi
log_ok "Homebrew $(brew --version | head -1)"

# 检查网络连通性
# macOS ping -W 单位为毫秒，用 -t 设置总超时秒数
if ping -c 1 -t 3 "$CONTROLLER_IP" &>/dev/null; then
  log_ok "主控 $CONTROLLER_IP 网络可达"
else
  log_error "无法连通主控 $CONTROLLER_IP，请检查网络"
  exit 1
fi

# ============================================================
# Step 2: 安装工具链
# ============================================================

log_info "Step 2/6: 安装工具链..."

if [ "$SKIP_INSTALL" = true ]; then
  log_warn "跳过工具安装 (--skip-install)"
else
  # yt-dlp
  if command -v yt-dlp &>/dev/null; then
    log_ok "yt-dlp 已安装: $(yt-dlp --version)"
  else
    log_info "安装 yt-dlp..."
    brew install yt-dlp
    log_ok "yt-dlp 安装完成"
  fi

  # ffmpeg
  if command -v ffmpeg &>/dev/null; then
    log_ok "ffmpeg 已安装: $(ffmpeg -version | head -1)"
  else
    log_info "安装 ffmpeg..."
    brew install ffmpeg
    log_ok "ffmpeg 安装完成"
  fi

  # Python3 + whisper
  if command -v python3 &>/dev/null; then
    log_ok "Python3 已安装: $(python3 --version)"
  else
    log_info "安装 Python3..."
    brew install python3
  fi

  if python3 -c "import whisper" &>/dev/null; then
    log_ok "openai-whisper 已安装"
  else
    log_info "安装 openai-whisper..."
    pip3 install openai-whisper --break-system-packages
    log_ok "openai-whisper 安装完成"
  fi

  # Node.js
  if command -v node &>/dev/null; then
    log_ok "Node.js 已安装: $(node --version)"
  else
    log_info "安装 Node.js..."
    brew install node
    log_ok "Node.js 安装完成"
  fi

  # Playwright
  if npx playwright-core --version &>/dev/null 2>&1; then
    log_ok "playwright-core 已安装"
  else
    log_info "安装 playwright-core..."
    npm install -g playwright-core
    log_ok "playwright-core 安装完成"
  fi

  # Kimi CLI（检查是否存在，不自动安装）
  if command -v kimi &>/dev/null; then
    log_ok "Kimi CLI 已安装"
  else
    log_warn "Kimi CLI 未安装，请手动安装: https://github.com/kimiapi/kimi-cli"
    log_warn "跳过 Kimi CLI，后续 Phase A 分析环节可能失败"
  fi
fi

# ============================================================
# Step 3: 挂载主控共享目录
# ============================================================

log_info "Step 3/6: 挂载主控共享目录..."

if mount | grep -q "$SHARED_MOUNT"; then
  log_ok "共享目录已挂载: $SHARED_MOUNT"
else
  # 创建挂载点
  sudo mkdir -p "$SHARED_MOUNT"

  # 获取密码
  if [ -z "$CONTROLLER_PASS" ]; then
    echo -n "请输入主控 SMB 密码 ($CONTROLLER_USER@$CONTROLLER_IP): "
    read -s CONTROLLER_PASS
    echo ""
  fi

  # 挂载 SMB（URL 编码密码，防止 @#:/ 等特殊字符破坏 URL）
  ENCODED_PASS=$(python3 -c "from urllib.parse import quote; import os; print(quote(os.environ['CONTROLLER_PASS'], safe=''))" 2>/dev/null || echo "$CONTROLLER_PASS")
  log_info "挂载 smb://$CONTROLLER_USER@$CONTROLLER_IP/production ..."
  mount_smbfs "//$CONTROLLER_USER:$ENCODED_PASS@$CONTROLLER_IP/production" "$SHARED_MOUNT"

  if mount | grep -q "$SHARED_MOUNT"; then
    log_ok "共享目录挂载成功: $SHARED_MOUNT"
  else
    log_error "共享目录挂载失败"
    exit 1
  fi
fi

# 验证共享目录结构
if [ -d "$SHARED_MOUNT/tasks/pending" ] && [ -d "$SHARED_MOUNT/assets" ]; then
  log_ok "共享目录结构验证通过"
else
  log_error "共享目录结构不完整，请先在主控运行 init_shared_storage.sh"
  exit 1
fi

# 确保 Worker 目录存在
mkdir -p "$SHARED_MOUNT/tasks/running/$WORKER_ID"
mkdir -p "$SHARED_MOUNT/logs/$WORKER_ID"
log_ok "Worker 目录已就绪: $SHARED_MOUNT/tasks/running/$WORKER_ID"

# ============================================================
# Step 4: 配置环境变量
# ============================================================

log_info "Step 4/6: 配置环境变量..."

ENV_FILE="$HOME/.production.env"

# 如果主控上有 .env 模板，先复制
if [ -f "$SHARED_MOUNT/code/config/.env" ]; then
  cp "$SHARED_MOUNT/code/config/.env" "$ENV_FILE"
  log_info "已从主控复制 .env 配置"
fi

# 写入 Worker 专属配置
cat > "$ENV_FILE" << EOF
# === 生产线环境配置 (${WORKER_ID}) ===
# 自动生成于 $(date)

# Worker 标识
WORKER_ID=${WORKER_ID}

# 共享存储挂载点
SHARED_DIR=${SHARED_MOUNT}

# 主控 IP
CONTROLLER_IP=${CONTROLLER_IP}

# Chrome CDP 端口
CDP_PORT=${CDP_PORT}

# 即梦 Chrome 用户数据目录
JIMENG_CHROME_PROFILE=\$HOME/.jimeng-chrome-profile

# AI Agent 调用方式 (claude / codex / openai-api)
AI_AGENT=claude

# 轮询间隔（秒）
POLL_INTERVAL=30

# 日志级别
LOG_LEVEL=info

# === 以下需要手动填写 ===

# 云雾 API Key
YUNWU_API_KEY=

# Kimi API Key
KIMI_API_KEY=
EOF

log_ok "环境变量已写入: $ENV_FILE"
log_warn "请手动编辑 $ENV_FILE 填写 API Keys"

# 加入 shell profile
PROFILE="$HOME/.zprofile"
if ! grep -q "production.env" "$PROFILE" 2>/dev/null; then
  echo "" >> "$PROFILE"
  echo "# 生产线环境变量" >> "$PROFILE"
  echo "[ -f ~/.production.env ] && source ~/.production.env" >> "$PROFILE"
  log_ok "已添加到 $PROFILE，下次登录自动加载"
fi

# 立即加载
source "$ENV_FILE"

# ============================================================
# Step 5: 配置 Chrome + 即梦
# ============================================================

log_info "Step 5/6: 配置 Chrome 即梦 profile..."

CHROME_PROFILE="$HOME/.jimeng-chrome-profile"

if [ -d "$CHROME_PROFILE" ]; then
  log_ok "Chrome profile 已存在: $CHROME_PROFILE"
else
  mkdir -p "$CHROME_PROFILE"
  log_ok "Chrome profile 已创建: $CHROME_PROFILE"
fi

# 创建 Chrome 启动脚本
CHROME_LAUNCHER="$HOME/start_jimeng_chrome.sh"
cat > "$CHROME_LAUNCHER" << 'SCRIPT'
#!/bin/bash
# 启动即梦专用 Chrome（带 CDP 端口）

source ~/.production.env

CHROME_APP="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -f "$CHROME_APP" ]; then
  echo "❌ Google Chrome 未安装"
  exit 1
fi

echo "🌐 启动即梦专用 Chrome..."
echo "   CDP 端口: $CDP_PORT"
echo "   Profile: $JIMENG_CHROME_PROFILE"
echo ""
echo "⚠️  请在 Chrome 中手动登录即梦: https://jimeng.jianying.com"
echo ""

"$CHROME_APP" \
  --remote-debugging-port=$CDP_PORT \
  --user-data-dir="$JIMENG_CHROME_PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  "https://jimeng.jianying.com" &

echo "Chrome 已启动 (PID: $!)"
echo "验证 CDP: curl http://localhost:$CDP_PORT/json/version"
SCRIPT

chmod +x "$CHROME_LAUNCHER"
log_ok "Chrome 启动脚本: $CHROME_LAUNCHER"

# ============================================================
# Step 6: 创建 Worker 启动/停止脚本
# ============================================================

log_info "Step 6/6: 创建 Worker 启动/停止脚本..."

# 启动脚本
WORKER_LAUNCHER="$HOME/start_worker.sh"
cat > "$WORKER_LAUNCHER" << 'SCRIPT'
#!/bin/bash
# 启动 Worker 主循环 + Harvest Daemon

source ~/.production.env
SCRIPTS_DIR="$SHARED_DIR/code/scripts/worker"

echo "═══════════════════════════════════════"
echo "  启动 Worker: $WORKER_ID"
echo "  共享目录: $SHARED_DIR"
echo "═══════════════════════════════════════"

# 检查共享目录可访问
if [ ! -d "$SHARED_DIR/tasks/pending" ]; then
  echo "❌ 共享目录不可访问，请检查 SMB 挂载"
  exit 1
fi

# 检查 Chrome CDP
if ! curl -s "http://localhost:$CDP_PORT/json/version" &>/dev/null; then
  echo "⚠️  Chrome CDP 未启动，请先运行 ~/start_jimeng_chrome.sh"
  echo "   Phase C (即梦提交) 将无法执行"
fi

# 启动 Harvest Daemon（后台）
echo "🔄 启动 Harvest Daemon..."
nohup bash "$SCRIPTS_DIR/harvest_daemon.sh" \
  > "$SHARED_DIR/logs/$WORKER_ID/harvest.log" 2>&1 &
HARVEST_PID=$!
echo "   Harvest Daemon PID: $HARVEST_PID"

# 启动 Worker 主循环（前台，方便看日志）
echo "🚀 启动 Worker 主循环..."
echo "   日志: $SHARED_DIR/logs/$WORKER_ID/"
echo "   按 Ctrl+C 优雅停止"
echo ""

bash "$SCRIPTS_DIR/worker_main.sh" 2>&1 | tee "$SHARED_DIR/logs/$WORKER_ID/worker.log"

# 主循环退出后，停止 Harvest Daemon
echo "停止 Harvest Daemon..."
kill $HARVEST_PID 2>/dev/null
echo "Worker 已停止"
SCRIPT

chmod +x "$WORKER_LAUNCHER"
log_ok "Worker 启动脚本: $WORKER_LAUNCHER"

# 停止脚本
WORKER_STOPPER="$HOME/stop_worker.sh"
cat > "$WORKER_STOPPER" << 'SCRIPT'
#!/bin/bash
# 优雅停止 Worker

echo "发送停止信号..."

# 停止 worker_main.sh
pkill -f "worker_main.sh" 2>/dev/null && echo "✅ Worker 主循环已停止" || echo "Worker 主循环未运行"

# 停止 harvest_daemon.sh
pkill -f "harvest_daemon.sh" 2>/dev/null && echo "✅ Harvest Daemon 已停止" || echo "Harvest Daemon 未运行"

echo "Worker 已完全停止"
SCRIPT

chmod +x "$WORKER_STOPPER"
log_ok "Worker 停止脚本: $WORKER_STOPPER"

# ============================================================
# 部署完成总结
# ============================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Worker 部署完成!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Worker ID:    $WORKER_ID"
echo "  共享目录:      $SHARED_MOUNT"
echo "  环境配置:      $ENV_FILE"
echo ""
echo "  接下来的步骤:"
echo "  1. 编辑 ~/.production.env 填写 YUNWU_API_KEY 和 KIMI_API_KEY"
echo "  2. 运行 ~/start_jimeng_chrome.sh 启动 Chrome 并登录即梦"
echo "  3. 运行 ~/start_worker.sh 启动 Worker"
echo ""
echo "  日常操作:"
echo "  · 启动: ~/start_worker.sh"
echo "  · 停止: ~/stop_worker.sh"
echo "  · 日志: $SHARED_MOUNT/logs/$WORKER_ID/"
echo ""
echo "  如需重新登录即梦:"
echo "  · ~/start_jimeng_chrome.sh"
echo "═══════════════════════════════════════════════════════"
