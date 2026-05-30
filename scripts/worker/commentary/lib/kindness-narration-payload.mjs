/**
 * kindness-narration-payload.mjs
 *
 * Builds the user-turn payload sent to Claude for kindness-reversal-commentary
 * narration script generation.
 *
 * No external dependencies.
 */

/**
 * Assemble the user payload string for kindness-reversal-commentary narration.
 *
 * @param {object} opts
 * @param {number}  opts.duration_sec      - Total video duration in seconds
 * @param {string}  opts.title             - Video title (from synopsis first line)
 * @param {string}  opts.story_document    - Full story_document markdown
 * @param {Array<{sec: number, description: string}>} opts.reversal_anchors
 * @param {object|null} opts.doubao_analysis - Parsed doubao_analysis.json or null
 * @returns {string} User payload for Claude messages API
 */
export function buildKindnessCommentaryUserPayload({
  duration_sec,
  title,
  story_document,
  reversal_anchors,
  doubao_analysis,
}) {
  const anchorsBlock = reversal_anchors.length
    ? reversal_anchors.map(a => `- ${a.sec} 秒: ${a.description}`).join('\n')
    : '(无识别到的明确反转锚点)';

  const doubaoBlock = doubao_analysis
    ? JSON.stringify(doubao_analysis, null, 2)
    : 'N/A (豆包分析未提供, 仅依赖剧本)';

  return `# 任务信息
原视频时长: ${duration_sec} 秒
原视频标题: ${title}

# 剧本 (story_document, 主要参考)
${story_document}

# 反转锚点 (从 jimeng_prompts 提取)
${anchorsBlock}

# 豆包成片画面分析 (补镜头节奏 + 微表情 + 偏离剧本之处)
${doubaoBlock}

请按 system 规则输出解说稿 JSON.`;
}
