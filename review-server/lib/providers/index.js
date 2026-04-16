// review-server/lib/providers/index.js
// Provider 路由

import * as apimart from './apimart-gemini.js';
import * as official from './official-gemini.js';

const PROVIDERS = {
  apimart,
  official,
};

export function getProvider(name) {
  const p = PROVIDERS[name];
  if (!p) throw new Error(`Unknown provider: ${name}`);
  return p;
}

export function getDefaultModel(name) {
  const p = getProvider(name);
  return p.DEFAULT_MODEL_NAME;
}

export function supportsFileApi(name) {
  const p = getProvider(name);
  return !!p.SUPPORTS_FILE_API;
}

export const AVAILABLE_PROVIDERS = Object.keys(PROVIDERS);

/**
 * 读取 VPS env 里的团队默认 provider 配置
 * 用于"员工未在设置页填 key 时"的 fallback
 * @returns {{provider, api_key, model}|null}
 */
export function getDefaultProviderConfig() {
  const provider = process.env.DEFAULT_PROVIDER_NAME;
  const apiKey = process.env.DEFAULT_PROVIDER_API_KEY;
  if (!provider || !apiKey) return null;
  if (!AVAILABLE_PROVIDERS.includes(provider)) {
    console.warn(`[providers] DEFAULT_PROVIDER_NAME="${provider}" 无效，忽略团队默认配置`);
    return null;
  }
  return {
    provider,
    api_key: apiKey,
    model: process.env.DEFAULT_PROVIDER_MODEL || null,
  };
}

/**
 * 拿到"生效的 provider 配置"
 * 优先级：用户个人配置 > VPS 团队默认配置
 * @param {object|null} userConfig — getProviderConfig(userId) 的返回
 * @returns {{provider, api_key, model, is_default}|null}
 */
export function getEffectiveProviderConfig(userConfig) {
  if (userConfig && userConfig.api_key) {
    return {
      provider: userConfig.provider,
      api_key: userConfig.api_key,
      model: userConfig.model || null,
      is_default: false,
    };
  }
  const def = getDefaultProviderConfig();
  if (def) return { ...def, is_default: true };
  return null;
}
