#!/usr/bin/env bash
# scripts/worker/material-ingest/analyze.sh
# 通过 review-server 的 /api/analyze 端点跑 Gemini 视频分析.
# 本脚本只负责调 API, 不直接碰 Gemini. review-server 的 analyze 路由已存在 (video-analyzer 复用).
#
# Usage:
#   analyze.sh <source_url>
# Stdout: JSON (raw Gemini output)
# 非 0 exit code 视为失败

set -euo pipefail

SOURCE_URL="$1"
: "${REVIEW_SERVER_URL:?REVIEW_SERVER_URL required}"
: "${DISPATCHER_TOKEN:?DISPATCHER_TOKEN required}"

curl -sS --max-time 240 \
  -H "Authorization: Bearer ${DISPATCHER_TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST "${REVIEW_SERVER_URL}/api/analyze" \
  -d "{\"video_url\": \"${SOURCE_URL}\", \"purpose\": \"material_library\"}"
