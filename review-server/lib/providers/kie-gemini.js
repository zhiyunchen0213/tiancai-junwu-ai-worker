// review-server/lib/providers/kie-gemini.js
// Kie 实现 — Gemini 原生格式 (snake_case inline_data / mime_type)
// NOTE: 2026-04-13 实测 Kie 的 Gemini 原生 endpoint 返回 HTTP 200 + 0 bytes，服务端 bug。

const BASE_URL = 'https://api.kie.ai/gemini/v1';
const DEFAULT_MODEL = 'gemini-3-flash';

function toKieFormat(contents) {
  return contents.map(item => ({
    ...item,
    parts: item.parts.map(part => {
      if (part.inlineData) {
        return {
          inline_data: {
            mime_type: part.inlineData.mimeType,
            data: part.inlineData.data,
          },
        };
      }
      if (part.fileData) {
        return {
          file_data: {
            mime_type: part.fileData.mimeType,
            file_uri: part.fileData.fileUri,
          },
        };
      }
      return part;
    }),
  }));
}

export async function* generateContentStream({ apiKey, model, contents }) {
  const url = `${BASE_URL}/models/${model || DEFAULT_MODEL}:streamGenerateContent`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ stream: true, contents: toKieFormat(contents) }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Kie error ${resp.status}: ${errText}`);
  }

  const contentLength = resp.headers.get('content-length');
  if (contentLength === '0') {
    throw new Error('Kie Gemini 接口当前返回空响应（服务端 bug），请换用其他 provider 或等 Kie 修复');
  }

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let totalTokens = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
      if (!line.startsWith('data: ')) continue;
      const jsonStr = line.slice(6);
      if (jsonStr === '[DONE]') continue;

      try {
        const parsed = JSON.parse(jsonStr);
        const text = parsed?.candidates?.[0]?.content?.parts?.[0]?.text;
        if (text) yield { type: 'text', content: text };
        if (parsed?.usageMetadata?.totalTokenCount) {
          totalTokens = parsed.usageMetadata.totalTokenCount;
        }
      } catch { /* skip */ }
    }
  }

  yield { type: 'done', model: model || DEFAULT_MODEL, tokenUsage: totalTokens };
}

export async function generateContent({ apiKey, model, contents }) {
  const url = `${BASE_URL}/models/${model || DEFAULT_MODEL}:generateContent`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ contents: toKieFormat(contents) }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Kie error ${resp.status}: ${errText}`);
  }

  const contentLength = resp.headers.get('content-length');
  if (contentLength === '0') {
    throw new Error('Kie Gemini 接口当前返回空响应（服务端 bug），请换用其他 provider 或等 Kie 修复');
  }

  const data = await resp.json();
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  const totalTokens = data?.usageMetadata?.totalTokenCount || 0;

  return { text, model: model || DEFAULT_MODEL, tokenUsage: totalTokens };
}

export const DEFAULT_MODEL_NAME = DEFAULT_MODEL;
