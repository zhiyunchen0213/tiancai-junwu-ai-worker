#!/usr/bin/env node
/**
 * Long Video Worker — Cover Thumbnail Rendering
 * Usage: node render_cover.mjs <work_dir>
 *
 * Input: work_dir/cover/cover_base.jpg, work_dir/titles_cover.json
 * Output: work_dir/output/thumbnail.jpg
 *
 * For MVP: just copies the cover base image as the thumbnail.
 * Future: overlay title text using Remotion or canvas.
 */

import { existsSync, mkdirSync, copyFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node render_cover.mjs <work_dir>'); process.exit(1); }

const outputDir = join(workDir, 'output');
mkdirSync(outputDir, { recursive: true });

const coverBase = join(workDir, 'cover', 'cover_base.jpg');
const thumbnailOut = join(outputDir, 'thumbnail.jpg');

if (existsSync(coverBase)) {
  copyFileSync(coverBase, thumbnailOut);
  console.log(`[cover] Thumbnail: ${thumbnailOut}`);
} else {
  // Fallback: use first scene image as thumbnail
  const imageDir = join(workDir, 'images');
  if (existsSync(imageDir)) {
    const { readdirSync } = await import('fs');
    const images = readdirSync(imageDir).filter(f => /\.(jpg|jpeg|png)$/i.test(f)).sort();
    if (images.length > 0) {
      copyFileSync(join(imageDir, images[0]), thumbnailOut);
      console.log(`[cover] Thumbnail (fallback from scene image): ${thumbnailOut}`);
    } else {
      console.warn('[cover] No cover or scene images available for thumbnail');
    }
  } else {
    console.warn('[cover] No images available for thumbnail');
  }
}
