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
 * Upload commentary pack zip (the primary deliverable) + standalone narration.mp3
 * and narration.srt (for inspection / future re-pack) to R2. Writes r2_manifest.json
 * to workDir.
 *
 * Primary deliverable is kindness-commentary-pack.zip — employee downloads this and
 * runs local edit (剪映 / Premiere). Standalone files are kept for ops debugging
 * and possible direct preview without unzip.
 */
export async function uploadKindnessCommentaryToR2(workDir, taskId) {
  const client = getR2Client();
  const bucket = process.env.R2_BUCKET || 'createflow-assets';
  const uploadedAt = new Date().toISOString();
  const manifest = {};

  // 1. Upload the pack zip (REQUIRED — the primary deliverable)
  //    R2 key 含 taskId (2026-06-01): 旧 `kindness-commentary-pack.zip` 让员工同时下
  //    多个解说包浏览器会自动加 (1)(2) 分不清; 改成 `kindness-commentary-<taskId>.zip`
  //    每条任务文件名唯一. 本地 workDir 里仍叫 kindness-commentary-pack.zip (worker 内部约定).
  const zipPath = join(workDir, 'kindness-commentary-pack.zip');
  const zipR2Key = `commentary/${taskId}/kindness-commentary-${taskId}.zip`;
  console.error(`[upload_r2] PUT ${zipR2Key}`);
  const zipSize = await putFile(client, bucket, zipR2Key, zipPath, 'application/zip');
  manifest.pack_zip = { r2_key: zipR2Key, size_bytes: zipSize, uploaded_at: uploadedAt };
  console.error(`[upload_r2] pack zip OK (${zipSize} bytes)`);

  // 2. Upload narration.mp3 standalone (best-effort, for preview/debug)
  const mp3Path = join(workDir, 'narration.mp3');
  try {
    await stat(mp3Path);
    const mp3R2Key = `commentary/${taskId}/narration.mp3`;
    console.error(`[upload_r2] PUT ${mp3R2Key}`);
    const mp3Size = await putFile(client, bucket, mp3R2Key, mp3Path, 'audio/mpeg');
    manifest.narration_mp3 = { r2_key: mp3R2Key, size_bytes: mp3Size, uploaded_at: uploadedAt };
    console.error(`[upload_r2] narration.mp3 OK (${mp3Size} bytes)`);
  } catch (_) {
    console.error('[upload_r2] narration.mp3 not found — skipping');
  }

  // 3. Upload narration.srt standalone (best-effort)
  const srtPath = join(workDir, 'narration.srt');
  try {
    await stat(srtPath);
    const srtR2Key = `commentary/${taskId}/narration.srt`;
    console.error(`[upload_r2] PUT ${srtR2Key}`);
    const srtSize = await putFile(client, bucket, srtR2Key, srtPath, 'text/plain; charset=utf-8');
    manifest.subtitles_srt = { r2_key: srtR2Key, size_bytes: srtSize, uploaded_at: uploadedAt };
    console.error(`[upload_r2] narration.srt OK (${srtSize} bytes)`);
  } catch (_) {
    console.error('[upload_r2] narration.srt not found — skipping');
  }

  // 4. Upload metadata.json standalone (best-effort, for direct read without unzip)
  const metadataPath = join(workDir, 'metadata.json');
  try {
    await stat(metadataPath);
    const metaR2Key = `commentary/${taskId}/metadata.json`;
    console.error(`[upload_r2] PUT ${metaR2Key}`);
    const metaSize = await putFile(client, bucket, metaR2Key, metadataPath, 'application/json');
    manifest.metadata_json = { r2_key: metaR2Key, size_bytes: metaSize, uploaded_at: uploadedAt };
    console.error(`[upload_r2] metadata.json OK (${metaSize} bytes)`);
  } catch (_) {
    console.error('[upload_r2] metadata.json not found — skipping');
  }

  // 5. Write manifest to work_dir
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
