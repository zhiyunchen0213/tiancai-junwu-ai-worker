#!/bin/bash
# bootstrap.sh — macking 首次部署 / 重部署 media-server 服务
#
# 用法:
#   MEDIA_TOKEN='<openssl rand -hex 32 的值>' bash bootstrap.sh
#
# 或者交互式 (token 不进 shell history):
#   bash bootstrap.sh   # 脚本会 prompt 让你粘贴 token
#
# 这个脚本幂等: 可以重复跑, 用来更新 plist / 重部署。
# 每次跑会 bootout 旧 plist 再 bootstrap 新的，所以会触发 ~2-3 秒服务中断。

set -euo pipefail

WORKER_REPO="https://github.com/zhiyunchen0213/tiancai-junwu-ai-worker.git"
WORKER_DIR="$HOME/worker-code"
MEDIA_SRC="$WORKER_DIR/media-server"
AGENT_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/production/logs"

echo "=== media-server bootstrap ==="

# Step 1: 收集 MEDIA_TOKEN
if [ -z "${MEDIA_TOKEN:-}" ]; then
  read -s -p "Paste MEDIA_TOKEN (32 hex chars, or any strong secret): " MEDIA_TOKEN
  echo ""
fi
if [ -z "$MEDIA_TOKEN" ] || [ "${#MEDIA_TOKEN}" -lt 16 ]; then
  echo "ERROR: MEDIA_TOKEN too short (<16 chars). 使用 openssl rand -hex 32 生成."
  exit 1
fi

# Step 2: 确保 worker-code 是正规 git clone (如果不是, 备份并 fresh clone)
if [ -d "$WORKER_DIR/.git" ]; then
  echo "[1/6] worker-code 已是 git clone, 跑 git pull"
  cd "$WORKER_DIR"
  git config http.version HTTP/1.1 || true
  git pull --ff-only
else
  if [ -d "$WORKER_DIR" ]; then
    BACKUP="$WORKER_DIR.backup-$(date +%s)"
    echo "[1/6] worker-code 不是 git clone, 备份到 $BACKUP 然后 fresh clone"
    mv "$WORKER_DIR" "$BACKUP"
  else
    echo "[1/6] 首次 clone worker-code"
  fi
  git clone "$WORKER_REPO" "$WORKER_DIR"
  cd "$WORKER_DIR"
  git config http.version HTTP/1.1
fi

# Step 3: 确保 media-server/ 已经同步下来
if [ ! -f "$MEDIA_SRC/server.mjs" ]; then
  echo "ERROR: $MEDIA_SRC/server.mjs 不存在. 主 repo 是否已经 sync 到 worker repo?"
  echo "  本地跑: bash scripts/sync_to_worker_repo.sh 然后 push worker repo"
  exit 1
fi

# Step 4: 准备日志和部署目录
mkdir -p "$LOG_DIR" "$AGENT_DIR"

# Step 5: 渲染并安装 LaunchAgent plist (替换 __HOME__ 和 __MEDIA_TOKEN__ 占位符)
echo "[2/6] 渲染 com.tiancai.media-server.plist"
sed -e "s|__HOME__|$HOME|g" \
    -e "s|__MEDIA_TOKEN__|$MEDIA_TOKEN|g" \
    "$MEDIA_SRC/deploy/com.tiancai.media-server.plist" \
    > "$AGENT_DIR/com.tiancai.media-server.plist"

echo "[3/6] 渲染 com.tiancai.worker-auto-update.plist"
sed -e "s|__HOME__|$HOME|g" \
    "$MEDIA_SRC/deploy/com.tiancai.worker-auto-update.plist" \
    > "$AGENT_DIR/com.tiancai.worker-auto-update.plist"

chmod +x "$MEDIA_SRC/deploy/auto-update.sh"

# Step 6: bootout (如果存在) + bootstrap
for label in com.tiancai.media-server com.tiancai.worker-auto-update; do
  if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
    echo "[4/6] bootout $label"
    launchctl bootout "gui/$UID" "$AGENT_DIR/$label.plist" 2>&1 || true
  fi
done

for label in com.tiancai.media-server com.tiancai.worker-auto-update; do
  echo "[5/6] bootstrap $label"
  launchctl bootstrap "gui/$UID" "$AGENT_DIR/$label.plist"
done

# Step 7: 等 media-server 起来, curl health check
echo "[6/6] 等 media-server 启动..."
sleep 2
for i in 1 2 3 4 5; do
  if curl -sf http://localhost:9000/health >/dev/null 2>&1; then
    echo "✓ media-server /health OK"
    echo ""
    echo "=== bootstrap 完成 ==="
    echo "  worker-code: $WORKER_DIR (git clone)"
    echo "  media-server: 跑在 localhost:9000"
    echo "  auto-update: 每 10 分钟 git pull, 变更时自动 kickstart"
    echo ""
    echo "下一步: 更新 VPS 的 MEDIA_TOKEN 到同一个值"
    exit 0
  fi
  sleep 2
done

echo "ERROR: media-server 没在 10 秒内起来. 看 $LOG_DIR/media-server.log"
exit 1
