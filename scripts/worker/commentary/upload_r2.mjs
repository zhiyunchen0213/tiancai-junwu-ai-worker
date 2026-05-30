#!/usr/bin/env node
// scripts/worker/commentary/upload_r2.mjs
//
// kindness-reversal-commentary phase_c: PUT final.mp4 (and optional SRT) to R2,
// write r2_manifest.json to work_dir.
//
// 用法:
//   node upload_r2.mjs <work_dir> <task_id>
//
// 输出 (文件):
//   <work_dir>/r2_manifest.json
//     { "final_mp4": { "r2_key": "commentary/<task_id>/final.mp4",
//                      "size_bytes": N, "uploaded_at": "..." },
//       "subtitles_srt"?: { "r2_key": "commentary/<task_id>/narration.srt",
//                           "size_bytes": N, "uploaded_at": "..." } }
//
// R2 prefix: commentary/<task_id>/ — 与 commentary-remix 现行 layout 对齐
// (CLAUDE.md: "R2 prefix discipline: commentary/<external_id>/")
//
// Env required: R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY
// Env optional: R2_BUCKET (default 'createflow-assets')
//
// Exit codes: 0=OK, 1=upload failure, 2=credentials missing, 64=usage error

import { readFile, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
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

async function putFile(client, bucket, r2Key, absPath, contentType) {
  const body = await readFile(absPath);
  const fileSize = body.length;
  await client.send(new PutObjectCommand({
    Bucket: bucket,
    Key: r2Key,
    Body: body,
    ContentType: contentType,
    ContentLength: fileSize,
  }));
  return fileSize;
}

/**
 * Upload final.mp4 (and narration.srt if present) to R2.
 * Writes r2_manifest.json to workDir.
 */
export async function uploadKindnessCommentaryToR2(workDir, taskId) {
  const client = getR2Client();
  const bucket = process.env.R2_BUCKET || 'createflow-assets';
  const uploadedAt = new Date().toISOString();
  const manifest = {};

  // 1. Upload final.mp4 (required)
  const finalMp4Path = join(workDir, 'final.mp4');
  const mp4R2Key = `commentary/${taskId}/final.mp4`;
  console.error(`[upload_r2] PUT ${mp4R2Key}`);
  const mp4Size = await putFile(client, bucket, mp4R2Key, finalMp4Path, 'video/mp4');
  manifest.final_mp4 = { r2_key: mp4R2Key, size_bytes: mp4Size, uploaded_at: uploadedAt };
  console.error(`[upload_r2] final.mp4 OK (${mp4Size} bytes)`);

  // 2. Upload narration.srt if present (best-effort, no fail if missing)
  const srtPath = join(workDir, 'narration.srt');
  let srtExists = false;
  try {
    await stat(srtPath);
    srtExists = true;
  } catch (_) { /* not present */ }

  if (srtExists) {
    const srtR2Key = `commentary/${taskId}/narration.srt`;
    console.error(`[upload_r2] PUT ${srtR2Key}`);
    const srtSize = await putFile(client, bucket, srtR2Key, srtPath, 'text/plain; charset=utf-8');
    manifest.subtitles_srt = { r2_key: srtR2Key, size_bytes: srtSize, uploaded_at: uploadedAt };
    console.error(`[upload_r2] narration.srt OK (${srtSize} bytes)`);
  } else {
    console.error('[upload_r2] narration.srt not found — skipping subtitle upload');
  }

  // 3. Write manifest to work_dir
  const manifestPath = join(workDir, 'r2_manifest.json');
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2), 'utf8');
  console.error(`[upload_r2] r2_manifest.json written`);

  return manifest;
}

// CLI entry — argv[2]=workDir, argv[3]=taskId
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const [, , workDir, taskId] = process.argv;
  if (!workDir || !taskId) {
    console.error('Usage: node upload_r2.mjs <work_dir> <task_id>');
    process.exit(64);
  }
  try {
    await uploadKindnessCommentaryToR2(workDir, taskId);
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
