#!/bin/bash

# === 共享存储初始化脚本 ===
# 用途: 在主控 Mac mini 上初始化共享存储目录结构
# 用法: ./init_shared_storage.sh [optional_shared_dir]

set -e

# 默认共享目录
DEFAULT_SHARED_DIR="/Volumes/shared"
SHARED_DIR="${1:-$DEFAULT_SHARED_DIR}"

# 如果存在 .env 文件，尝试从中读取 SHARED_DIR
if [ -f ".env" ]; then
    SHARED_DIR=$(grep "^SHARED_DIR=" .env | cut -d'=' -f2 | tr -d ' ')
    if [ -z "$SHARED_DIR" ]; then
        SHARED_DIR="$DEFAULT_SHARED_DIR"
    fi
fi

echo "=== 共享存储初始化 ==="
echo "共享目录: $SHARED_DIR"
echo ""

# 创建基础目录
echo "创建基础目录结构..."

# tasks 目录树
mkdir -p "$SHARED_DIR/tasks/pending"
mkdir -p "$SHARED_DIR/tasks/running"
for i in {1..10}; do
    mkdir -p "$SHARED_DIR/tasks/running/worker-$i"
done
mkdir -p "$SHARED_DIR/tasks/harvesting"
mkdir -p "$SHARED_DIR/tasks/completed"
mkdir -p "$SHARED_DIR/tasks/failed"

# assets 目录树
mkdir -p "$SHARED_DIR/assets/characters"
mkdir -p "$SHARED_DIR/assets/scenes"
mkdir -p "$SHARED_DIR/assets/props"

# code 目录树
mkdir -p "$SHARED_DIR/code/skills"
mkdir -p "$SHARED_DIR/code/scripts"
mkdir -p "$SHARED_DIR/code/config"

# 其他目录
mkdir -p "$SHARED_DIR/locks"
mkdir -p "$SHARED_DIR/alerts"
mkdir -p "$SHARED_DIR/logs/daily"
for i in {1..10}; do
    mkdir -p "$SHARED_DIR/logs/worker-$i"
done

echo "✓ 所有目录已创建"
echo ""

# 创建 assets/index.json
echo "初始化 assets/index.json..."
if [ ! -f "$SHARED_DIR/assets/index.json" ]; then
    echo "{}" > "$SHARED_DIR/assets/index.json"
    echo "✓ assets/index.json 已创建"
else
    echo "✓ assets/index.json 已存在（跳过）"
fi
echo ""

# 设置权限为 SMB 共享
echo "设置权限为 SMB 共享 (777)..."
chmod -R 777 "$SHARED_DIR"
echo "✓ 权限已设置"
echo ""

# 生成汇总报告
echo "=== 初始化完成 ==="
echo ""
echo "创建的目录结构:"
echo ""
echo "$SHARED_DIR/"
echo "├── tasks/"
echo "│   ├── pending/              (待处理任务)"
echo "│   ├── running/"
echo "│   │   ├── worker-1/         (各 Worker 运行目录)"
echo "│   │   └── worker-10/"
echo "│   ├── harvesting/           (收获中的任务)"
echo "│   ├── completed/            (已完成的任务)"
echo "│   └── failed/               (失败的任务)"
echo "├── assets/"
echo "│   ├── characters/           (角色资源)"
echo "│   ├── scenes/               (场景资源)"
echo "│   ├── props/                (道具资源)"
echo "│   └── index.json            (资源索引)"
echo "├── code/"
echo "│   ├── skills/               (技能脚本)"
echo "│   ├── scripts/              (执行脚本)"
echo "│   └── config/               (配置文件)"
echo "├── locks/                    (互斥锁文件)"
echo "├── alerts/                   (警报文件)"
echo "└── logs/"
echo "    ├── daily/                (日志存档)"
echo "    ├── worker-1/             (各 Worker 日志)"
echo "    └── worker-10/"
echo ""
echo "权限: 777 (SMB 共享可访问)"
echo ""
