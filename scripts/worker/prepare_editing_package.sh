#!/bin/bash
# prepare_editing_package.sh — 在 macking 上整理剪辑包到桌面
#
# 用法: bash prepare_editing_package.sh <task_id>
# 运行位置: macking（可由 harvest 完成后自动触发，也可手动执行）
#
# 数据来源:
#   视频文件:    ~/production/deliveries/{taskId}/videos/
#   原视频:      ~/production/delivery/{taskId}/original.mp4
#   参考图:      ~/production/delivery/{taskId}/参考图/ 或 deliveries/{taskId}/参考图/
#   submit_state: ~/production/delivery/{taskId}/phase_b/submit_state.json
#   改编大纲:    VPS API → /api/v1/tasks/{taskId} → adaptation_plan
#
# 输出:
#   ~/Desktop/剪辑包/{赛道名}_{短ID}/
#     原视频.mp4
#     改编大纲.md
#     批次1/Pro.mp4, Fast.mp4, Pro_重做.mp4, ...
#     批次2/...
#     参考图/

set -euo pipefail

TASK_ID="${1:?用法: bash prepare_editing_package.sh <task_id>}"
SHORT_ID="${TASK_ID##*-}"  # 提取最后的短 ID（如 iq96_dir1）

DELIVERIES_DIR="$HOME/production/deliveries/${TASK_ID}"
DELIVERY_DIR="$HOME/production/delivery/${TASK_ID}"
REVIEW_URL="${REVIEW_SERVER_URL:-https://studio.createflow.art}"
DTOK="${DISPATCHER_TOKEN:-}"

# 从 .production.env 读取 token（如果没设置）
if [[ -z "$DTOK" ]] && [[ -f "$HOME/.production.env" ]]; then
    DTOK=$(grep DISPATCHER_TOKEN "$HOME/.production.env" 2>/dev/null | cut -d= -f2 || echo "")
fi

echo "=== 准备剪辑包: $TASK_ID ==="

# ── Step 1: 从 VPS 获取任务信息 ──
echo "[1/5] 获取任务信息..."
TASK_JSON=$(curl -sf -H "Authorization: Bearer ${DTOK}" \
    "${REVIEW_URL}/api/v1/tasks/${TASK_ID}" 2>/dev/null || echo "{}")

TRACK=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('track','unknown'))" 2>/dev/null || echo "unknown")
ADAPTATION=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('adaptation_plan',''))" 2>/dev/null || echo "")
SYNOPSIS=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('synopsis',''))" 2>/dev/null || echo "")

# 赛道中文名映射
case "$TRACK" in
    kindness-reversal) TRACK_CN="善意反转" ;;
    kpop-dance)        TRACK_CN="KPOP舞蹈" ;;
    zombie-horror)     TRACK_CN="僵尸恐怖" ;;
    *)                 TRACK_CN="$TRACK" ;;
esac

PACKAGE_NAME="${TRACK_CN}_${SHORT_ID}"
PACKAGE_DIR="$HOME/Desktop/剪辑包/${PACKAGE_NAME}"

echo "  赛道: $TRACK_CN"
echo "  输出: $PACKAGE_DIR"

# 清理旧的（如果存在）
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

# ── Step 2: 获取 asset 信息并建立映射 ──
echo "[2/5] 获取视频映射..."

# 从 VPS API 获取 assets（含 batch_num, model, generation_round）
ASSETS_TMP="/tmp/editing_pkg_assets_$$.json"
curl -sf -H "Authorization: Bearer ${DTOK}" \
    "${REVIEW_URL}/api/review/tasks/${TASK_ID}/gate/g4" > "$ASSETS_TMP" 2>/dev/null || echo "{}" > "$ASSETS_TMP"

# 用 Python 生成重命名映射
python3 - "$ASSETS_TMP" "$DELIVERIES_DIR/videos" "$PACKAGE_DIR" << 'PYEOF'
import sys, json, os, shutil

with open(sys.argv[1], encoding='utf-8-sig') as f:
    assets_json = json.load(f)
video_src = sys.argv[2]
pkg_dir = sys.argv[3]

assets = [a for a in assets_json.get("assets", []) if a.get("type") == "generated_video"]
if not assets:
    print("  ⚠ 无视频 assets")
    sys.exit(0)

# 按 batch_num 分组
batches = {}
for a in assets:
    meta = json.loads(a.get("metadata", "{}"))
    bn = a.get("batch_num", 1)
    model = meta.get("model", "unknown")
    gen_round = a.get("generation_round", 1)
    fn = a.get("filename", "")

    if bn not in batches:
        batches[bn] = []
    batches[bn].append({
        "filename": fn,
        "model": model,
        "round": gen_round,
    })

max_round = max(a.get("generation_round", 1) for a in assets)

for bn in sorted(batches.keys()):
    batch_dir = os.path.join(pkg_dir, f"批次{bn}")
    os.makedirs(batch_dir, exist_ok=True)

    for item in sorted(batches[bn], key=lambda x: (x["round"], x["model"])):
        # 确定目标文件名
        model_label = "Fast" if "fast" in item["model"].lower() else "Pro"
        if item["round"] > 1:
            # 多轮重做: 第2轮=重做, 第3轮=重做2, ...
            redo_suffix = "_重做" if item["round"] == 2 else f"_重做{item['round']-1}"
            target_name = f"{model_label}{redo_suffix}.mp4"
        else:
            target_name = f"{model_label}.mp4"

        # 避免同名冲突（同一轮+同模型有多个结果时）
        target_path = os.path.join(batch_dir, target_name)
        counter = 2
        while os.path.exists(target_path):
            base = target_name.rsplit(".", 1)[0]
            target_path = os.path.join(batch_dir, f"{base}_{counter}.mp4")
            counter += 1

        # 复制或硬链接视频文件
        src = os.path.join(video_src, item["filename"])
        if os.path.exists(src):
            os.link(src, target_path)  # 硬链接，不占额外磁盘
            print(f"  批次{bn}/{os.path.basename(target_path)} ← {item['filename']}")
        else:
            print(f"  ⚠ 文件不存在: {item['filename']}")

print(f"  共 {len(batches)} 个批次")
os.remove(sys.argv[1])  # 清理临时文件
PYEOF

# ── Step 3: 获取原视频 ──
# 优先级: 本地 delivery 目录（存量兼容）→ VPS 回拉（新路径）
echo "[3/5] 获取原视频..."
ORIGINAL=""
CLEANUP_TMP=""

# 1) 本地 delivery 目录（存量任务可能已经有）
for candidate in \
    "$DELIVERY_DIR/original.mp4" \
    "$DELIVERIES_DIR/original.mp4"; do
    if [[ -f "$candidate" ]]; then
        ORIGINAL="$candidate"
        break
    fi
done

# 2) 本地没有 → 从 VPS 回拉
if [[ -z "$ORIGINAL" ]] && [[ -n "$DTOK" ]]; then
    TMP_ORIG="/tmp/original_${TASK_ID}_$$.mp4"
    if curl -sf \
        -H "Authorization: Bearer ${DTOK}" \
        --max-time 180 --retry 2 --retry-delay 3 --retry-max-time 180 \
        "${REVIEW_URL}/api/v1/tasks/${TASK_ID}/source-video" \
        -o "$TMP_ORIG" 2>/dev/null && [[ -s "$TMP_ORIG" ]]; then
        ORIGINAL="$TMP_ORIG"
        CLEANUP_TMP="$TMP_ORIG"
        echo "  ✓ 从 VPS 回拉原视频"
    else
        rm -f "$TMP_ORIG"
    fi
fi

# 3) 落位到包内
if [[ -n "$ORIGINAL" ]]; then
    if [[ -n "$CLEANUP_TMP" ]]; then
        # 来自 /tmp 的回拉文件：mv（跨 FS 时自动 copy+unlink）
        mv "$ORIGINAL" "$PACKAGE_DIR/原视频.mp4"
    else
        # 来自本地 delivery 目录：硬链接优先（不占磁盘），失败降级 cp
        ln "$ORIGINAL" "$PACKAGE_DIR/原视频.mp4" 2>/dev/null || \
            cp "$ORIGINAL" "$PACKAGE_DIR/原视频.mp4"
    fi
    echo "  ✓ 原视频已添加"
else
    echo "  ⚠ 原视频回拉失败，包中缺失"
fi

# ── Step 4: 写入改编大纲 ──
echo "[4/5] 生成改编大纲..."
if [[ -n "$ADAPTATION" ]] && [[ "$ADAPTATION" != "null" ]]; then
    {
        echo "# 改编大纲"
        echo ""
        if [[ -n "$SYNOPSIS" ]] && [[ "$SYNOPSIS" != "null" ]]; then
            echo "## 故事简介"
            echo "$SYNOPSIS"
            echo ""
        fi
        echo "## 改编方案与剪辑思路"
        echo "$ADAPTATION"
    } > "$PACKAGE_DIR/改编大纲.md"
    echo "  ✓ 改编大纲已生成"
else
    echo "  ⚠ 无改编大纲数据"
fi

# ── Step 5: 复制参考图 ──
echo "[5/5] 复制参考图..."
REFS_SRC=""
for candidate in \
    "$DELIVERY_DIR/参考图" \
    "$DELIVERIES_DIR/参考图"; do
    if [[ -d "$candidate" ]] && [[ -n "$(ls -A "$candidate" 2>/dev/null)" ]]; then
        REFS_SRC="$candidate"
        break
    fi
done

if [[ -n "$REFS_SRC" ]]; then
    mkdir -p "$PACKAGE_DIR/参考图"
    # 只复制主要参考图（不含 .png 别名）
    for f in "$REFS_SRC"/*.jpeg "$REFS_SRC"/*.jpg; do
        [[ -f "$f" ]] || continue
        ln "$f" "$PACKAGE_DIR/参考图/$(basename "$f")" 2>/dev/null || \
            cp "$f" "$PACKAGE_DIR/参考图/$(basename "$f")"
    done
    REF_COUNT=$(ls -1 "$PACKAGE_DIR/参考图/" 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✓ ${REF_COUNT} 张参考图"
else
    echo "  ⚠ 无参考图"
fi

echo ""
echo "=== 剪辑包准备完成 ==="
echo "路径: $PACKAGE_DIR"
echo "内容:"
find "$PACKAGE_DIR" -type f | sort | while read f; do
    echo "  ${f#$PACKAGE_DIR/}"
done
echo ""
TOTAL_SIZE=$(du -sh "$PACKAGE_DIR" | cut -f1)
echo "总大小: $TOTAL_SIZE"
