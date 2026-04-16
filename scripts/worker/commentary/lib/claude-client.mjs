// ClaudeClient — Anthropic-compatible messages client.
//
// Designed to target multiple gateways that expose the same
// `/v1/messages` shape:
//   - Kie   (default): https://api.kie.ai/claude/v1/messages       + Bearer auth
//   - apimart:         https://api.apimart.ai/v1/messages          + x-api-key + anthropic-version
//   - Anthropic direct: https://api.anthropic.com/v1/messages      + x-api-key + anthropic-version
//
// Constructor options:
//   apiKey             (required)
//   model              default: 'claude-sonnet-4-6'
//   endpoint           default: 'https://api.kie.ai/claude/v1/messages'
//   authMode           'bearer' | 'anthropic'  (default: 'bearer')
//   anthropicVersion   default: '2023-06-01' (only used in authMode='anthropic')
//
// Response body is expected to match Anthropic's shape:
//   { content: [{ type: 'text', text: '...' }, ...], ... }
// Both Kie and apimart are documented as Anthropic-compatible, so this
// should hold — but flag this as an integration risk if Kie deviates.

export class ClaudeClient {
  constructor({
    apiKey,
    model = 'claude-sonnet-4-6',
    endpoint = 'https://api.kie.ai/claude/v1/messages',
    authMode = 'bearer',
    anthropicVersion = '2023-06-01',
  }) {
    if (!apiKey) throw new Error('ClaudeClient: apiKey required');
    if (authMode !== 'bearer' && authMode !== 'anthropic') {
      throw new Error(`ClaudeClient: invalid authMode '${authMode}' (expected 'bearer' | 'anthropic')`);
    }
    this.apiKey = apiKey;
    this.model = model;
    this.endpoint = endpoint;
    this.authMode = authMode;
    this.anthropicVersion = anthropicVersion;
  }

  _headers() {
    const h = { 'content-type': 'application/json' };
    if (this.authMode === 'bearer') {
      h['authorization'] = `Bearer ${this.apiKey}`;
    } else {
      h['x-api-key'] = this.apiKey;
      h['anthropic-version'] = this.anthropicVersion;
    }
    return h;
  }

  async generateScript({ systemPrompt, userPayload }) {
    const body = {
      model: this.model,
      max_tokens: 2048,
      stream: false,  // Kie defaults stream=true; we need a single JSON reply
      system: systemPrompt,
      messages: [
        { role: 'user', content: JSON.stringify(userPayload) },
      ],
    };

    let lastErr;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const resp = await fetch(this.endpoint, {
          method: 'POST',
          headers: this._headers(),
          body: JSON.stringify(body),
        });
        if (!resp.ok) {
          const detail = await resp.text().catch(() => '');
          throw new Error(`Claude ${resp.status}: ${detail.slice(0, 200)}`);
        }
        const json = await resp.json();
        const txt = (json.content || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
        if (!txt) throw new Error('Claude: empty text content');
        return txt;
      } catch (e) {
        lastErr = e;
        if (attempt === 0) {
          await new Promise(r => setTimeout(r, 2000));
          continue;
        }
        throw e;
      }
    }
    throw lastErr;
  }
}
