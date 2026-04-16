// review-server/lib/providers/apimart-gemini.js
// APImart 实现 — Gemini 原生 HTTP 格式 (camelCase)

const BASE_URL = 'https://api.apimart.ai/v1beta';
const DEFAULT_MODEL = 'gemini-3-flash-preview-nothinking';

export async function* generateContentStream({ apiKey, model, contents }) {
  const url = `${BASE_URL}/models/${model || DEFAULT_MODEL}:streamGenerateContent?alt=sse`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ contents }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`APImart error ${resp.status}: ${errText}`);
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
    body: JSON.stringify({ contents }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`APImart error ${resp.status}: ${errText}`);
  }

  const data = await resp.json();
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  const totalTokens = data?.usageMetadata?.totalTokenCount || 0;

  return { text, model: model || DEFAULT_MODEL, tokenUsage: totalTokens };
}

export const DEFAULT_MODEL_NAME = DEFAULT_MODEL;
