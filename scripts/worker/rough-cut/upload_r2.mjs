#!/usr/bin/env node
// scripts/worker/rough-cut/upload_r2.mjs
//
// Worker 端: assemble.sh 跑完后 main.sh 调本脚本把 deliveries/commentary/<id>/
// 所有产物串行 PUT R2. 全成功 stdout 输出 manifest JSON, 任一失败 exit 1.
// 缺凭证 exit 2 让 main.sh 报 r2_credentials_missing.
//
// 用法 (CLI):
//   node upload_r2.mjs <external_id> <delivery_dir>
//
// 用法 (programmatic, 给 vitest):
//   import { uploadDirectoryToR2 } from './upload_r2.mjs';
//   const manifest = await uploadDirectoryToR2(externalId, dir);
//
// Spec: docs/superpowers/specs/2026-05-25-commentary-r2-package-design.md

import { readdir, stat, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

function getR2Client() {
  const accountId = process.env.R2_ACCOUNT_ID;
  const accessKeyId = process.env.R2_ACCESS_KEY_ID;
  const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
  if (!accountId || !accessKeyId || !secretAccessKey) {
    const e = new Error('R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY 任一缺失');
    e.code = 'CREDS_MISSING';
    throw e;
  }
  return new S3Client({
    region: 'auto',
    endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
    credentials: { accessKeyId, secretAccessKey },
  });
}

// NOTE: This map is a TRIMMED copy of review-server/lib/r2-storage.js#CONTENT_TYPE_MAP.
// Worker repo (deployed via sync_to_worker_repo.sh) doesn't include r2-storage.js,
// so we can't import the canonical map. If you add a new MIME type here, also add
// it to review-server/lib/r2-storage.js to keep them in sync. Worker only needs
// types actually present in commentary deliveries: mp4/mp3/json/txt + image types
// for thumbnails. Falls back to application/octet-stream for unknown — works fine
// for R2 (R2 doesn't reject any content-type).
const CONTENT_TYPE_MAP = {
  '.mp4': 'video/mp4', '.mp3': 'audio/mpeg', '.json': 'application/json',
  '.txt': 'text/plain; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg',
};
function inferContentType(filename) {
  const m = filename.match(/\.[^./]+$/);
  if (!m) return 'application/octet-stream';
  return CONTENT_TYPE_MAP[m[0].toLowerCase()] || 'application/octet-stream';
}

/**
 * 递归扫目录, skip dotfiles, 返回 [{absolutePath, relativePath, size}].
 */
async function listFilesRecursive(rootDir) {
  const out = [];
  async function walk(dir) {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile()) {
        const st = await stat(full);
        out.push({ absolutePath: full, relativePath: relative(rootDir, full), size: st.size });
      }
    }
  }
  await walk(rootDir);
  return out;
}

/**
 * 串行 PUT 所有 deliveryDir 下的文件到 R2 commentary/<externalId>/<relativePath>.
 * 返回 manifest object (待写到 stdout).
 *
 * 串行不并发 — 16MB 总量不需要优化时间 (spec 决策点 2 YAGNI).
 * R2 PUT idempotent — 同 key 覆盖, 整车重跑安全.
 */
export async function uploadDirectoryToR2(externalId, deliveryDir) {
  const client = getR2Client();
  const bucket = process.env.R2_BUCKET || 'createflow-assets';
  const files = await listFilesRecursive(deliveryDir);

  const manifestFiles = [];
  for (const f of files) {
    const r2Key = `commentary/${externalId}/${f.relativePath.replace(/\\/g, '/')}`;
    const body = await readFile(f.absolutePath);
    await client.send(new PutObjectCommand({
      Bucket: bucket, Key: r2Key, Body: body,
      ContentType: inferContentType(f.relativePath),
      ContentLength: f.size,
    }));
    manifestFiles.push({ key: r2Key, size: f.size, relative_path: f.relativePath.replace(/\\/g, '/') });
  }

  return {
    external_id: externalId,
    uploaded_at: new Date().toISOString(),
    bucket,
    files: manifestFiles,
  };
}

// CLI entry — argv[2]=externalId, argv[3]=deliveryDir
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const [, , externalId, deliveryDir] = process.argv;
  if (!externalId || !deliveryDir) {
    console.error('Usage: node upload_r2.mjs <external_id> <delivery_dir>');
    process.exit(64);
  }
  try {
    const manifest = await uploadDirectoryToR2(externalId, deliveryDir);
    process.stdout.write(JSON.stringify(manifest));
    process.exit(0);
  } catch (e) {
    if (e.code === 'CREDS_MISSING') {
      console.error(`[upload_r2] R2 凭证缺失: ${e.message}`);
      process.exit(2);
    }
    console.error(`[upload_r2] PUT 失败: ${e.message}`);
    process.exit(1);
  }
}
