#!/usr/bin/env node
/**
 * media-server.mjs — 轻量静态文件服务器 (零依赖)
 *
 * 职责: 服务 ~/production/deliveries/ 下的视频和图片，通过 Cloudflare Tunnel
 * 暴露到 media.createflow.art，给 VPS review-server 的 /media-cache 路由做回源。
 *
 * 部署: macking (Mac mini)
 * 启动: com.tiancai.media-server LaunchAgent (KeepAlive)
 * 代码分发: 主 repo → worker repo → ~/worker-code/media-server/ (自动 git pull)
 *
 * Token rotation: 修改 com.tiancai.media-server.plist 的
 * EnvironmentVariables.MEDIA_TOKEN，然后 launchctl bootout + bootstrap。
 * 同时必须同步更新 VPS 的 review-server/.env MEDIA_TOKEN。两端值必须一致。
 */
import { createServer } from 'http';
import { join, resolve, extname } from 'path';
import { createReadStream, statSync, readdirSync } from 'fs';
import { homedir } from 'os';

const PORT = parseInt(process.env.PORT || '9000');
const TOKEN = process.env.MEDIA_TOKEN;
const ROOT = resolve(process.env.MEDIA_ROOT || join(homedir(), 'production', 'deliveries'));

// Fail-fast: 未设 MEDIA_TOKEN 时拒绝启动，避免回到公开 fallback。
// LaunchAgent KeepAlive 会无限重启循环，log 里会持续打印该错误，
// 足够让运维注意到。不做 fallback = 不给攻击者任何已知的默认凭证可用。
if (!TOKEN) {
  console.error('[media-server] FATAL: MEDIA_TOKEN env var is required. Set it in the LaunchAgent plist EnvironmentVariables dict.');
  process.exit(1);
}

const MIME = {
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp',
  '.json': 'application/json', '.md': 'text/markdown',
};

function sendJSON(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(data));
}

const server = createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization',
    });
    return res.end();
  }

  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (url.pathname === '/health') return sendJSON(res, 200, { ok: true, root: ROOT });

  const token = url.searchParams.get('token') || (req.headers.authorization || '').replace('Bearer ', '');
  if (token !== TOKEN) return sendJSON(res, 401, { error: 'Unauthorized' });

  const reqPath = decodeURIComponent(url.pathname).replace(/^\/+/, '');
  const absPath = resolve(ROOT, reqPath);
  if (!absPath.startsWith(ROOT)) return sendJSON(res, 403, { error: 'Forbidden' });

  let stat;
  try { stat = statSync(absPath); } catch { return sendJSON(res, 404, { error: 'Not found' }); }

  if (stat.isDirectory()) {
    try {
      const entries = readdirSync(absPath).filter(f => !f.startsWith('.')).sort();
      return sendJSON(res, 200, entries);
    } catch { return sendJSON(res, 500, { error: 'Cannot read directory' }); }
  }

  const ext = extname(absPath).toLowerCase();
  const mime = MIME[ext] || 'application/octet-stream';
  const size = stat.size;
  const range = req.headers.range;

  if (range) {
    const [startStr, endStr] = range.replace('bytes=', '').split('-');
    const start = parseInt(startStr);
    const end = endStr ? parseInt(endStr) : size - 1;
    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${size}`,
      'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1,
      'Content-Type': mime, 'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'public, max-age=604800',
    });
    createReadStream(absPath, { start, end }).pipe(res);
  } else {
    res.writeHead(200, {
      'Content-Length': size, 'Content-Type': mime,
      'Accept-Ranges': 'bytes', 'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'public, max-age=604800',
    });
    createReadStream(absPath).pipe(res);
  }
});

server.listen(PORT, () => {
  console.log(`[media-server] :${PORT} serving ${ROOT}`);
});
