#!/bin/bash
# deploy_heartbeat.sh — 拉取最新代码 + 重启 Worker（带心跳）
# 用法: bash deploy_heartbeat.sh
# 在每台 Mac mini (m1, m3) 上执行即可

set -euo pipefail

echo ""
echo "═══════════════════════════════════════"
echo "  部署 Worker 心跳修复"
echo "═══════════════════════════════════════"
echo ""

# Step 1: 找到代码目录
CODE_DIR=""
for d in ~/worker-code ~/production/code; do
  if [ -d "$d/.git" ]; then
    CODE_DIR="$d"
    break
  fi
done

if [ -z "$CODE_DIR" ]; then
  echo "❌ 找不到代码目录 (~/worker-code 或 ~/production/code)"
  exit 1
fi
echo "[1/4] 代码目录: $CODE_DIR"

# Step 2: 拉取最新代码
cd "$CODE_DIR"
echo "[2/4] 拉取最新代码..."
git pull origin main
echo "  ✅ 代码已更新"

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
