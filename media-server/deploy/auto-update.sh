#!/bin/bash
# auto-update.sh — macking 上每 10 分钟跑一次
# 如果 worker repo 有更新且 media-server/ 目录变了，kickstart media-server 服务
#
# 被 com.tiancai.worker-auto-update LaunchAgent 调用，日志写
# ~/production/logs/worker-auto-update.log

set -euo pipefail

cd "$HOME/worker-code" || exit 1

# git fetch/pull，抓 HEAD 更新前后的 SHA 比较
OLD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "none")
git pull --quiet --ff-only 2>&1 || {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [auto-update] git pull failed, skipping this tick"
  exit 0
}
NEW_SHA=$(git rev-parse HEAD 2>/dev/null || echo "none")

# 无更新, 静默退出
if [ "$OLD_SHA" = "$NEW_SHA" ]; then
  exit 0
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [auto-update] pulled $OLD_SHA..$NEW_SHA"

# 看这次 pull 改了什么路径. 如果 media-server/ 有变化, 重启服务.
CHANGED=$(git diff --name-only "$OLD_SHA" "$NEW_SHA" 2>/dev/null || true)

if echo "$CHANGED" | grep -q '^media-server/'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [auto-update] media-server/ changed, kickstarting service"
  # -k = kill then restart (KeepAlive 会拉起), -s = synchronous
  launchctl kickstart -k "gui/$UID/com.tiancai.media-server" || {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [auto-update] kickstart failed — media-server may need manual bootout+bootstrap"
    exit 1
  }
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [auto-update] media-server restarted"
fi
