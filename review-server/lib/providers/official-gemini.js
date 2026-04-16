// stub: official Gemini provider not available on worker (requires @google/genai)
export const DEFAULT_MODEL_NAME = 'gemini-3-flash';
export const SUPPORTS_FILE_API = false;
export async function generateContent() { throw new Error('official-gemini not available on worker'); }
export async function* generateContentStream() { throw new Error('official-gemini not available on worker'); }
export async function uploadFile() { throw new Error('official-gemini not available on worker'); }
