#!/bin/bash
# fix_and_start_worker.sh — 修复路径 + 投放任务 + 启动 Worker
# 用法: bash fix_and_start_worker.sh [worker-id]

WORKER_ID="${1:-worker-m2}"
echo "=== 修复 Worker: $WORKER_ID ==="

# 修复代码路径
ln -sf ~/worker-code ~/production/code
echo "1. 代码路径已修复"

# 清理失败的任务
rm -f ~/production/tasks/failed/*.json
rm -f ~/production/tasks/pending/*.json
rm -f ~/production/tasks/running/$WORKER_ID/*.json
echo "2. 旧任务已清理"

# 创建环境变量（如果不存在）
if [ ! -f ~/.production.env ]; then
  echo "WORKER_ID=$WORKER_ID" > ~/.production.env
  echo "SHARED_DIR=$HOME/production" >> ~/.production.env
  echo "REVIEW_SERVER_URL=http://107.175.215.216" >> ~/.production.env
  echo "DISPATCHER_TOKEN=kwR2m0GMdeGZu0fSvfcVRJGvWYS255qe" >> ~/.production.env
  echo "AI_AGENT=claude" >> ~/.production.env
  echo "POLL_INTERVAL=30" >> ~/.production.env
  echo "3. 环境变量已创建"
else
  echo "3. 环境变量已存在"
fi

# 确保 SHARED_DIR 指向本地
grep -q "SHARED_DIR=\$HOME/production" ~/.production.env || echo "SHARED_DIR=$HOME/production" >> ~/.production.env
source ~/.production.env

# 投放测试任务
python3 -c "
import json,os
t={
  'task_id':'task-test-003',
  'id':'task-test-003',
  'video_url':'https://www.youtube.com/shorts/Xo0zswJ3qZQ',
  'url':'https://www.youtube.com/shorts/Xo0zswJ3qZQ',
  'track':'kpop-dance',
  'variants':['V1'],
  'priority':'normal',
  'status':'pending',
  'gate_mode':'full_review',
  'gates_enabled':['g1','g2','g4']
}
p=os.path.expanduser('~/production/tasks/pending/task-test-003.json')
json.dump(t,open(p,'w'))
print('4. 测试任务已投放')
"

# 启动 Worker（后台）
echo "5. 启动 Worker..."
nohup bash ~/worker-code/scripts/worker/worker_main.sh > ~/production/logs/worker.log 2>&1 &
echo "   PID: $!"
echo ""
echo "=== Worker 已启动 ==="
echo "查看日志: tail -f ~/production/logs/worker.log"
