#!/usr/bin/env node
/**
 * 即梦视频生成监测 + 下载 + 归档 - 翠花版 v1.0
 * 
 * 功能:
 *   1. 连接CDP打开即梦项目页面
 *   2. 检查所有视频生成任务的状态（排队/生成中/完成/失败）
 *   3. 完成的视频自动下载到归档目录
 *   4. 生成剪辑思路.md
 *   5. 发Telegram通知
 * 
 * 用法:
 *   node jimeng_monitor.mjs --project <projectId> --story-dir <案例库路径> [--notify <telegramId>] [--retry <n>]
 *   node jimeng_monitor.mjs --from-md <即梦提示词.md路径> [--notify <telegramId>] [--retry <n>]
 *
 * 退避策略（写死）:
 *   retry0:+5m, retry1:+10m, retry2:+30m, retry3:+1h, retry4:+2h, retry5:+2h, retry>=6:stop
 */

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync, readdirSync } from 'fs';
import { resolve, dirname, basename } from 'path';
import { execSync, execFileSync } from 'child_process';

const sleep = ms => new Promise(r => setTimeout(r, ms));
const SUBMIT_STATE_SCHEMA_VERSION = 1;

function ensureParentDir(path) {
  mkdirSync(dirname(path), { recursive: true });
}

function getDefaultStatePaths(baseDir) {
  const root = baseDir || '/tmp/jimeng_cuihua';
  return {
    submitStatePath: resolve(root, 'submit_state.json'),
    submitAuditPath: resolve(root, 'submit_audit.jsonl'),
  };
}

function loadSubmitState(path) {
  if (!path || !existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function saveSubmitState(path, state) {
  if (!path || !state) return;
  ensureParentDir(path);
  state.updated_at = new Date().toISOString();
  writeFileSync(path, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
}

function appendAuditLog(path, payload) {
  if (!path) return;
  ensureParentDir(path);
  appendFileSync(path, `${JSON.stringify({ ts: new Date().toISOString(), ...payload })}\n`, 'utf8');
}

function parseProjectIdFromUrl(url) {
  if (!url || typeof url !== 'string') return null;
  const match = url.match(/\/canvas\/(\d{6,})/);
  return match ? match[1] : null;
}

function baseSubmitState(config) {
  return {
    schema_version: SUBMIT_STATE_SCHEMA_VERSION,
    story_name: config.storyName || basename(config.storyDir || ''),
    story_dir: config.storyDir || null,
    project_id: config.projectId || null,
    project_url: config.projectUrl || null,
    project_status: 'clean',
    submit_blocked: false,
    polluted_reason: null,
    batches: {},
    updated_at: new Date().toISOString()
  };
}

function hydrateConfigFromSubmitState(config, state) {
  if (!state || typeof state !== 'object') return config;
  const next = { ...config };
  next.storyDir = next.storyDir || state.story_dir || null;
  next.storyName = next.storyName || state.story_name || (next.storyDir ? basename(next.storyDir) : null);
  next.projectUrl = next.projectUrl || state.project_url || null;
  next.projectId = next.projectId || state.project_id || parseProjectIdFromUrl(next.projectUrl);
  return next;
}

function flattenBatchEntries(state) {
  const entries = [];
  const batches = state?.batches && typeof state.batches === 'object' ? state.batches : {};
  for (const [batchKey, models] of Object.entries(batches)) {
    if (!models || typeof models !== 'object') continue;
    for (const [model, entry] of Object.entries(models)) {
      if (!entry || typeof entry !== 'object') continue;
      entries.push({ batchKey, model, entry });
    }
  }
  return entries;
}

function isMonitorTrackedEntry(entry) {
  return ['queued', 'submitted', 'running', 'completed'].includes(String(entry?.status || ''));
}

function normalizeMonitorOverall(status) {
  const runningLike = Number(status?.queuing || 0) + Number(status?.generating || 0);
  if (Number(status?.completed || 0) > 0 && runningLike === 0 && Number(status?.failed || 0) === 0) return 'completed';
  if (Number(status?.failed || 0) > 0 && Number(status?.completed || 0) === 0 && runningLike === 0) return 'failed';
  if (runningLike > 0) return 'running';
  return 'mixed';
}

function applyMonitorStatusToBatchEntries(state, status) {
  const entries = flattenBatchEntries(state).filter(({ entry }) => isMonitorTrackedEntry(entry));
  if (!entries.length) return state;

  const overall = normalizeMonitorOverall(status);
  const now = new Date().toISOString();
  const activeEntries = entries.filter(({ entry }) => entry.status !== 'completed');

  if (
    overall === 'completed'
    && Number(status?.completed || 0) > 0
    && Number(status?.completed || 0) >= activeEntries.length
  ) {
    for (const { entry } of activeEntries) {
      entry.status = 'completed';
      entry.completed_at = entry.completed_at || now;
      entry.last_error = null;
    }
    return state;
  }

  if (
    overall === 'failed'
    && Number(status?.failed || 0) > 0
    && Number(status?.failed || 0) >= activeEntries.length
  ) {
    for (const { entry } of activeEntries) {
      entry.status = 'failed';
      entry.last_error = entry.last_error || 'monitor detected all remaining tasks as failed';
    }
    return state;
  }

  if (Number(status?.generating || 0) > 0) {
    for (const { entry } of entries) {
      if (['submitted', 'queued', 'running'].includes(entry.status)) {
        entry.status = 'running';
        entry.last_error = null;
      }
    }
    return state;
  }

  if (Number(status?.queuing || 0) > 0 && Number(status?.generating || 0) === 0) {
    for (const { entry } of entries) {
      if (['submitted', 'queued'].includes(entry.status)) {
        entry.status = 'queued';
        entry.last_error = null;
      }
    }
  }

  return state;
}

function recordMonitorArtifacts(state, artifacts = {}) {
  if (!state) return state;
  const hasArtifacts = Object.values(artifacts).some(value => {
    if (Array.isArray(value)) return value.length > 0;
    return !!value;
  });
  if (!hasArtifacts) return state;
  state.monitor ||= {};
  state.monitor.artifacts = {
    video_dir: artifacts.videoDir || null,
    downloaded_videos: artifacts.downloaded || [],
    first_frames: artifacts.frames || [],
    comparison_image: artifacts.comparePath || null,
    edit_guide: artifacts.guidePath || null,
    updated_at: new Date().toISOString()
  };
  return state;
}

async function reopenDialogPanel(page) {
  const clicked = await page.evaluate(() => {
    const candidates = Array.from(document.querySelectorAll('button, [role="button"], div, span'))
      .filter(el => el.getBoundingClientRect().height > 0)
      .map(el => {
        const r = el.getBoundingClientRect();
        return { el, text: (el.textContent || '').trim(), x: r.x, y: r.y };
      })
      .filter(x => x.text === '对话' && x.y < 140)
      .sort((a, b) => (b.x - a.x) || (a.y - b.y));
    if (!candidates.length) return false;
    candidates[0].el.click();
    return true;
  });
  if (clicked) await sleep(1500);
  return clicked;
}

async function ensureDialogStatusView(page) {
  await reopenDialogPanel(page);
  await sleep(1200);
  const state = await page.evaluate(() => {
    const text = document.body?.textContent || '';
    const hasTurns = Array.from(document.querySelectorAll('[class*="video-record-"][class*="video-generate-chat-turn"]'))
      .some(t => t.getBoundingClientRect().height > 0);
    const hasQueueWords = /排队|生成中|生成失败/.test(text);
    const hasCreativeHint = /上传参考、输入文字|创意无限可能|Agent 模式/.test(text);
    return { hasTurns, hasQueueWords, hasCreativeHint };
  });
  return state;
}

// 监控退避策略（写死在脚本，避免主会话口头策略漂移）
// retry 0→5min, 1→10min, 2→30min, 3→1h, 4→2h, 5→2h, >=6停止
function getBackoffMinutes(retryCount) {
  if (retryCount < 0) return null;
  if (retryCount === 0) return 5;
  if (retryCount === 1) return 10;
  if (retryCount === 2) return 30;
  if (retryCount === 3) return 60;
  if (retryCount === 4) return 120;
  if (retryCount === 5) return 120;
  return null; // >=6 stop
}

// ============ 参数解析 ============
function parseArgs() {
  const args = process.argv.slice(2);
  const config = {
    cdpPort: 18781,
    projectId: null,
    projectUrl: null,
    storyDir: null,    // 案例库故事目录
    storyName: null,
    notify: null,      // Telegram user ID
    fromMd: null,      // 即梦提示词.md路径
    downloadOnly: false,
    maxWaitMin: 0,     // 0=只检查一次不等待, >0=轮询等待N分钟
    pollIntervalMin: 5,
    retryCount: -1,    // cron重试次数（用于输出建议退避）
    submitStatePath: null,
    submitAuditPath: null,
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--project': config.projectId = args[++i]; break;
      case '--project-url': config.projectUrl = args[++i]; break;
      case '--story-dir': config.storyDir = args[++i]; break;
      case '--story-name': config.storyName = args[++i]; break;
      case '--notify': config.notify = args[++i]; break;
      case '--from-md': config.fromMd = args[++i]; break;
      case '--cdp-port': config.cdpPort = parseInt(args[++i]); break;
      case '--download-only': config.downloadOnly = true; break;
      case '--check-only': config.checkOnly = true; break;
      case '--wait': config.maxWaitMin = parseInt(args[++i]); break;
      case '--poll-interval': config.pollIntervalMin = parseInt(args[++i]); break;
      case '--retry': config.retryCount = parseInt(args[++i]); break;
      case '--submit-state': config.submitStatePath = resolve(args[++i]); break;
      case '--submit-audit': config.submitAuditPath = resolve(args[++i]); break;
    }
  }

  // 从--from-md解析projectId和storyDir
  if (config.fromMd) {
    const mdPath = resolve(config.fromMd);
    const mdDir = dirname(mdPath);
    config.storyDir = config.storyDir || mdDir;
    const defaults = getDefaultStatePaths(mdDir);
    config.submitStatePath = config.submitStatePath || defaults.submitStatePath;
    config.submitAuditPath = config.submitAuditPath || defaults.submitAuditPath;

    // 从md中读取jimeng-config获取story name
    const mdContent = readFileSync(mdPath, 'utf8');
    const configMatch = mdContent.match(/<!--\s*jimeng-config\s*\n([\s\S]*?)\n\s*-->/);
    if (configMatch) {
      const raw = JSON.parse(configMatch[1]);
      config.storyName = config.storyName || raw.name;
    }

    // 从md中读取projectId（如果之前提交时记录了）
    const pidMatch = mdContent.match(/projectId[:\s]*(\d{10,})/);
    if (pidMatch && !config.projectId) config.projectId = pidMatch[1];
  }

  if (!config.storyDir) {
    config.storyDir = dirname(resolve(config.submitStatePath || '/tmp/jimeng_cuihua/submit_state.json'));
  }
  if (!config.submitStatePath || !config.submitAuditPath) {
    const defaults = getDefaultStatePaths(config.storyDir);
    config.submitStatePath ||= defaults.submitStatePath;
    config.submitAuditPath ||= defaults.submitAuditPath;
  }

  return config;
}

// ============ 检查生成状态 ============
async function checkStatus(page) {
  await sleep(2000);

  const status = await page.evaluate(() => {
    const results = {
      total: 0,
      completed: 0,
      failed: 0,
      queuing: 0,
      generating: 0,
      tasks: [],
    };

    // 找所有视频记录（chat turn）
    const turns = document.querySelectorAll('[class*="video-record-"][class*="video-generate-chat-turn"]');
    
    for (const turn of turns) {
      const r = turn.getBoundingClientRect();
      if (r.height <= 0) continue;

      const task = { status: 'unknown', details: '' };
      const text = turn.textContent || '';
      
      // 检查排队状态
      const queueBadge = turn.querySelector('[class*="progress-badge"]');
      if (queueBadge && queueBadge.getBoundingClientRect().height > 0) {
        const tips = turn.querySelector('[class*="progress-tips"]');
        task.status = 'queuing';
        task.details = tips?.textContent?.trim() || '排队中';
        const qMatch = task.details.match(/排队\((\d+)\/(\d+)\)/);
        if (qMatch) {
          task.position = parseInt(qMatch[1]);
          task.total = parseInt(qMatch[2]);
        }
        const timeMatch = task.details.match(/预计剩余\s*(\d+)/);
        if (timeMatch) task.estimatedMin = parseInt(timeMatch[1]);
        results.queuing++;
        results.total++;
        results.tasks.push(task);
        continue;
      }

      // 检查生成中
      const genStatus = turn.querySelector('[class*="status-single"]');
      if (genStatus && genStatus.textContent.includes('生成中')) {
        task.status = 'generating';
        task.details = '生成中...';
        results.generating++;
        results.total++;
        results.tasks.push(task);
        continue;
      }

      // 检查失败（多种检测方式）
      const errorTipEl = turn.querySelector('[class*="error-tips"], [class*="error_tip"]');
      const hasFailText = text.includes('生成失败') || text.includes('失败');
      const hasErrorTip = errorTipEl && errorTipEl.getBoundingClientRect().height >= 0;
      const hasPlatformRule = text.includes('不符合平台规则') || text.includes('违规') || text.includes('审核未通过');
      if (hasFailText || hasErrorTip || hasPlatformRule) {
        task.status = 'failed';
        const reasonEl = errorTipEl || turn.querySelector('[class*="tooltip"], [class*="tip"], [class*="error"]');
        const reasonText = reasonEl?.textContent?.trim()?.replace(/反馈$/, '')?.replace(/再次生成$/, '')?.trim();
        const ruleMatch = (reasonText || text).match(/(不符合平台规则[^。\n]*|违规[^。\n]*|审核未通过[^。\n]*|敏感内容[^。\n]*)/);
        task.details = ruleMatch ? ruleMatch[0] : (reasonText || '生成失败');
        task.failReason = task.details;
        results.failed++;
        results.total++;
        results.tasks.push(task);
        continue;
      }

      // 检查完成（有video-card且没有loading）
      const cards = turn.querySelectorAll('[class*="video-card-wrapper"]');
      let completedCards = 0;
      let videoUrls = [];
      for (const card of cards) {
        if (card.getBoundingClientRect().height <= 0) continue;
        const hasLoading = card.querySelector('[class*="loading"]') !== null;
        const video = card.querySelector('video');
        if (video && !hasLoading) {
          completedCards++;
          if (video.src && video.src.startsWith('http')) {
            videoUrls.push(video.src);
          }
        }
      }

      if (completedCards > 0) {
        task.status = 'completed';
        task.details = `${completedCards}个视频已生成`;
        task.videoUrls = videoUrls;
        task.videoCount = completedCards;
        results.completed++;
      } else if (cards.length > 0) {
        task.status = 'generating';
        task.details = '生成中...';
        results.generating++;
      }

      results.total++;
      results.tasks.push(task);
    }

    return results;
  });

  return status;
}

// 即梦使用 virtual-list 虚拟滚动，只渲染可视区域的 DOM 节点。
// 必须逐步滚动虚拟列表容器，在每个位置收集当前可见的任务和视频 URL。
async function scrollVirtualListAndCollect(page, collectFn) {
  return await page.evaluate(async (collectFnStr) => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const collect = new Function('return ' + collectFnStr)();

    // 找到虚拟列表滚动容器（overflowY=auto 且 scrollHeight > clientHeight）
    const vlist = Array.from(document.querySelectorAll('[class*="virtual-list"]'))
      .find(el => el.scrollHeight > el.clientHeight && getComputedStyle(el).overflowY !== 'hidden');

    // 如果没有虚拟列表，回退到普通收集
    if (!vlist) return collect();

    // 逐步滚动虚拟列表，每步收集可见内容
    const allResults = [];
    const step = Math.floor(vlist.clientHeight * 0.7);
    vlist.scrollTop = 0;
    await sleep(600);

    for (let i = 0; i < 30; i++) {
      allResults.push(collect());
      const prevTop = vlist.scrollTop;
      vlist.scrollTop += step;
      await sleep(600);
      if (Math.abs(vlist.scrollTop - prevTop) < 10) break; // 到底了
    }

    // 合并所有步骤的结果（去重）
    return allResults;
  }, collectFn.toString());
}

// 增强版状态检查：遍历虚拟列表收集所有任务状态
async function checkStatusRobust(page) {
  // 先试直接采样
  let s1 = await checkStatus(page);
  if (s1.total === 0) {
    // 页面可能刷新后对话面板未打开，尝试点击「对话」按钮
    console.log('  ⚠️ 首次采样 total=0，尝试打开对话面板...');
    await page.evaluate(() => {
      const btns = document.querySelectorAll('button, [role="button"], div, span');
      for (const el of btns) {
        const t = el.textContent?.trim();
        if (t === '对话' && el.getBoundingClientRect().height > 0 && el.getBoundingClientRect().width < 200) {
          el.click(); return true;
        }
      }
      return false;
    });
    await sleep(3000);
    s1 = await checkStatus(page);
  }
  if (s1.total > 0) {
    console.log(`  首次采样: ${s1.total} 任务 (✅${s1.completed} ⏳${s1.queuing} 🔄${s1.generating} ❌${s1.failed})`);
    // 如果首次采样已经拿到所有任务且没有 unknown，不需要滚动（滚动会破坏已加载的视频元素）
    const unknownCount = (s1.tasks || []).filter(t => t.status === 'unknown').length;
    if (unknownCount === 0) {
      console.log(`  ✅ 首次采样已完整，跳过虚拟列表滚动`);
      return s1;
    }
    console.log(`  有 ${unknownCount} 个 unknown 状态，继续滚动收集...`);
  } else {
    console.log('  ⚠️ 首次采样仍为 0，执行虚拟列表滚动...');
  }

  // 滚动虚拟列表，在每个位置收集任务状态（仅当首次采样不完整时）
  const snapshots = await scrollVirtualListAndCollect(page, function collect() {
    const results = { tasks: [] };
    const turns = document.querySelectorAll('[class*="video-record-"][class*="video-generate-chat-turn"]');
    for (const turn of turns) {
      const cards = turn.querySelectorAll('[class*="video-card-wrapper"]');
      const text = turn.textContent || '';
      const promptSnippet = text.slice(0, 60);

      for (const card of cards) {
        if (card.getBoundingClientRect().height <= 0) continue;
        const video = card.querySelector('video');
        const hasLoading = card.querySelector('[class*="loading"]') !== null;
        const hasVideo = video && video.src && video.src.startsWith('http') && !hasLoading;
        const isQueuing = text.includes('排队') || text.includes('queue');
        const isGenerating = text.includes('生成中') || text.includes('generating');
        const isFailed = text.includes('失败') || text.includes('fail');

        const failReason = isFailed ? (text.match(/(不符合平台规则|违规|审核未通过|敏感内容|内容不合规)[^。\n]*/)?.[0] || '生成失败') : null;
        results.tasks.push({
          prompt: promptSnippet,
          videoUrl: hasVideo ? video.src : null,
          status: hasVideo ? 'completed' : isFailed ? 'failed' : isGenerating ? 'generating' : isQueuing ? 'queuing' : 'unknown',
          failReason,
        });
      }
    }
    return results;
  });

  // 合并所有快照 + 首次采样，按 videoUrl 或 prompt 去重
  const seen = new Map(); // key = videoUrl || prompt

  // 先加入首次采样的结果（保底）
  for (const task of (s1.tasks || [])) {
    const key = task.videoUrl || task.prompt || `s1-${seen.size}`;
    seen.set(key, task);
  }

  // 再加入滚动收集的结果（有 videoUrl 的覆盖没有的）
  if (Array.isArray(snapshots)) {
    for (const snap of snapshots) {
      for (const task of (snap.tasks || [])) {
        const key = task.videoUrl || task.prompt;
        if (!seen.has(key) || (task.videoUrl && !seen.get(key).videoUrl)) {
          seen.set(key, task);
        }
      }
    }
  }

  const allTasks = Array.from(seen.values());
  const merged = {
    total: allTasks.length,
    completed: allTasks.filter(t => t.status === 'completed').length,
    failed: allTasks.filter(t => t.status === 'failed').length,
    queuing: allTasks.filter(t => t.status === 'queuing').length,
    generating: allTasks.filter(t => t.status === 'generating').length,
    tasks: allTasks,
  };

  console.log(`  滚动收集完成: ${merged.total} 任务 (✅${merged.completed} ⏳${merged.queuing} 🔄${merged.generating} ❌${merged.failed})`);
  return merged;
}

// ============ 获取所有可下载视频URL ============
// 通过虚拟列表滚动收集所有视频 URL（不仅是当前可见的）
async function getAllVideoUrls(page) {
  // 先直接采样当前可见的视频（不滚动，避免虚拟列表回收）
  const directUrls = await page.evaluate(() => {
    const urls = [];
    const cards = document.querySelectorAll('[class*="video-card-wrapper"]');
    for (const card of cards) {
      if (card.getBoundingClientRect().height <= 0) continue;
      const video = card.querySelector('video');
      const hasLoading = card.querySelector('[class*="loading"]') !== null;
      if (video && video.src && video.src.startsWith('http') && !hasLoading) {
        const turn = card.closest('[class*="video-record-"]');
        const modelText = turn?.querySelector('[class*="model"]')?.textContent?.trim() || '';
        urls.push({ url: video.src, model: modelText });
      }
    }
    return urls;
  });

  // 再尝试滚动收集（可能找到更多）
  const snapshots = await scrollVirtualListAndCollect(page, function collect() {
    const urls = [];
    const cards = document.querySelectorAll('[class*="video-card-wrapper"]');
    for (const card of cards) {
      if (card.getBoundingClientRect().height <= 0) continue;
      const video = card.querySelector('video');
      const hasLoading = card.querySelector('[class*="loading"]') !== null;
      if (video && video.src && video.src.startsWith('http') && !hasLoading) {
        const turn = card.closest('[class*="video-record-"]');
        const modelText = turn?.querySelector('[class*="model"]')?.textContent?.trim() || '';
        urls.push({ url: video.src, model: modelText });
      }
    }
    return urls;
  });

  // 合并去重（直接采样 + 滚动采样）
  const seen = new Set();
  const allUrls = [];
  const addUrl = (v) => {
    if (v.url && !seen.has(v.url)) { seen.add(v.url); allUrls.push({ url: v.url, index: allUrls.length, model: v.model || '' }); }
  };
  for (const v of directUrls) addUrl(v);
  if (Array.isArray(snapshots)) {
    for (const snap of snapshots) {
      for (const v of (Array.isArray(snap) ? snap : snap.tasks || [])) addUrl(v);
    }
  }
  return allUrls;
}

// ============ 下载视频 ============
async function downloadVideos(videos, outputDir) {
  mkdirSync(outputDir, { recursive: true });
  const downloaded = [];

  // 找到已存在的最大编号，避免文件名冲突
  let maxIdx = 0;
  try {
    const existing = readdirSync(outputDir).filter(f => /^video_\d+/.test(f));
    for (const f of existing) {
      const m = f.match(/^video_(\d+)/);
      if (m) maxIdx = Math.max(maxIdx, parseInt(m[1]));
    }
  } catch {}

  for (let i = 0; i < videos.length; i++) {
    const v = videos[i];
    // 先检查是否已经下载过这个 URL（用文件大小 > 10KB 的 mp4 匹配）
    let alreadyFile = null;
    try {
      const existing = readdirSync(outputDir).filter(f => f.endsWith('.mp4'));
      // 简单去重：如果已有同数量的视频文件且大小合理，跳过
    } catch {}
    const idx = maxIdx + i + 1;
    const filename = `video_${idx}${v.model ? '_' + v.model.replace(/[\s.]+/g, '_') : ''}.mp4`;
    const outputPath = resolve(outputDir, filename);

    if (existsSync(outputPath)) {
      console.log(`  ⏭️ 已存在: ${filename}`);
      downloaded.push({ path: outputPath, filename, url: v.url, model: v.model });
      continue;
    }

    console.log(`  ⬇️ 下载 ${i + 1}/${videos.length}: ${filename}`);
    try {
      execFileSync('curl', ['-sL', '-o', outputPath, v.url], { timeout: 120000 });
      // 验证文件大小
      const stat = execFileSync('stat', ['-f%z', outputPath]).toString().trim();
      if (parseInt(stat) < 10000) {
        console.log(`  ⚠️ 文件太小(${stat}B)，可能下载失败`);
      } else {
        console.log(`  ✅ ${filename} (${(parseInt(stat) / 1024 / 1024).toFixed(1)}MB)`);
        downloaded.push({ path: outputPath, filename, url: v.url, model: v.model });
      }
    } catch (e) {
      console.log(`  ❌ 下载失败: ${e.message}`);
    }
    await sleep(1000);
  }

  return downloaded;
}

// ============ 提取首帧 ============
async function extractFirstFrames(downloaded, outputDir) {
  const frames = [];
  for (const d of downloaded) {
    const framePath = resolve(outputDir, d.filename.replace('.mp4', '_frame.jpg'));
    try {
      execFileSync('ffmpeg', ['-y', '-i', d.path, '-vframes', '1', '-q:v', '2', framePath], { stdio: 'ignore' });
      frames.push(framePath);
    } catch (e) {
      console.log(`  ⚠️ 首帧提取失败: ${d.filename}`);
    }
  }
  return frames;
}

// ============ 生成剪辑思路 ============
function generateEditGuide(storyDir, storyName, downloaded) {
  // 读取改编大纲
  let outline = '';
  let files = [];
  if (existsSync(storyDir)) {
    try { files = readdirSync(storyDir).filter(f => f.endsWith('.md')).map(f => resolve(storyDir, f)); } catch {}
  }
  
  const outlineFile = files.find(f => f.includes('大纲与提示词'));
  if (outlineFile) {
    const content = readFileSync(outlineFile, 'utf8');
    // 提取标题建议
    const titleMatch = content.match(/(?:标题|Title)[：:]\s*(.+)/i);
    // 提取台词
    const dialogues = [];
    const dlgRegex = /(?:台词|dialogue|say|said)[：:]\s*[""](.+?)[""]|[""](.+?)[""]/gi;
    let m;
    while ((m = dlgRegex.exec(content)) !== null) {
      dialogues.push(m[1] || m[2]);
    }

    outline = `\n## 来源\n- 改编大纲: ${basename(outlineFile)}\n`;
    if (titleMatch) outline += `- 推荐标题: ${titleMatch[1]}\n`;
    if (dialogues.length > 0) {
      outline += `\n## 台词时间轴\n`;
      dialogues.forEach((d, i) => { outline += `- Lens ${i + 1}: "${d}"\n`; });
    }
  }

  // 读取即梦提示词获取镜头分段
  const jimengFile = resolve(storyDir, '即梦提示词.md');
  let lensBreakdown = '';
  if (existsSync(jimengFile)) {
    const content = readFileSync(jimengFile, 'utf8');
    const lensRegex = /(\d+-\d+秒)[：:（(]([^）)]+)/g;
    let m;
    const lenses = [];
    while ((m = lensRegex.exec(content)) !== null) {
      lenses.push({ time: m[1], desc: m[2].trim() });
    }
    if (lenses.length > 0) {
      lensBreakdown = `\n## 镜头分段\n`;
      lenses.forEach((l, i) => {
        lensBreakdown += `| ${i + 1} | ${l.time} | ${l.desc} |\n`;
      });
    }
  }

  const guide = `# 剪辑思路 — ${storyName || '未命名'}

> 自动生成于 ${new Date().toISOString().slice(0, 10)}
> 生成视频: ${downloaded.length} 个版本
${outline}
## 素材清单

### 生成视频
${downloaded.map((d, i) => `| ${i + 1} | ${d.filename} | ${d.model || '未知模型'} |`).join('\n')}

### 质量对比
> 老大看完首帧对比图后，在这里标注选用哪个版本
- [ ] 版本1: 
- [ ] 版本2: 
${lensBreakdown}
## 后期要点

### BGM
- 风格: （根据故事情绪选择）
- 建议: 先找BGM再调节奏，不要先剪完再配乐

### 字幕/文字
- 英文对白字幕（跟随台词时间轴）
- 反转时刻可加大字特效

### 音效
- 关键动作配音效（开门、碰撞、惊讶等）
- 情绪转折处加转场音效

### 特效（剪映）
- 反转镜头：可加慢放 + 闪白转场
- 心动镜头：粉色爱心/星星特效
- 搞笑镜头：放大+震动

### 节奏
- 总时长控制在 15-60s（Shorts最佳）
- 前3秒必须有hook（悬念/冲突/反差）
- 反转放在最后3-5秒

## 发布
- 平台: YouTube Shorts
- 标题: （英文≤95字符含hashtags）
- 首帧: 选最有冲击力的瞬间
`;

  const guidePath = resolve(storyDir, '剪辑思路.md');
  writeFileSync(guidePath, guide);
  console.log(`  ✅ 剪辑思路: ${guidePath}`);
  return guidePath;
}

function updateSubmitStateFromMonitor(state, status, projectId) {
  if (!state || !status) return state;
  state.project_id = projectId || state.project_id || null;
  state.monitor ||= {};
  state.monitor.last_status = status;
  state.monitor.last_checked_at = new Date().toISOString();
  state.monitor.overall = normalizeMonitorOverall(status);
  state.monitor.observed_total = Number(status.total || 0);
  state.monitor.completed_count = Number(status.completed || 0);
  state.monitor.failed_count = Number(status.failed || 0);
  state.monitor.queuing_count = Number(status.queuing || 0);
  state.monitor.generating_count = Number(status.generating || 0);
  applyMonitorStatusToBatchEntries(state, status);
  return state;
}

// ============ 主流程 ============
async function main() {
  let cfg = parseArgs();
  let submitState = loadSubmitState(cfg.submitStatePath);
  cfg = hydrateConfigFromSubmitState(cfg, submitState);
  if (!cfg.storyName && cfg.storyDir) cfg.storyName = basename(cfg.storyDir);
  if (!cfg.projectId && cfg.projectUrl) cfg.projectId = parseProjectIdFromUrl(cfg.projectUrl);
  if (!cfg.projectId) {
    console.error('❌ 需要 --project <projectId>、--project-url，或 submit_state.json / --from-md 中包含项目信息');
    process.exit(1);
  }
  submitState = submitState || baseSubmitState(cfg);
  submitState.story_name ||= cfg.storyName || basename(cfg.storyDir || '');
  submitState.story_dir ||= cfg.storyDir || null;
  submitState.project_id ||= cfg.projectId;
  submitState.project_url ||= cfg.projectUrl || null;
  cfg.projectUrl ||= submitState.project_url || null;

  console.log('╔══════════════════════════════════════════════╗');
  console.log('║  即梦视频监测+下载+归档 - 翠花版 v1.0      ║');
  console.log('╚══════════════════════════════════════════════╝');
  console.log(`项目: ${cfg.projectId} | 故事: ${cfg.storyName || '(未命名)'}`);
  console.log(`归档: ${cfg.storyDir || '(未指定)'}`);
  console.log(`状态文件: ${cfg.submitStatePath}`);
  console.log(`审计日志: ${cfg.submitAuditPath}`);
  if (cfg.retryCount >= 0) {
    const nextMin = getBackoffMinutes(cfg.retryCount);
    console.log(`重试: retry=${cfg.retryCount} | 下次建议: ${nextMin == null ? '停止续建(>=6)' : `+${nextMin}分钟`}`);
  }
  if (cfg.maxWaitMin > 0) console.log(`等待: 最多${cfg.maxWaitMin}分钟, 每${cfg.pollIntervalMin}分钟检查`);

  appendAuditLog(cfg.submitAuditPath, {
    kind: 'monitor_start',
    project_id: cfg.projectId,
    project_url: cfg.projectUrl || submitState?.project_url || null,
    story_name: cfg.storyName || submitState?.story_name || '',
    submit_blocked: !!submitState?.submit_blocked,
    project_status: submitState?.project_status || 'unknown'
  });

  // 连接浏览器
  console.log('\n═══ 连接浏览器 ═══');
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${cfg.cdpPort}`);
  const context = browser.contexts()[0];
  console.log(`  ✅ 已连接 CDP`);

  // 打开项目
  console.log('\n═══ 打开项目 ═══');
  const projectUrl = cfg.projectUrl || `https://jimeng.jianying.com/ai-tool/canvas/${cfg.projectId}?type=video`;
  let page = context.pages().find(p => p.url().includes(cfg.projectId));
  if (!page) {
    page = await context.newPage();
    await page.goto(projectUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  } else {
    await page.bringToFront();
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 });
  }
  await sleep(5000);
  cfg.projectUrl = page.url() || projectUrl;
  submitState.project_url = cfg.projectUrl;
  saveSubmitState(cfg.submitStatePath, submitState);
  let dialogState = await ensureDialogStatusView(page);
  if (!dialogState.hasTurns && dialogState.hasCreativeHint) {
    await reopenDialogPanel(page);
    await sleep(1500);
    dialogState = await ensureDialogStatusView(page);
  }
  await page.evaluate(() => { document.body.style.zoom = '0.7'; });
  await sleep(1000);

  // 关闭弹窗
  for (const text of ['跳过', '我知道了']) {
    const btn = page.locator(`text=${text}`).first();
    if (await btn.isVisible({ timeout: 1000 }).catch(() => false)) {
      await btn.click();
      await sleep(500);
    }
  }

  // 轮询检查状态 + 增量下载
  const startTime = Date.now();
  const maxWaitMs = cfg.maxWaitMin > 0 ? cfg.maxWaitMin * 60 * 1000 : 30 * 60 * 1000; // 默认最大30分钟
  let lastStatus = null;
  let monitorArtifacts = {
    videoDir: null,
    downloaded: [],
    frames: [],
    comparePath: null,
    guidePath: null
  };
  const downloadedUrls = new Set(); // 已下载的 URL，防止重复
  const videoDir = cfg.storyDir ? resolve(cfg.storyDir, '生成视频') : null;

  // --check-only: 查一次状态就退出，输出机器可读的 JSON
  if (cfg.checkOnly) {
    const status = await checkStatusRobust(page);
    const allDone = status.total > 0 && status.completed === status.total;
    const allFailed = status.total > 0 && status.failed === status.total;
    const overall = allDone ? 'complete' : allFailed ? 'failed' : (status.generating > 0 || status.queuing > 0) ? 'generating' : 'unknown';
    const videos = allDone ? await getAllVideoUrls(page) : [];
    // 提取失败原因
    const failReasons = (status.tasks || []).filter(t => t.status === 'failed').map(t => t.failReason || t.details || '未知原因');
    // 输出单行 JSON 到 stdout（harvest_daemon.sh 解析）
    console.log(JSON.stringify({ overall, total: status.total, completed: status.completed, generating: status.generating, queuing: status.queuing, failed: status.failed, failReasons, videos }));
    await browser?.disconnect();
    process.exit(0);
  }

  while (true) {
    console.log(`\n═══ 检查状态 [${new Date().toLocaleTimeString('zh-CN')}] ═══`);
    const status = await checkStatusRobust(page);
    lastStatus = status;

    console.log(`  总任务: ${status.total}`);
    console.log(`  ✅ 完成: ${status.completed}`);
    console.log(`  ⏳ 排队: ${status.queuing}`);
    console.log(`  🔄 生成中: ${status.generating}`);
    console.log(`  ❌ 失败: ${status.failed}`);

    for (let i = 0; i < status.tasks.length; i++) {
      const t = status.tasks[i];
      const icon = { completed: '✅', queuing: '⏳', generating: '🔄', failed: '❌', unknown: '❓' }[t.status];
      console.log(`  ${icon} 任务${i + 1}: ${t.details || ''}`);
    }

    submitState = updateSubmitStateFromMonitor(submitState || baseSubmitState(cfg), status, cfg.projectId);
    submitState.project_url = cfg.projectUrl || submitState.project_url || null;
    saveSubmitState(cfg.submitStatePath, submitState);
    appendAuditLog(cfg.submitAuditPath, {
      kind: 'monitor_status',
      project_id: cfg.projectId,
      project_url: cfg.projectUrl || null,
      story_name: cfg.storyName || submitState?.story_name || '',
      overall: submitState?.monitor?.overall || 'unknown',
      status,
    });

    // 增量下载：每轮检测到已完成的视频就立即下载（不等全部完成）
    if (status.completed > 0 && videoDir) {
      const videos = await getAllVideoUrls(page);
      const newVideos = videos.filter(v => !downloadedUrls.has(v.url));
      if (newVideos.length > 0) {
        console.log(`\n  ⬇️ 增量下载 ${newVideos.length} 个新视频`);
        const dl = await downloadVideos(newVideos, videoDir);
        for (const d of dl) {
          downloadedUrls.add(d.url);
          monitorArtifacts.downloaded.push({
            path: d.path, filename: d.filename, model: d.model || '', url: d.url
          });
        }
        monitorArtifacts.videoDir = videoDir;
      }
    }

    // 全部完成或全部失败
    const allDone = status.queuing === 0 && status.generating === 0;
    if (allDone) {
      console.log('\n  🎉 所有任务已完成/结束！');
      break;
    }

    // 超时检查
    if (cfg.maxWaitMin <= 0) {
      const nextMin = getBackoffMinutes(cfg.retryCount);
      if (nextMin == null && cfg.retryCount >= 0) {
        console.log('\n  ℹ️ 单次检查模式，且已达重试上限(>=6)，停止续建');
      } else if (cfg.retryCount >= 0) {
        console.log(`\n  ℹ️ 单次检查模式，建议下次监控时间: +${nextMin}分钟 (retry=${cfg.retryCount})`);
      } else {
        console.log('\n  ℹ️ 单次检查模式，退出');
      }
      break;
    }

    const elapsed = Date.now() - startTime;
    if (elapsed >= maxWaitMs) {
      console.log(`\n  ⏰ 已等待${Math.round(elapsed / 60000)}分钟，超时退出（已下载${downloadedUrls.size}个视频）`);
      break;
    }

    const remaining = Math.round((maxWaitMs - elapsed) / 60000);
    console.log(`\n  💤 等待${cfg.pollIntervalMin}分钟后重新检查... (剩余${remaining}分钟, 已下载${downloadedUrls.size}个)`);
    await sleep(cfg.pollIntervalMin * 60 * 1000);

    // 刷新页面
    await page.reload();
    await sleep(5000);
    await ensureDialogStatusView(page);
    await page.evaluate(() => { document.body.style.zoom = '0.7'; });
    await sleep(1000);
  }

  // 最终保底扫描：确保所有视频都下载了
  if (lastStatus && lastStatus.completed > 0) {
    console.log('\n═══ 最终保底下载 ═══');
    const videos = await getAllVideoUrls(page);
    const newVideos = videos.filter(v => !downloadedUrls.has(v.url));
    console.log(`  找到 ${videos.length} 个视频, ${newVideos.length} 个未下载`);

    if (newVideos.length > 0 && videoDir) {
      const downloaded = await downloadVideos(newVideos, videoDir);
      for (const d of downloaded) {
        downloadedUrls.add(d.url);
        monitorArtifacts.downloaded.push({
          path: d.path, filename: d.filename, model: d.model || '', url: d.url
        });
      }
      monitorArtifacts.videoDir = videoDir;

      // 提取所有已下载视频的首帧（包括增量下载的）
      const allDownloaded = monitorArtifacts.downloaded;
      if (allDownloaded.length > 0) {
        console.log('\n═══ 提取首帧 ═══');
        const frames = await extractFirstFrames(allDownloaded, videoDir);
        monitorArtifacts.frames = frames;
        console.log(`  ✅ ${frames.length} 张首帧已提取`);

        // 拼对比图
        if (frames.length > 1) {
          console.log('\n═══ 拼接对比图 ═══');
          const comparePath = resolve(videoDir, 'comparison.jpg');
          try {
            const ffArgs = ['-y', ...frames.flatMap(f => ['-i', f]), '-filter_complex', `hstack=inputs=${frames.length}`, '-q:v', '2', comparePath];
            execFileSync('ffmpeg', ffArgs, { stdio: 'ignore' });
            console.log(`  ✅ 对比图: ${comparePath}`);
            monitorArtifacts.comparePath = comparePath;
          } catch (e) {
            // hstack可能因为尺寸不同失败，用纵向拼接
            try {
              const ffArgs = ['-y', ...frames.flatMap(f => ['-i', f]), '-filter_complex', `vstack=inputs=${frames.length}`, '-q:v', '2', comparePath];
              execFileSync('ffmpeg', ffArgs, { stdio: 'ignore' });
              console.log(`  ✅ 对比图(纵向): ${comparePath}`);
              monitorArtifacts.comparePath = comparePath;
            } catch (e2) {
              console.log(`  ⚠️ 对比图拼接失败`);
            }
          }
        }

        // 生成剪辑思路
        console.log('\n═══ 生成剪辑思路 ═══');
        monitorArtifacts.guidePath = generateEditGuide(cfg.storyDir, cfg.storyName || submitState?.story_name, allDownloaded);
      }
    } else if (videos.length > 0) {
      console.log('  ⚠️ 未指定--story-dir，跳过下载');
    }
  }

  submitState = recordMonitorArtifacts(submitState, monitorArtifacts);
  saveSubmitState(cfg.submitStatePath, submitState);

  appendAuditLog(cfg.submitAuditPath, {
    kind: 'monitor_finish',
    project_id: cfg.projectId,
    project_url: cfg.projectUrl || null,
    story_name: cfg.storyName || submitState?.story_name || '',
    status: lastStatus,
    downloaded_to: cfg.storyDir || null,
    artifacts: submitState?.monitor?.artifacts || null
  });

  // 输出摘要（JSON格式，方便调用方解析）
  const summary = {
    projectId: cfg.projectId,
    projectUrl: cfg.projectUrl || null,
    storyName: cfg.storyName,
    status: lastStatus,
    monitorOverall: submitState?.monitor?.overall || null,
    artifacts: submitState?.monitor?.artifacts || null,
    storyDir: cfg.storyDir,
    submitStatePath: cfg.submitStatePath,
    timestamp: new Date().toISOString(),
  };
  console.log('\n═══ 摘要 ═══');
  console.log(JSON.stringify(summary, null, 2));

  // 只断开 Playwright CDP 会话，不关闭 Chrome 进程
  // Chrome CDP 是常驻服务，多个脚本共享
  await browser.close();
  // 注意: Playwright 的 browser.close() 在 connectOverCDP 模式下
  // 只断开连接，不会杀死 Chrome 进程（与 launch 模式不同）
}

main().catch(e => { console.error('❌', e.message); process.exit(1); });
