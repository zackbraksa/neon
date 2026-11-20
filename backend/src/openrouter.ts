import { APIError } from './db.js';

export const reasoningEfforts = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'] as const;
export type ReasoningEffort = typeof reasoningEfforts[number];

export interface ChatMessage { role: 'user' | 'assistant'; content: string; images?: string[] }
export interface ResponseMetadata {
  responseModel?: string | null;
  inputTokens?: number | null;
  outputTokens?: number | null;
  totalTokens?: number | null;
  costUSD?: number | null;
}
export type Generate = (key: string, model: string, history: ChatMessage[], signal: AbortSignal,
  onMetadata?: (metadata: ResponseMetadata) => void, reasoningEffort?: ReasoningEffort) => AsyncIterable<string>;

export function responseMetadata(value: unknown): ResponseMetadata {
  if (!value || typeof value !== 'object') return {};
  const event = value as Record<string, unknown>;
  const result: ResponseMetadata = {};
  if (typeof event.model === 'string' && event.model.trim() && event.model.length <= 200)
    result.responseModel = event.model.trim();
  if (event.usage && typeof event.usage === 'object') {
    const usage = event.usage as Record<string, unknown>;
    for (const [wire, field] of [['prompt_tokens', 'inputTokens'], ['completion_tokens', 'outputTokens'], ['total_tokens', 'totalTokens']] as const) {
      const value = usage[wire];
      if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) result[field] = value;
    }
    if (typeof usage.cost === 'number' && Number.isFinite(usage.cost) && usage.cost >= 0) result.costUSD = usage.cost;
  }
  return result;
}

/** Streaming UTF-8 decoder and SSE framing, including CRLF and split chunks. */
export async function* sseData(chunks: AsyncIterable<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let buffer = ''; let fields: string[] = []; let eventLength = 0;
  for await (const chunk of chunks) {
    buffer += decoder.decode(chunk, { stream: true });
    if (buffer.length > 2_000_000) throw new Error('Provider event too large');
    let newline: number;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline).replace(/\r$/, ''); buffer = buffer.slice(newline + 1);
      if (line === '') { if (fields.length) { yield fields.join('\n'); fields = []; eventLength = 0; } }
      else if (line.startsWith('data:')) {
        eventLength += line.length;
        if (eventLength > 2_000_000) throw new Error('Provider event too large');
        fields.push(line.slice(5).replace(/^ /, ''));
      }
    }
  }
  decoder.decode(); // Detect a truncated UTF-8 sequence, even at EOF.
}

export const generate: Generate = async function* (key, model, messages, signal, onMetadata, reasoningEffort) {
  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST', signal: AbortSignal.any([signal, AbortSignal.timeout(15 * 60_000)]),
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Accept: 'text/event-stream' },
    body: JSON.stringify({ model, messages: messages.map(({ role, content, images }) => ({ role, content: images?.length
      ? [...(content ? [{ type: 'text', text: content }] : []), ...images.map(url => ({ type: 'image_url', image_url: { url } }))]
      : content })), stream: true, ...(reasoningEffort === undefined ? {} : { reasoning: { effort: reasoningEffort } }) }),
  });
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    throw new Error(`OpenRouter HTTP ${response.status}; check credit, key, and model access`);
  }
  let finished = false;
  try {
    for await (const data of sseData(response.body)) {
      signal.throwIfAborted();
      if (data === '[DONE]') { finished = true; break; }
      const event = JSON.parse(data) as { error?: unknown; choices?: { delta?: { content?: string }; finish_reason?: string | null }[] };
      if (event.error) throw new Error('Provider streaming error');
      const metadata = responseMetadata(event);
      if (Object.keys(metadata).length) onMetadata?.(metadata);
      const choice = event.choices?.[0];
      if (typeof choice?.delta?.content === 'string') yield choice.delta.content;
      if (choice?.finish_reason) {
        if (choice.finish_reason === 'error') throw new Error('Provider interrupted the response');
        finished = true;
      }
    }
  } finally {
    // Iterator disposal cancels the underlying ReadableStream on early exit.
  }
  if (!finished) throw new Error('Provider connection ended early; partial answer saved');
};

export type ValidateKey = (key: string) => Promise<void>;
export const validateKey: ValidateKey = async key => {
  try {
    const response = await fetch('https://openrouter.ai/api/v1/key', {
      headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(8000), redirect: 'error',
    });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401 || response.status === 403) throw new APIError(401, 'OpenRouter rejected this API key');
      throw new APIError(503, 'OpenRouter key validation is temporarily unavailable');
    }
    const result = await response.json() as { data?: unknown };
    if (!result.data || typeof result.data !== 'object') throw new APIError(503, 'OpenRouter key validation is temporarily unavailable');
  } catch (error) {
    if (error instanceof APIError) throw error;
    throw new APIError(503, 'OpenRouter key validation is temporarily unavailable');
  }
};
