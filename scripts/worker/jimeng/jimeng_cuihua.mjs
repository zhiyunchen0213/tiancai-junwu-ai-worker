#!/usr/bin/env node
/**
 * 即梦视频生成自动化 - 翠花版 v2.4
 * 
 * v2.4 改进:
 *   - 修复项目命名: 支持从 "project" 或 "name" 字段读取项目名称
 *   - 增强命名失败警告: 空名称时提示用户检查jimeng-config配置
 * v2.3 改进:
 *   - --from-md 模式：直接从即梦提示词.md读取config+提示词，一行命令提交
 *   - @引用修复：占位符方案避免即梦自动转换，只在lv-select-popup弹窗选择
 *   - 模型选择修复：排除Fast的精确匹配
 *   - 项目命名提前到新建项目后立即执行
 * v2.2 改进:
 *   - 提交前审核机制：验证参考图数量、比例、时长、模型、提示词内容
 *   - 修复批次2+提示词写入失败：用位置定位正确的输入编辑器
 *   - 清空后重新click获取焦点再insertText
 *   - 审核不通过则暂停报错，不盲目提交
 */

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'fs';
import { resolve, basename, dirname } from 'path';
import { createHash } from 'crypto';

function sanitizePromptText(rawPrompt) {
  let text = typeof rawPrompt === 'string' ? rawPrompt : `${rawPrompt ?? ''}`;
  for (let i = 0; i < 2; i++) {
    const next = text
      .replace(/\\r\\n/g, '\n')
      .replace(/\\n/g, '\n')
      .replace(/\\r/g, '\n')
      .replace(/\\t/g, '\t')
      .replace(/\\"/g, '"')
      .replace(/\\'/g, "'")
      .replace(/\\\\/g, '\\');
    if (next === text) break;
    text = next;
  }
  return text
    .replace(/\r\n?/g, '\n')
    .replace(/\u00a0/g, ' ')
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .trim();
}

function assertNoVisibleEscapes(promptText, context = 'prompt') {
  const leftovers = [...new Set((promptText.match(/\\(?:n|r|t|"|')/g) || []))];
  if (leftovers.length) {
    throw new Error(`${context} 仍含未清洗转义: ${leftovers.join(', ')}`);
  }
}

function sha1(text) {
  return createHash('sha1').update(String(text || ''), 'utf8').digest('hex');
}

function ensureParentDir(path) {
  mkdirSync(dirname(path), { recursive: true });
}

function getBatchStateKey(batchNum) {
  return `batch${batchNum}`;
}

function buildSubmissionFingerprint(batch, model, ratio) {
  return {
    promptHash: sha1(sanitizePromptText(batch.prompt || '')),
    refsHash: sha1((batch.refs || []).map(f => resolve(f)).join('|')),
    atRefsHash: sha1(JSON.stringify(batch.atRefs || [])),
    ratio: ratio || '9:16',
    duration: batch.duration || 15,
    model,
  };
}

function getDefaultStatePaths(baseDir) {
  const root = baseDir || '/tmp/jimeng_cuihua';
  return {
    submitStatePath: resolve(root, 'submit_state.json'),
    submitAuditPath: resolve(root, 'submit_audit.jsonl'),
  };
}

function normalizeProjectId(value) {
  if (value === undefined || value === null) return null;
  const text = String(value).trim();
  if (!text || text === 'unknown' || text === 'null' || text === 'undefined') return null;
  return text;
}

function loadSubmitState(path, cfg) {
  const defaults = {
    schema_version: 1,
    story_name: cfg.name || '',
    story_dir: cfg.storyDir || null,
    project_id: normalizeProjectId(cfg.projectId),
    project_status: 'clean',
    submit_blocked: false,
    polluted_reason: null,
    batches: {},
    updated_at: new Date().toISOString(),
  };
  if (!path || !existsSync(path)) return defaults;
  try {
    const merged = { ...defaults, ...JSON.parse(readFileSync(path, 'utf8')) };
    merged.project_id = normalizeProjectId(merged.project_id);
    return merged;
  } catch (e) {
    console.log(`  ⚠️ submit_state 读取失败，改用默认空状态: ${e.message}`);
    return defaults;
  }
}

function saveSubmitState(path, state) {
  if (!path) return;
  ensureParentDir(path);
  state.updated_at = new Date().toISOString();
  writeFileSync(path, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
}

function appendAuditLog(path, payload) {
  if (!path) return;
  ensureParentDir(path);
  appendFileSync(path, `${JSON.stringify({ ts: new Date().toISOString(), ...payload })}\n`, 'utf8');
}

function ensureBatchModelState(state, batchKey, model) {
  state.batches ||= {};
  state.batches[batchKey] ||= {};
  state.batches[batchKey][model] ||= {};
  return state.batches[batchKey][model];
}

function markProjectPolluted(state, reason) {
  state.project_status = 'polluted';
  state.submit_blocked = true;
  state.polluted_reason = reason || 'unknown';
}

function assertSubmissionAllowed(state, batchNum, model, fingerprint, forceResubmit = false) {
  if (state.submit_blocked || state.project_status === 'polluted') {
    throw new Error(`项目已封存为 polluted，禁止继续 submit: ${state.polluted_reason || 'unknown'}`);
  }
  const batchKey = getBatchStateKey(batchNum);
  const current = state.batches?.[batchKey]?.[model];
  if (!current) return { batchKey, current: null };

  const alreadyActive = ['submitted', 'queued', 'running', 'completed'].includes(current.status);
  const sameFingerprint = current.promptHash === fingerprint.promptHash
    && current.refsHash === fingerprint.refsHash
    && current.atRefsHash === fingerprint.atRefsHash
    && current.ratio === fingerprint.ratio
    && current.duration === fingerprint.duration;

  if (!forceResubmit && alreadyActive && sameFingerprint) {
    throw new Error(`幂等闸门：${batchKey} / ${model} 已存在状态 ${current.status}，禁止重复提交`);
  }
  return { batchKey, current };
}

// ============ --from-md 解析器 ============
/**
 * 从即梦提示词.md解析出config
 * 
 * md文件末尾需包含:
 *   <!-- jimeng-config
 *   { JSON config }
 *   -->
 * 
 * 提示词从 ```代码块``` 中提取（每个批次对应一个"即梦提示词"代码块）
 * 参考图路径相对于md文件所在目录
 */
function parseFromMd(mdPath) {
  const mdContent = readFileSync(mdPath, 'utf8');
  const mdDir = dirname(resolve(mdPath));

  // 1. 提取 <!-- jimeng-config ... --> 块
  const configMatch = mdContent.match(/<!--\s*jimeng-config\s*\n([\s\S]*?)\n\s*-->/);
  if (!configMatch) {
    console.error('❌ 未找到 <!-- jimeng-config --> 块');
    process.exit(1);
  }
  const raw = JSON.parse(configMatch[1]);
  if (!raw.batches || !Array.isArray(raw.batches) || raw.batches.length === 0) {
    console.error('❌ jimeng-config 缺少 batches，无法提交');
    process.exit(1);
  }

  // 2. 提取所有"即梦提示词"代码块
  //    匹配模式: ### 即梦提示词 后面跟着 ```...```
  const promptBlocks = [];
  // 兼容格式：允许 "### 即梦提示词" 与代码块之间有说明文字（如 批次/场景/情绪弧）
  // 取每个标题后遇到的第一个代码块作为该批次提示词。
  const promptRegex = /###\s*即梦提示词[\s\S]*?```[^\n]*\n([\s\S]*?)```/g;
  let m;
  while ((m = promptRegex.exec(mdContent)) !== null) {
    promptBlocks.push(m[1].trim());
  }

  // 3. 组装config
  const defaultPaths = getDefaultStatePaths(mdDir);
  const config = {
    name: raw.name || raw.project || '',
    ratio: raw.ratio || '9:16',
    dualModel: raw.dualModel !== undefined ? raw.dualModel : true,
    projectId: normalizeProjectId(raw.projectId),
    mdProjectId: normalizeProjectId(raw.projectId),
    screenshotDir: raw.screenshotDir || `/tmp/jimeng_cuihua/${raw.name || 'unnamed'}`,
    dryRun: raw.dryRun || false,
    storyDir: mdDir,
    submitStatePath: raw.submitStatePath || defaultPaths.submitStatePath,
    submitAuditPath: raw.submitAuditPath || defaultPaths.submitAuditPath,
    forceResubmit: !!raw.forceResubmit,
    batches: [],
  };

  for (let i = 0; i < (raw.batches || []).length; i++) {
    const b = raw.batches[i];
    if (!Array.isArray(b.refs) || b.refs.length === 0) {
      console.error(`❌ 批次${i + 1} 缺少 refs（参考图列表）`);
      process.exit(1);
    }
    if (!Array.isArray(b.atRefs) || b.atRefs.length === 0) {
      console.error(`❌ 批次${i + 1} 缺少 atRefs（@引用映射）`);
      process.exit(1);
    }

    // 解析refs路径（相对于md文件目录）
    const refs = (b.refs || []).map(f => resolve(mdDir, f)).filter(f => {
      if (!existsSync(f)) { console.log(`  ⚠️ 参考图不存在，跳过: ${f}`); return false; }
      return true;
    });
    // extraRefs（可选，文件存在才加入）
    const extraRefs = (b.extraRefs || []).map(f => resolve(mdDir, f)).filter(f => existsSync(f));
    const allRefs = [...refs, ...extraRefs];
    if (allRefs.length === 0) {
      console.error(`❌ 批次${i + 1} 没有可用参考图（refs/extraRefs均无效）`);
      process.exit(1);
    }

    for (const r of b.atRefs) {
      if (!r || typeof r.search !== 'string' || typeof r.label !== 'string' || !r.search.trim() || !r.label.trim()) {
        console.error(`❌ 批次${i + 1} atRefs 存在非法项: ${JSON.stringify(r)}`);
        process.exit(1);
      }
    }

    // 提示词：优先用promptBlocks[i]，fallback到b.prompt
    const prompt = sanitizePromptText(promptBlocks[i] || b.prompt || '');
    if (!prompt) {
      console.log(`  ⚠️ 批次${i + 1} 无提示词`);
    }

    // 预检闸门：标准化 atRefs.label 为 图片N，并检查 search 是否存在于提示词
    const normalizedAtRefs = (b.atRefs || []).map((r, idx) => {
      const expectedLabel = `图片${idx + 1}`;
      let label = (r.label || '').trim();
      if (!/^图片\d+$/.test(label)) {
        console.log(`  ⚠️ 批次${i + 1} atRefs.label 非标准("${label}")，自动修正为 "${expectedLabel}"`);
        label = expectedLabel;
      }
      const search = (r.search || '').trim();
      if (prompt && search && !prompt.includes(search)) {
        console.error(`❌ 批次${i + 1} atRefs.search 未在提示词中找到: ${search}`);
        process.exit(1);
      }
      return {
        search,
        label,
        ref: r.ref || allRefs[idx] || ''
      };
    });

    config.batches.push({
      refs: allRefs,
      prompt,
      duration: b.duration || 15,
      atRefs: normalizedAtRefs,
      model: b.model || 'Seedance 2.0',
      refMode: b.refMode || '全能参考',
    });
  }

  console.log(`📄 从MD解析: ${config.name}`);
  console.log(`   批次: ${config.batches.length}, 提示词块: ${promptBlocks.length}`);
  for (let i = 0; i < config.batches.length; i++) {
    const b = config.batches[i];
    console.log(`   批次${i + 1}: ${b.refs.length}张参考图, ${b.prompt.length}字符提示词, ${b.duration}s`);
  }

  return config;
}

// ============ 参数解析 ============
function parseArgs() {
  const args = process.argv.slice(2);
  const config = {
    cdpPort: 18781,
    name: '',
    ratio: '9:16',
    dualModel: false,
    projectId: null,
    screenshotDir: '/tmp/jimeng_cuihua',
    dryRun: false,
    keepBrowser: false,
    batches: [],
    mdProjectId: null,
    storyDir: null,
    submitStatePath: null,
    submitAuditPath: null,
    forceResubmit: false,
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--config': {
        const configPath = resolve(args[++i]);
        const raw = JSON.parse(readFileSync(configPath, 'utf8'));
        const configDir = dirname(configPath);
        const defaultPaths = getDefaultStatePaths(dirname(configPath));
        config.storyDir = dirname(configPath);
        config.submitStatePath = raw.submitStatePath || defaultPaths.submitStatePath;
        config.submitAuditPath = raw.submitAuditPath || defaultPaths.submitAuditPath;
        config.forceResubmit = !!raw.forceResubmit;
        if (raw.name) config.name = raw.name;
        if (raw.ratio) config.ratio = raw.ratio;
        if (raw.dualModel !== undefined) config.dualModel = raw.dualModel;
        if (raw.projectId) config.projectId = normalizeProjectId(raw.projectId);
        if (raw.screenshotDir) config.screenshotDir = raw.screenshotDir;
        if (raw.dryRun !== undefined) config.dryRun = raw.dryRun;
        if (raw.batches) {
          config.batches = raw.batches.map(b => ({
            refs: (b.refs || []).map(f => resolve(configDir, f)),
            prompt: sanitizePromptText(
              b.promptFile && existsSync(resolve(configDir, b.promptFile))
                ? readFileSync(resolve(configDir, b.promptFile), 'utf8').trim()
                : (b.prompt || '')
            ),
            duration: b.duration || 15,
            atRefs: b.atRefs || [],
            model: b.model || 'Seedance 2.0',
            refMode: b.refMode || '全能参考',
          }));
        }
        break;
      }
      case '--cdp-port': config.cdpPort = parseInt(args[++i]); break;
      case '--name': config.name = args[++i]; break;
      case '--refs': {
        const refs = args[++i].split(',').map(f => resolve(f));
        if (config.batches.length === 0) config.batches.push({ refs, prompt: '', duration: 15, atRefs: [], model: 'Seedance 2.0', refMode: '全能参考' });
        else config.batches[0].refs = refs;
        break;
      }
      case '--prompt': {
        const pf = args[++i];
        const prompt = sanitizePromptText(existsSync(pf) ? readFileSync(pf, 'utf8').trim() : pf);
        if (config.batches.length === 0) config.batches.push({ refs: [], prompt, duration: 15, atRefs: [], model: 'Seedance 2.0', refMode: '全能参考' });
        else config.batches[0].prompt = prompt;
        break;
      }
      case '--at-refs': {
        const atRefs = args[++i].split(',').map(s => {
          const [search, label] = s.split(':');
          return { search, label };
        });
        if (config.batches.length > 0) config.batches[0].atRefs = atRefs;
        break;
      }
      case '--ratio': config.ratio = args[++i]; break;
      case '--duration':
        if (config.batches.length > 0) config.batches[0].duration = parseInt(args[++i]);
        else { config.batches.push({ refs: [], prompt: '', duration: parseInt(args[++i]), atRefs: [], model: 'Seedance 2.0', refMode: '全能参考' }); }
        break;
      case '--dual-model': config.dualModel = true; break;
      case '--project': {
        const nextProject = normalizeProjectId(args[++i]);
        if (config.mdProjectId && nextProject && nextProject !== config.mdProjectId) {
          console.error(`❌ 项目ID冲突：配置文件为 ${config.mdProjectId}，CLI为 ${nextProject}。禁止混用多个项目号。`);
          process.exit(1);
        }
        config.projectId = nextProject;
        break;
      }
      case '--screenshot-dir': config.screenshotDir = args[++i]; break;
      case '--submit-state': config.submitStatePath = resolve(args[++i]); break;
      case '--submit-audit': config.submitAuditPath = resolve(args[++i]); break;
      case '--story-dir': config.storyDir = resolve(args[++i]); break;
      case '--force-resubmit': config.forceResubmit = true; break;
      case '--dry-run': config.dryRun = true; break;
      case '--keep-browser': config.keepBrowser = true; break;
      case '--from-md': {
        const mdCfg = parseFromMd(args[++i]);
        if ((config.mdProjectId && mdCfg.projectId && config.mdProjectId !== mdCfg.projectId)
          || (!config.mdProjectId && config.projectId && mdCfg.projectId && config.projectId !== mdCfg.projectId)) {
          const cliProject = config.projectId || 'null';
          const mdProject = mdCfg.projectId || 'null';
          console.error(`❌ 项目ID冲突：CLI=${cliProject}，MD=${mdProject}。请统一使用同一项目号。`);
          process.exit(1);
        }
        const keepProjectId = config.projectId;
        Object.assign(config, mdCfg);
        if (keepProjectId) config.projectId = keepProjectId;
        break;
      }
    }
  }
  if (!config.storyDir) {
    config.storyDir = dirname(resolve(config.submitStatePath || config.screenshotDir));
  }
  if (!config.submitStatePath || !config.submitAuditPath) {
    const defaults = getDefaultStatePaths(config.storyDir || dirname(resolve(config.screenshotDir)));
    config.submitStatePath ||= defaults.submitStatePath;
    config.submitAuditPath ||= defaults.submitAuditPath;
  }
  return config;
}

// ============ 工具函数 ============
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function ss(page, name, dir) {
  mkdirSync(dir, { recursive: true });
  await page.screenshot({ path: `${dir}/${name}.png` });
  console.log(`📸 ${name}`);
}

/** 获取当前对话主面板的可见toolbar（优先右侧可见） */
async function getVisibleToolbar(page) {
  return page.evaluate(() => {
    const toolbars = Array.from(document.querySelectorAll('[class*="toolbar-settings-content"]'))
      .filter(tb => tb.getBoundingClientRect().height > 0);
    if (!toolbars.length) return { exists: false };
    const textRich = toolbars.filter(tb => {
      const text = (tb.textContent || '').replace(/\s+/g, '').trim();
      return text.length >= 5;
    });
    const targetGroup = textRich.length ? textRich : toolbars;
    const toolbar = targetGroup.length ? targetGroup.reduce((a, b) => {
      const ra = a.getBoundingClientRect();
      const rb = b.getBoundingClientRect();
      return rb.x > ra.x ? b : a;
    }, targetGroup[0]) : null;
    return toolbar ? {
      exists: true,
      childCount: toolbar.children.length,
      positions: Array.from(toolbar.children).map(ch => {
        const r = ch.getBoundingClientRect();
        return { cx: Math.round(r.x + r.width/2), cy: Math.round(r.y + r.height/2), w: Math.round(r.width), h: Math.round(r.height) };
      })
    } : { exists: false };
  });
}

/** 打开指定combobox，返回可见弹窗文本 */
async function openComboAt(page, idx) {
  // 滚动到可见区域
  await page.evaluate((i) => {
    const el = document.querySelectorAll('[role="combobox"]')[i];
    if (el) el.scrollIntoView({ block: 'center', inline: 'center' });
  }, idx);
  await sleep(200);

  // 最多尝试 3 次点击，确保 popup 弹出
  for (let attempt = 0; attempt < 3; attempt++) {
    // 先关闭可能残留的 popup
    await page.evaluate(() => { document.activeElement?.blur(); });
    await sleep(150);

    try {
      const combo = page.locator('[role="combobox"]').nth(idx);
      await combo.click({ timeout: 3000 });
    } catch {
      // fallback: JS click
      await page.evaluate((i) => {
        const el = document.querySelectorAll('[role="combobox"]')[i];
        if (el) { el.scrollIntoView({ block: 'center' }); el.click(); el.focus(); }
      }, idx);
    }
    await sleep(800);

    const text = await page.evaluate(() => {
      for (const pop of document.querySelectorAll('[class*="lv-select-popup"]')) {
        if (pop.getBoundingClientRect().height > 0) {
          return pop.textContent?.trim().slice(0, 400) || '';
        }
      }
      return '';
    });
    if (text) return text;
    // popup 没弹出，重试
    if (attempt < 2) await sleep(500);
  }
  return '';
}

function classifyPopupText(text) {
  if (!text) return null;
  if (text.includes('Agent 模式') || text.includes('图片生成') || text.includes('视频生成')) return 'createMode';
  if (text.includes('全能参考') || text.includes('首尾帧') || text.includes('智能多帧') || text.includes('主体参考')) return 'refMode';
  if (text.includes('Seedance 2.0') || text.includes('视频3.5 Pro')) return 'model';
  if (text.includes('4s') || text.includes('15s')) return 'duration';
  return null;
}

/** 扫描所有 combobox，按弹窗内容识别控件身份 */
async function detectComboboxRoles(page) {
  const count = await page.evaluate(() => document.querySelectorAll('[role="combobox"]').length);
  const map = {};
  for (let i = 0; i < count; i++) {
    const text = await openComboAt(page, i);
    const kind = classifyPopupText(text);
    if (kind && map[kind] === undefined) {
      map[kind] = i;
    }
    await page.evaluate(() => document.body.click());
    await sleep(300);
  }
  return map;
}

/** 在已知身份的 combobox 上选择 option */
async function openAndSelectByKind(page, kind, optionText, roleMap) {
  const idx = roleMap[kind];
  if (idx === undefined) {
    console.log(`  ❌ 未识别到控件身份: ${kind}`);
    return false;
  }
  await openComboAt(page, idx);
  const clicked = await page.evaluate((t) => {
    for (const pop of document.querySelectorAll('[class*="lv-select-popup"]')) {
      if (pop.getBoundingClientRect().height > 0) {
        const opts = pop.querySelectorAll('li[role="option"]');
        const wantFast = t.includes('Fast');
        for (const opt of opts) {
          const text = opt.textContent || '';
          if (text.includes(t)) {
            if (!wantFast && text.includes('Fast')) continue;
            opt.click();
            return true;
          }
        }
      }
    }
    return false;
  }, optionText);
  if (clicked) console.log(`  ✅ 选择"${optionText}"`);
  else console.log(`  ❌ 未找到"${optionText}"选项`);
  await sleep(500);
  return clicked;
}

/** 
 * 找到正确的输入编辑器（不是对话历史区）
 * 即梦右侧面板有两个contenteditable：
 *   - 上面的：对话历史展示区（大面积，高度大）
 *   - 下面的：输入框（小面积，y值最大）
 * 用"y值最大+高度最小"来定位输入框
 */
async function getInputEditor(page) {
  return page.evaluate(() => {
    const eds = Array.from(document.querySelectorAll('[contenteditable="true"]')).filter(ed => {
      const r = ed.getBoundingClientRect();
      return r.height > 0 && r.width > 80;
    });
    if (!eds.length) return null;

    // 优先：位于页面下半部分、宽度较大、接近底部工具栏的编辑器
    let inputEd = null;
    let bestScore = -1;
    for (const ed of eds) {
      const r = ed.getBoundingClientRect();
      let score = 0;
      if (r.y > window.innerHeight * 0.45) score += 3;
      if (r.width > 300) score += 2;
      if (r.height < 220) score += 2;
      if ((ed.textContent || '').length < 5000) score += 1;
      if (r.y > bestScore) {
        // keep scoring separate below
      }
      if (score > bestScore) {
        bestScore = score;
        inputEd = ed;
      }
    }
    if (!inputEd) return null;
    const r = inputEd.getBoundingClientRect();
    return {
      x: Math.round(r.x + r.width/2),
      y: Math.round(r.y + r.height/2),
      w: Math.round(r.width),
      h: Math.round(r.height),
      text: (inputEd.textContent || '').trim(),
      textLen: (inputEd.textContent || '').trim().length
    };
  });
}

/** 读取右侧对话面板输入框（用于提交前最终核验） */
async function getRightDialogEditor(page) {
  return page.evaluate(() => {
    const eds = Array.from(document.querySelectorAll('[contenteditable="true"]')).filter(ed => {
      const r = ed.getBoundingClientRect();
      return r.height > 0 && r.width > 80;
    });
    if (!eds.length) return null;

    const viewportW = window.innerWidth;
    let best = null;
    let bestScore = -1;

    for (const ed of eds) {
      const r = ed.getBoundingClientRect();
      const isRight = r.x > viewportW * 0.4 ? 1 : 0;
      const score = (r.x + r.width / 2) + (r.y * 0.2) + (isRight * 10);
      if (score > bestScore) {
        bestScore = score;
        const text = (ed.textContent || '').trim();
        best = {
          x: Math.round(r.x + r.width / 2),
          y: Math.round(r.y + r.height / 2),
          w: Math.round(r.width),
          h: Math.round(r.height),
          text: text,
          textLen: text.length,
          mentionCount: ed.querySelectorAll('[class*="mention"]').length,
        };
      }
    }
    return best;
  });
}

async function getActivePanelBounds(page) {
  return page.evaluate(() => {
    const toolbars = Array.from(document.querySelectorAll('[class*="toolbar-settings-content"]'))
      .filter(tb => tb.getBoundingClientRect().height > 0);
    if (!toolbars.length) return null;
    const textRich = toolbars.filter(tb => {
      const text = (tb.textContent || '').replace(/\s+/g, '').trim();
      return text.length >= 5;
    });
    const targetGroup = textRich.length ? textRich : toolbars;
    const toolbar = targetGroup.reduce((a, b) => {
      const ra = a.getBoundingClientRect();
      const rb = b.getBoundingClientRect();
      return rb.x > ra.x ? b : a;
    }, targetGroup[0]);
    const tRect = toolbar.getBoundingClientRect();
    return {
      xMin: Math.max(0, tRect.x - 240),
      xMax: tRect.x + tRect.width + 240,
    };
  });
}

/** 统计当前已上传参考图数量（按当前右侧 panel） */
async function getRefCount(page) {
  const bounds = await getActivePanelBounds(page);
  if (!bounds) return 0;

  return page.evaluate((b) => {
    const containers = Array.from(document.querySelectorAll('[class*="remove-button-container"]'));
    let count = 0;
    for (const c of containers) {
      const r = c.getBoundingClientRect();
      if (r.height <= 0) continue;
      const cx = r.x + r.width / 2;
      if (cx >= b.xMin && cx <= b.xMax) count++;
    }
    return count;
  }, bounds);
}

/** 清空所有参考图（强制验空） */
async function clearRefs(page) {
  const before = await getRefCount(page);
  let cleared = 0;

  // 最多尝试 40 次删除，直到引用数归零
  for (let attempt = 0; attempt < 40; attempt++) {
    const current = await getRefCount(page);
    if (current <= 0) break;

    const removed = await page.evaluate((bounds) => {
      const inBounds = (el) => {
        const r = el.getBoundingClientRect();
        const cx = r.x + r.width / 2;
        return cx >= bounds.xMin && cx <= bounds.xMax;
      };

      // 优先点删除容器里的真正可点击按钮（而不是容器本身）
      const containers = Array.from(document.querySelectorAll('[class*="remove-button-container"]'))
        .filter(c => c.getBoundingClientRect().height > 0 && inBounds(c));
      if (!containers.length) return false;

      // 取最右侧一个，减少点错概率
      containers.sort((a, b) => b.getBoundingClientRect().x - a.getBoundingClientRect().x);
      const c = containers[0];

      const candidates = [
        ...c.querySelectorAll('button, [role="button"], [class*="remove-btn"], [class*="close-btn"], [class*="remove-button"]'),
        c
      ];

      for (const el of candidates) {
        const r = el.getBoundingClientRect();
        if (r.height > 0 && r.width > 0) {
          el.click();
          return true;
        }
      }
      return false;
    }, await getActivePanelBounds(page) || { xMin: 0, xMax: 1e9, yMin: -1e9, yMax: 1e9 });

    if (removed) {
      cleared++;
      await sleep(500);
    } else {
      break;
    }
  }

  const after = await getRefCount(page);
  console.log(`  清空参考图: ${cleared} 次点击 | 前=${before} 后=${after}`);
  return { before, after, cleared };
}

/** 清空提示词（zoom模式下） - 使用正确的编辑器定位 */
async function clearPrompt(page) {
  const ed = await getInputEditor(page);
  if (!ed) { console.log('  ⚠️ 未找到输入框'); return; }

  // 先click获取焦点
  await page.mouse.click(ed.x, ed.y);
  await sleep(200);
  // Ctrl+A全选 + Backspace清空
  await page.keyboard.press('Meta+a');
  await sleep(100);
  await page.keyboard.press('Backspace');
  await sleep(300);

  // 验证是否清空
  const after = await getInputEditor(page);
  if (after && after.textLen > 0) {
    console.log(`  ⚠️ 还有 ${after.textLen} 字符，再试一次`);
    await page.mouse.click(after.x, after.y);
    await sleep(200);
    await page.keyboard.press('Meta+a');
    await sleep(100);
    await page.keyboard.press('Backspace');
    await sleep(300);
  }

  const final = await getInputEditor(page);
  console.log(`  ✅ 清空提示词 (剩余: ${final?.textLen || 0} 字符)`);
}

/** 上传参考图 */
async function uploadRefs(page, refs) {
  const fileInputs = page.locator('input[type="file"][class*="file-input"]');
  const fiCount = await fileInputs.count();
  for (let i = 0; i < fiCount; i++) {
    const inp = fileInputs.nth(i);
    const multiple = await inp.getAttribute('multiple').catch(() => null);
    if (multiple !== null) {
      try {
        await inp.setInputFiles(refs);
        console.log(`  ✅ 已上传 ${refs.length} 张: ${refs.map(f => basename(f)).join(', ')}`);
        return true;
      } catch (e) {
        console.log(`  ⚠️ input[${i}]: ${e.message.slice(0, 60)}`);
      }
    }
  }
  console.log('  ❌ 上传失败');
  return false;
}

/** 设置比例 */
async function setRatio(page, ratio) {
  const alreadyVisible = await readVisibleToolbarText(page);
  if (alreadyVisible && alreadyVisible.includes(ratio)) {
    console.log(`  ✅ 比例 ${ratio}（已保持）`);
    return true;
  }

  const toolbar = await getVisibleToolbar(page);
  if (toolbar.exists && toolbar.childCount >= 4) {
    const pos = toolbar.positions[3];
    await page.mouse.click(pos.cx, pos.cy);
    await sleep(800);
  }

  const clickedFromPopover = await page.evaluate((target) => {
    const pop = Array.from(document.querySelectorAll('div.lv-popover-content'))
      .find(p => (p.textContent || '').includes('选择比例'));
    if (!pop) return false;
    const options = Array.from(pop.querySelectorAll('div')).filter(el => {
      const r = el.getBoundingClientRect();
      const t = (el.textContent || '').trim();
      return r.height > 0 && r.width > 0 && /\d:\d/.test(t);
    });
    for (const opt of options) {
      const t = (opt.textContent || '').trim();
      if (t === target) {
        const r = opt.getBoundingClientRect();
        opt.click();
        return true;
      }
    }
    return false;
  }, ratio);

  const clickedFallback = clickedFromPopover ? true : await page.evaluate((target) => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      if (walker.currentNode.textContent.trim() === target) {
        const el = walker.currentNode.parentElement;
        const r = el.getBoundingClientRect();
        if (r.height > 0 && r.width > 0) { el.click(); return true; }
      }
    }
    return false;
  }, ratio);

  let confirmed = clickedFallback;
  if (!confirmed) {
    const afterText = await readVisibleToolbarText(page);
    confirmed = !!(afterText && afterText.includes(ratio));
  }

  if (confirmed) console.log(`  ✅ 比例 ${ratio}`);
  else console.log(`  ❌ 比例 ${ratio} 未找到`);
  await page.evaluate(() => document.body.click());
  await sleep(300);
  return confirmed;
}

/** 设置时长 */
async function setDuration(page, duration) {
  const target = `${duration}s`;
  const toolbar = await getVisibleToolbar(page);
  if (toolbar.exists && toolbar.childCount >= 5) {
    const pos = toolbar.positions[4];
    await page.mouse.click(pos.cx, pos.cy);
    await sleep(600);
  }

  const clickedFromPopup = await page.evaluate((target) => {
    const popup = Array.from(document.querySelectorAll('[class*=\"lv-select-popup\"]')).find(p => p.getBoundingClientRect().height > 0);
    if (!popup) return false;
    const options = popup.querySelectorAll('li[role=\"option\"]');
    for (const opt of Array.from(options)) {
      const t = (opt.textContent || '').trim();
      if (t === target) {
        opt.click();
        return true;
      }
    }
    return false;
  }, target);

  const clicked = clickedFromPopup
    || await page.evaluate((target) => {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        if (walker.currentNode.textContent?.trim() === target) {
          const el = walker.currentNode.parentElement;
          const r = el.getBoundingClientRect();
          if (r.height > 0 && r.width > 0) {
            el.click();
            return true;
          }
        }
      }
      return false;
    }, target);

  await page.evaluate(() => document.body.click());
  await sleep(300);
  return clicked;
}

/** 输入提示词（zoom模式下） - 使用正确的编辑器定位 */
async function inputPrompt(page, context, promptText) {
  const cleanedPrompt = sanitizePromptText(promptText);
  assertNoVisibleEscapes(cleanedPrompt, '注入前prompt');
  // 先清空确保干净
  const ed = await getInputEditor(page);
  if (!ed) { console.log('  ❌ 未找到输入框'); return false; }

  // 清空DOM内容
  await page.evaluate(() => {
    const eds = document.querySelectorAll('[contenteditable="true"]');
    let inputEd = null, maxY = -1;
    for (const ed of eds) {
      const r = ed.getBoundingClientRect();
      if (r.height > 0 && r.y > maxY) { maxY = r.y; inputEd = ed; }
    }
    if (inputEd) {
      inputEd.textContent = '';
      inputEd.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
    }
  });
  await sleep(300);

  // 重新获取位置（清空后尺寸可能变）
  const edAfter = await getInputEditor(page);
  if (!edAfter) { console.log('  ❌ 清空后找不到输入框'); return false; }

  // 🔴 关键：mouse.click 获取真正的浏览器焦点
  await page.mouse.click(edAfter.x, edAfter.y);
  await sleep(300);

  // CDP insertText
  const client = await context.newCDPSession(page);
  await client.send('Input.insertText', { text: cleanedPrompt });
  await sleep(500);

  // 验证
  const verify = await getInputEditor(page);
  const actualLen = verify?.textLen || 0;
  console.log(`  提示词: ${actualLen}/${cleanedPrompt.length} 字符`);

  // 如果写入失败，重试
  if (actualLen < cleanedPrompt.length * 0.5) {
    console.log('  ⚠️ 写入不足，重试...');
    // 重新click + 清空 + 写入
    const ed2 = await getInputEditor(page);
    if (ed2) {
      await page.mouse.click(ed2.x, ed2.y);
      await sleep(200);
      await page.keyboard.press('Meta+a');
      await page.keyboard.press('Backspace');
      await sleep(300);
      await page.mouse.click(ed2.x, ed2.y);
      await sleep(200);
      await client.send('Input.insertText', { text: cleanedPrompt });
      await sleep(500);
      const v2 = await getInputEditor(page);
      console.log(`  重试后: ${v2?.textLen || 0}/${cleanedPrompt.length} 字符`);
    }
  }
  await client.detach();
  return true;
}

async function getMentionCount(page) {
  return page.evaluate(() => {
    const eds = document.querySelectorAll('[contenteditable="true"]');
    let inputEd = null, maxY = -1;
    for (const ed of eds) {
      const r = ed.getBoundingClientRect();
      if (r.height > 0 && r.y > maxY) { maxY = r.y; inputEd = ed; }
    }
    if (!inputEd) return 0;
    return inputEd.querySelectorAll('[class*="mention"]').length;
  });
}

async function insertSingleAtRef(page, ref) {
  const debugCount = await page.evaluate((search) => {
    const eds = document.querySelectorAll('[contenteditable="true"]');
    let inputEd = null, maxY = -1;
    for (const ed of eds) { const r = ed.getBoundingClientRect(); if (r.height > 0 && r.y > maxY) { maxY = r.y; inputEd = ed; } }
    if (!inputEd) return { count: -1 };
    const fullText = inputEd.textContent || '';
    let count = 0, idx = 0;
    while ((idx = fullText.indexOf(search, idx)) !== -1) { count++; idx += search.length; }
    return { count };
  }, ref.search);
  console.log(`    [debug] "${ref.search}" 在编辑器中出现 ${debugCount.count} 次`);

  const found = await page.evaluate((search) => {
    const eds = document.querySelectorAll('[contenteditable="true"]');
    let inputEd = null, maxY = -1;
    for (const ed of eds) {
      const r = ed.getBoundingClientRect();
      if (r.height > 0 && r.y > maxY) { maxY = r.y; inputEd = ed; }
    }
    if (!inputEd) return false;
    const walker = document.createTreeWalker(inputEd, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const idx = walker.currentNode.textContent.indexOf(search);
      if (idx >= 0) {
        const range = document.createRange();
        range.setStart(walker.currentNode, idx);
        range.setEnd(walker.currentNode, idx + search.length);
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        return true;
      }
    }
    return false;
  }, ref.search);

  if (!found) {
    console.log(`    ⚠️ "${ref.search}" 未找到`);
    return { ok: false, reason: 'placeholder_missing' };
  }

  await page.keyboard.press('Backspace');
  await sleep(300);

  let clicked = false;
  const toolbar = await getVisibleToolbar(page);
  if (toolbar.exists && toolbar.childCount >= 6) {
    const atPos = toolbar.positions[5];
    await page.mouse.click(atPos.cx, atPos.cy);
    await sleep(800);
    const popupPick = await page.evaluate((label) => {
      const popups = document.querySelectorAll('[class*="lv-select-popup"]');
      let lastVisiblePop = null;
      for (const pop of popups) {
        if (pop.getBoundingClientRect().height > 0) lastVisiblePop = pop;
      }
      if (!lastVisiblePop) return { items: ['no popup'], pos: null };
      const items = lastVisiblePop.querySelectorAll('li[class*="lv-select-option"]');
      for (const item of items) {
        const ir = item.getBoundingClientRect();
        if (ir.height <= 0) continue;
        const text = item.textContent?.trim();
        if (text === label) {
          return { items: [text], pos: { x: Math.round(ir.x + ir.width/2), y: Math.round(ir.y + ir.height/2) } };
        }
      }
      const allTexts = [];
      for (const item of items) { if (item.getBoundingClientRect().height > 0) allTexts.push(item.textContent?.trim()); }
      return { items: allTexts, pos: null };
    }, ref.label);

    if (popupPick.pos) {
      await page.mouse.click(popupPick.pos.x, popupPick.pos.y);
      await sleep(500);
      clicked = true;
    } else if (popupPick.items?.length === 1 && popupPick.items[0] === 'no popup') {
      const fallback = await page.evaluate((label) => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          if (walker.currentNode.textContent?.trim() === label) {
            const el = walker.currentNode.parentElement;
            if (el && el.getBoundingClientRect().height > 0) { el.click(); return true; }
          }
        }
        return false;
      }, ref.label);
      clicked = fallback;
    } else {
      if (popupPick.items?.length > 0) {
        console.log(`    ⚠️ 弹窗选项: [${popupPick.items.join(', ')}] 无匹配 "${ref.label}"`);
      }
      clicked = false;
    }
  }

  await page.evaluate((search) => {
    const eds = document.querySelectorAll('[contenteditable="true"]');
    let inputEd = null, maxY = -1;
    for (const ed of eds) {
      const r = ed.getBoundingClientRect();
      if (r.height > 0 && r.y > maxY) { maxY = r.y; inputEd = ed; }
    }
    if (!inputEd) return;
    const walker = document.createTreeWalker(inputEd, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      if (node.textContent.includes(search)) {
        node.textContent = node.textContent
          .replaceAll(`（${search}）`, '')
          .replaceAll(`(${search})`, '')
          .replaceAll(search, '');
      }
    }
  }, ref.search);

  return { ok: clicked };
}

/** 替换@引用 */
async function replaceAtRefs(page, atRefs) {
  const stats = { total: atRefs.length, success: 0, missing: 0, failed: 0 };
  for (const ref of atRefs) {
    const result = await insertSingleAtRef(page, ref);
    console.log(`    @${ref.label}: ${result.ok ? '✅' : '❌'}`);
    if (result.ok) stats.success++; else if (result.reason === 'placeholder_missing') stats.missing++; else stats.failed++;
    await sleep(500);
  }

  let mentionCount = await getMentionCount(page);
  if (mentionCount < atRefs.length) {
    console.log(`  ⚠️ mention数量不足 ${mentionCount}/${atRefs.length}，启动补插...`);
    for (const ref of atRefs) {
      if (mentionCount >= atRefs.length) break;
      const ed = await getInputEditor(page);
      if (!ed) break;
      await page.mouse.click(ed.x, ed.y);
      await sleep(200);
      const client = await page.context().newCDPSession(page);
      await client.send('Input.insertText', { text: ` ${ref.search}` });
      await client.detach();
      await sleep(250);
      const rescue = await insertSingleAtRef(page, ref);
      console.log(`    补插@${ref.label}: ${rescue.ok ? '✅' : '❌'}`);
      mentionCount = await getMentionCount(page);
      await sleep(300);
    }
  }

  stats.finalMentions = await getMentionCount(page);
  return stats;
}

/** 项目命名（新建项目后立即调用） */
async function renameProject(page, context, name) {
  if (!name) {
    console.log('\n═══ 项目命名 ═══');
    console.log('  ⚠️ 警告: 项目名称为空，将保持"未命名项目"');
    console.log('  💡 请在jimeng-config中设置 "project" 或 "name" 字段');
    return false;
  }
  console.log(`\n═══ 项目命名: ${name} ═══`);

  const collectTitleCandidates = async () => page.evaluate(() => {
    const visible = (el) => {
      const r = el.getBoundingClientRect();
      const cs = window.getComputedStyle(el);
      return r.width > 8 && r.height > 8 && cs.display !== 'none' && cs.visibility !== 'hidden';
    };
    const textOf = (el) => ('value' in el ? (el.value || '') : (el.textContent || '')).trim();
    const els = Array.from(document.querySelectorAll('input, textarea, [contenteditable="true"], [class*="title-"], [class*="top-bar-left"], [class*="header"] *'));
    return els
      .filter(visible)
      .map((el) => {
        const r = el.getBoundingClientRect();
        const cls = String(el.className || '');
        const text = textOf(el);
        const title = el.getAttribute('title') || '';
        const contenteditable = el.getAttribute('contenteditable') || '';
        let score = 0;
        if (/title-input/i.test(cls)) score += 80;
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') score += 50;
        if (contenteditable === 'true') score += 40;
        if (/title/i.test(cls)) score += 20;
        if (title) score += 10;
        if (r.y < 60) score += 15;
        if (r.x < 420) score += 15;
        if (text.includes('未命名项目') || title.includes('未命名项目')) score += 30;
        if (text.length > 0) score += 5;
        return {
          tag: el.tagName,
          cls,
          text,
          title,
          contenteditable,
          x: Math.round(r.x + r.width / 2),
          y: Math.round(r.y + r.height / 2),
          left: Math.round(r.x),
          top: Math.round(r.y),
          w: Math.round(r.width),
          h: Math.round(r.height),
          score
        };
      })
      .filter(item => item.top < 100 && item.left < 500)
      .sort((a, b) => b.score - a.score || a.top - b.top || a.left - b.left)
      .slice(0, 12);
  });

  const setTitleValue = async (expected) => page.evaluate((value) => {
    const visible = (el) => {
      const r = el.getBoundingClientRect();
      const cs = window.getComputedStyle(el);
      return r.width > 8 && r.height > 8 && cs.display !== 'none' && cs.visibility !== 'hidden';
    };
    const candidates = Array.from(document.querySelectorAll(
      'input[class*="title-input"], textarea[class*="title-input"], [class*="top-bar-left"] input, [class*="top-bar-left"] textarea, [class*="top-bar-left"] [contenteditable="true"], input, textarea, [contenteditable="true"]'
    )).filter(visible).filter((el) => {
      const r = el.getBoundingClientRect();
      return r.y < 90 && r.x < 500;
    });
    const target = candidates.sort((a, b) => {
      const ra = a.getBoundingClientRect();
      const rb = b.getBoundingClientRect();
      const sa = (/title-input/i.test(String(a.className || '')) ? 100 : 0) + (a.tagName === 'INPUT' ? 50 : 0) - ra.y * 0.2 + (500 - ra.x) * 0.02;
      const sb = (/title-input/i.test(String(b.className || '')) ? 100 : 0) + (b.tagName === 'INPUT' ? 50 : 0) - rb.y * 0.2 + (500 - rb.x) * 0.02;
      return sb - sa;
    })[0];
    if (!target) return { ok: false, reason: 'no-editable-target' };
    target.focus();
    if ('select' in target) target.select();
    if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
      target.value = value;
      target.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
      target.dispatchEvent(new Event('change', { bubbles: true }));
      target.blur?.();
      return { ok: true, mode: 'input', cls: String(target.className || '') };
    }
    target.textContent = value;
    target.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
    target.dispatchEvent(new Event('change', { bubbles: true }));
    target.blur?.();
    return { ok: true, mode: 'contenteditable', cls: String(target.className || '') };
  }, expected).catch(() => ({ ok: false, reason: 'exception' }));

  let focused = false;
  for (let attempt = 0; attempt < 8; attempt++) {
    const candidates = await collectTitleCandidates().catch(() => []);
    if (attempt === 0 && candidates.length) {
      console.log(`  标题候选: ${JSON.stringify(candidates.slice(0, 3))}`);
    }
    const directSet = await setTitleValue(name);
    if (directSet?.ok) {
      focused = true;
      break;
    }
    const best = candidates[0];
    if (best) {
      await page.mouse.click(best.x, best.y).catch(() => {});
      await sleep(200);
      await page.mouse.click(best.x, best.y).catch(() => {});
      await sleep(250);
      const activated = await setTitleValue(name);
      if (activated?.ok) {
        focused = true;
        break;
      }
    }
    await sleep(700);
  }

  if (!focused) {
    const candidates = await collectTitleCandidates().catch(() => []);
    console.log(`  ⚠️ 未找到标题输入区/未命名项目标题，候选=${JSON.stringify(candidates.slice(0, 5))}`);
    return false;
  }

  const renamedByDom = await setTitleValue(name);

  if (!renamedByDom?.ok) {
    await page.keyboard.press('Meta+a').catch(() => {});
    await sleep(120);
    const client = await context.newCDPSession(page);
    await client.send('Input.insertText', { text: name });
    await sleep(300);
    await page.keyboard.press('Enter').catch(() => {});
    await sleep(300);
    await client.detach();
  }

  await page.keyboard.press('Enter').catch(() => {});
  await sleep(800);

  const renamed = await page.evaluate((expected) => {
    const candidates = Array.from(document.querySelectorAll('input, textarea, [contenteditable="true"], [class*="title-"], [class*="container-"]'));
    return candidates.some(el => {
      const r = el.getBoundingClientRect();
      if (!(r.y < 100 && r.x < 500)) return false;
      const text = ('value' in el ? (el.value || '') : (el.textContent || '')).trim();
      const title = (el.getAttribute?.('title') || '').trim();
      return text === expected || title === expected;
    });
  }, name);
  console.log(`  ${renamed ? '✅' : '⚠️'} 项目命名结果: ${renamed ? name : '未验证到新名称'}`);
  return renamed;
}

/** 点击提交按钮 */
async function clickSubmit(page) {
  const result = await page.evaluate(() => {
    const visible = (el) => {
      const r = el.getBoundingClientRect();
      const cs = window.getComputedStyle(el);
      return r.width > 0
        && r.height > 0
        && cs.visibility !== 'hidden'
        && cs.display !== 'none'
        && cs.pointerEvents !== 'none';
    };

    const btns = Array.from(document.querySelectorAll('button, [role="button"]'))
      .filter(visible)
      .map(el => {
        const r = el.getBoundingClientRect();
        const text = (el.textContent || '').trim();
        const cls = String(el.className || '');
        const inComposer = r.y > window.innerHeight * 0.75 && r.x > window.innerWidth * 0.75;
        const isRound = Math.abs(r.width - r.height) <= 6;
        const looksPrimary = cls.includes('lv-btn-primary') || cls.includes('submit-button');
        const looksBlackSend = looksPrimary && isRound && r.width >= 20 && r.width <= 40;
        const looksSend = looksBlackSend || (cls.includes('submit-button') && text === '');
        const score = (inComposer ? 1000 : 0) + (looksBlackSend ? 500 : 0) + (looksPrimary ? 200 : 0) + r.x + r.y;
        return {
          x: Math.round(r.x + r.width / 2),
          y: Math.round(r.y + r.height / 2),
          w: Math.round(r.width),
          h: Math.round(r.height),
          left: Math.round(r.x),
          top: Math.round(r.y),
          text,
          cls,
          disabled: !!(el.disabled || cls.includes('disabled') || el.getAttribute('aria-disabled') === 'true'),
          score,
        };
      })
      .sort((a, b) => b.score - a.score);

    return {
      target: btns[0] || null,
      topCandidates: btns.slice(0, 8),
    };
  });

  if (!result.target) return { ok: false, error: 'not found', topCandidates: result.topCandidates || [] };

  await page.mouse.click(result.target.x, result.target.y);
  await sleep(500);
  return {
    ok: !result.target.disabled,
    forced: result.target.disabled,
    x: result.target.x,
    y: result.target.y,
    cls: result.target.cls,
    text: result.target.text,
    w: result.target.w,
    h: result.target.h,
    topCandidates: result.topCandidates,
  };
}

/** 提交后DOM快照（减少口头误差） */
async function postSubmitDomSnapshot(page, batchNum, model, screenshotDir) {
  await sleep(2500);
  const stat = await readSubmitEvidence(page);

  const shotName = `batch${batchNum}_${model.replace(/\s+/g, '_')}_dom_snapshot`;
  await ss(page, shotName, screenshotDir);
  console.log(`  📌 DOM快照: turns=${stat.visibleTurns}, 排队词频=${stat.queueCount}, 生成中词频=${stat.generatingCount}`);
  console.log(`  📸 ${shotName}`);
  return stat;
}

/** 读取指定身份控件当前选中值 */
async function readComboSelectedByKind(page, kind, roleMap) {
  const idx = roleMap[kind];
  if (idx === undefined) return null;
  await openComboAt(page, idx);
  await sleep(600);
  const selected = await page.evaluate(() => {
    for (const pop of document.querySelectorAll('[class*="lv-select-popup"]')) {
      if (pop.getBoundingClientRect().height > 0) {
        for (const opt of pop.querySelectorAll('li[role="option"]')) {
          if (opt.classList.contains('lv-select-option-wrapper-selected') || opt.getAttribute('aria-selected') === 'true') {
            return opt.textContent?.trim().slice(0, 80) || '';
          }
        }
      }
    }
    return null;
  });
  await page.evaluate(() => document.body.click());
  await sleep(300);
  return selected;
}

async function readComboSelectedRetry(page, kind, roleMap, retry = 2) {
  let val = null;
  for (let i = 0; i < retry; i++) {
    val = await readComboSelectedByKind(page, kind, roleMap);
    if (val && val !== 'undefined' && val !== 'null') return val;
    await sleep(500);
  }
  return val;
}

async function readVisibleToolbarText(page) {
  return page.evaluate(() => {
    const toolbars = Array.from(document.querySelectorAll('[class*="toolbar-settings-content"]'))
      .filter(tb => tb.getBoundingClientRect().height > 0);
    if (!toolbars.length) return '';
    const candidates = toolbars.filter(tb => {
      const text = (tb.textContent || '').replace(/\s+/g, '').trim();
      return text.length >= 5;
    });
    const toolbar = candidates.length
      ? candidates.reduce((a, b) => b.getBoundingClientRect().x > a.getBoundingClientRect().x ? b : a)
      : toolbars.slice(-1)[0];
    return (toolbar.textContent || '').trim();
  });
}

async function readToolbarSlotText(page, childIdx) {
  return page.evaluate((idx) => {
    const toolbars = Array.from(document.querySelectorAll('[class*="toolbar-settings-content"]'))
      .filter(tb => tb.getBoundingClientRect().height > 0);
    if (!toolbars.length) return null;
    const candidates = toolbars.filter(tb => {
      const text = (tb.textContent || '').replace(/\s+/g, '').trim();
      return text.length >= 5;
    });
    const toolbar = candidates.length
      ? candidates.reduce((a, b) => b.getBoundingClientRect().x > a.getBoundingClientRect().x ? b : a)
      : toolbars.slice(-1)[0];
    const child = toolbar.children[idx];
    if (!child) return null;
    return (child.textContent || '').trim() || null;
  }, childIdx);
}

async function reopenDialogPanel(page) {
  const alreadyStrict = await page.evaluate(() => {
    const toolbars = Array.from(document.querySelectorAll('[class*="toolbar-settings-content"]'))
      .filter(tb => tb.getBoundingClientRect().height > 0);
    const visibleEditors = Array.from(document.querySelectorAll('[contenteditable="true"]'))
      .filter(ed => ed.getBoundingClientRect().height > 0 && ed.getBoundingClientRect().width > 120);
    const hasToolbar = toolbars.some(tb => tb.children.length >= 6);
    const hasRightEditor = visibleEditors.some(ed => ed.getBoundingClientRect().x > 300);
    return hasToolbar && hasRightEditor;
  });
  if (alreadyStrict) {
    console.log('  ↺ strict 面板已在位，跳过重复点击「对话」');
    return false;
  }

  const clicked = await page.evaluate(() => {
    const candidates = Array.from(document.querySelectorAll('button, [role="button"], div, span'))
      .filter(el => el.getBoundingClientRect().height > 0)
      .map(el => {
        const r = el.getBoundingClientRect();
        return { el, text: (el.textContent || '').trim(), x: r.x, y: r.y, w: r.width, h: r.height };
      })
      .filter(x => x.text === '对话' && x.y < 140 && x.x > window.innerWidth * 0.7)
      .sort((a, b) => (b.x - a.x) || (a.y - b.y));
    if (!candidates.length) return false;
    candidates[0].el.click();
    return true;
  });
  if (clicked) {
    console.log('  ↺ 重新点右上角「对话」');
    await sleep(1200);
  }
  return clicked;
}

async function inspectStrictDialogPanel(page) {
  const roleMap = await detectComboboxRoles(page);
  const currentMode = await readComboSelectedRetry(page, 'createMode', roleMap, 2);
  const currentRefMode = await readComboSelectedRetry(page, 'refMode', roleMap, 2);
  const editor = await getRightDialogEditor(page);
  const toolbar = await getVisibleToolbar(page);
  const health = await page.evaluate(() => {
    const visibleEditors = Array.from(document.querySelectorAll('[contenteditable="true"]'))
      .filter(ed => ed.getBoundingClientRect().height > 0 && ed.getBoundingClientRect().width > 80)
      .map(ed => {
        const r = ed.getBoundingClientRect();
        return { x: r.x, y: r.y, w: r.width, h: r.height };
      });
    const visibleFileInputs = Array.from(document.querySelectorAll('input[type="file"]'))
      .filter(inp => inp.getBoundingClientRect().height > 0 || inp.offsetParent !== null).length;
    return {
      visibleEditors,
      visibleFileInputs,
      url: location.href,
      bodyText: (document.body?.textContent || '').slice(0, 1000),
    };
  });

  const hasVideoMode = (currentMode && currentMode.includes('视频生成')) || roleMap.refMode !== undefined;
  const hasAllPowerRef = !!(currentRefMode && currentRefMode.includes('全能参考'));
  const hasToolbar = !!(toolbar.exists && toolbar.childCount >= 4);
  const hasRightEditor = !!(editor && editor.w > 200 && editor.h > 20 && editor.x > 300);
  const hasPopoverToolbar = !!(currentRefMode && currentMode && hasRightEditor);
  const hasUpload = (health.visibleFileInputs || 0) > 0;
  const looksLikeBottomInputOnly = !!(editor && editor.y > 0 && editor.y < 220 && editor.x < 500);

  const structuralStrictOk = hasToolbar && hasRightEditor && !looksLikeBottomInputOnly;
  return {
    ok: (hasVideoMode && hasAllPowerRef && (hasToolbar || hasPopoverToolbar) && hasRightEditor && !looksLikeBottomInputOnly)
      || structuralStrictOk,
    hasVideoMode,
    hasAllPowerRef,
    hasToolbar,
    hasRightEditor,
    hasUpload,
    looksLikeBottomInputOnly,
    currentMode: currentMode || null,
    currentRefMode: currentRefMode || null,
    toolbarChildCount: toolbar.childCount || 0,
    editor,
    url: health.url,
  };
}

async function ensureStrictDialogPanel(page, contextLabel = 'unknown') {
  await reopenDialogPanel(page);
  await sleep(800);

  const healthy = await ensurePageHealthy(page, `${contextLabel}-dialog`);
  if (!healthy) {
    await reopenDialogPanel(page);
    await sleep(1500);
  }

  const panel = await inspectStrictDialogPanel(page);
  if (!panel.ok) {
    throw new Error(`未进入 strict 右侧对话面板（${contextLabel}）：videoMode=${panel.hasVideoMode}, refMode=${panel.currentRefMode || 'null'}, toolbar=${panel.hasToolbar}, rightEditor=${panel.hasRightEditor}, bottomInputOnly=${panel.looksLikeBottomInputOnly}`);
  }
  console.log(`  ✅ strict 对话面板已确认（${contextLabel}）`);
}

/** 读取提交后证据（排队/生成中） */
async function readSubmitEvidence(page) {
  return page.evaluate(() => {
    const text = document.body?.textContent || '';
    const turns = document.querySelectorAll('[class*="video-record-"][class*="video-generate-chat-turn"]');
    let visibleTurns = 0;
    for (const t of turns) {
      if (t.getBoundingClientRect().height > 0) visibleTurns++;
    }
    return {
      visibleTurns,
      queueCount: (text.match(/排队/g) || []).length,
      generatingCount: (text.match(/生成中/g) || []).length,
    };
  });
}

/** 等待并确认提交后出现“排队/生成中” */
async function waitSubmitEvidence(page, batchNum, model, screenshotDir) {
  const deadline = Date.now() + 45000;
  const intervalMs = 1500;
  let last = { visibleTurns: 0, queueCount: 0, generatingCount: 0 };

  while (Date.now() < deadline) {
    const stat = await readSubmitEvidence(page);
    last = stat;
    if (stat.queueCount > 0 || stat.generatingCount > 0) {
      console.log(`  ✅ 提交证据已确认: 排队=${stat.queueCount}, 生成中=${stat.generatingCount}, turns=${stat.visibleTurns}`);
      return { ok: true, stat };
    }
    await sleep(intervalMs);
  }

  await ss(page, `batch${batchNum}_${model.replace(/\\s+/g, '_')}_submit_no_signal`, screenshotDir);
  const reason = `未见排队/生成中。当前 queue=${last.queueCount}, generating=${last.generatingCount}`;
  console.log(`  ❌ ${reason}`);
  return { ok: false, reason, stat: last };
}

// 页面健康检查：避免白屏/空面板直接往下跑
async function ensurePageHealthy(page, tag = 'health') {
  const check = async () => page.evaluate(() => {
    const hasEditor = Array.from(document.querySelectorAll('[contenteditable="true"]')).some(ed => ed.getBoundingClientRect().height > 0);
    const hasToolbar = Array.from(document.querySelectorAll('[class*="toolbar-settings-content"]')).some(tb => tb.getBoundingClientRect().height > 0);
    const hasUpload = Array.from(document.querySelectorAll('input[type="file"]')).some(inp => inp.getBoundingClientRect().height > 0 || inp.offsetParent !== null);
    return { hasEditor, hasToolbar, hasUpload, url: location.href };
  });

  let state = await check();
  if (state.hasEditor && state.hasToolbar) return true;

  console.log(`  ⚠️ 页面健康检查失败(${tag})，尝试刷新恢复...`);
  await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  await sleep(3000);
  state = await check();
  if (state.hasEditor && state.hasToolbar) {
    console.log('  ✅ 页面恢复成功');
    return true;
  }

  console.log(`  ❌ 页面仍异常: editor=${state.hasEditor} toolbar=${state.hasToolbar} upload=${state.hasUpload}`);
  return false;
}

// ============ 🔴 提交前审核 ============
async function preSubmitAudit(page, batch, expectedRatio, expectedModel, runtimeHints = {}) {
  console.log('\n  🔍 === 提交前审核 ===');
  const issues = [];

  // 1. 参考图数量（只数 remove-button-container，不数内部 button）
  const refCount = await getRefCount(page);
  if (refCount === batch.refs.length) {
    console.log(`  ✅ 参考图: ${refCount}/${batch.refs.length} 张`);
  } else {
    const msg = `参考图数量不匹配: 页面${refCount} vs 期望${batch.refs.length}`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 2. 创作类型
  const roleMapMode = await detectComboboxRoles(page);
  let mode = await readComboSelectedRetry(page, 'createMode', roleMapMode, 2);
  if ((!mode || mode === 'null') && (await readVisibleToolbarText(page)).includes('视频生成')) {
    mode = '视频生成';
  }
  if (mode && mode.includes('视频生成')) {
    console.log(`  ✅ 模式: 视频生成`);
  } else {
    const msg = `模式不对: "${mode}" (期望"视频生成")`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 3. 模型 (combo[5])
  const roleMapModel = await detectComboboxRoles(page);
  const model = await readComboSelectedRetry(page, 'model', roleMapModel, 3);
  if (model && model.includes(expectedModel)) {
    console.log(`  ✅ 模型: ${expectedModel}`);
  } else {
    const msg = `模型不匹配: "${model?.slice(0, 40)}" vs 期望"${expectedModel}"`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 4. 参考模式 (combo[6])
  const roleMapRef = await detectComboboxRoles(page);
  const refMode = await readComboSelectedRetry(page, 'refMode', roleMapRef, 2);
  if (refMode && refMode.includes('全能参考')) {
    console.log(`  ✅ 参考: 全能参考`);
  } else {
    const msg = `参考模式不对: "${refMode}" (期望"全能参考")`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 5. 时长（优先信设置动作成功，其次再读UI）
  const durationStr = `${batch.duration}s`;
  let duration = null;
  if (runtimeHints.durationSetOk) {
    duration = durationStr;
  } else {
    const roleMapDuration = await detectComboboxRoles(page);
    duration = await readComboSelectedRetry(page, 'duration', roleMapDuration, 2);
    const toolbarDurationText = await readToolbarSlotText(page, 4);
    if ((!duration || duration === 'null') && toolbarDurationText && toolbarDurationText.includes(durationStr)) {
      duration = toolbarDurationText;
    }
  }
  if (duration && duration.includes(durationStr)) {
    console.log(`  ✅ 时长: ${durationStr}`);
  } else {
    const msg = `时长不匹配: "${duration}" vs 期望"${durationStr}"`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 6. 比例（优先信设置动作成功，其次再读UI）
  let ratioText = '';
  let ratioOk = false;
  if (runtimeHints.ratioSetOk) {
    ratioOk = true;
    ratioText = expectedRatio;
  } else {
    ratioText = await readVisibleToolbarText(page);
    ratioOk = ratioText.includes(expectedRatio);
  }
  if (ratioOk) {
    console.log(`  ✅ 比例: ${expectedRatio}`);
  } else {
    const msg = `比例不匹配: toolbar="${ratioText.slice(0, 80)}", 期望"${expectedRatio}"`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 7. 提示词内容（必须在右侧对话面板）
  const ed = await getRightDialogEditor(page);
  if (ed && ed.textLen > 0) {
    // 放宽审核：@引用替换后提示词会变，只要长度>100字符就算通过
    if (ed.textLen > 100) {
      console.log(`  ✅ 提示词: ${ed.textLen} 字符 (>100字符阈值) ✓`);
      if (batch.atRefs && batch.atRefs.length > 0) {
        const expectedMentions = batch.atRefs.length;
        if (ed.mentionCount >= expectedMentions) {
          console.log(`  ✅ @引用: ${ed.mentionCount}/${expectedMentions}`);
        } else {
          const msg = `右侧对话框@引用不足: ${ed.mentionCount}/${expectedMentions}`;
          console.log(`  ❌ ${msg}`);
          issues.push(msg);
        }
      }
    } else {
      const msg = `提示词太短: ${ed.textLen} 字符 (期望>100)`;
      console.log(`  ❌ ${msg}`);
      issues.push(msg);
    }
  } else {
    const msg = `提示词为空! (${ed?.textLen || 0} 字符)`;
    console.log(`  ❌ ${msg}`);
    issues.push(msg);
  }

  // 汇总
  if (issues.length === 0) {
    console.log('  ✅✅✅ 审核通过 ✅✅✅');
    return { pass: true, issues: [] };
  } else {
    console.log(`  ❌❌❌ 审核失败 (${issues.length}个问题) ❌❌❌`);
    return { pass: false, issues };
  }
}

// ============ 主流程 ============
async function main() {
  const cfg = parseArgs();
  mkdirSync(cfg.screenshotDir, { recursive: true });
  const submitState = loadSubmitState(cfg.submitStatePath, cfg);
  submitState.story_name = cfg.name || submitState.story_name || '';
  submitState.story_dir = cfg.storyDir || submitState.story_dir || null;

  console.log('╔══════════════════════════════════════════════╗');
  console.log('║   即梦视频生成自动化 - 翠花版 v2.2          ║');
  console.log('╚══════════════════════════════════════════════╝');
  console.log(`故事: ${cfg.name || '(未命名)'} | 比例: ${cfg.ratio} | 双模型: ${cfg.dualModel}`);
  console.log(`批次数: ${cfg.batches.length} | Dry run: ${cfg.dryRun} | Keep browser: ${cfg.keepBrowser}`);
  console.log(`状态文件: ${cfg.submitStatePath}`);
  console.log(`审计日志: ${cfg.submitAuditPath}`);
  console.log('');

  // 验证文件
  for (const batch of cfg.batches) {
    for (const f of batch.refs) {
      if (!existsSync(f)) { console.error(`❌ 文件不存在: ${f}`); process.exit(1); }
    }
  }

  // ═══════ Step 1: 连接浏览器 ═══════
  console.log('═══ Step 1: 连接浏览器 ═══');
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${cfg.cdpPort}`);
  const context = browser.contexts()[0];
  console.log(`  ✅ 已连接 CDP, ${context.pages().length} 个标签页`);

  // ═══════ Step 2: 打开/新建项目 ═══════
  console.log('\n═══ Step 2: 打开项目 ═══');
  let page;

  let created = false;
  if (cfg.projectId) {
    const url = `https://jimeng.jianying.com/ai-tool/canvas/${cfg.projectId}?type=video`;
    page = context.pages().find(p => p.url().includes(`/canvas/${cfg.projectId}`) && !p.url().includes('devtools'));
    if (page) {
      await page.bringToFront();
      await page.waitForLoadState('domcontentloaded', { timeout: 15000 }).catch(() => {});
      await sleep(2000);
      console.log(`  ✅ 复用已有项目页 ${cfg.projectId}`);
    } else {
      page = await context.newPage();
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await sleep(3000);
      console.log(`  ✅ 打开已有项目 ${cfg.projectId}`);
    }
  } else {
    for (const p of context.pages()) {
      if (p.url().includes('/canvas/') && !p.url().includes('devtools')) { await p.close(); }
    }
    await sleep(500);
    page = context.pages().find(p => p.url().includes('jimeng.jianying.com') && !p.url().includes('devtools'));
    if (!page) page = await context.newPage();
    await page.bringToFront();
    const assetsUrl = 'https://jimeng.jianying.com/ai-tool/assets-canvas?workspace=0';
    for (let createAttempt = 1; createAttempt <= 2 && !created; createAttempt++) {
      await page.goto(assetsUrl, {
        waitUntil: 'domcontentloaded', timeout: 60000
      });
      await page.waitForFunction(() => {
        const text = document.body?.innerText || '';
        return text.includes('最近项目') || text.includes('新建项目');
      }, { timeout: 15000 }).catch(() => {});
      await sleep(1500);

      const clicked = await page.evaluate(() => {
        const visible = (els) => Array.from(els).filter(el => el.getBoundingClientRect().height > 0);
        const directCard = visible(document.querySelectorAll('[class*="asset-item"]')).find(el => {
          const text = (el.textContent || '').trim();
          return text.includes('新建项目');
        });
        if (directCard) {
          const r = directCard.getBoundingClientRect();
          const x = Math.round(r.x + r.width / 2);
          const y = Math.round(r.y + r.height / 2);
          const target = document.elementFromPoint(x, y) || directCard;
          target.click();
          return true;
        }

        const titleCard = visible(document.querySelectorAll('[class*="title-"], [class*="info-"]')).find(el => {
          const text = (el.textContent || '').trim();
          return text === '新建项目';
        });
        if (titleCard) {
          const card = titleCard.closest('[class*="asset-item"]') || titleCard.parentElement;
          if (card) {
            const r = card.getBoundingClientRect();
            const x = Math.round(r.x + r.width / 2);
            const y = Math.round(r.y + r.height / 2);
            const target = document.elementFromPoint(x, y) || card;
            target.click();
            return true;
          }
        }

        const all = visible(document.querySelectorAll('button, [role="button"], div, span, a'));
        const candidates = all.map(el => {
          const r = el.getBoundingClientRect();
          const text = (el.textContent || '').trim();
          return { el, text, x: r.x, y: r.y, w: r.width, h: r.height, cls: String(el.className||'') };
        }).filter(x => x.text.includes('新建项目') && x.y > 250)
          .sort((a,b)=> (b.w*b.h - a.w*a.h) || (a.y-b.y) || (a.x-b.x));
        if (!candidates.length) return false;
        const c = candidates[0];
        const target = document.elementFromPoint(Math.round(c.x + c.w/2), Math.round(c.y + c.h/2)) || c.el;
        target.click();
        return true;
      });
      if (!clicked) {
        throw new Error('在 assets-canvas workspace=0 页未找到“最近项目”区域里的【新建项目】卡片');
      }

      let canvasPage = null;
      for (let retry = 0; retry < 12; retry++) {
        await sleep(1000);
        canvasPage = context.pages().find(p => /\/canvas\/\d+/.test(p.url()) && !p.url().includes('devtools'));
        if (canvasPage) break;
        if (/\/canvas\/\d+/.test(page.url())) { canvasPage = page; break; }
        if (page.url().includes('/ai-tool/canvas?type=video&workspace=0')) break;
      }
      if (canvasPage && canvasPage !== page) {
        page = canvasPage;
        await page.bringToFront();
        await page.waitForLoadState('domcontentloaded', { timeout: 15000 }).catch(() => {});
        await sleep(2000);
      }
      const match = page.url().match(/\/canvas\/(\d+)/);
      cfg.projectId = normalizeProjectId(match ? match[1] : null);
      if (cfg.projectId) {
        created = true;
        break;
      }
      console.log(`  ⚠️ 第${createAttempt}次创建后仍停在通用 /canvas?type=video&workspace=0，回到 assets 首页重建`);
    }
    if (!created || !cfg.projectId) {
      throw new Error('从 assets-canvas workspace=0 连续2次创建项目后，仍未拿到真实 /canvas/{id} project_id；停止自动化并报错');
    }
    console.log(`  ✅ 新项目: ${cfg.projectId}`);
  }

  cfg.projectId = normalizeProjectId(cfg.projectId);
  const nextProjectId = normalizeProjectId(cfg.projectId || submitState.project_id);
  const previousProjectId = normalizeProjectId(submitState.project_id);
  if (created || (nextProjectId && previousProjectId && nextProjectId !== previousProjectId)) {
    submitState.project_status = 'clean';
    submitState.submit_blocked = false;
    delete submitState.polluted_reason;
    submitState.batches = {};
  }
  submitState.project_id = nextProjectId;
  if (!submitState.project_id) {
    throw new Error('未拿到真实 project_id；禁止把 unknown/null 写入 submit_state 或继续 submit');
  }
  saveSubmitState(cfg.submitStatePath, submitState);
  appendAuditLog(cfg.submitAuditPath, {
    kind: 'project_opened',
    project_id: submitState.project_id,
    story_name: cfg.name || '',
    submit_blocked: !!submitState.submit_blocked,
    project_status: submitState.project_status || 'clean'
  });
  if (submitState.submit_blocked || submitState.project_status === 'polluted') {
    throw new Error(`项目 ${cfg.projectId} 已被标记为 polluted，禁止继续 submit: ${submitState.polluted_reason || 'unknown'}`);
  }

  // ═══════ 项目命名（新建后立即命名） ═══════
  let projectRenamed = await renameProject(page, context, cfg.name);

  // ═══════ Step 3: 初始化 ═══════
  console.log('\n═══ Step 3: 初始化 ═══');
  for (const text of ['跳过', '我知道了']) {
    const btn = page.locator(`text=${text}`).first();
    if (await btn.isVisible({ timeout: 1500 }).catch(() => false)) {
      await btn.click();
      await sleep(500);
    }
  }
  let dialogClicked = false;
  const dialogBtn = page.locator('button:has-text("对话")').first();
  if (await dialogBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    await dialogBtn.click();
    dialogClicked = true;
    console.log('  ✅ 对话面板');
    await sleep(2000);
  } else {
    const recovered = await page.evaluate(() => {
      const text = document.body?.textContent || '';
      const looksEmpty = text.includes('To pick up a draggable item') || document.querySelectorAll('[role="combobox"]').length === 0;
      const btns = Array.from(document.querySelectorAll('button,[role="button"],div,span')).filter(el => el.getBoundingClientRect().height > 0).map(el => {
        const r = el.getBoundingClientRect();
        return {el, text:(el.textContent||'').trim(), x:r.x, y:r.y, w:r.width, h:r.height, cls:String(el.className||'')};
      });
      const dialog = btns
        .filter(b => b.text === '对话' && b.y < 140 && b.x > window.innerWidth * 0.75)
        .sort((a,b)=> (b.x-a.x) || (a.y-b.y))[0];
      if (dialog) { dialog.el.click(); return 'clicked-top-right-black-dialog'; }
      if (looksEmpty) {
        location.reload();
        return 'reloaded-empty-canvas';
      }
      return 'no-dialog';
    }).catch(()=>'no-dialog');
    dialogClicked = recovered.startsWith('clicked-');
    console.log(`  ⚠️ 初始化未直接命中对话按钮，恢复动作: ${recovered}`);
    await sleep(3000);
  }

  // 🔴 先按当前页面可见文本直接切换创作类型（不再先依赖 combobox 语义）
  let modeOk = false;
  for (let attempt = 0; attempt < 4; attempt++) {
    const roleMap = await detectComboboxRoles(page);
    console.log(`  combobox roles: ${JSON.stringify(roleMap)}`);

    // 关键兜底：已有 strict 面板时通常已经处于“视频生成”，此时可能根本不存在 createMode 控件
    if (roleMap.refMode !== undefined && roleMap.createMode === undefined) {
      console.log('  ✅ 已检测到参考模式控件，直接判定当前处于 视频生成');
      modeOk = true;
      break;
    }

    // 优先：如果已经识别到创作类型控件，就按标准 combobox 流程切到“视频生成”
    if (roleMap.createMode !== undefined) {
      const switched = await openAndSelectByKind(page, 'createMode', '视频生成', roleMap);
      if (!switched && roleMap.refMode !== undefined) {
        console.log('  ⚠️ createMode 控件疑似误判，但参考模式控件已在位；按已处于 视频生成 继续');
        modeOk = true;
        break;
      }
      if (!switched) {
        await openComboAt(page, roleMap.createMode);
        await sleep(600);
        await page.evaluate(() => {
          const popups = Array.from(document.querySelectorAll('[class*="lv-select-popup"]'))
            .filter(p => p.getBoundingClientRect().height > 0);
          for (const pop of popups) {
            const opts = Array.from(pop.querySelectorAll('li[role="option"], div, span'));
            for (const opt of opts) {
              const text = (opt.textContent || '').trim();
              if (text === '视频生成') { opt.click(); return true; }
            }
          }
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            if (walker.currentNode.textContent?.trim() === '视频生成') {
              const el = walker.currentNode.parentElement;
              if (el && el.getBoundingClientRect().height > 0) { el.click(); return true; }
            }
          }
          return false;
        });
        await sleep(1200);
      }
    } else {
      // 兜底：还没识别到 createMode 时，优先在当前可见弹层里点“视频生成”
      await page.evaluate(() => {
        const popups = Array.from(document.querySelectorAll('[class*="lv-select-popup"]'))
          .filter(p => p.getBoundingClientRect().height > 0);
        for (const pop of popups) {
          const opts = Array.from(pop.querySelectorAll('li[role="option"], div, span'));
          for (const opt of opts) {
            const text = (opt.textContent || '').trim();
            if (text === '视频生成') { opt.click(); return true; }
          }
        }
        const btns = Array.from(document.querySelectorAll('button, [role="button"], div, span'));
        for (const el of btns) {
          const text = (el.textContent || '').trim();
          if (text === '视频生成' && el.getBoundingClientRect().height > 0) {
            el.click();
            return true;
          }
        }
        return false;
      });
      await sleep(1200);
    }

    const roleMapAfter = await detectComboboxRoles(page);
    console.log(`  combobox roles(after): ${JSON.stringify(roleMapAfter)}`);
    const currentMode = await readComboSelectedRetry(page, 'createMode', roleMapAfter, 2);
    console.log(`  当前创作类型: ${currentMode}`);
    const inferredVideoMode = roleMapAfter.refMode !== undefined;
    if (currentMode && currentMode.includes('视频生成')) {
      console.log('  ✅ 已确认切到 视频生成');
      modeOk = true;
      break;
    } else if (inferredVideoMode) {
      console.log('  ✅ 通过参考模式控件推断：当前已处于 视频生成');
      modeOk = true;
      break;
    }
    await reopenDialogPanel(page);
  }
  if (!modeOk) {
    throw new Error('创作类型切换失败：页面仍停留在 Agent 模式，未进入 视频生成');
  }

  // 进入视频生成后，再识别参考模式控件并切全能参考
  let refModeOk = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    const roleMap = await detectComboboxRoles(page);
    await openAndSelectByKind(page, 'refMode', '全能参考', roleMap);
    await sleep(1000);
    const currentRefMode = await readComboSelectedRetry(page, 'refMode', roleMap, 2);
    console.log(`  当前参考模式: ${currentRefMode}`);
    if (currentRefMode && currentRefMode.includes('全能参考')) {
      console.log('  ✅ 已确认切到 全能参考');
      refModeOk = true;
      break;
    }
  }
  if (!refModeOk) {
    throw new Error('参考模式切换失败：未进入 全能参考');
  }

  let healthyAfterInit = await ensurePageHealthy(page, 'init');
  if (!healthyAfterInit) {
    await ss(page, '00_init_unhealthy', cfg.screenshotDir);
    const recovery = await page.evaluate((projectId) => {
      const text = document.body?.textContent || '';
      const isHome = text.includes('今天想在无限画布创作什么') || text.includes('这次创作想从哪里开始');
      if (isHome && projectId && projectId !== 'unknown') {
        location.href = `https://jimeng.jianying.com/ai-tool/canvas/${projectId}?type=video`;
        return 'redirect-project';
      }
      const dialogBtn = Array.from(document.querySelectorAll('button')).find(b => (b.textContent || '').includes('对话'));
      if (dialogBtn) {
        dialogBtn.click();
        return 'clicked-dialog';
      }
      return 'no-recovery';
    }, cfg.projectId);
    console.log(`  ⚠️ 初始化异常，尝试恢复: ${recovery}`);
    await sleep(3000);
    healthyAfterInit = await ensurePageHealthy(page, 'init-retry');
    if (!healthyAfterInit) {
      await ss(page, '00_init_unhealthy_retry', cfg.screenshotDir);
      throw new Error('页面初始化失败：缺少编辑器或上传区（已尝试项目页重定向/对话恢复）');
    }
  }

  await ss(page, '00_init', cfg.screenshotDir);

  // 部分新画布初始态会晚于 project_opened 才挂出标题输入区；初始化完成后再兜底命名一次。
  if (!projectRenamed && cfg.name) {
    console.log('\n═══ 项目命名补偿重试 ═══');
    projectRenamed = await renameProject(page, context, cfg.name);
  }

  // ═══════ 逐批次提交 ═══════
  let totalSubmits = 0;
  let failedAudits = 0;
  let failedSubmits = 0;
  let failedBatches = 0;
  let storyAbortReason = null;

  function abortStory(reason, extra = {}) {
    if (!reason) return;
    if (!storyAbortReason) {
      storyAbortReason = reason;
    }
    markProjectPolluted(submitState, reason);
    saveSubmitState(cfg.submitStatePath, submitState);
    appendAuditLog(cfg.submitAuditPath, {
      kind: 'story_aborted',
      project_id: cfg.projectId,
      reason,
      ...extra,
    });
  }

  for (let bi = 0; bi < cfg.batches.length; bi++) {
    const batch = cfg.batches[bi];
    const batchNum = bi + 1;
    const models = cfg.dualModel ? ['Seedance 2.0', 'Seedance 2.0 Fast'] : [batch.model || 'Seedance 2.0'];

    console.log(`\n${'═'.repeat(50)}`);
    console.log(`  批次 ${batchNum}/${cfg.batches.length} | ${batch.duration}s | 参考图 ${batch.refs.length} 张`);
    console.log(`  模型: ${models.join(' + ')}`);
    console.log(`${'═'.repeat(50)}`);

    try {
      console.log(`\n  --- 重新进入 strict 对话面板 (batch${batchNum}) ---`);
      await ensureStrictDialogPanel(page, `batch${batchNum}-start`);

      // --- 批次2+: 清空上一批次 ---
      if (bi > 0) {
        console.log('\n  --- 清空上一批次 ---');
        await page.evaluate(() => { document.body.style.zoom = '0.7'; });
        await sleep(800);
        const clr = await clearRefs(page);
        await clearPrompt(page);
        await page.evaluate(() => { document.body.style.zoom = '1'; });
        await sleep(500);

        // 硬闸：未清空不允许进入下一批次
        if (clr.after > 0) {
          throw new Error(`上一批次参考图未清空（剩余${clr.after}张），停止当前批次以避免跨批次污染`);
        }
      }

      const healthyBeforeBatch = await ensurePageHealthy(page, `batch${batchNum}-start`);
      if (!healthyBeforeBatch) {
        await ss(page, `batch${batchNum}_unhealthy`, cfg.screenshotDir);
        throw new Error(`批次${batchNum}页面异常，终止当前批次`);
      }

      // --- 上传参考图（zoom=1状态） ---
      console.log(`\n  --- 上传参考图 ---`);
      await uploadRefs(page, batch.refs);
      await sleep(2000);

      // --- zoom=0.7 设比例+时长+提示词+@引用 ---
      await page.evaluate(() => { document.body.style.zoom = '0.7'; });
      await sleep(800);

      console.log(`\n  --- 设置比例 ${cfg.ratio} ---`);
      await setRatio(page, cfg.ratio);

      console.log(`\n  --- 设置时长 ${batch.duration}s ---`);
      const durationSet = await setDuration(page, batch.duration);
      if (!durationSet) {
        await page.evaluate((target) => {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            if (walker.currentNode.textContent?.trim() === target) {
              const el = walker.currentNode.parentElement;
              if (el && el.getBoundingClientRect().height > 0) { el.click(); return; }
            }
          }
        }, `${batch.duration}s`);
        await sleep(800);
      }

      console.log(`\n  --- 输入提示词 ---`);
      let promptToInsert = batch.prompt;
      const atRefsBySearchLen = [...batch.atRefs].sort((a, b) => (b.search?.length || 0) - (a.search?.length || 0));
      for (const ref of atRefsBySearchLen) {
        const placeholder = `##REF_${ref.label}##`;
        const search = ref.search || '';
        // @name → 占位符 + 名字（不加括号）
        // 例: @Rumi → ##REF_图片1## Rumi，即梦里显示为 [图片1] Rumi
        const name = search.startsWith('@') ? search.slice(1).trim() : '';
        const replacement = name ? `${placeholder} ${name}` : placeholder;
        promptToInsert = promptToInsert.replaceAll(search, replacement);
      }
      await inputPrompt(page, context, promptToInsert);

      if (batch.atRefs.length > 0) {
        console.log(`\n  --- @引用 (${batch.atRefs.length}个) ---`);
        const atRefsWithPlaceholder = batch.atRefs.map(ref => ({
          ...ref,
          search: `##REF_${ref.label}##`,
        }));
        atRefsWithPlaceholder.sort((a, b) => {
          const idxA = promptToInsert.indexOf(a.search);
          const idxB = promptToInsert.indexOf(b.search);
          return (idxA === -1 ? Infinity : idxA) - (idxB === -1 ? Infinity : idxB);
        });
        console.log(`  处理顺序: ${atRefsWithPlaceholder.map(r => r.label).join(' → ')}`);
        const refStats = await replaceAtRefs(page, atRefsWithPlaceholder);
        const effectiveSuccess = Math.max(refStats.success || 0, refStats.finalMentions || 0);
        console.log(`  @引用结果: 成功${effectiveSuccess}/${refStats.total}, 未找到${refStats.missing}, 失败${refStats.failed}, mention=${refStats.finalMentions || 0}`);

        if (effectiveSuccess < refStats.total) {
          throw new Error(`@引用硬闸触发：成功${effectiveSuccess}/${refStats.total}，停止当前批次`);
        }

        const mentionCount = await page.evaluate(() => {
          const eds = document.querySelectorAll('[contenteditable="true"]');
          let inputEd = null, maxY = -1;
          for (const ed of eds) {
            const r = ed.getBoundingClientRect();
            if (r.height > 0 && r.y > maxY) { maxY = r.y; inputEd = ed; }
          }
          if (!inputEd) return 0;
          return inputEd.querySelectorAll('[class*="mention"]').length;
        });
        if (mentionCount < 1) {
          throw new Error('@引用硬闸触发：mention标签数量为0，停止当前批次');
        }
        console.log(`  ✅ mention标签数量: ${mentionCount}`);
      }

      await ss(page, `batch${batchNum}_ready`, cfg.screenshotDir);

      for (let mi = 0; mi < models.length; mi++) {
        const model = models[mi];
        const fingerprint = buildSubmissionFingerprint(batch, model, cfg.ratio);
        let batchKey = getBatchStateKey(batchNum);

        console.log(`\n  --- 模型: ${model} ---`);
        try {
          const gate = assertSubmissionAllowed(submitState, batchNum, model, fingerprint, cfg.forceResubmit);
          batchKey = gate.batchKey;
        } catch (gateErr) {
          console.log(`  🚫 ${gateErr.message}`);
          appendAuditLog(cfg.submitAuditPath, {
            kind: 'idempotency_block',
            project_id: cfg.projectId,
            batch: batchKey,
            model,
            reason: gateErr.message,
          });
          continue;
        }

        const modelState = ensureBatchModelState(submitState, batchKey, model);
        Object.assign(modelState, fingerprint, {
          status: cfg.dryRun ? 'dry_run_ready' : 'preparing',
          last_attempt_at: new Date().toISOString(),
        });
        saveSubmitState(cfg.submitStatePath, submitState);
        appendAuditLog(cfg.submitAuditPath, {
          kind: 'model_prepare',
          project_id: cfg.projectId,
          batch: batchKey,
          model,
          ratio: cfg.ratio,
          duration: batch.duration,
        });

        const roleMapModelPick = await detectComboboxRoles(page);
        await openAndSelectByKind(page, 'model', model, roleMapModelPick);
        await sleep(500);

        console.log(`  --- 复位比例 ${cfg.ratio} 与时长 ${batch.duration}s (${model}) ---`);
        const ratioSetPerModel = await setRatio(page, cfg.ratio);
        const durationSetPerModel = await setDuration(page, batch.duration);
        if (!durationSetPerModel) {
          const roleMapPerModel = await detectComboboxRoles(page);
          await openAndSelectByKind(page, 'duration', `${batch.duration}s`, roleMapPerModel);
        }
        await sleep(500);

        await ensureStrictDialogPanel(page, `${batchKey}-${model}-before-audit`);
        const audit = await preSubmitAudit(page, batch, cfg.ratio, model, {
          ratioSetOk: !!ratioSetPerModel,
          durationSetOk: !!durationSetPerModel,
        });
        await ss(page, `batch${batchNum}_audit_${model.replace(/\s+/g, '_')}`, cfg.screenshotDir);

        if (!audit.pass) {
          console.log(`  🚫 审核未通过，跳过提交 (${model})`);
          console.log(`  问题: ${audit.issues.join('; ')}`);
          failedAudits++;
          modelState.status = 'audit_failed';
          modelState.audit_issues = audit.issues;
          saveSubmitState(cfg.submitStatePath, submitState);
          appendAuditLog(cfg.submitAuditPath, {
            kind: 'audit_failed',
            project_id: cfg.projectId,
            batch: batchKey,
            model,
            issues: audit.issues,
          });
          abortStory(`batch${batchNum} ${model} 审核失败: ${audit.issues.join('; ')}`, {
            batch: batchKey,
            model,
            issues: audit.issues,
          });
          break;
        }

        if (cfg.dryRun) {
          modelState.status = 'dry_run_ready';
          saveSubmitState(cfg.submitStatePath, submitState);
          appendAuditLog(cfg.submitAuditPath, {
            kind: 'dry_run_ready',
            project_id: cfg.projectId,
            batch: batchKey,
            model,
          });
          console.log(`  🏁 DRY RUN — 跳过提交 (${model})`);
        } else {
          modelState.status = 'submitting';
          saveSubmitState(cfg.submitStatePath, submitState);
          appendAuditLog(cfg.submitAuditPath, {
            kind: 'submit_click_start',
            project_id: cfg.projectId,
            batch: batchKey,
            model,
          });

          const result = await clickSubmit(page);
          if (result.topCandidates?.length) {
            console.log(`  提交按钮候选: ${JSON.stringify(result.topCandidates.slice(0, 5))}`);
          }
          if (result.ok || result.forced) {
            const evidence = await waitSubmitEvidence(page, batchNum, model, cfg.screenshotDir);
            await postSubmitDomSnapshot(page, batchNum, model, cfg.screenshotDir);
            if (evidence.ok) {
              totalSubmits++;
              modelState.status = evidence.stat.generatingCount > 0 ? 'running' : 'queued';
              modelState.submitted_at = new Date().toISOString();
              modelState.last_submit_evidence = evidence.stat;
              saveSubmitState(cfg.submitStatePath, submitState);
              appendAuditLog(cfg.submitAuditPath, {
                kind: 'submit_confirmed',
                project_id: cfg.projectId,
                batch: batchKey,
                model,
                evidence: evidence.stat,
              });
              console.log(`  ✅ 已确认提交 (${model})`);
            } else {
              failedSubmits++;
              modelState.status = 'submit_blocked';
              modelState.last_error = evidence.reason;
              saveSubmitState(cfg.submitStatePath, submitState);
              appendAuditLog(cfg.submitAuditPath, {
                kind: 'submit_blocked',
                project_id: cfg.projectId,
                batch: batchKey,
                model,
                reason: evidence.reason,
                evidence: evidence.stat,
              });
              console.log(`  🚫 提交阻塞 (${model}): ${evidence.reason}`);
              abortStory(`batch${batchNum} ${model} 提交阻塞: ${evidence.reason}`, {
                batch: batchKey,
                model,
                reason: evidence.reason,
              });
              break;
            }
          } else {
            failedSubmits++;
            modelState.status = 'submit_failed';
            modelState.last_error = '未点到提交按钮';
            saveSubmitState(cfg.submitStatePath, submitState);
            appendAuditLog(cfg.submitAuditPath, {
              kind: 'submit_failed',
              project_id: cfg.projectId,
              batch: batchKey,
              model,
              reason: '未点到提交按钮',
            });
            console.log(`  ❌ 未点到提交按钮 (${model})`);
            abortStory(`batch${batchNum} ${model} 提交失败: 未点到提交按钮`, {
              batch: batchKey,
              model,
              reason: '未点到提交按钮',
            });
            break;
          }
        }
        await ss(page, `batch${batchNum}_${model.replace(/\s+/g, '_')}_submitted`, cfg.screenshotDir);
        if (storyAbortReason) {
          console.log(`  ⛔ 故事停止：${storyAbortReason}`);
          break;
        }
      }
    } catch (batchErr) {
      failedBatches++;
      console.log(`  ❌ 批次${batchNum}失败：${batchErr.message}`);
      abortStory(`batch${batchNum} 失败: ${batchErr.message}`, {
        batch: getBatchStateKey(batchNum),
      });
      await ss(page, `batch${batchNum}_fatal`, cfg.screenshotDir);
    } finally {
      await page.evaluate(() => { document.body.style.zoom = '1'; });
      await sleep(500);
    }
    if (storyAbortReason) {
      console.log(`⛔ 因错误停止后续批次：${storyAbortReason}`);
      break;
    }
  }

  // ═══════ Content Policy 检测 + 自动重试 ═══════
  // 提交后等 60 秒检测是否被内容审核拦截，拦截的允许重试 1 次
  if (totalSubmits > 0) {
    console.log('\n═══ Content Policy 检测 (等 60s) ═══');
    await sleep(60000);

    const policyFails = await page.evaluate(() => {
      const fails = [];
      const turns = document.querySelectorAll('[class*="video-record-"][class*="video-generate-chat-turn"]');
      Array.from(turns).forEach((turn, i) => {
        const errorTip = turn.querySelector('[class*="error-tips"], [class*="error_tip"]');
        const text = turn.textContent || '';
        if (errorTip || text.includes('不符合平台规则') || text.includes('违规')) {
          const reason = errorTip?.textContent?.trim()?.replace(/反馈$/, '')?.replace(/再次生成$/, '')?.trim() || '内容审核拦截';
          // 检查是否有"再次生成"按钮
          const retryBtn = turn.querySelector('[class*="error-tips"] span, [class*="retry"]');
          fails.push({ turnIndex: i, reason, hasRetryBtn: !!retryBtn });
        }
      });
      return fails;
    });

    if (policyFails.length > 0) {
      console.log(`  ⚠️ 检测到 ${policyFails.length} 个内容审核拦截:`);
      for (const f of policyFails) {
        console.log(`    turn ${f.turnIndex + 1}: ${f.reason}`);
      }

      // 尝试重试（点击"再次生成"按钮）— 只重试 1 次
      const retried = await page.evaluate(() => {
        let count = 0;
        const turns = document.querySelectorAll('[class*="video-record-"][class*="video-generate-chat-turn"]');
        for (const turn of turns) {
          const errorTip = turn.querySelector('[class*="error-tips"], [class*="error_tip"]');
          if (!errorTip) continue;
          // 找"再次生成"按钮
          const btns = errorTip.querySelectorAll('span, button, a, div');
          for (const btn of btns) {
            if (btn.textContent?.trim() === '再次生成' && btn.getBoundingClientRect().height > 0) {
              btn.click();
              count++;
              break;
            }
          }
        }
        return count;
      });

      if (retried > 0) {
        console.log(`  🔄 已点击 ${retried} 个"再次生成"按钮（自动重试 1 次）`);
        appendAuditLog(cfg.submitAuditPath, {
          kind: 'content_policy_retry',
          project_id: cfg.projectId,
          retried_count: retried,
          reasons: policyFails.map(f => f.reason),
        });
      } else {
        console.log(`  ❌ 未找到"再次生成"按钮，无法自动重试`);
      }
    } else {
      console.log('  ✅ 未检测到内容审核拦截');
    }
  }

  // ═══════ 完成 ═══════
  await ss(page, 'final', cfg.screenshotDir);

  const expectedSubmits = cfg.dualModel ? cfg.batches.length * 2 : cfg.batches.length;
  const allOk = failedAudits === 0 && failedSubmits === 0 && !storyAbortReason;
  console.log('\n╔══════════════════════════════════════════════╗');
  console.log(`║  ${allOk ? '🎉' : '⚠️'} 完成！项目ID: ${cfg.projectId}`);
  console.log(`║  故事: ${cfg.name || '(未命名)'}`);
  console.log(`║  批次: ${cfg.batches.length} | 提交: ${totalSubmits}/${expectedSubmits}`);
  if (failedBatches > 0) {
    console.log(`║  ❌ 批次级失败: ${failedBatches} 次`);
  }
  if (failedAudits > 0) {
    console.log(`║  ❌ 审核失败: ${failedAudits} 次`);
  }
  if (failedSubmits > 0) {
    console.log(`║  ❌ 提交失败(未见排队/生成中): ${failedSubmits} 次`);
  }
  if (storyAbortReason) {
    console.log(`║  ⛔ 故事已终止: ${storyAbortReason.slice(0, 80)}`);
  }
  console.log(`║  截图: ${cfg.screenshotDir}/`);
  console.log('╚══════════════════════════════════════════════╝');

  if (cfg.keepBrowser) {
    console.log('ℹ️ 保持浏览器常驻（--keep-browser）');
    await browser.close(); // 仅断开会话
  } else {
    console.log('🧹 关闭CDP浏览器实例（默认）');
    try {
      const bsession = await browser.newBrowserCDPSession();
      await bsession.send('Browser.close');
      await sleep(800);
    } catch (e) {
      // 回退：至少断开CDP会话
      await browser.close();
    }
  }
  process.exit(failedAudits > 0 || failedSubmits > 0 || !!storyAbortReason ? 1 : 0);
}

main().catch(err => {
  console.error(`\n❌ 执行失败: ${err.message}`);
  console.error(err.stack);
  process.exit(1);
});
