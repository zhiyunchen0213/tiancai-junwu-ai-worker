#!/usr/bin/env node
/**
 * Long Video Worker — Character Reference Image Generation
 * Usage: node generate_character_refs.mjs <work_dir>
 * Input: work_dir/segments.json, work_dir/project.json
 * Output: work_dir/character_refs/ directory with images
 *
 * For fixed_ip tracks: copies from ip-library/
 * For per_story tracks: generates via Apimart T2I
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node generate_character_refs.mjs <work_dir>'); process.exit(1); }

const project = JSON.parse(readFileSync(join(workDir, 'project.json'), 'utf8'));
const trackId = project.track_id;

// Read track.yaml to determine character_mode
// Simple YAML field extraction without js-yaml dependency
const skillsDir = process.env.LV_SKILLS_DIR || join(__dirname, '..', '..', '..', 'skills', 'tracks-longvideo');
const trackYaml = readFileSync(join(skillsDir, trackId, 'track.yaml'), 'utf8');
const charMode = trackYaml.match(/character_mode:\s*(\S+)/)?.[1] || 'per_story';
const ipGroup = trackYaml.match(/ip_group:\s*(\S+)/)?.[1] || '';

const refsDir = join(workDir, 'character_refs');
mkdirSync(refsDir, { recursive: true });

if (charMode === 'fixed_ip' && ipGroup) {
  // Copy from ip-library
  const ipLibDir = process.env.IP_LIBRARY_DIR || join(__dirname, '..', '..', '..', 'ip-library');
  const ipDir = join(ipLibDir, ipGroup);

  if (existsSync(ipDir)) {
    const { readdirSync } = await import('fs');
    const images = readdirSync(ipDir).filter(f => /\.(jpg|jpeg|png|webp)$/i.test(f));
    const refs = [];
    for (const img of images.slice(0, 5)) {
      const dest = join(refsDir, img);
      copyFileSync(join(ipDir, img), dest);
      refs.push(dest);
      console.log(`[character_refs] Copied IP image: ${img}`);
    }
    writeFileSync(join(workDir, 'character_refs.json'), JSON.stringify(refs), 'utf8');
    console.log(`[character_refs] ${refs.length} images from IP library: ${ipGroup}`);
  } else {
    console.warn(`[character_refs] IP group directory not found: ${ipDir}`);
    writeFileSync(join(workDir, 'character_refs.json'), '[]', 'utf8');
  }
} else {
  // per_story: generate via Apimart (stub for now — will use review-server yunwu.js pattern)
  console.log(`[character_refs] per_story mode — character ref generation stub`);

  // Read first segment's visual_prompt for character description
  const segments = JSON.parse(readFileSync(join(workDir, 'segments.json'), 'utf8'));
  const firstVisual = segments.find(s => s.segment_type === 'digital_human');
  const charDesc = firstVisual?.visual_prompt || 'An elderly man in a warm cardigan';

  // TODO: In Sub-Plan 4, call Apimart API to generate the image
  // For now, write the prompt to a file so the system knows what to generate
  const refPrompt = `Character reference portrait: ${charDesc}. Photorealistic, studio lighting, front-facing, neutral background.`;
  writeFileSync(join(refsDir, 'ref_prompt.txt'), refPrompt, 'utf8');
  writeFileSync(join(workDir, 'character_refs.json'), JSON.stringify([join(refsDir, 'ref_prompt.txt')]), 'utf8');
  console.log(`[character_refs] Stub: saved ref generation prompt`);
}
