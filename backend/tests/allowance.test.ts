import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { APIError, Store } from '../src/db.js';
import { readKeyAllowance } from '../src/allowance.js';
import { buildServer } from '../src/server.js';

const key = 'sk-or-synthetic-allowance-test';
test('allowance uses bounded read-only key info and strips private provider fields', async () => {
  const fake: typeof fetch = async (url, options) => {
    assert.equal(url, 'https://openrouter.ai/api/v1/key');
    assert.equal(new Headers(options?.headers).get('authorization'), `Bearer ${key}`);
    assert.equal(options?.redirect, 'error');
    assert.ok(options?.signal instanceof AbortSignal);
    return new Response(JSON.stringify({ data: { label: 'private label', limit: 20, limit_remaining: 12.345, usage: 7.655 } }));
  };
  assert.deepEqual(await readKeyAllowance(key, fake), { limit: 20, remaining: 12.345 });
  assert.deepEqual(await readKeyAllowance(key, async () => new Response('{"data":{"limit":null,"limit_remaining":null}}')), { limit: null, remaining: null });
});

test('allowance failures are sanitized and reject malformed or oversized responses', async () => {
  for (const status of [401, 403, 429, 500]) {
    await assert.rejects(readKeyAllowance(key, async () => new Response(key, { status })), error => {
      assert.ok(error instanceof APIError);
      assert.equal(error.statusCode, status === 401 || status === 403 ? 422 : status === 429 ? 429 : 503);
      assert.ok(!error.message.includes(key));
      return true;
    });
  }
  for (const body of ['not json', '{}', '{"data":{"limit":"secret","limit_remaining":2}}', '{"data":{"limit":10,"limit_remaining":1e999}}', 'x'.repeat(65537)]) {
    await assert.rejects(readKeyAllowance(key, async () => new Response(body)), error => error instanceof APIError && error.statusCode === 503);
  }
  await assert.rejects(readKeyAllowance(key, async () => { throw new DOMException(key, 'AbortError'); }), error => error instanceof APIError && error.statusCode === 503 && !error.message.includes(key));
});

test('allowance endpoint authenticates and reads only the session workspace key', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'neon-allowance-'));
  const store = new Store(join(directory, 'data.sqlite'), randomBytes(32));
  const used: string[] = [];
  const app = await buildServer({ store, token: 'synthetic-owner-token-at-least-32-characters', startWorker: false,
    validateKey: async () => {}, keyAllowance: async value => { used.push(value); return { limit: 30, remaining: value.endsWith('-a') ? 20 : 10 }; } });
  try {
    const a = store.createSession('sk-or-synthetic-a', randomUUID());
    const b = store.createSession('sk-or-synthetic-b', randomUUID());
    const headers = (session: typeof a) => ({ authorization: `Bearer ${session.token}`, 'x-openchat-server-id': session.serverId });
    assert.equal((await app.inject({ url: '/v1/settings/openrouter-allowance' })).statusCode, 401);
    assert.equal((await app.inject({ url: '/v1/settings/openrouter-allowance', headers: { ...headers(a), 'x-openchat-server-id': b.serverId } })).statusCode, 409);
    assert.deepEqual(used, []);
    const first = await app.inject({ url: '/v1/settings/openrouter-allowance', headers: headers(a) });
    assert.deepEqual(first.json(), { configured: true, limit: 30, remaining: 20 });
    assert.equal(first.headers['cache-control'], 'no-store');
    assert.deepEqual((await app.inject({ url: '/v1/settings/openrouter-allowance', headers: headers(b) })).json(), { configured: true, limit: 30, remaining: 10 });
    assert.deepEqual(used, ['sk-or-synthetic-a', 'sk-or-synthetic-b']);
    store.setKey(a.serverId, '');
    assert.deepEqual((await app.inject({ url: '/v1/settings/openrouter-allowance', headers: headers(a) })).json(), { configured: false, limit: null, remaining: null });
    assert.equal(used.length, 2);
  } finally { await app.close(); store.close(); rmSync(directory, { recursive: true, force: true }); }
});
