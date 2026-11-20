import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { Store } from '../src/db.js';
import { buildServer } from '../src/server.js';
import type { Generate } from '../src/openrouter.js';

test('a real HTTP subscriber can disconnect and replay the finished job without cancelling generation', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'openchat-stream-'));
  const store = new Store(join(dir, 'db.sqlite'), randomBytes(32));
  store.setKey(store.serverID, 'test-only');
  const token = 'test-only-owner-token-with-32-characters';
  const provider: Generate = async function* () { yield 'First 🙂'; await delay(450); yield ' and last'; };
  const app = await buildServer({ store, token, provider });
  try {
    const origin = await app.listen({ host: '127.0.0.1', port: 0 });
    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
    const thread = randomUUID(); const id = randomUUID();
    assert.equal((await fetch(`${origin}/v1/threads`)).status, 401);
    await fetch(`${origin}/v1/threads`, { method: 'POST', headers, body: JSON.stringify({ id: thread, title: 'Live stream' }) });
    assert.equal((await fetch(`${origin}/v1/threads/${thread}/messages`, { method: 'POST', headers,
      body: JSON.stringify({ id, prompt: 'Hello', model: 'auto' }) })).status, 202);
    const abort = new AbortController();
    const response = await fetch(`${origin}/v1/jobs/${id}/events`, { headers, signal: abort.signal });
    const reader = response.body!.getReader();
    let first = '';
    while (!first.includes('event: delta')) {
      const chunk = await reader.read(); assert.equal(chunk.done, false);
      first += new TextDecoder().decode(chunk.value);
    }
    abort.abort();
    try { await reader.cancel(); } catch { /* Expected transport cancellation. */ }
    for (let i = 0; i < 200 && store.job(store.serverID, id).status !== 'complete'; i++) await delay(10);
    assert.equal(store.job(store.serverID, id).status, 'complete');
    assert.equal(store.job(store.serverID, id).content, 'First 🙂 and last');
    const replay = await fetch(`${origin}/v1/jobs/${id}/events`, { headers: { ...headers, 'last-event-id': String('First 🙂'.length) } });
    const body = await replay.text();
    assert.match(body, /"text":" and last"/);
    assert.match(body, /"status":"complete"/);
    assert.doesNotMatch(body, /"text":"First/);
  } finally { app.server.closeAllConnections(); await app.close(); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
