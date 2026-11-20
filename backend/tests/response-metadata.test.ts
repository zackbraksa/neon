import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { Store } from '../src/db.js';
import { generate, responseMetadata, type Generate, type ResponseMetadata } from '../src/openrouter.js';
import { Worker } from '../src/worker.js';
import { buildServer } from '../src/server.js';

const fields = ['responseModel', 'inputTokens', 'outputTokens', 'totalTokens', 'costUSD'];
function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'neon-response-metadata-'));
  const path = join(directory, 'data.sqlite'), key = randomBytes(32);
  const store = new Store(path, key); store.setKey(store.serverID, 'synthetic-provider-key');
  const thread = randomUUID(); store.createThread(store.serverID, thread, 'Original', true);
  const id = randomUUID(); store.enqueue(store.serverID, thread, id, 'Hello', 'openrouter/auto');
  return { store, thread, id, path, key, cleanup: () => { store.close(); rmSync(directory, { recursive: true, force: true }); } };
}
async function until(predicate: () => boolean) {
  for (let i = 0; i < 100; i++) { if (predicate()) return; await delay(10); }
  assert.fail('Timed out');
}

test('provider reads reported model and trailing empty-choice usage after finish reason across fragmented SSE', async t => {
  const source = [
    { model: 'vendor/actual', choices: [{ delta: { content: 'Hi 🙂' } }] },
    { choices: [{ delta: {}, finish_reason: 'stop' }] },
    { choices: [], usage: { prompt_tokens: 12, completion_tokens: 0, total_tokens: 12, cost: 0 } },
    { model: ' ', choices: [], usage: { prompt_tokens: -1, completion_tokens: '9', cost: null } },
  ].map(event => `data: ${JSON.stringify(event)}\r\n\r\n`).join('') + 'data: [DONE]\n\n';
  const bytes = new TextEncoder().encode(source);
  t.mock.method(globalThis, 'fetch', async (_url: unknown, options: RequestInit) => {
    assert.deepEqual(Object.keys(JSON.parse(options.body as string)).sort(), ['messages', 'model', 'stream']);
    return new Response(new ReadableStream({ start(controller) {
      for (let i = 0; i < bytes.length; i += 3) controller.enqueue(bytes.slice(i, i + 3));
      controller.close();
    } }));
  });
  const metadata: ResponseMetadata[] = []; let text = '';
  for await (const chunk of generate('synthetic-key', 'openrouter/auto', [], new AbortController().signal, value => metadata.push(value))) text += chunk;
  assert.equal(text, 'Hi 🙂');
  assert.deepEqual(Object.assign({}, ...metadata), { responseModel: 'vendor/actual', inputTokens: 12, outputTokens: 0, totalTokens: 12, costUSD: 0 });
});

test('provider metadata rejects malformed fields independently and preserves meaningful zero values', () => {
  assert.deepEqual(responseMetadata(null), {});
  assert.deepEqual(responseMetadata({ model: ' ', usage: { prompt_tokens: -1, completion_tokens: 1.5, total_tokens: Number.MAX_SAFE_INTEGER + 1, cost: Infinity } }), {});
  assert.deepEqual(responseMetadata({ model: 'x'.repeat(201), usage: { prompt_tokens: '4', completion_tokens: null, total_tokens: 0, cost: -1 } }), { totalTokens: 0 });
  assert.deepEqual(responseMetadata({ model: ' vendor/actual ', usage: { prompt_tokens: 0, completion_tokens: 7, total_tokens: 7, cost: 0.0000123 } }),
    { responseModel: 'vendor/actual', inputTokens: 0, outputTokens: 7, totalTokens: 7, costUSD: 0.0000123 });
});

test('metadata persists, advances revision only for changes, copies into fork and rejects late terminal writes', () => {
  const f = fixture();
  try {
    f.store.claim();
    const before = f.store.thread(f.store.serverID, f.thread).revision as number;
    const metadata = { responseModel: 'vendor/actual', inputTokens: 10, outputTokens: 4, totalTokens: 14, costUSD: 0.00004 };
    f.store.recordResponseMetadata(f.id, metadata);
    assert.equal(f.store.thread(f.store.serverID, f.thread).revision, before + 1);
    f.store.recordResponseMetadata(f.id, metadata);
    f.store.recordResponseMetadata(f.id, {});
    f.store.recordResponseMetadata(f.id, { costUSD: null });
    assert.equal(f.store.thread(f.store.serverID, f.thread).revision, before + 1);
    f.store.append(f.id, 'Answer'); f.store.finish(f.id, 'complete');
    f.store.recordResponseMetadata(f.id, { costUSD: 99 });
    assert.equal(f.store.job(f.store.serverID, f.id).costUSD, metadata.costUSD);
    assert.equal(f.store.job(f.store.serverID, f.id).model, 'openrouter/auto');
    const target = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Next', 'openrouter/auto');
    const branch = randomUUID(); f.store.fork(f.store.serverID, f.thread, target.id, branch, randomUUID(), 'Edited next');
    const copied = f.store.jobs(f.store.serverID, branch)[0];
    for (const field of fields) assert.equal((copied as unknown as Record<string, unknown>)[field], (metadata as unknown as Record<string, unknown>)[field]);
    const reopened = new Store(f.path, f.key);
    try { assert.equal(reopened.job(f.store.serverID, f.id).responseModel, 'vendor/actual'); assert.equal(reopened.job(f.store.serverID, f.id).totalTokens, 14); }
    finally { reopened.close(); }
  } finally { f.cleanup(); }
});

test('schema4 upgrade retains historical jobs, pin and revision while leaving old usage unknown', () => {
  const f = fixture();
  try {
    const before = f.store.thread(f.store.serverID, f.thread);
    f.store.close();
    const old = new Store(f.path, f.key);
    old.db.exec('ALTER TABLE jobs DROP COLUMN images; ALTER TABLE jobs DROP COLUMN reasoningEffort;');
    old.db.exec(fields.map(field => `ALTER TABLE jobs DROP COLUMN ${field};`).join('') + 'PRAGMA user_version=4;');
    old.close();
    const migrated = new Store(f.path, f.key);
    try {
      assert.equal(migrated.db.prepare('PRAGMA user_version').get()!.user_version, 8);
      assert.deepEqual(migrated.thread(migrated.serverID, f.thread), before);
      const job = migrated.job(migrated.serverID, f.id);
      assert.equal(job.prompt, 'Hello'); assert.equal(job.model, 'openrouter/auto');
      for (const field of fields) assert.equal((job as unknown as Record<string, unknown>)[field], null);
    } finally { migrated.close(); }
  } finally { rmSync(join(f.path, '..'), { recursive: true, force: true }); }
});

test('worker retains partial metadata on interruption and ignores callbacks after stop', async () => {
  const f = fixture();
  let callback: ((metadata: ResponseMetadata) => void) | undefined;
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const provider: Generate = async function* (_key, _model, _history, _signal, onMetadata) {
    callback = onMetadata; onMetadata?.({ responseModel: 'vendor/actual', inputTokens: 7 });
    yield 'Partial'; await gate; onMetadata?.({ outputTokens: 999 }); yield 'late';
  };
  const worker = new Worker(f.store, provider);
  try {
    worker.tick(); await until(() => callback !== undefined);
    worker.stop(f.store.serverID, f.thread);
    release(); await worker.close();
    const job = f.store.job(f.store.serverID, f.id);
    assert.equal(job.status, 'stopped'); assert.equal(job.responseModel, 'vendor/actual');
    assert.equal(job.inputTokens, 7); assert.equal(job.outputTokens, null);
  } finally { release(); await worker.close(); f.cleanup(); }
  const failed = fixture();
  const failing: Generate = async function* (_key, _model, _history, _signal, onMetadata) {
    onMetadata?.({ responseModel: 'vendor/interrupted', outputTokens: 2 }); yield 'Partial'; throw new Error('Provider connection ended early');
  };
  const failedWorker = new Worker(failed.store, failing);
  try {
    failedWorker.tick(); await until(() => failed.store.job(failed.store.serverID, failed.id).status === 'failed');
    assert.equal(failed.store.job(failed.store.serverID, failed.id).outputTokens, 2);
  } finally { await failedWorker.close(); failed.cleanup(); }
});

test('status SSE emits metadata changes while running and replays final metadata through API and reconnect', async () => {
  const f = fixture(); f.store.claim();
  const token = 'synthetic-response-metadata-owner-token-32-characters';
  const app = await buildServer({ store: f.store, token, startWorker: false });
  try {
    const origin = await app.listen({ host: '127.0.0.1', port: 0 });
    const headers = { authorization: `Bearer ${token}`, 'x-openchat-server-id': f.store.serverID };
    const response = await fetch(`${origin}/v1/jobs/${f.id}/events`, { headers, signal: AbortSignal.timeout(5000) });
    const reader = response.body!.getReader();
    const decoder = new TextDecoder(); let received = '';
    const readUntil = async (value: string) => { while (!received.includes(value)) { const part = await reader.read(); assert.equal(part.done, false); received += decoder.decode(part.value); } };
    await readUntil('"responseModel":null');
    f.store.recordResponseMetadata(f.id, { responseModel: 'vendor/actual', inputTokens: 0 });
    await readUntil('"responseModel":"vendor/actual"');
    assert.equal(f.store.job(f.store.serverID, f.id).status, 'running');
    f.store.recordResponseMetadata(f.id, { outputTokens: 3, totalTokens: 3, costUSD: 0 });
    f.store.finish(f.id, 'complete');
    while (true) { const part = await reader.read(); if (part.done) break; received += decoder.decode(part.value); }
    assert.match(received, /"status":"complete".*"totalTokens":3,"costUSD":0/);
    const snapshot = await app.inject({ url: `/v1/threads/${f.thread}`, headers });
    assert.equal(snapshot.json().jobs[0].responseModel, 'vendor/actual');
    assert.equal((await app.inject({ url: `/v1/jobs/${f.id}`, headers })).json().inputTokens, 0);
    const replay = await fetch(`${origin}/v1/jobs/${f.id}/events`, { headers: { ...headers, 'last-event-id': '0' } });
    assert.match(await replay.text(), /"responseModel":"vendor\/actual".*"costUSD":0/);
  } finally { app.server.closeAllConnections(); await app.close(); f.cleanup(); }
});
