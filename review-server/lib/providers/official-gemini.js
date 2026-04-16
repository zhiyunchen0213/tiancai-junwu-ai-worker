// review-server/lib/providers/official-gemini.js
// 官方 Gemini — 用 @google/genai SDK (支持 File API 处理大视频)

import { GoogleGenAI } from '@google/genai';

const DEFAULT_MODEL = 'gemini-2.5-flash';

function getClient(apiKey) {
  return new GoogleGenAI({ apiKey });
}

export async function uploadFile({ apiKey, filePath, mimeType }) {
  const ai = getClient(apiKey);
  const uploaded = await ai.files.upload({
    file: filePath,
    config: { mimeType: mimeType || 'video/mp4' },
  });
  return uploaded.uri;
}

export async function* generateContentStream({ apiKey, model, contents }) {
  const ai = getClient(apiKey);
  const response = await ai.models.generateContentStream({
    model: model || DEFAULT_MODEL,
    contents,
  });

  let totalTokens = 0;
  for await (const chunk of response) {
    if (chunk.text) yield { type: 'text', content: chunk.text };
    if (chunk.usageMetadata?.totalTokenCount) {
      totalTokens = chunk.usageMetadata.totalTokenCount;
    }
  }

  yield { type: 'done', model: model || DEFAULT_MODEL, tokenUsage: totalTokens };
}

export async function generateContent({ apiKey, model, contents }) {
  const ai = getClient(apiKey);
  const response = await ai.models.generateContent({
    model: model || DEFAULT_MODEL,
    contents,
  });

  const text = response.text || '';
  const totalTokens = response.usageMetadata?.totalTokenCount || 0;

  return { text, model: model || DEFAULT_MODEL, tokenUsage: totalTokens };
}

export const DEFAULT_MODEL_NAME = DEFAULT_MODEL;
export const SUPPORTS_FILE_API = true;
