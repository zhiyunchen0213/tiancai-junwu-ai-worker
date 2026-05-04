#!/usr/bin/env node
// scripts/worker/material-ingest/cdp-extract-douyin-url.mjs
//
// 用 CDP 让 macking 上的 cookie-refresh Chrome 真访问抖音视频页, 等视频元素渲染,
// 从 video.currentSrc 拿真实 mp4 CDN URL (douyinvod) 输出到 stdout.
//
// 为啥不用 yt-dlp:
//   yt-dlp douyin extractor 调 /aweme/v1/web/aweme/detail/ API 时缺 X-Bogus + msToken
//   signature, 抖音最近加强校验后所有 yt-dlp 都失败 (即使带完整登录态 cookies).
//   CDP 让 Chrome 真渲染页面, 服务端把签名好的 mp4 URL 直接给浏览器, 我们抓出来就行.
//
// Usage:
//   CDP_PORT=9224 node cdp-extract-douyin-url.mjs <source_url>
//
// stdout: 一行真实 mp4 URL (douyinvod / byteicdn 域名)
// stderr: 进度日志
// exit:
//   0 成功
//   1 CDP 不可达
//   2 视频元素没渲染出来 (probe URL 失效或抖音改版)
//   3 其他错误

import { setTimeout as sleep } from 'node:timers/promises';

const CDP_PORT = Number(process.env.CDP_PORT || 9224);
const NAV_SETTLE_MS = Number(process.env.NAV_SETTLE_MS || 8_000);
const POLL_INTERVAL_MS = 1_000;
const POLL_MAX = 8;
const SOURCE_URL = process.argv[2];

if (!SOURCE_URL || !/^https?:\/\//.test(SOURCE_URL)) {
  console.error('usage: cdp-extract-douyin-url.mjs <https://www.douyin.com/video/...>');
  process.exit(3);
}

function log(...a) { console.error(`[cdp-extract] ${new Date().toISOString()}`, ...a); }

async function fetchJson(url, method = 'GET') {
  const r = await fetch(url, { method });
  if (!r.ok) throw new Error(`${url} → HTTP ${r.status}`);
  return r.json();
}

async function cdpClient(targetWsUrl) {
  const WS = globalThis.WebSocket;
  if (!WS) throw new Error('node 22+ required (built-in WebSocket)');
  const ws = new WS(targetWsUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', (e) => reject(new Error(`ws: ${e.message || 'connect failed'}`)), { once: true });
  });
  let nextId = 1;
  const inflight = new Map();
  ws.addEventListener('message', (evt) => {
    let msg;
    try { msg = JSON.parse(typeof evt.data === 'string' ? evt.data : evt.data.toString()); } catch { return; }
    if (msg.id && inflight.has(msg.id)) {
      const { resolve, reject } = inflight.get(msg.id);
      inflight.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });
  return {
    send(method, params = {}) {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        inflight.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
      });
    },
    close() { try { ws.close(); } catch {} },
  };
}

// 在 page context 里跑, 找当前主播放器的真实 mp4 URL.
// 优先级: video.currentSrc → performance entries 里 douyinvod/byteicdn mp4
const EXTRACT_VIDEO_URL_JS = `(() => {
  function isMp4Url(u) {
    if (!u || typeof u !== 'string') return false;
    if (!u.startsWith('http')) return false;
    if (/\\.m3u8(\\?|$)/i.test(u)) return false;
    if (!/(douyinvod|byteicdn|\\.mp4)/i.test(u)) return false;
    return true;
  }
  // 1. video element
  const videos = Array.from(document.querySelectorAll('video'));
  for (const v of videos) {
    if (isMp4Url(v.currentSrc)) return v.currentSrc;
    if (isMp4Url(v.src)) return v.src;
  }
  // 2. performance entries
  const entries = performance.getEntriesByType('resource').filter((e) => isMp4Url(e.name));
  if (entries.length === 0) return null;
  // 取 size 最大的 (主视频 vs 缩略图/广告)
  entries.sort((a, b) => (b.transferSize || b.encodedBodySize || 0) - (a.transferSize || a.encodedBodySize || 0));
  return entries[0]?.name || null;
})()`;

async function main() {
  log(`source=${SOURCE_URL}  cdp=${CDP_PORT}`);

  // 1. 检查 CDP
  let version;
  try { version = await fetchJson(`http://127.0.0.1:${CDP_PORT}/json/version`); }
  catch (e) { log(`CDP unreachable: ${e.message}`); process.exit(1); }
  log(`Chrome ${version.Browser}`);

  // 2. 新 tab + navigate
  const tab = await fetchJson(`http://127.0.0.1:${CDP_PORT}/json/new?about:blank`, 'PUT');
  const cdp = await cdpClient(tab.webSocketDebuggerUrl);
  let videoUrl = null;
  try {
    await cdp.send('Page.enable');
    await cdp.send('Network.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Page.navigate', { url: SOURCE_URL });

    log(`navigated, waiting ${NAV_SETTLE_MS}ms for initial render...`);
    await sleep(NAV_SETTLE_MS);

    // 3. 轮询拿 video URL (有时候 video.currentSrc 渲染慢)
    for (let i = 0; i < POLL_MAX; i++) {
      const r = await cdp.send('Runtime.evaluate', {
        expression: EXTRACT_VIDEO_URL_JS,
        returnByValue: true,
      });
      const u = r?.result?.value;
      if (u) {
        videoUrl = u;
        log(`got video URL on poll ${i + 1}`);
        break;
      }
      log(`poll ${i + 1}/${POLL_MAX}: no video URL yet`);
      await sleep(POLL_INTERVAL_MS);
    }

    if (!videoUrl) {
      log('FAIL: no video URL after polling. probe page may not have loaded media.');
      process.exit(2);
    }
  } finally {
    cdp.close();
    try { await fetch(`http://127.0.0.1:${CDP_PORT}/json/close/${tab.id}`); } catch {}
  }

  // stdout: 唯一一行, downloader bash 直接 read
  process.stdout.write(videoUrl + '\n');
  process.exit(0);
}

main().catch((e) => { log(`UNCAUGHT: ${e.stack || e.message}`); process.exit(3); });
