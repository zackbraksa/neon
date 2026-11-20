import { APIError } from './db.js';

export interface KeyAllowance { limit: number | null; remaining: number | null }
export type ReadKeyAllowance = (key: string) => Promise<KeyAllowance>;
const unavailable = () => new APIError(503, 'OpenRouter key allowance is temporarily unavailable');

export async function readKeyAllowance(key: string, providerFetch: typeof fetch = fetch): Promise<KeyAllowance> {
  try {
    const response = await providerFetch('https://openrouter.ai/api/v1/key', {
      headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(8000), redirect: 'error',
    });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401 || response.status === 403) throw new APIError(422, 'OpenRouter rejected the configured API key');
      if (response.status === 429) throw new APIError(429, 'OpenRouter key allowance is temporarily rate limited');
      throw unavailable();
    }
    if (!response.body) throw unavailable();
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = []; let size = 0;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > 64 * 1024) throw unavailable();
        chunks.push(chunk.value);
      }
    } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const result: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!result || typeof result !== 'object' || !('data' in result) || !result.data || typeof result.data !== 'object') throw unavailable();
    const info = result.data as Record<string, unknown>;
    const numberOrNull = (value: unknown): number | null => {
      if (value === null) return null;
      if (typeof value !== 'number' || !Number.isFinite(value)) throw unavailable();
      return value;
    };
    const limit = numberOrNull(info.limit);
    const remaining = numberOrNull(info.limit_remaining);
    if (limit !== null && limit < 0) throw unavailable();
    return { limit, remaining: limit === null ? null : remaining };
  } catch (error) {
    if (error instanceof APIError) throw error;
    throw unavailable();
  }
}
