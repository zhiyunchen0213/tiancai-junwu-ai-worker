# YouTube AI 短视频生产线 — Worker 部署包

> 此仓库仅包含 Worker 执行层代码，由主仓库自动同步生成。
> **请勿在此仓库直接修改代码**，所有改动应在主仓库进行。

## 目录结构

```
scripts/
├── worker/           # Worker 执行脚本
│   ├── worker_main.sh          # 主循环
│   ├── download_and_extract.sh # Phase A: 下载+帧提取
│   ├── transcribe.sh           # Phase A: Whisper 转录
│   ├── analyze_video.sh        # Phase A: Kimi 分析
│   ├── ai_judgment.sh          # Phase B: AI 判断
│   ├── pre_submit_check.mjs    # Phase C: 双闸门校验
│   └── harvest_daemon.sh       # Phase D: 收割守护进程
├── setup/            # 部署脚本
│   ├── worker_setup.sh         # 一键部署
│   ├── init_shared_storage.sh  # 共享存储初始化
│   └── .env.template           # 环境变量模板
shared/
├── schemas/          # 数据契约
│   └── task.schema.json
└── templates/        # 批量清单模板
media-server/         # macking 专用: 零依赖 Node 媒体回源服务
├── server.mjs
├── deploy/           # bootstrap.sh, plist 模板, auto-update.sh
└── README.md
```

## 部署步骤

### 普通 worker (m1~m4)
1. Clone 此仓库到 Mac mini
2. 复制 `scripts/setup/.env.template` 到 `~/.production.env` 并填写配置
3. 运行 `bash scripts/setup/worker_setup.sh`
4. 启动 Worker: `bash scripts/worker/worker_main.sh`

### macking (媒体服务 + 存储)
1. 不跑 worker_main
2. 首次部署: 参考 `media-server/README.md` 的 Token Rotation + bootstrap 流程
3. 后续代码更新由 `com.tiancai.worker-auto-update` LaunchAgent 每 10 分钟自动 git pull
