#!/bin/bash
# deploy_heartbeat.sh — 拉取最新代码 + 重启 Worker（带心跳）
# 用法: bash deploy_heartbeat.sh
# 在每台 Mac mini (m1, m3) 上执行即可

set -euo pipefail

REPO_URL="https://github.com/zhiyunchen0213/tiancai-junwu-ai-worker.git"
CODE_DIR="$HOME/worker-code"

echo ""
echo "═══════════════════════════════════════"
echo "  部署 Worker 心跳修复"
echo "═══════════════════════════════════════"
echo ""

# Step 1: 确保代码目录是 git 仓库
if [ -d "$CODE_DIR/.git" ]; then
  echo "[1/4] 代码目录已存在，拉取更新..."
  cd "$CODE_DIR"
  git pull origin main
else
  echo "[1/4] 初始化代码目录..."
  # 备份旧文件（如有）
  if [ -d "$CODE_DIR" ]; then
    mv "$CODE_DIR" "${CODE_DIR}.bak.$(date +%s)"
    echo "  旧目录已备份"
  fi
  git clone "$REPO_URL" "$CODE_DIR"
  cd "$CODE_DIR"
fi
echo "  ✅ 代码已就绪"

# 确保 ~/production/code 指向正确位置
ln -sfn "$CODE_DIR" "$HOME/production/code" 2>/dev/null || true

# Step 3: 停止旧 Worker
echo "[3/4] 停止旧 Worker 进程..."
OLD_PIDS=$(pgrep -f "worker_main.sh" 2>/dev/null || true)
if [ -n "$OLD_PIDS" ]; then
  echo "  发现旧进程: $OLD_PIDS"
  kill $OLD_PIDS 2>/dev/null || true
  sleep 3
  # 确认已停止
  REMAINING=$(pgrep -f "worker_main.sh" 2>/dev/null || true)
  if [ -n "$REMAINING" ]; then
    kill -9 $REMAINING 2>/dev/null || true
  fi
  echo "  ✅ 旧进程已停止"
else
  echo "  (无旧进程)"
fi

# Step 4: 启动新 Worker
echo "[4/4] 启动新 Worker..."
source ~/.production.env 2>/dev/null || true
WORKER_ID="${WORKER_ID:-unknown}"
LOG_DIR="${HOME}/production/logs"
mkdir -p "$LOG_DIR"

nohup bash "$CODE_DIR/scripts/worker/worker_main.sh" > "$LOG_DIR/worker.log" 2>&1 &
NEW_PID=$!
sleep 2

# 验证
if kill -0 $NEW_PID 2>/dev/null; then
  echo ""
  echo "═══════════════════════════════════════"
  echo "  ✅ Worker $WORKER_ID 已启动 (PID: $NEW_PID)"
  echo "  心跳间隔: ${HEARTBEAT_INTERVAL:-60}s"
  echo "  查看日志: tail -f $LOG_DIR/worker.log"
  echo "═══════════════════════════════════════"
else
  echo "  ❌ Worker 启动失败，查看日志:"
  tail -5 "$LOG_DIR/worker.log" 2>/dev/null
  exit 1
fi
