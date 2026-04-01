# CLAUDE.md — Worker Repo

## Project Overview
YouTube AI Shorts生产线的 Worker 执行层。Mac mini 集群通过 VPS 调度系统领取/执行视频生产任务。

**双仓库架构：**
- **本仓库 (Worker)**: `~/YoutubeProject/TiancaixJunwu_Aivideo_worker` — Bash 脚本，跑在 Mac mini 上
- **System 仓库**: `~/YoutubeProject/TiancaixJunwu_Aivideo_system` — Express.js review-server，跑在 VPS 上

## Architecture
- VPS (brain, 107.175.215.216): review-server (PM2, port 3000), SQLite DB, worker-repo mirror
- Workers (Mac minis): autossh reverse tunnels through cloudflared → VPS
- Task flow: Dashboard submit → DB → Worker poll → Phase A/B/C → Report back
- Auto-update: Workers check GitHub every 5min; fallback rsync from VPS /opt/worker-repo

## Worker Fleet SSH Access
From local dev: `ssh brain` then `ssh m1/m2/m3/m4/macking`
- m1: port 2374, user m1-solider
- m2: port 2222, user m2-solider
- m3: port 2471, user m3-solider
- m4: port 2242, user m4-solider
- macking: port 2223, user zjw-mini
- worker-dev: 开发机，不接入正式流程

## Key Paths (on Workers)
- Code: `~/worker-code/` (git clone), symlinked as `~/production/code`
- Env: `~/.production.env` (WORKER_ID, REVIEW_SERVER_URL, DISPATCHER_TOKEN, etc.)
- Logs: `~/production/logs/worker.log`
- Tasks: `~/production/tasks/running/{worker-id}/`
- Tunnel plist: `~/Library/LaunchAgents/com.tiancai.autossh-tunnel.plist`

## Key Paths (on VPS)
- Review server: `/opt/review-server/` (.env, data/review.db)
- Worker repo mirror: `/opt/worker-repo/` (cron pulls from GitHub every 5min)
- SSH config: `~/.ssh/config` (worker aliases)

## Bash Scripting Rules
- Heredoc with variable interpolation: ALWAYS use `<< 'PYEOF'` (quoted) + env vars, NEVER `<< PYEOF` with `${var}` — prevents code injection
- worker_main.sh uses `set -euo pipefail` for init, then `set +e` before main loop
- Pass values to inline Python via env vars (TJ_FILE, TJ_FIELD, TJ_VALUE), not shell interpolation
- JSON manipulation: use Python `json` module, not jq (not always installed on workers)

## Security Constraints (established 2026-03-30)
- ASSET_SECRET is separate from DISPATCHER_TOKEN (both in VPS .env)
- HMAC signatures: .slice(0, 32) (128-bit), never shorter
- Path traversal: whitelist filenames with regex, resolve+startsWith containment
- No execSync with string interpolation — use execFileSync with args array
- requireDispatcher middleware on sensitive routes (submit, claim, judge)
- escapeHtml must include single quote: `'` → `&#39;`

## Common Operations
- Check all workers: `ssh brain 'source /opt/review-server/.env; curl -s -H "Authorization: Bearer $DISPATCHER_TOKEN" http://localhost:3000/api/v1/workers'`
- Check health: same pattern with `/api/v1/health`
- Restart a worker remotely: `ssh brain "ssh m1 'pkill -f worker_main.sh; sleep 2; source ~/.production.env; nohup bash ~/worker-code/scripts/worker/worker_main.sh > ~/production/logs/worker.log 2>&1 &'"`
- Clean stuck tasks on worker: `ssh brain "ssh m1 'rm -rf ~/production/tasks/running/worker-m1/task-*.json ~/production/tasks/running/worker-m1/work_*'"`
- Deploy review-server: `ssh brain 'cd /opt/review-server && git pull && pm2 restart review-server'`
- DB direct query: `ssh brain "sqlite3 /opt/review-server/data/review.db 'SELECT ...'"`

## Gotchas
- cloudflared is NOT installed on dev machine — use `ssh brain` (direct IP), not cloudflared proxy
- Some workers intermittently can't reach GitHub (GFW) — auto-update has VPS rsync fallback
- Worker task cleanup: must remove BOTH .json files AND work_* dirs from running/
- PM2 review-server restarts clear in-memory heartbeat Map — DB persistence is the source of truth
- .env.template is outdated (still references SMB/CONTROLLER_IP) — actual config uses REVIEW_SERVER_URL
- tasks table uses `id` not `task_id` as primary key column name
