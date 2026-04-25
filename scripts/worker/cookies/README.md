# Cookie Refresh & Sync (macking)

为所有 worker 提供 Netscape 格式 cookie 文件, yt-dlp 通过 `--cookies path` 加载,
不依赖每台 worker 的浏览器 / Keychain 状态.

## 架构

```
macking GUI session (Aqua)
  └─ com.tiancai.cookie-refresh LaunchAgent (每 6h)
       └─ refresh-cookies.sh
            ├─ yt-dlp --cookies-from-browser 'chrome:Profile 1' youtube.com → youtube.cookies.txt
            ├─ yt-dlp --cookies-from-browser 'chrome:Profile 1' douyin.com  → douyin.cookies.txt
            └─ sync-cookies-to-workers.sh
                 ├─ scp youtube.cookies.txt → m1/m2/m3/m4:~/.cache/worker-cookies/
                 └─ scp douyin.cookies.txt  → m1/m2/m3/m4:~/.cache/worker-cookies/

worker (m1~m4 + macking 自己)
  └─ yt-dlp --cookies $YT_DLP_*_COOKIES_PATH (download.sh)
```

## 为什么必须跑在 Aqua session

macOS Chrome 把 cookies 用 Keychain 里的 "Chrome Safe Storage" master key 加密.
后台进程 (没有 GUI session 上下文) 调 `--cookies-from-browser chrome` 会看到
"Extracted 0 cookies from chrome (N could not be decrypted)" — 解不开任何一个.

LaunchAgent 加上 `LimitLoadToSessionType=Aqua` 才会等 GUI 用户登录后启动,
此时 Keychain 已解锁, 进程有权限读 master key (首次访问会弹"始终允许"对话框).

## 首次安装步骤 (macking 上)

1. **GUI 登录 + Chrome 访问目标站点**
   - 用 Profile 1 打开 https://www.youtube.com/ 和 https://www.douyin.com/
   - 抖音建议登录账号 (登录态 cookies 30+ 天才过期, 否则 visitor cookies 7 天)

2. **首次 Keychain 授权**
   - 在 macking GUI Terminal 跑一次:
     ```bash
     bash ~/worker-code/scripts/worker/cookies/refresh-cookies.sh
     ```
   - 弹 Keychain 框 "Terminal wants to access ... Chrome Safe Storage" → 点 **Always Allow**
   - 见到 "youtube cookie refreshed → ..." 和 "douyin cookie refreshed → ..." 即成功

3. **安装 LaunchAgent**
   ```bash
   cp ~/worker-code/scripts/worker/cookies/com.tiancai.cookie-refresh.plist.template \
      ~/Library/LaunchAgents/com.tiancai.cookie-refresh.plist
   launchctl unload ~/Library/LaunchAgents/com.tiancai.cookie-refresh.plist 2>/dev/null
   launchctl load ~/Library/LaunchAgents/com.tiancai.cookie-refresh.plist
   ```

4. **验证**
   ```bash
   tail -f ~/production/logs/cookie-refresh.log
   ls -la ~/production/shared/cookies/*.cookies.txt
   ```

## Worker 端配置

每个 worker 的 `~/.production.env`:

```bash
# macking (本地路径, 直接读源文件)
YT_DLP_COOKIES_PATH=/Users/zjw-mini/production/shared/cookies/youtube.cookies.txt
YT_DLP_DOUYIN_COOKIES_PATH=/Users/zjw-mini/production/shared/cookies/douyin.cookies.txt

# m1~m4 (sync 推过来的本地缓存)
YT_DLP_COOKIES_PATH=/Users/<user>/.cache/worker-cookies/youtube.cookies.txt
YT_DLP_DOUYIN_COOKIES_PATH=/Users/<user>/.cache/worker-cookies/douyin.cookies.txt
```

`scripts/worker/material-ingest/download.sh` 自动按 URL 域名选择对应 cookie 文件.

## 加新站点

改 `refresh-cookies.sh` 加 `refresh_one <site> <url>` 一行, 改 `sync-cookies-to-workers.sh`
的 `FILES` 数组加 `<site>.cookies.txt`. download.sh 里加 URL 匹配 + 对应 env var.
