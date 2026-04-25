#!/bin/bash
# scripts/worker/cookies/sync-cookies-to-workers.sh
# 把 macking 上 ~/production/shared/cookies/*.cookies.txt 推到所有其他 worker 的
# ~/.cache/worker-cookies/ 目录, 供 yt-dlp --cookies path 加载.
#
# Netscape txt 是 yt-dlp 原生格式, worker 不用再解析, 也不受 macOS 沙盒 TCC 拦.
# mDNS 主机名兜底 LAN IP 变动.

set -u
SRC_DIR="$HOME/production/shared/cookies"
REMOTE_DIR=".cache/worker-cookies"

# 当前要同步的站点 cookie 文件. 加新站点改这一行即可.
FILES=("youtube.cookies.txt" "douyin.cookies.txt")

# 检查源文件
missing=0
for f in "${FILES[@]}"; do
    if [[ ! -f "$SRC_DIR/$f" ]]; then
        echo "[$(date)] WARN source missing: $SRC_DIR/$f (跳过该文件分发)" >&2
        missing=$((missing+1))
    fi
done

# 全部都缺就直接失败, 不用浪费 SSH
if [[ "$missing" -ge "${#FILES[@]}" ]]; then
    echo "[$(date)] all cookie sources missing, abort" >&2
    exit 1
fi

# 并发推到 4 台 worker
for host_user in \
    "M1-soliderdeMac-mini.local:m1-solider" \
    "M2-soliderdeMac-mini.local:m2-solider" \
    "m3-soliderdeMac-mini.local:m3-solider" \
    "M4-soliderdeMac-mini.local:m4-solider"; do
    host="${host_user%%:*}"
    user="${host_user##*:}"
    (
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "$user@$host" "mkdir -p $REMOTE_DIR" 2>/dev/null \
            || { echo "[$(date)] → $user@$host UNREACHABLE"; exit 0; }

        for f in "${FILES[@]}"; do
            [[ -f "$SRC_DIR/$f" ]] || continue
            scp -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                "$SRC_DIR/$f" "$user@$host:$REMOTE_DIR/$f" 2>/dev/null \
                && echo "[$(date)] → $user@$host $f OK" \
                || echo "[$(date)] → $user@$host $f FAIL"
        done
    ) &
done
wait
echo "[$(date)] sync done"
