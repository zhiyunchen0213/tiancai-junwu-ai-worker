#!/bin/bash
set -euo pipefail

# Harvest Daemon - 后台守护进程，监控即梦任务完成状态并下载视频
# 运行在每个Worker Mac mini上，每5分钟扫描一次任务状态

# 加载生产环境配置
if [[ -f "$HOME/.production.env" ]]; then
    set -a
    source "$HOME/.production.env"
    set +a
else
    echo "错误: 无法找到 $HOME/.production.env 配置文件" >&2
    exit 1
fi

# 验证必需的环境变量
: "${SHARED_DIR:?缺少SHARED_DIR环境变量}"
: "${WORKER_ID:?缺少WORKER_ID环境变量}"
: "${CDP_PORT:?缺少CDP_PORT环境变量}"

# Review Server 上报
: "${REVIEW_SERVER_URL:=}"
: "${DISPATCHER_TOKEN:=}"

report_event() {
    [[ -z "$REVIEW_SERVER_URL" ]] && return 0
    [[ -z "$DISPATCHER_TOKEN" ]] && return 0
    local task_id="$1" event="$2" payload="${3:-{}}"
    (
        TASK_ID="$task_id" EVENT="$event" PAYLOAD="$payload" \
        REVIEW_URL="$REVIEW_SERVER_URL" DTOK="$DISPATCHER_TOKEN" \
        python3 -c "
import json, os, urllib.request
url = os.environ['REVIEW_URL'].rstrip('/') + '/api/v1/tasks/report'
body = json.dumps({'task_id': os.environ['TASK_ID'], 'event': os.environ['EVENT'], 'payload': json.loads(os.environ['PAYLOAD'])}).encode()
req = urllib.request.Request(url, data=body, headers={'Content-Type':'application/json','Authorization':f\"Bearer {os.environ['DTOK']}\"})
try: urllib.request.urlopen(req, timeout=10)
except Exception as e: print(f'[review-server] {e}')
" 2>/dev/null
    ) &
}

# 确保必需的目录存在
mkdir -p "$SHARED_DIR/tasks/harvesting"
mkdir -p "$SHARED_DIR/tasks/completed"
mkdir -p "$SHARED_DIR/tasks/failed"
mkdir -p "$SHARED_DIR/logs"

# 日志配置
LOG_FILE="$SHARED_DIR/logs/harvest_daemon_${WORKER_ID}.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# 日志函数
# ============================================================================

log_info() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $message" | tee -a "$LOG_FILE"
}

log_warn() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $message" | tee -a "$LOG_FILE" >&2
}

# ============================================================================
# JSON处理函数
# ============================================================================

update_task_json() {
    local task_file="$1"
    local key="$2"
    local value="$3"

    # 使用 python3 更新（与 worker_main.sh 保持一致，避免 jq 依赖）
    if [[ -f "$task_file" ]]; then
        python3 << PYEOF
import json, sys
try:
    with open('${task_file}', 'r') as f:
        data = json.load(f)
    raw = '''${value}'''
    if raw == '':
        parsed = None
    elif raw.isdigit():
        parsed = int(raw)
    elif raw.lower() == 'null' or raw.lower() == 'none':
        parsed = None
    elif raw.lower() == 'true':
        parsed = True
    elif raw.lower() == 'false':
        parsed = False
    else:
        parsed = raw
    data['${key}'] = parsed
    with open('${task_file}', 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'Error updating JSON: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
    fi
}

get_task_field() {
    local task_file="$1"
    local field="$2"
    local default="${3:-}"

    if [[ -f "$task_file" ]]; then
        python3 -c "
import json
try:
    with open('${task_file}', 'r') as f:
        data = json.load(f)
    val = data.get('${field}', '${default}')
    print('' if val is None else val)
except:
    print('${default}')
" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# ============================================================================
# 告警函数
# ============================================================================

send_alert() {
    local level="$1"
    local title="$2"
    local message="$3"
    local action_required="${4:-false}"

    local alert_file="$SHARED_DIR/alerts/$(date +%s)_${RANDOM}.json"
    mkdir -p "$SHARED_DIR/alerts"

    # 使用环境变量传参避免 JSON/shell 注入
    ALERT_FILE="$alert_file" \
    ALERT_LEVEL="$level" \
    ALERT_TITLE="$title" \
    ALERT_MSG="$message" \
    ALERT_ACTION="$action_required" \
    ALERT_WORKER="$WORKER_ID" \
    python3 << 'PYEOF'
import json, os
from datetime import datetime, timezone

alert = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "level": os.environ["ALERT_LEVEL"],
    "title": os.environ["ALERT_TITLE"],
    "message": os.environ["ALERT_MSG"],
    "action_required": os.environ["ALERT_ACTION"].lower() == "true",
    "worker_id": os.environ["ALERT_WORKER"],
    "source": "harvest_daemon",
}
with open(os.environ["ALERT_FILE"], "w") as f:
    json.dump(alert, f, indent=2, ensure_ascii=False)
PYEOF

    log_info "发送告警: [$level] $title"
}

# ============================================================================
# 即梦相关函数
# ============================================================================

check_jimeng_status() {
    local project_id="$1"

    # 调用jimeng_monitor.mjs获取生成状态
    local monitor_script="$SCRIPT_DIR/jimeng_monitor.mjs"

    if [[ ! -f "$monitor_script" ]]; then
        log_error "找不到 jimeng_monitor.mjs 脚本"
        return 1
    fi

    # 调用监控脚本获取状态
    local status
    status=$(node "$monitor_script" \
        --project-id "$project_id" \
        --cdp-port "$CDP_PORT" \
        2>/dev/null || echo "error")

    echo "$status"
}

download_jimeng_video() {
    local project_id="$1"
    local output_dir="$2"

    local monitor_script="$SCRIPT_DIR/jimeng_monitor.mjs"

    if [[ ! -f "$monitor_script" ]]; then
        log_error "找不到 jimeng_monitor.mjs 脚本"
        return 1
    fi

    # 创建输出目录
    mkdir -p "$output_dir"

    # 调用监控脚本下载视频
    node "$monitor_script" \
        --project-id "$project_id" \
        --cdp-port "$CDP_PORT" \
        --download \
        --output-dir "$output_dir" \
        2>/dev/null || return 1

    return 0
}

# ============================================================================
# 任务处理函数
# ============================================================================

package_deliverables() {
    local task_id="$1"
    local download_dir="$2"
    local deliverables_dir="$3"

    # 创建deliverables目录结构
    mkdir -p "$deliverables_dir/videos"
    mkdir -p "$deliverables_dir/assets"

    # 移动视频文件（.mp4, .mov等）
    find "$download_dir" -maxdepth 1 \( -name "*.mp4" -o -name "*.mov" -o -name "*.webm" \) \
        -exec mv {} "$deliverables_dir/videos/" \; 2>/dev/null || true

    # 移动资源文件（字幕、缩略图等）
    find "$download_dir" -maxdepth 1 \( -name "*.srt" -o -name "*.vtt" -o -name "*.jpg" -o -name "*.png" \) \
        -exec mv {} "$deliverables_dir/assets/" \; 2>/dev/null || true

    log_info "任务 $task_id: 已打包deliverables到 $deliverables_dir"
}

calculate_cost() {
    local task_file="$1"
    local project_id="$2"

    # 从任务进度读取成本数据
    # 这是一个简化实现，实际可能需要解析更复杂的成本计算
    local cost=0

    if [[ -f "$task_file" ]]; then
        # 使用 python3 替代 jq（macOS 兼容）
        cost=$(python3 -c "
import json
try:
    with open('${task_file}', 'r') as f:
        data = json.load(f)
    print(data.get('jimeng_cost', 0))
except:
    print(0)
" 2>/dev/null || echo "0")
    fi

    echo "$cost"
}

process_harvesting_task() {
    local task_file="$1"
    local task_id

    task_id=$(basename "$task_file" .json)

    log_info "处理任务: $task_id"

    # 读取任务元数据
    local jimeng_submitted_at
    local jimeng_project_id
    local jimeng_submitted_by

    jimeng_submitted_at=$(get_task_field "$task_file" "jimeng_submitted_at" "")
    jimeng_project_id=$(get_task_field "$task_file" "jimeng_project_id" "")
    jimeng_submitted_by=$(get_task_field "$task_file" "jimeng_submitted_by" "")

    # 验证任务是否由本Worker提交
    if [[ "$jimeng_submitted_by" != "$WORKER_ID" ]]; then
        return 0
    fi

    if [[ -z "$jimeng_submitted_at" ]] || [[ -z "$jimeng_project_id" ]]; then
        log_warn "任务 $task_id: 缺少必需的即梦元数据"
        return 1
    fi

    # 计算自提交以来的经过时间（秒）
    local submit_timestamp
    local current_timestamp
    local elapsed_seconds

    # macOS 兼容：用 python3 解析 ISO 时间戳
    submit_timestamp=$(python3 -c "
from datetime import datetime
try:
    dt = datetime.fromisoformat('${jimeng_submitted_at}'.replace('Z', '+00:00'))
    print(int(dt.timestamp()))
except:
    print(0)
" 2>/dev/null || echo 0)
    current_timestamp=$(date +%s)
    elapsed_seconds=$((current_timestamp - submit_timestamp))

    # 检查即梦生成状态
    local status
    status=$(check_jimeng_status "$jimeng_project_id")

    log_info "任务 $task_id: 状态=$status, 耗时=$((elapsed_seconds/60))分钟"

    case "$status" in
        generating)
            # 生成中：监控超时
            if ((elapsed_seconds > 5400)); then
                # 超过90分钟，标记失败
                log_error "任务 $task_id: 即梦生成超时（>90分钟）"
                update_task_json "$task_file" "status" "failed" || true
                update_task_json "$task_file" "failed_reason" "jimeng_generation_timeout" || true
                update_task_json "$task_file" "failed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true

                # 移动工作目录到 failed/
                local work_dir_timeout
                work_dir_timeout=$(get_task_field "$task_file" "work_dir" "")
                if [[ -n "$work_dir_timeout" ]] && [[ -d "$work_dir_timeout" ]]; then
                    mv "$work_dir_timeout" "$SHARED_DIR/tasks/failed/work_${task_id}" 2>/dev/null || true
                fi

                # 移动到失败目录
                mv "$task_file" "$SHARED_DIR/tasks/failed/$task_id.json"

                send_alert "error" "即梦生成超时" "任务 $task_id 在即梦上生成超过90分钟，已标记为失败" true
                report_event "$task_id" "task_failed" "{\"error\":\"jimeng_generation_timeout\"}"
            elif ((elapsed_seconds > 1800)); then
                # 超过30分钟，发出警告
                log_warn "任务 $task_id: 即梦生成耗时较长（>30分钟）"
                send_alert "warning" "即梦生成进行中" "任务 $task_id 已生成30分钟以上，请关注进度" false
            fi
            ;;

        complete)
            # 已完成：下载视频
            log_info "任务 $task_id: 即梦生成完成，开始下载"

            local download_dir
            download_dir="$SHARED_DIR/temp/downloads/$task_id"

            if download_jimeng_video "$jimeng_project_id" "$download_dir"; then
                # 创建completed目录
                local completed_dir
                completed_dir="$SHARED_DIR/tasks/completed/$task_id"
                mkdir -p "$completed_dir"

                # 打包deliverables
                local deliverables_dir
                deliverables_dir="$completed_dir/deliverables"
                package_deliverables "$task_id" "$download_dir" "$deliverables_dir"

                # 更新任务状态
                update_task_json "$task_file" "status" "completed" || true
                update_task_json "$task_file" "completed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true

                # 计算成本
                local cost
                cost=$(calculate_cost "$task_file" "$jimeng_project_id")
                update_task_json "$task_file" "jimeng_cost" "$cost" || true

                # 移动工作目录到 completed/
                local work_dir
                work_dir=$(get_task_field "$task_file" "work_dir" "")
                if [[ -n "$work_dir" ]] && [[ -d "$work_dir" ]]; then
                    mv "$work_dir" "$completed_dir/work" 2>/dev/null || true
                    update_task_json "$task_file" "work_dir" "$completed_dir/work" || true
                fi

                # 移动任务文件到completed目录
                mv "$task_file" "$completed_dir/task.json"

                # 清理临时目录（安全检查：确保路径在预期前缀下）
                if [[ -n "$download_dir" ]] && [[ "$download_dir" == "$SHARED_DIR/temp/"* ]]; then
                    rm -rf "$download_dir"
                else
                    log_warn "跳过清理: download_dir 路径不在预期范围内: $download_dir"
                fi

                log_info "任务 $task_id: 已完成并下载"
                send_alert "info" "任务完成" "任务 $task_id 已从即梦完成并下载" false
                report_event "$task_id" "harvest_complete" "{}"
            else
                log_error "任务 $task_id: 下载视频失败"
                send_alert "error" "下载失败" "任务 $task_id 下载视频时出错，将重试" false
            fi
            ;;

        failed)
            # 生成失败
            log_error "任务 $task_id: 即梦生成失败"
            update_task_json "$task_file" "status" "failed" || true
            update_task_json "$task_file" "failed_reason" "jimeng_generation_failed" || true
            update_task_json "$task_file" "failed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true

            # 移动工作目录到 failed/
            local work_dir_fail
            work_dir_fail=$(get_task_field "$task_file" "work_dir" "")
            if [[ -n "$work_dir_fail" ]] && [[ -d "$work_dir_fail" ]]; then
                mv "$work_dir_fail" "$SHARED_DIR/tasks/failed/work_${task_id}" 2>/dev/null || true
            fi

            # 移动到失败目录
            mv "$task_file" "$SHARED_DIR/tasks/failed/$task_id.json"

            send_alert "error" "即梦生成失败" "任务 $task_id 在即梦上生成失败" true
            report_event "$task_id" "task_failed" "{\"error\":\"jimeng_generation_failed\"}"
            ;;

        login_expired)
            # 登录态过期：不处理，等待手动重新登录
            log_warn "任务 $task_id: 即梦登录态已过期"
            send_alert "urgent" "即梦登录态过期" "即梦登录态过期，需要手动重新登录。受影响的任务: $task_id" true
            # 不移动或失败任务，下一个周期继续检查
            ;;

        *)
            log_error "任务 $task_id: 未知的即梦状态: $status"
            ;;
    esac
}

# ============================================================================
# 主循环
# ============================================================================

main_loop() {
    log_info "Harvest Daemon 已启动 (Worker ID: $WORKER_ID, CDP Port: $CDP_PORT)"

    local scan_round=0

    while true; do
        ((scan_round++)) || true
        local task_count=0

        # 扫描harvesting目录中的所有任务
        if [[ -d "$SHARED_DIR/tasks/harvesting" ]]; then
            while IFS= read -r task_file; do
                if [[ -f "$task_file" ]]; then
                    process_harvesting_task "$task_file" || true
                    ((task_count++)) || true
                fi
            done < <(find "$SHARED_DIR/tasks/harvesting" -maxdepth 1 -name "*.json" -type f)
        fi

        # 只在有任务时或每6轮（30分钟）打一次日志
        if [[ $task_count -gt 0 ]]; then
            log_info "本轮扫描完成，处理了 $task_count 个任务"
        elif [[ $((scan_round % 6)) -eq 0 ]]; then
            log_info "Harvest Daemon 运行中，暂无harvesting任务 (已运行 $((scan_round * 5)) 分钟)"
        fi

        # 休眠5分钟
        sleep 300
    done
}

# ============================================================================
# 信号处理
# ============================================================================

cleanup() {
    log_info "Harvest Daemon 收到SIGTERM信号，优雅关闭..."
    exit 0
}

trap cleanup SIGTERM SIGINT

# ============================================================================
# 启动守护进程
# ============================================================================

main_loop
