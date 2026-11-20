import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { Store } from '../src/db.js';
import { buildServer } from '../src/server.js';
import { generate, reasoningEfforts, type Generate, type ReasoningEffort } from '../src/openrouter.js';
import { Worker } from '../src/worker.js';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'neon-effort-'));
  const path = join(dir, 'db.sqlite'); const key = randomBytes(32);
  const store = new Store(path, key); store.setKey(store.serverID, 'synthetic-provider-key');
  const thread = randomUUID(); store.createThread(store.serverID, thread, 'Effort');
  return { store, path, key, thread, cleanup: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

test('provider serializes every explicit effort and omits reasoning for provider default', async t => {
  const bodies: Record<string, unknown>[] = [];
  t.mock.method(globalThis, 'fetch', async (_url: string, options: RequestInit) => {
    bodies.push(JSON.parse(options.body as string));
    return new Response('data: [DONE]\n\n');
  });
  for (const effort of [undefined, ...reasoningEfforts]) {
    for await (const _chunk of generate('synthetic-key', 'test/model', [], new AbortController().signal, undefined, effort)) { /* consume */ }
  }
  assert.deepEqual(bodies[0], { model: 'test/model', messages: [], stream: true });
  assert.deepEqual(bodies.slice(1).map(body => body.reasoning), reasoningEfforts.map(effort => ({ effort })));
});

test('API advertises effort support, validates input and rejects conflicting immutable retries', async () => {
  const f = fixture(); const token = 'synthetic-owner-token-with-32-characters';
  const app = await buildServer({ store: f.store, token, startWorker: false });
  const headers = { authorization: `Bearer ${token}` };
  const send = (payload: object) => app.inject({ method: 'POST', url: `/v1/threads/${f.thread}/messages`, headers, payload });
  try {
    assert.equal((await app.inject({ url: '/v1/capabilities', headers })).json().reasoningEffort, true);
    for (const reasoningEffort of [null, '', 'default', 'extreme', 1, {}, ['high']]) {
      assert.equal((await send({ id: randomUUID(), prompt: 'Hello', model: 'auto', reasoningEffort })).statusCode, 400);
    }
    for (const reasoningEffort of reasoningEfforts) {
      const payload = { id: randomUUID(), prompt: 'Hello', model: 'auto', reasoningEffort };
      const accepted = await send(payload);
      assert.equal(accepted.statusCode, 202); assert.equal(accepted.json().reasoningEffort, reasoningEffort);
      assert.equal((await send(payload)).json().id, payload.id);
      assert.equal((await send({ ...payload, reasoningEffort: reasoningEffort === 'high' ? 'low' : 'high' })).statusCode, 409);
      const { reasoningEffort: _effort, ...defaultPayload } = payload;
      assert.equal((await send(defaultPayload)).statusCode, 409);
    }
    const legacy = { id: randomUUID(), prompt: 'Default', model: 'auto' };
    assert.equal((await send(legacy)).json().reasoningEffort, null);
    assert.equal((await send(legacy)).statusCode, 202);
    assert.equal((await send({ ...legacy, reasoningEffort: 'none' })).statusCode, 409);
  } finally { await app.close(); f.cleanup(); }
});

test('queued effort survives restart and worker forwards captured values without replaying interrupted work', async () => {
  const f = fixture();
  const interrupted = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Running', 'auto', false, 'high');
  f.store.claim();
  const queued = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Queued', 'auto', false, 'low');
  f.store.close();
  const reopened = new Store(f.path, f.key);
  const seen: (ReasoningEffort | undefined)[] = [];
  const provider: Generate = async function* (_key, _model, _history, _signal, _metadata, effort) { seen.push(effort); yield 'Answer'; };
  const worker = new Worker(reopened, provider);
  try {
    worker.start();
    assert.equal(reopened.job(reopened.serverID, interrupted.id).status, 'stopped');
    assert.equal(reopened.job(reopened.serverID, interrupted.id).reasoningEffort, 'high');
    assert.equal(reopened.job(reopened.serverID, queued.id).status, 'queued');
    assert.deepEqual(seen, []);
    reopened.resume(reopened.serverID, f.thread); worker.tick();
    for (let i = 0; i < 100 && reopened.job(reopened.serverID, queued.id).status !== 'complete'; i++) await delay(10);
    assert.equal(reopened.job(reopened.serverID, queued.id).status, 'complete');
    assert.deepEqual(seen, ['low']);
  } finally { await worker.close(); reopened.close(); rmSync(join(f.path, '..'), { recursive: true, force: true }); }
});

test('fork copies prior efforts and edited turn inherits its original target effort', () => {
  const f = fixture();
  try {
    const prior = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Prior', 'model/one', false, 'minimal');
    f.store.claim(); f.store.append(prior.id, 'Prior answer'); f.store.finish(prior.id, 'complete');
    const target = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Target', 'model/two', false, 'xhigh');
    const branch = randomUUID();
    const edited = f.store.fork(f.store.serverID, f.thread, target.id, branch, randomUUID(), 'Edited');
    assert.equal(edited.reasoningEffort, 'xhigh'); assert.equal(edited.model, 'model/two');
    assert.deepEqual(f.store.jobs(f.store.serverID, branch).map(job => job.reasoningEffort), ['minimal', 'xhigh']);
    assert.equal(f.store.job(f.store.serverID, target.id).prompt, 'Target');
  } finally { f.cleanup(); }
});

test('schema5 migration preserves legacy jobs and revision with default provider effort', () => {
  const f = fixture();
  const old = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Legacy', 'auto');
  const revision = f.store.thread(f.store.serverID, f.thread).revision;
  f.store.db.exec('ALTER TABLE jobs DROP COLUMN images; ALTER TABLE jobs DROP COLUMN reasoningEffort; PRAGMA user_version=5;'); f.store.close();
  const migrated = new Store(f.path, f.key);
  try {
    assert.equal(migrated.db.prepare('PRAGMA user_version').get()!.user_version, 8);
    assert.equal(migrated.job(migrated.serverID, old.id).reasoningEffort, null);
    assert.equal(migrated.thread(migrated.serverID, f.thread).revision, revision);
    assert.equal(migrated.enqueue(migrated.serverID, f.thread, old.id, 'Legacy', 'auto').id, old.id);
  } finally { migrated.close(); rmSync(join(f.path, '..'), { recursive: true, force: true }); }
});
