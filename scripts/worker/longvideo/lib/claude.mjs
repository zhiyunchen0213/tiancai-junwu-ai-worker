import { spawn } from 'child_process';

const CLAUDE_TIMEOUT = parseInt(process.env.CLAUDE_TIMEOUT || '300000'); // 5 min default
const CLAUDE_RETRIES = parseInt(process.env.CLAUDE_RETRIES || '2');

/**
 * Call Claude CLI with a prompt and return the text response.
 * @param {string} prompt - The full prompt text
 * @param {object} opts - Options: { timeout, retries, sshHost }
 * @returns {Promise<string>} Claude's response text
 */
export async function callClaude(prompt, opts = {}) {
  const timeout = opts.timeout || CLAUDE_TIMEOUT;
  const retries = opts.retries ?? CLAUDE_RETRIES;
  const sshHost = opts.sshHost || process.env.CLAUDE_SSH_HOST;

  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const result = await _invoke(prompt, timeout, sshHost);
      return result.trim();
    } catch (err) {
      if (attempt < retries) {
        const wait = (attempt + 1) * 10;
        console.error(`[Claude] Attempt ${attempt + 1} failed: ${err.message}. Retrying in ${wait}s...`);
        await new Promise(r => setTimeout(r, wait * 1000));
      } else {
        throw new Error(`Claude failed after ${retries + 1} attempts: ${err.message}`);
      }
    }
  }
}

/**
 * Call Claude and parse the response as JSON.
 * Handles markdown code fences in the response.
 */
export async function callClaudeJSON(prompt, opts = {}) {
  const raw = await callClaude(prompt, opts);
  // Strip markdown code fences if present
  const cleaned = raw.replace(/^```(?:json)?\s*\n?/m, '').replace(/\n?```\s*$/m, '').trim();
  try {
    return JSON.parse(cleaned);
  } catch (e) {
    throw new Error(`Claude response is not valid JSON: ${e.message}\nRaw: ${raw.slice(0, 500)}`);
  }
}

function _invoke(prompt, timeout, sshHost) {
  return new Promise((resolve, reject) => {
    let cmd, args;
    if (sshHost) {
      cmd = 'ssh';
      args = [sshHost, 'claude', '-p', '--output-format', 'text'];
    } else {
      cmd = 'claude';
      args = ['-p', '--output-format', 'text'];
    }

    const child = spawn(cmd, args, {
      timeout,
      env: { ...process.env, HOME: process.env.HOME || '/root' },
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', d => { stdout += d; });
    child.stderr.on('data', d => { stderr += d; });

    // Write prompt in chunks (avoid pipe buffer overflow)
    const CHUNK = 4096;
    for (let i = 0; i < prompt.length; i += CHUNK) {
      child.stdin.write(prompt.slice(i, i + CHUNK));
    }
    child.stdin.end();

    child.on('close', code => {
      if (code === 0 && stdout.length > 0) {
        resolve(stdout);
      } else {
        reject(new Error(`claude exited ${code}: ${stderr.slice(0, 300)}`));
      }
    });

    child.on('error', reject);
  });
}
