#!/usr/bin/env node
/**
 * Long Video Worker — Video Rendering via Remotion
 * Usage: node render_video.mjs <work_dir> [format]
 * format: "landscape" (default, 16:9) or "portrait" (9:16)
 *
 * Input: work_dir/{segments.json, audio_manifest.json, image_manifest.json, opening.mp4}
 * Output: work_dir/output/draft_landscape.mp4 or draft_portrait.mp4
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
const format = process.argv[3] || 'landscape';
if (!workDir) { console.error('Usage: node render_video.mjs <work_dir> [landscape|portrait]'); process.exit(1); }

const remotionDir = join(__dirname, 'remotion');
const outputDir = join(workDir, 'output');
mkdirSync(outputDir, { recursive: true });

// Read Phase A+B outputs
const segments = JSON.parse(readFileSync(join(workDir, 'segments.json'), 'utf8'));
const audioManifest = JSON.parse(readFileSync(join(workDir, 'audio_manifest.json'), 'utf8'));
const imageManifest = existsSync(join(workDir, 'image_manifest.json'))
  ? JSON.parse(readFileSync(join(workDir, 'image_manifest.json'), 'utf8'))
  : [];

const FPS = 30;
const isPortrait = format === 'portrait';
const width = isPortrait ? 1080 : 1920;
const height = isPortrait ? 1920 : 1080;

// Build segment timing from audio durations
let currentFrame = 0;
const timedSegments = segments.map((seg, i) => {
  const audio = audioManifest.find(a => a.index === i);
  const actualDuration = audio?.duration_estimate || seg.duration_hint || 15;
  const durationFrames = Math.round(actualDuration * FPS);
  const startFrame = currentFrame;
  currentFrame += durationFrames;

  return {
    index: seg.index,
    text: seg.text,
    visualPrompt: seg.visual_prompt,
    durationHint: seg.duration_hint,
    segmentType: seg.segment_type,
    actualDuration,
    startFrame,
    endFrame: startFrame + durationFrames,
  };
});

const totalFrames = currentFrame;

// Build audio files list (absolute paths for Remotion)
const audioFiles = audioManifest
  .filter(a => a.path)
  .map(a => ({ index: a.index, path: a.path, duration: a.duration_estimate || 15 }));

// Build image files list
const imageFiles = imageManifest
  .filter(m => m.status === 'ok' && m.path)
  .map(m => ({ index: m.index, path: m.path }));

// Opening video path
const openingPath = join(workDir, 'opening.mp4');
const openingVideoPath = existsSync(openingPath) ? openingPath : undefined;

// Track render config (simplified defaults)
const config = {
  kenBurns: true,
  transition: 'crossfade',
  transitionDuration: 0.5,
  subtitleStyle: 'bottom_center',
  introDuration: 3,
  outroDuration: 5,
};

// Build inputProps
const inputProps = {
  segments: timedSegments,
  audioFiles,
  imageFiles,
  openingVideoPath,
  width,
  height,
  fps: FPS,
  durationInFrames: totalFrames,
  config,
};

// Write props to file for Remotion
const propsPath = join(workDir, `remotion_props_${format}.json`);
writeFileSync(propsPath, JSON.stringify(inputProps, null, 2), 'utf8');

const compositionId = isPortrait ? 'ElderlyStoryTemplate-Portrait' : 'ElderlyStoryTemplate';
const outputPath = join(outputDir, `draft_${format}.mp4`);

console.log(`[render] Rendering ${format} video: ${timedSegments.length} segments, ${totalFrames} frames (${(totalFrames / FPS).toFixed(1)}s)`);
console.log(`[render] Composition: ${compositionId}, Output: ${outputPath}`);

// Invoke Remotion render
try {
  const cmd = [
    'npx', 'remotion', 'render',
    'src/Root.tsx',
    compositionId,
    outputPath,
    '--props', propsPath,
    '--concurrency', '2',
  ].join(' ');

  console.log(`[render] Running: ${cmd}`);
  execSync(cmd, {
    cwd: remotionDir,
    stdio: 'inherit',
    timeout: 30 * 60 * 1000, // 30 min timeout
    env: { ...process.env, NODE_OPTIONS: '--max-old-space-size=4096' },
  });

  console.log(`[render] ✓ ${format} video rendered: ${outputPath}`);
} catch (err) {
  console.error(`[render] Remotion render failed: ${err.message}`);
  process.exit(1);
}
