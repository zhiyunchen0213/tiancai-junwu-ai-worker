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
echo "[1/7] 获取任务信息..."
TASK_JSON=$(curl -sf -H "Authorization: Bearer ${DTOK}" \
    "${REVIEW_URL}/api/v1/tasks/${TASK_ID}" 2>/dev/null || echo "{}")

TRACK=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('track','unknown'))" 2>/dev/null || echo "unknown")
ADAPTATION=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('adaptation_plan',''))" 2>/dev/null || echo "")
SYNOPSIS=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('synopsis',''))" 2>/dev/null || echo "")
SELECTED_DIR=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('selected_direction',1))" 2>/dev/null || echo "1")
JIMENG_PROMPTS=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jimeng_prompts',''))" 2>/dev/null || echo "")
STORY_DOC=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('story_document',''))" 2>/dev/null || echo "")

# 赛道中文名映射
case "$TRACK" in
    kindness-reversal) TRACK_CN="善意反转" ;;
    kpop-dance)        TRACK_CN="KPOP舞蹈" ;;
    brainrot-fruit)    TRACK_CN="脑腐水果" ;;
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
echo "[2/7] 获取视频映射..."

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
echo "[3/7] 获取原视频..."
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

# ── Step 4: 写入改编故事文档 ──
echo "[4/7] 生成改编故事文档..."
if [[ -n "$STORY_DOC" ]] && [[ "$STORY_DOC" != "null" ]]; then
    echo "$STORY_DOC" > "$PACKAGE_DIR/改编故事文档.md"
    echo "  ✓ 改编故事文档已生成（含角色选角、场景规划、时序分镜）"
elif [[ -n "$ADAPTATION" ]] && [[ "$ADAPTATION" != "null" ]]; then
    # Fallback: 老任务没有 story_document，用 adaptation_plan
    {
        echo "# 改编方向建议"
        echo ""
        if [[ -n "$SYNOPSIS" ]] && [[ "$SYNOPSIS" != "null" ]]; then
            echo "## 故事简介"
            echo "$SYNOPSIS"
            echo ""
        fi
        echo "$ADAPTATION"
    } > "$PACKAGE_DIR/改编故事文档.md"
    echo "  ✓ 改编故事文档已生成（旧格式：改编方向建议）"
else
    echo "  ⚠ 无改编故事文档"
fi

# ── Step 5: 生成发布信息（标题 + 简介 + 标签）──
echo "[5/7] 生成发布信息..."
echo "$TASK_JSON" | python3 - "$PACKAGE_DIR" "$TRACK" "$SELECTED_DIR" << 'PYEOF'
import sys, json, re

task = json.load(sys.stdin)
pkg_dir = sys.argv[1]
track = sys.argv[2]
selected_dir = int(sys.argv[3]) if sys.argv[3].isdigit() else 1

adaptation = task.get('adaptation_plan', '')
jimeng_prompts = task.get('jimeng_prompts', '')

# --- 优先从 Publish Info 块提取标题和简介 ---
title = ''
desc = ''

# Claude B-2 在 jimeng_prompts 末尾输出:
# ## Publish Info
# Title: ...
# Description: ...
pub_block = re.search(r'##\s*Publish Info\s*\n([\s\S]*?)(?:\n##|\n---|\Z)', jimeng_prompts or '')
if pub_block:
    pub_text = pub_block.group(1)
    t_match = re.search(r'Title\s*[:：]\s*(.+)', pub_text)
    d_match = re.search(r'Description\s*[:：]\s*([\s\S]*?)(?:\nTitle|\n##|\Z)', pub_text)
    if t_match:
        title = t_match.group(1).strip().strip('"\'')
    if d_match:
        desc = d_match.group(1).strip()

# Fallback 标题：从 adaptation_plan 的方向标题提取
if not title:
    if selected_dir > 0:
        titles = re.findall(r'###\s*["""]([^"""]+)["""]', adaptation)
        if selected_dir <= len(titles):
            title = titles[selected_dir - 1]
        elif titles:
            title = titles[0]

if not title:
    title = 'Untitled'

title = title[:100]

# Fallback 简介：用标题扩写
if not desc and title != 'Untitled':
    desc = f'Watch what happens when {title[0].lower() + title[1:]}.'

# --- 赛道默认标签 ---
track_tags = {
    'kindness-reversal': '#Kindness #Respect #Shorts #Viral #Humanity #RestoreFaith',
    'kpop-dance':        '#KPOP #Dance #Shorts #Viral',
    'brainrot-fruit':    '#BrainrotFruit #FruitEthics #Shorts #Viral #Brainrot',
}
tags = track_tags.get(track, '#Shorts #Viral')

# --- 写入文件 ---
out_path = f'{pkg_dir}/发布信息.txt'
with open(out_path, 'w', encoding='utf-8') as f:
    f.write(f'标题 (Title):\n{title}\n\n')
    f.write(f'简介 (Description):\n{desc}\n\n')
    f.write(f'标签 (Tags):\n{tags}\n')

print(f'  ✓ 标题: {title}')
print(f'  ✓ 标签: {tags}')
PYEOF

# ── Step 6: 复制参考图 ──
echo "[6/7] 复制参考图..."
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
    for f in "$REFS_SRC"/*.jpeg "$REFS_SRC"/*.jpg "$REFS_SRC"/*.png; do
        [[ -f "$f" ]] || continue
        ln "$f" "$PACKAGE_DIR/参考图/$(basename "$f")" 2>/dev/null || \
            cp "$f" "$PACKAGE_DIR/参考图/$(basename "$f")"
    done
    REF_COUNT=$(ls -1 "$PACKAGE_DIR/参考图/" 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✓ ${REF_COUNT} 张参考图（本地）"
else
    # 本地无参考图 → 从 VPS 的 ref_results 下载
    echo "  本地无参考图，尝试从 VPS 下载..."
    mkdir -p "$PACKAGE_DIR/参考图"
    echo "$TASK_JSON" | python3 - "$PACKAGE_DIR/参考图" "$REVIEW_URL" "$DTOK" << 'PYEOF'
import sys, json, os, urllib.request

refs_dir = sys.argv[1]
base_url = sys.argv[2]
token = sys.argv[3]
task = json.load(sys.stdin)

# ref_results 存在 video_metadata JSON 中
meta = json.loads(task.get('video_metadata', '{}'))
ref_results = meta.get('ref_results', {})
count = 0

for category in ['costume', 'scene', 'props']:
    for item in ref_results.get(category, []):
        fn = item.get('filename', '')
        if not fn:
            continue
        # 构建 VPS URL：参考图存在 /ip-images/ 下
        # 角色图: /ip-images/{GROUP}/{charName}/{filename}
        # 场景图: /ip-images/场景/{indoor|outdoor}/{filename}
        # 道具图: /ip-images/道具/{filename}
        if category == 'costume':
            char_name = item.get('character', '')
            track = task.get('track', '')
            # per-story 模式的参考图在任务专属目录
            group = task.get('ip_characters', '').upper().replace('-DANCE', '')
            if not group or group == 'PER-STORY':
                group = 'TASK-REFS'
            url = f"{base_url}/ip-images/{group}/{char_name}/{fn}"
        elif category == 'scene':
            scene_type = item.get('sceneType', '户外')
            url = f"{base_url}/ip-images/场景/{scene_type}/{fn}"
        elif category == 'props':
            url = f"{base_url}/ip-images/道具/{fn}"
        else:
            continue

        out_path = os.path.join(refs_dir, fn)
        try:
            req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
            with urllib.request.urlopen(req, timeout=15) as resp:
                with open(out_path, 'wb') as f:
                    f.write(resp.read())
            count += 1
        except Exception as e:
            # 尝试 thumb 版本
            thumb_fn = fn.rsplit('.', 1)[0] + '_thumb.jpeg'
            thumb_url = url.rsplit('/', 1)[0] + '/' + thumb_fn
            try:
                req2 = urllib.request.Request(thumb_url, headers={'Authorization': f'Bearer {token}'})
                with urllib.request.urlopen(req2, timeout=15) as resp:
                    with open(os.path.join(refs_dir, thumb_fn), 'wb') as f:
                        f.write(resp.read())
                count += 1
            except:
                print(f"  ⚠ 下载失败: {fn} ({e})")

print(f"  ✓ 从 VPS 下载 {count} 张参考图")
PYEOF
    REF_COUNT=$(ls -1 "$PACKAGE_DIR/参考图/" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$REF_COUNT" -eq 0 ]]; then
        rmdir "$PACKAGE_DIR/参考图" 2>/dev/null
        echo "  ⚠ 无参考图可下载"
    fi
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
