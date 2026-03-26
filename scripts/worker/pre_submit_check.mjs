#!/usr/bin/env node

/**
 * pre_submit_check.mjs — 即梦提交前双闸门校验
 *
 * 闸门1: jimeng-config JSON 结构完整性校验
 * 闸门2: @引用匹配校验（所有 @引用必须在参考图中找到）
 *
 * 用法:
 *   node pre_submit_check.mjs <即梦提示词.md路径> <参考图目录>
 *
 * 退出码:
 *   0 = 双闸门通过
 *   1 = 闸门1失败（config 结构问题）
 *   2 = 闸门2失败（@引用匹配问题）
 *   3 = 参数错误
 */

import { readFileSync, readdirSync, existsSync } from 'fs';
import { basename, join, extname } from 'path';

// ============================================================
// 工具函数
// ============================================================

const RED = '\x1b[31m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const BLUE = '\x1b[34m';
const RESET = '\x1b[0m';

function log(level, msg) {
  const prefix = {
    info: `${BLUE}[INFO]${RESET}`,
    ok: `${GREEN}[✅ PASS]${RESET}`,
    warn: `${YELLOW}[⚠️ WARN]${RESET}`,
    fail: `${RED}[❌ FAIL]${RESET}`,
  };
  console.log(`${prefix[level] || '[LOG]'} ${msg}`);
}

// ============================================================
// 从 Markdown 中提取 jimeng-config JSON
// ============================================================

function extractJimengConfig(mdContent) {
  // 匹配 <!-- jimeng-config ... --> 注释块
  const commentRegex = /<!--\s*jimeng-config\s*([\s\S]*?)-->/;
  const match = mdContent.match(commentRegex);

  if (!match) {
    // 备选：匹配 ```json ... ``` 中包含 jimeng-config 标记的块
    const codeBlockRegex = /```json\s*\n\s*\/\/\s*jimeng-config\s*\n([\s\S]*?)```/;
    const codeMatch = mdContent.match(codeBlockRegex);
    if (!codeMatch) {
      // 再备选：匹配任何包含 "ratio"/"batches" 的 JSON 块（支持嵌套结构）
      const genericRegex = /```json\s*\n([\s\S]*?)```/g;
      let m;
      while ((m = genericRegex.exec(mdContent)) !== null) {
        try {
          const obj = JSON.parse(m[1]);
          // 直接顶层有 ratio + batches
          if (obj.ratio && obj.batches) {
            return obj;
          }
          // 嵌套在 jimeng_config 或 jimeng-config 键下
          const inner = obj.jimeng_config || obj['jimeng-config'] || obj.config;
          if (inner && inner.batches) {
            // 规范化：确保有 ratio 字段
            if (!inner.ratio && inner.aspect_ratio) inner.ratio = inner.aspect_ratio;
            return inner;
          }
        } catch {
          continue;
        }
      }
      return null;
    }
    try {
      return JSON.parse(codeMatch[1]);
    } catch {
      return null;
    }
  }

  try {
    return JSON.parse(match[1]);
  } catch {
    return null;
  }
}

// ============================================================
// 从 Markdown 中提取提示词文本块
// ============================================================

function extractPromptBlocks(mdContent) {
  // 匹配 "## 批次 N" 或 "### 即梦提示词" 后的内容
  const blocks = [];
  const batchRegex = /##\s*批次\s*(\d+)[\s\S]*?(?=##\s*批次\s*\d+|##\s*素材准备|$)/g;
  let match;
  while ((match = batchRegex.exec(mdContent)) !== null) {
    blocks.push({
      batchNum: parseInt(match[1]),
      content: match[0],
    });
  }
  return blocks;
}

// ============================================================
// 从提示词文本中提取所有 @引用
// ============================================================

function extractAtRefs(text) {
  // 匹配 @图-xxx 或 @角色名 格式
  const atRegex = /@([^\s,，。！？、;；\n@]+)/g;
  const refs = new Set();
  let match;
  while ((match = atRegex.exec(text)) !== null) {
    refs.add(match[1]);
  }
  return [...refs];
}

// ============================================================
// 闸门1: jimeng-config 结构校验
// ============================================================

function gate1_validateConfig(config) {
  const errors = [];
  const warnings = [];

  // 必填字段
  if (!config.ratio) {
    errors.push('缺少 ratio 字段（视频比例，如 "16:9" / "9:16"）');
  } else if (!['16:9', '9:16', '1:1', '4:3', '3:4'].includes(config.ratio)) {
    warnings.push(`ratio "${config.ratio}" 不是常见比例，请确认`);
  }

  if (config.dualModel === undefined) {
    warnings.push('缺少 dualModel 字段（是否双模型），默认 false');
  }

  if (!config.batches || !Array.isArray(config.batches)) {
    errors.push('缺少 batches 数组或格式不正确');
    return { pass: false, errors, warnings };
  }

  if (config.batches.length === 0) {
    errors.push('batches 数组为空，至少需要 1 个批次');
    return { pass: false, errors, warnings };
  }

  // 校验每个批次
  config.batches.forEach((batch, i) => {
    const prefix = `批次 ${i + 1}`;

    if (!batch.prompt || typeof batch.prompt !== 'string') {
      errors.push(`${prefix}: 缺少 prompt 或不是字符串`);
    } else if (batch.prompt.length < 20) {
      warnings.push(`${prefix}: prompt 长度只有 ${batch.prompt.length} 字符，可能太短`);
    }

    if (!batch.duration) {
      errors.push(`${prefix}: 缺少 duration（时长）`);
    } else {
      const dur = parseFloat(batch.duration);
      if (isNaN(dur) || dur < 2 || dur > 15) {
        errors.push(`${prefix}: duration ${batch.duration} 不在 2-15 秒范围内`);
      }
    }

    if (!batch.refs || !Array.isArray(batch.refs)) {
      warnings.push(`${prefix}: 缺少 refs 数组（参考图列表）`);
    }

    if (!batch.atRefs || typeof batch.atRefs !== 'object') {
      warnings.push(`${prefix}: 缺少 atRefs 映射（@引用 → 参考图文件名）`);
    }

    // 检查 refs + 视频 + 音频总数不超过 12
    const refsCount = (batch.refs || []).length;
    const videosCount = (batch.videos || []).length;
    const audiosCount = (batch.audios || []).length;
    const total = refsCount + videosCount + audiosCount;
    if (total > 12) {
      errors.push(`${prefix}: 素材总数 ${total} 超过即梦上限 12（图${refsCount}+视频${videosCount}+音频${audiosCount}）`);
    }
    if (refsCount > 9) {
      errors.push(`${prefix}: 参考图数量 ${refsCount} 超过即梦上限 9`);
    }
  });

  return {
    pass: errors.length === 0,
    errors,
    warnings,
  };
}

// ============================================================
// 闸门2: @引用匹配校验
// ============================================================

function gate2_validateAtRefs(config, promptBlocks, refDir) {
  const errors = [];
  const warnings = [];

  // 获取参考图目录中的所有文件
  let availableFiles = [];
  if (existsSync(refDir)) {
    availableFiles = readdirSync(refDir)
      .filter(f => ['.jpg', '.jpeg', '.png', '.webp'].includes(extname(f).toLowerCase()))
      .map(f => basename(f, extname(f)));
  } else {
    errors.push(`参考图目录不存在: ${refDir}`);
    return { pass: false, errors, warnings };
  }

  if (availableFiles.length === 0) {
    errors.push(`参考图目录为空: ${refDir}`);
    return { pass: false, errors, warnings };
  }

  log('info', `参考图目录中有 ${availableFiles.length} 个文件: ${availableFiles.join(', ')}`);

  // 检查每个批次的 atRefs 映射
  if (config.batches) {
    config.batches.forEach((batch, i) => {
      const prefix = `批次 ${i + 1}`;
      const atRefs = batch.atRefs || {};

      // 检查 atRefs 中的每个引用是否在参考图目录中
      // 兼容两种格式：数组 [{search, refImage/label}] 或对象 {refName: fileName}
      const entries = Array.isArray(atRefs)
        ? atRefs.map(r => [r.label || r.search || '', r.refImage || r.ref || ''])
        : Object.entries(atRefs);
      entries.forEach(([refName, fileName]) => {
        if (!fileName || typeof fileName !== 'string') return;
        const fileBase = basename(fileName, extname(fileName));
        if (!availableFiles.some(f => f === fileBase || fileName === f || f.includes(fileBase) || fileBase.includes(f))) {
          errors.push(`${prefix}: @${refName} 映射到 "${fileName}"，但参考图目录中找不到匹配文件`);
        }
      });
    });
  }

  // 从提示词文本中提取 @引用，检查是否都有对应映射
  promptBlocks.forEach((block) => {
    const atRefsInText = extractAtRefs(block.content);
    const configBatch = config.batches?.[block.batchNum - 1];
    const declaredAtRefs = configBatch?.atRefs || {};

    atRefsInText.forEach((ref) => {
      // 跳过常见的非引用 @ 符号
      if (['图', '角色', '场景', '道具'].some(skip => ref === skip)) return;

      // 兼容数组和对象格式的 atRefs
      const declaredKeys = Array.isArray(declaredAtRefs)
        ? declaredAtRefs.map(r => (r.search || '').replace(/^@/, ''))
        : Object.keys(declaredAtRefs);
      const found = declaredKeys.some(
        (key) => key === ref || key.includes(ref) || ref.includes(key)
      );
      if (!found) {
        warnings.push(`批次 ${block.batchNum}: 提示词中出现 @${ref}，但 atRefs 中未声明映射`);
      }
    });
  });

  return {
    pass: errors.length === 0,
    errors,
    warnings,
  };
}

// ============================================================
// 主流程
// ============================================================

function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.log('用法: node pre_submit_check.mjs <即梦提示词.md> <参考图目录>');
    console.log('');
    console.log('示例:');
    console.log('  node pre_submit_check.mjs ./即梦提示词.md ./参考图/');
    process.exit(3);
  }

  const [mdPath, refDir] = args;

  console.log('');
  console.log('═══════════════════════════════════════════');
  console.log('  即梦提交前双闸门校验');
  console.log('═══════════════════════════════════════════');
  console.log('');

  // 读取 Markdown 文件
  if (!existsSync(mdPath)) {
    log('fail', `即梦提示词文件不存在: ${mdPath}`);
    process.exit(3);
  }
  const mdContent = readFileSync(mdPath, 'utf-8');
  log('info', `已读取: ${mdPath} (${mdContent.length} 字符)`);

  // 提取 jimeng-config
  const config = extractJimengConfig(mdContent);
  if (!config) {
    log('fail', '无法从 Markdown 中提取 jimeng-config JSON');
    log('info', '支持的格式: <!-- jimeng-config {...} --> 或 ```json // jimeng-config {...} ```');
    process.exit(1);
  }
  log('info', `已提取 jimeng-config: ${config.batches?.length || 0} 个批次`);

  // 提取提示词文本块
  const promptBlocks = extractPromptBlocks(mdContent);
  log('info', `已提取 ${promptBlocks.length} 个提示词文本块`);

  // ========================
  // 闸门 1: Config 结构校验
  // ========================
  console.log('');
  console.log('── 闸门 1: jimeng-config 结构校验 ──');
  const gate1 = gate1_validateConfig(config);

  gate1.warnings.forEach((w) => log('warn', w));
  gate1.errors.forEach((e) => log('fail', e));

  if (gate1.pass) {
    log('ok', `闸门 1 通过 (${config.batches.length} 个批次, ${gate1.warnings.length} 个警告)`);
  } else {
    log('fail', `闸门 1 未通过: ${gate1.errors.length} 个错误`);
    process.exit(1);
  }

  // ========================
  // 闸门 2: @引用匹配校验
  // ========================
  console.log('');
  console.log('── 闸门 2: @引用匹配校验 ──');
  const gate2 = gate2_validateAtRefs(config, promptBlocks, refDir);

  gate2.warnings.forEach((w) => log('warn', w));
  gate2.errors.forEach((e) => log('fail', e));

  if (gate2.pass) {
    log('ok', `闸门 2 通过 (${gate2.warnings.length} 个警告)`);
  } else {
    log('fail', `闸门 2 未通过: ${gate2.errors.length} 个错误`);
    process.exit(2);
  }

  // ========================
  // 总结
  // ========================
  console.log('');
  console.log('═══════════════════════════════════════════');
  const totalWarnings = gate1.warnings.length + gate2.warnings.length;
  if (totalWarnings > 0) {
    log('ok', `双闸门全部通过 (${totalWarnings} 个警告，建议检查)`);
  } else {
    log('ok', '双闸门全部通过，可以提交即梦');
  }
  console.log('═══════════════════════════════════════════');
  console.log('');

  process.exit(0);
}

main();
