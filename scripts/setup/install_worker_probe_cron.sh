#!/bin/bash
# install_worker_probe_cron.sh — 在 VPS 上安装 worker 网络探测 cron entry
#
# 用法 (在 VPS 上执行):
#   bash /opt/system-repo/scripts/setup/install_worker_probe_cron.sh
#
# 效果:
#   每 10 min 跑 /opt/system-repo/scripts/probe_worker_health.sh
#   日志: /var/log/worker-probe.log
#   去抖状态: /opt/system-repo/data/worker-probe-suppress/
#
# idempotent: 重跑只检查是否已有 entry, 不会重复添加.

set -euo pipefail

PROBE_SCRIPT="/opt/system-repo/scripts/probe_worker_health.sh"
LOG="/var/log/worker-probe.log"
MARKER="probe_worker_health.sh"  # 用脚本路径作为去重标识

if [[ ! -x "$PROBE_SCRIPT" ]]; then
    echo "✗ $PROBE_SCRIPT 不存在或没执行权限"
    echo "  (确保 git pull 已同步, 然后跑 chmod +x)"
    exit 1
fi

# 确保 log 文件可写
touch "$LOG" 2>/dev/null || { echo "✗ 无法写 $LOG (用 sudo?)"; exit 1; }

# 检查 crontab 里是否已有 entry
if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
    echo "✓ Cron entry 已存在, 无需重复添加"
    crontab -l | grep -F "$MARKER"
    exit 0
fi

# 加 entry: 每 10 min
NEW_ENTRY="*/10 * * * * $PROBE_SCRIPT >> $LOG 2>&1"
(crontab -l 2>/dev/null; echo "$NEW_ENTRY") | crontab -

echo "✓ Cron entry 已添加:"
echo "  $NEW_ENTRY"
echo ""
echo "立即试跑一次确认能工作:"
bash "$PROBE_SCRIPT"
echo "  日志最后 5 行:"
tail -5 "$LOG"
