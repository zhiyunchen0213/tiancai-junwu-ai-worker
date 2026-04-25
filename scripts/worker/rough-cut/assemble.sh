#!/usr/bin/env bash
# scripts/worker/rough-cut/assemble.sh
# 执行 review-server 给的 ffmpeg 命令清单 + 硬链接 source_materials.
#
# Usage:
#   assemble.sh <task_external_id> <plan_json_path>
#
# plan_json_path 格式参考 rough-cut-planner.js 的 output:
#   { clips, concat_list, source_materials_to_link, commands, editingPackageJson }

set -euo pipefail

TASK_ID="$1"
PLAN_JSON="$2"

: "${DELIVERY_BASE_DIR:?DELIVERY_BASE_DIR required}"
: "${MATERIAL_LIBRARY_PATH:?MATERIAL_LIBRARY_PATH required}"

DELIVERY_DIR="${DELIVERY_BASE_DIR}/${TASK_ID}"
mkdir -p "${DELIVERY_DIR}/clips" "${DELIVERY_DIR}/source_materials"

# 1. 写 concat.txt
jq -r '.commands[] | select(.type == "concat_list") | .content' "${PLAN_JSON}" \
  > "${DELIVERY_DIR}/concat.txt"

# 2. 执行 clip 切片命令
jq -r '.commands[] | select(.type == "clip") | .cmd' "${PLAN_JSON}" | while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  echo ">>> $cmd" >&2
  eval "$cmd"
done

# 3. 硬链接原视频
jq -r '.source_materials_to_link[]' "${PLAN_JSON}" | while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  src="${MATERIAL_LIBRARY_PATH}/${rel}"
  dst_name=$(basename "$rel")
  dst="${DELIVERY_DIR}/source_materials/${dst_name}"
  if [ ! -e "$dst" ]; then
    ln "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
  fi
done

# 4. 执行 concat 命令 (拼 draft.mp4 + narration)
CONCAT_CMD=$(jq -r '.commands[] | select(.type == "concat") | .cmd' "${PLAN_JSON}")
echo ">>> ${CONCAT_CMD}" >&2
eval "${CONCAT_CMD}"

echo "✓ assembled: ${DELIVERY_DIR}/draft.mp4"
