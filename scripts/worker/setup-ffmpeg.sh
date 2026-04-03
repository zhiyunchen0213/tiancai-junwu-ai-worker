#!/bin/bash
# setup-ffmpeg.sh — 在非 brew worker 上安装 portable ffmpeg
#
# 用法: bash scripts/worker/setup-ffmpeg.sh
#
# 逻辑:
# 1. 如果 ffmpeg 已在 PATH 且能正常运行 → 跳过
# 2. 从 macking 下载预构建的 portable bundle（install_name_tool 重写过，零 homebrew 依赖）
# 3. 安装到 ~/bin/ffmpeg-portable/，创建 ~/bin/ffmpeg 和 ~/bin/ffprobe 符号链接
#
# 构建 portable bundle 的方法（在有 brew 的 macking 上执行）:
#   见 docs/ 或 scripts/worker/build-ffmpeg-portable.sh

set -euo pipefail

INSTALL_DIR="$HOME/bin/ffmpeg-portable"
LINK_DIR="$HOME/bin"
MACKING_HOST="${MACKING_HOST:-192.168.31.222}"
MACKING_USER="${MACKING_USER:-zjw-mini}"
BUNDLE_PATH="/tmp/ffmpeg-portable-arm64.tar.gz"

# 检查是否已有可用的 ffmpeg
if command -v ffmpeg &>/dev/null; then
    if ffmpeg -version &>/dev/null; then
        echo "✓ ffmpeg already works: $(ffmpeg -version 2>&1 | head -1)"
        exit 0
    else
        echo "⚠ ffmpeg found but broken, reinstalling..."
    fi
fi

# 也检查 ~/bin/ffmpeg
if [[ -x "$LINK_DIR/ffmpeg" ]] && "$LINK_DIR/ffmpeg" -version &>/dev/null; then
    echo "✓ ffmpeg already works at $LINK_DIR/ffmpeg"
    exit 0
fi

echo "Installing portable ffmpeg to $INSTALL_DIR ..."

mkdir -p "$INSTALL_DIR" "$LINK_DIR"

# 从 macking 下载 bundle
echo "  Downloading from $MACKING_USER@$MACKING_HOST ..."
if ! scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "$MACKING_USER@$MACKING_HOST:$BUNDLE_PATH" "/tmp/ffmpeg-portable-arm64.tar.gz" 2>/dev/null; then
    echo "✗ Failed to download from macking. Make sure the bundle exists at $BUNDLE_PATH"
    echo "  To rebuild: ssh macking 'bash ~/worker-code/scripts/worker/build-ffmpeg-portable.sh'"
    exit 1
fi

# 解压
tar xzf /tmp/ffmpeg-portable-arm64.tar.gz -C "$INSTALL_DIR"
rm -f /tmp/ffmpeg-portable-arm64.tar.gz

# 确保可执行
chmod +x "$INSTALL_DIR/ffmpeg" "$INSTALL_DIR/ffprobe"

# 创建符号链接（覆盖旧的）
ln -sf "$INSTALL_DIR/ffmpeg" "$LINK_DIR/ffmpeg"
ln -sf "$INSTALL_DIR/ffprobe" "$LINK_DIR/ffprobe"

# 验证
if "$LINK_DIR/ffmpeg" -version &>/dev/null; then
    echo "✓ Installed: $("$LINK_DIR/ffmpeg" -version 2>&1 | head -1)"
else
    echo "✗ Installation failed — ffmpeg doesn't run"
    exit 1
fi
