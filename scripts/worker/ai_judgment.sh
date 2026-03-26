#!/bin/bash
# Phase B: AI-powered judgment and creative decisions
# 处理阶段B：AI驱动的评审和创意决策
# 组装Phase A输出并调用AI代理进行非交互式分析

set -euo pipefail

# 加载环境变量
if [[ -f "${HOME}/.production.env" ]]; then
    source "${HOME}/.production.env"
fi

# 配置默认值
AI_AGENT="${AI_AGENT:-claude}"
SHARED_DIR="${SHARED_DIR:-.}"
RETRY_COUNT=0
MAX_RETRIES=2

# 验证输入参数
if [[ $# -lt 1 ]]; then
    echo "用法: $0 <work_directory>"
    echo "Usage: $0 <work_directory>"
    exit 1
fi

WORK_DIR="$1"

# 日志函数
log_info() {
    echo "[INFO] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1" >&2
}

# 读取赛道信息 / Read track from task.json
TASK_JSON="$WORK_DIR/task.json"
TRACK=$(python3 -c "
import json
d = json.load(open('$TASK_JSON'))
print(d.get('track', 'kpop-dance'))
" 2>/dev/null || echo "kpop-dance")

log_info "赛道 / Track: $TRACK"

# ============================================================================
# 第1步: 验证Phase A输出存在
# Step 1: Validate Phase A outputs exist
# ============================================================================
log_info "验证Phase A输出文件 / Validating Phase A outputs..."

REQUIRED_FILES=(
    "$WORK_DIR/kimi_analysis.md"
    "$WORK_DIR/transcript.txt"
    "$WORK_DIR/metadata.json"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        log_error "缺少必需文件 / Missing required file: $file"
        exit 1
    fi
done

if [[ ! -d "$WORK_DIR/frames" ]]; then
    log_error "缺少frames目录 / Missing frames directory: $WORK_DIR/frames"
    exit 1
fi

log_success "所有Phase A输出验证通过 / All Phase A outputs validated"

# ============================================================================
# 第2步: 创建Phase B工作目录
# Step 2: Create Phase B work directory
# ============================================================================
log_info "创建Phase B工作目录 / Creating Phase B work directory..."

PHASE_B_DIR="$WORK_DIR/phase_b"
mkdir -p "$PHASE_B_DIR"

log_success "Phase B工作目录已创建 / Phase B directory created: $PHASE_B_DIR"

# ============================================================================
# 第3步: 组装AI任务提示词
# Step 3: Assemble AI task prompt
# ============================================================================
log_info "组装AI任务提示词 / Assembling AI task prompt..."

PROMPT_FILE="$PHASE_B_DIR/ai_prompt.txt"
KIMI_ANALYSIS="$WORK_DIR/kimi_analysis.md"
TRANSCRIPT="$WORK_DIR/transcript.txt"
METADATA="$WORK_DIR/metadata.json"

# 提取视频元数据（使用 python3 避免 jq 依赖）
VIDEO_DURATION=$(python3 -c "import json; d=json.load(open('$METADATA')); print(d.get('duration_seconds','unknown'))" 2>/dev/null || echo "unknown")
VIDEO_RESOLUTION=$(python3 -c "import json; d=json.load(open('$METADATA')); print(d.get('resolution','unknown'))" 2>/dev/null || echo "unknown")
VIDEO_FORMAT=$(python3 -c "import json; d=json.load(open('$METADATA')); print(d.get('video_file','unknown'))" 2>/dev/null || echo "unknown")

# 读取病毒视频分解技能的关键规则（前500行）
SKILL_RULES=""
SKILL_FILE="$SHARED_DIR/viral-video-breakdown/SKILL.md"
if [[ -f "$SKILL_FILE" ]]; then
    SKILL_RULES=$(head -500 "$SKILL_FILE")
fi

# 组装提示词
cat > "$PROMPT_FILE" << 'PROMPT_EOF'
# Phase B: AI创意评审与改编建议
## Phase B: AI Creative Judgment & Adaptation Recommendations

你是一位资深的视频创意评审官和编剧。你的任务是基于提供的多模态信息（视频分析、台词、元数据）生成创意评审和改编建议。

You are a senior video creative reviewer and screenwriter. Your task is to generate creative judgments and adaptation recommendations based on the provided multimodal information.

---

## 输入信息 / Input Information

### 视频元数据 / Video Metadata
```
Duration: {VIDEO_DURATION}
Resolution: {VIDEO_RESOLUTION}
Format: {VIDEO_FORMAT}
```

### Kimi分析 / Kimi Analysis
```
{KIMI_ANALYSIS}
```

### 脚本台词 / Transcript
```
{TRANSCRIPT}
```

### 病毒视频分解关键规则 / Viral Video Breakdown Rules
```
{SKILL_RULES}
```

---

## 任务要求 / Task Requirements

请生成以下三个输出文件，格式和内容要求如下：

### 1. 631评分.md
**创意评分系统 (6-3-1 Scoring System)**
- 创意分 (6分制): 核心概念的创新性、吸引力、传播潜力
- 剧本分 (3分制): 叙事结构、人物塑造、台词质量
- 剪辑分 (1分制): 节奏感、视觉冲击、转场效果

每个维度提供：
- 分数（数字）
- 得分理由（2-3句）
- 改进建议（1-2句）

### 2. 改编建议.md
**改编方向分析**
- 提供≥3个核心改编方向
- 每个方向说明：
  * 改编思路（概述）
  * 核心DNA分析（该方向保留原作的什么DNA）
  * 人物IP映射（原作人物→新改编人物的映射关系）

### 3. 改编1_大纲与提示词.md
**第一改编方向的具体实施方案**
格式要求：
- 场景表 (Scene Table): 列出完整的故事场景序列，包含场景号、地点、核心动作、时长预估
- 人物表 (Character Table): 主要角色信息、性格特征、弧线变化
- 每个场景的AI生成提示词 (Prompt per Scene): 用于后续AI创意生成的详细场景提示词

### 4. 即梦提示词.md
**即梦 Seedance 可执行提示词（Phase C 直接消费）**
此文件必须包含以下结构：

#### 文件头部嵌入 jimeng-config JSON（二选一格式）：
格式A（推荐）:
\`\`\`json
// jimeng-config
{
  "ratio": "9:16",
  "batches": [
    {
      "prompt": "批次1的完整提示词文本...",
      "duration": 13,
      "refs": ["角色A.png", "角色B.png"],
      "atRefs": [
        {"label": "角色A", "search": "@角色A"}
      ]
    }
  ]
}
\`\`\`

格式B:
<!-- jimeng-config {"ratio":"9:16","batches":[...]} -->

#### 规则：
- 每个批次 duration 建议 12-15 秒（即梦 Seedance 2.0 最佳时长）
- prompt 应为中文，包含场景描述、角色动作、镜头语言（如"中景"、"缓慢推进"、"俯拍"）
- refs 数组列出该批次需要的参考图文件名
- atRefs 数组中 search 以 @ 开头，label 为显示名
- 如果原视频总时长超过 15 秒，必须拆分为多个批次
- prompt 中包含 @引用 时，写法为 `@角色名` 格式（与 atRefs.search 对应）

---

## 输出位置 / Output Location
所有文件应保存在当前工作目录，不需要创建子目录。

All files should be saved in the current working directory, no subdirectory needed.

---

## 评估标准 / Evaluation Criteria
1. 创意评分必须数据化和有理据支撑
2. 改编建议必须基于原作内核，提出有差异的方向
3. 大纲和提示词必须具体可执行，为后续AI内容生成提供清晰指导
4. 所有分析必须考虑当前社交媒体传播趋势
5. 即梦提示词.md 必须包含有效的 jimeng-config JSON 块

---

现在请生成上述三个输出文件。

Now please generate the above three output files.
PROMPT_EOF

# 替换模板变量（使用 python3 安全替换，避免 sed 在 macOS 上的兼容性问题和特殊字符破坏）
export PROMPT_FILE VIDEO_DURATION VIDEO_RESOLUTION VIDEO_FORMAT KIMI_ANALYSIS TRANSCRIPT SKILL_FILE
python3 << 'PYEOF'
import os

prompt_file = os.environ.get("PROMPT_FILE", "")
if not prompt_file:
    import sys; sys.exit(1)

with open(prompt_file, 'r') as f:
    content = f.read()

# 读取替换内容
def read_file_safe(path, max_lines=None):
    try:
        with open(path, 'r') as f:
            lines = f.readlines()
            if max_lines:
                lines = lines[:max_lines]
            return ''.join(lines)
    except:
        return ''

replacements = {
    '{VIDEO_DURATION}': os.environ.get('VIDEO_DURATION', 'unknown'),
    '{VIDEO_RESOLUTION}': os.environ.get('VIDEO_RESOLUTION', 'unknown'),
    '{VIDEO_FORMAT}': os.environ.get('VIDEO_FORMAT', 'unknown'),
    '{KIMI_ANALYSIS}': read_file_safe(os.environ.get('KIMI_ANALYSIS', '')),
    '{TRANSCRIPT}': read_file_safe(os.environ.get('TRANSCRIPT', '')),
    '{SKILL_RULES}': read_file_safe(os.environ.get('SKILL_FILE', ''), max_lines=500),
}

for placeholder, value in replacements.items():
    content = content.replace(placeholder, value)

with open(prompt_file, 'w') as f:
    f.write(content)
PYEOF

log_success "AI任务提示词已生成 / AI task prompt generated: $PROMPT_FILE"

# ============================================================================
# 辅助函数: 调用OpenAI API
# Helper function: Call OpenAI API
# ============================================================================
call_openai_api() {
    local prompt_file="$1"
    local api_key="${OPENAI_API_KEY:-}"

    if [[ -z "$api_key" ]]; then
        log_error "缺少OPENAI_API_KEY环境变量 / Missing OPENAI_API_KEY environment variable"
        return 1
    fi

    # 使用 python3 构建 JSON 请求体（避免 shell 中转义双引号等注入问题）
    local request_body
    request_body=$(PROMPT_FILE_PATH="$prompt_file" python3 << 'PYEOF'
import json, os
with open(os.environ["PROMPT_FILE_PATH"], "r") as f:
    prompt_content = f.read()
payload = {
    "model": "gpt-4",
    "messages": [
        {"role": "system", "content": "你是一位资深的视频创意评审官和编剧。生成高质量的创意评审和改编建议。"},
        {"role": "user", "content": prompt_content}
    ],
    "temperature": 0.7,
    "max_tokens": 4000
}
print(json.dumps(payload, ensure_ascii=False))
PYEOF
    )

    local response
    response=$(curl -s -X POST "https://api.openai.com/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $api_key" \
        -d "$request_body")

    echo "$response"
}

# ============================================================================
# 第4步: 调用AI代理
# Step 4: Call AI agent based on AI_AGENT env var
# ============================================================================
log_info "调用AI代理 / Calling AI agent: $AI_AGENT"

AI_OUTPUT_LOG="$PHASE_B_DIR/ai_output.log"

# 改变到Phase B目录以便AI输出文件存储在正确位置
cd "$PHASE_B_DIR"

case "$AI_AGENT" in
    claude)
        log_info "使用Claude Code CLI / Using Claude Code CLI..."
        if command -v claude &> /dev/null; then
            claude -p "$(cat $PROMPT_FILE)" --allowedTools "Edit,Write,Read,Bash" 2>&1 | tee "$AI_OUTPUT_LOG"
        else
            log_error "Claude Code CLI未找到 / Claude Code CLI not found"
            exit 1
        fi
        ;;
    codex)
        log_info "使用OpenAI Codex / Using OpenAI Codex..."
        if command -v codex &> /dev/null; then
            codex --approval-mode full-auto --quiet "$(cat $PROMPT_FILE)" 2>&1 | tee "$AI_OUTPUT_LOG"
        else
            log_error "Codex未找到 / Codex not found"
            exit 1
        fi
        ;;
    openai-api)
        log_info "使用OpenAI API直接调用 / Using OpenAI API direct call..."
        call_openai_api "$PROMPT_FILE" > "$AI_OUTPUT_LOG" 2>&1
        ;;
    *)
        log_error "未知的AI代理 / Unknown AI agent: $AI_AGENT"
        exit 1
        ;;
esac

# 返回原始工作目录
cd "$WORK_DIR"

log_success "AI代理执行完成 / AI agent execution completed"

# ============================================================================
# 第5步: 验证输出文件存在
# Step 5: Validate outputs exist
# ============================================================================
log_info "验证输出文件 / Validating output files..."

REQUIRED_OUTPUTS=(
    "631评分.md"
    "改编建议.md"
    "改编1_大纲与提示词.md"
    "即梦提示词.md"
)

MISSING_OUTPUTS=()
for output in "${REQUIRED_OUTPUTS[@]}"; do
    if [[ ! -f "$PHASE_B_DIR/$output" ]]; then
        MISSING_OUTPUTS+=("$output")
    fi
done

# 如果有缺失的文件，尝试搜索AI可能写入的其他位置
if [[ ${#MISSING_OUTPUTS[@]} -gt 0 ]]; then
    log_info "尝试在其他位置查找输出文件 / Searching for output files in alternative locations..."

    for output in "${MISSING_OUTPUTS[@]}"; do
        # 搜索工作目录和phase_b目录
        if find "$WORK_DIR" -name "$output" -type f 2>/dev/null | grep -q .; then
            found_file=$(find "$WORK_DIR" -name "$output" -type f 2>/dev/null | head -1)
            log_info "找到文件，移动到Phase B目录 / Found file, moving to Phase B directory: $found_file"
            cp "$found_file" "$PHASE_B_DIR/"
        fi
    done
fi

# 重新检查缺失的文件
MISSING_OUTPUTS=()
for output in "${REQUIRED_OUTPUTS[@]}"; do
    if [[ ! -f "$PHASE_B_DIR/$output" ]]; then
        MISSING_OUTPUTS+=("$output")
    fi
done

# 如果仍有缺失且重试次数未超，重试使用简化提示词
if [[ ${#MISSING_OUTPUTS[@]} -gt 0 ]] && [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
    log_info "缺失文件，准备重试 / Missing files, preparing retry (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    RETRY_COUNT=$((RETRY_COUNT + 1))

    # 生成简化的提示词
    SIMPLIFIED_PROMPT="$PHASE_B_DIR/ai_prompt_simplified_$RETRY_COUNT.txt"
    cat > "$SIMPLIFIED_PROMPT" << 'SIMPLIFIED_PROMPT_EOF'
请生成以下三个markdown文件，确保文件名正确：

1. "631评分.md" - 用创意6分、剧本3分、剪辑1分的评分系统评价
2. "改编建议.md" - 提供3个改编方向
3. "改编1_大纲与提示词.md" - 第一个改编方向的详细大纲

基于之前提供的视频信息完成分析。

Generate three markdown files with correct filenames:
1. "631评分.md"
2. "改编建议.md"
3. "改编1_大纲与提示词.md"

Complete the analysis based on the video information provided.
SIMPLIFIED_PROMPT_EOF

    cd "$PHASE_B_DIR"
    case "$AI_AGENT" in
        claude)
            claude -p "$(cat $SIMPLIFIED_PROMPT)" --allowedTools "Edit,Write,Read,Bash" 2>&1 | tee -a "$AI_OUTPUT_LOG"
            ;;
        openai-api)
            call_openai_api "$SIMPLIFIED_PROMPT" >> "$AI_OUTPUT_LOG" 2>&1
            ;;
    esac
    cd "$WORK_DIR"
fi

# 最终文件检查
MISSING_OUTPUTS=()
for output in "${REQUIRED_OUTPUTS[@]}"; do
    if [[ ! -f "$PHASE_B_DIR/$output" ]]; then
        MISSING_OUTPUTS+=("$output")
    fi
done

if [[ ${#MISSING_OUTPUTS[@]} -gt 0 ]]; then
    log_error "无法生成必需的输出文件 / Failed to generate required output files: ${MISSING_OUTPUTS[*]}"
    exit 1
fi

log_success "所有输出文件已验证 / All output files validated"

# ============================================================================
# 第6步: 后处理
# Step 6: Post-processing
# ============================================================================
log_info "执行后处理 / Performing post-processing..."

# 确保所有输出文件都在Phase B目录中
for output in "${REQUIRED_OUTPUTS[@]}"; do
    if [[ ! -f "$PHASE_B_DIR/$output" ]]; then
        if [[ -f "$WORK_DIR/$output" ]]; then
            mv "$WORK_DIR/$output" "$PHASE_B_DIR/"
            log_info "移动输出文件 / Moved output file: $output"
        fi
    fi
done

# 创建Phase B摘要JSON
SUMMARY_FILE="$PHASE_B_DIR/phase_b_summary.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILES_PRODUCED=$(ls "$PHASE_B_DIR"/*.md 2>/dev/null | wc -l)

# 估计token数（粗略估计：假设1个token ≈ 4个字符）
TOTAL_CHARS=0
for file in "$PHASE_B_DIR"/*.md; do
    if [[ -f "$file" ]]; then
        CHARS=$(wc -c < "$file")
        TOTAL_CHARS=$((TOTAL_CHARS + CHARS))
    fi
done
TOKEN_ESTIMATE=$((TOTAL_CHARS / 4))

cat > "$SUMMARY_FILE" << JSON_EOF
{
    "timestamp": "$TIMESTAMP",
    "ai_agent_used": "$AI_AGENT",
    "files_produced": $FILES_PRODUCED,
    "output_files": [
        "631评分.md",
        "改编建议.md",
        "改编1_大纲与提示词.md",
        "即梦提示词.md"
    ],
    "estimated_tokens": $TOKEN_ESTIMATE,
    "work_directory": "$PHASE_B_DIR",
    "status": "completed"
}
JSON_EOF

log_success "Phase B摘要已生成 / Phase B summary generated: $SUMMARY_FILE"

# ============================================================================
# 完成
# Completion
# ============================================================================
log_success "Phase B处理完成 / Phase B processing completed successfully"
log_info "输出目录 / Output directory: $PHASE_B_DIR"
log_info "生成的文件数 / Files produced: $FILES_PRODUCED"

exit 0
