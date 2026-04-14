# media-server

轻量静态文件服务器 (零依赖 Node HTTP)，部署在 **macking**，通过 Cloudflare Tunnel
暴露到 `media.createflow.art`，给 VPS `review-server` 的 `/media-cache` 路由做回源。

## 角色

```
VPS review-server                     macking
/media-cache/<path>                   ~/production/deliveries/<path>
  ├─ cache hit → VPS 磁盘返回             ▲
  └─ cache miss ────(Cloudflare)───────> media-server :9000
                    Authorization header        └─ 校验 MEDIA_TOKEN
                                                └─ path traversal 检查
                                                └─ 流式返回 (支持 Range)
```

## 部署机制

代码通过主 repo 同步到 worker repo，macking 每 10 分钟 git pull（LaunchAgent
`com.tiancai.worker-auto-update`）。进程由 `com.tiancai.media-server` LaunchAgent
管理，KeepAlive 保活。

```
主 repo: /path/to/TiancaixJunwu_Aivideo_system/media-server/
  ↓ scripts/sync_to_worker_repo.sh
worker repo: /path/to/TiancaixJunwu_Aivideo_worker/media-server/
  ↓ git push origin main
GitHub: zhiyunchen0213/tiancai-junwu-ai-worker
  ↓ macking ~/worker-code/ git pull (每 10 分钟)
macking: ~/worker-code/media-server/server.mjs
  ↑ LaunchAgent com.tiancai.media-server
    ProgramArguments: /opt/homebrew/bin/node $HOME/worker-code/media-server/server.mjs
```

## 首次部署 (macking)

```bash
# 在 macking 上跑一次。MEDIA_TOKEN 通过 env 传入，不会留在 shell history 里。
MEDIA_TOKEN='<openssl rand -hex 32 生成的值>' \
  bash $HOME/worker-code/media-server/deploy/bootstrap.sh
```

bootstrap.sh 会：

1. 备份旧 `~/worker-code`（如存在非 git 版本）
2. fresh clone worker repo 到 `~/worker-code`
3. 装 `com.tiancai.worker-auto-update.plist`（10 分钟 git pull + 检测 media-server 变更自动重启）
4. 装 `com.tiancai.media-server.plist`（含 `MEDIA_TOKEN` env var）
5. bootout 旧进程 + bootstrap 新进程
6. 跑 `curl localhost:9000/health` 验证

## Token Rotation

**必须 VPS 和 macking 两端同步切换**，否则回源立刻断。

**推荐路径（零中断）:**

1. 生成新 token: `openssl rand -hex 32`
2. **macking** 先更新 plist：
   ```bash
   ssh brain "ssh -p 2223 zjw-mini@127.0.0.1 'plutil -replace EnvironmentVariables.MEDIA_TOKEN -string \"<新 token>\" ~/Library/LaunchAgents/com.tiancai.media-server.plist && launchctl bootout gui/$UID ~/Library/LaunchAgents/com.tiancai.media-server.plist && launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.tiancai.media-server.plist'"
   ```
3. **立即**更新 VPS `.env`：
   ```bash
   ssh brain "sed -i 's/^MEDIA_TOKEN=.*/MEDIA_TOKEN=<新 token>/' /opt/system-repo/review-server/.env && pm2 restart review-server"
   ```
4. 验证：`curl -H "Authorization: Bearer <新 token>" https://media.createflow.art/health`
5. 验证：VPS `/media-cache/<task>/<sub>/<file>` cache miss 能回源成功

实际窗口：macking 重启 ~2 秒 + VPS pm2 restart ~4 秒。如果两步间隔 <5 秒，用户
看到的只是冷 cache 请求失败一次；reload 后自然恢复。**永远先改 macking 再改 VPS**
（macking 进程重启完 → VPS 发旧 token 被拒 401 → VPS 重启后发新 token → 通）。

## 安全契约

- **公开暴露**: Cloudflare Tunnel，任何 IP 可达
- **唯一凭证**: `MEDIA_TOKEN`（32 字节随机）
- **路径白名单**: 所有请求必须 resolve 到 `MEDIA_ROOT` 目录内，防 traversal
- **health check 不鉴权**: `GET /health` → 用于 LaunchAgent/Cloudflare 存活探测
- **日志**: `~/production/logs/media-server.log` (stdout + stderr)
