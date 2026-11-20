import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Store } from '../src/db.js';
import { Worker } from '../src/worker.js';
import { buildServer } from '../src/server.js';

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'neon-deletion-'));
  const path = join(directory, 'data.sqlite'), key = randomBytes(32);
  const store = new Store(path, key);
  const a = store.createSession('sk-or-synthetic-deletion-a', randomUUID());
  const b = store.createSession('sk-or-synthetic-deletion-b', randomUUID());
  return { store, a, b, path, key, cleanup: () => { store.close(); rmSync(directory, { recursive: true, force: true }); } };
}

test('delete erases active and archived history and blocks stale recreation across restarts', async () => {
  const f = fixture();
  const app = await buildServer({ store: f.store, token: 'synthetic-deletion-owner-token-at-least-32-chars', startWorker: false });
  const headers = { authorization: `Bearer ${f.a.token}`, 'x-openchat-server-id': f.a.serverId };
  try {
    assert.equal((await app.inject({ url: '/v1/capabilities', headers })).json().conversationDeletion, true);
    const kept = randomUUID(); f.store.createThread(f.a.serverId, kept, 'Keep');
    for (const archived of [false, true]) {
      const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Private title', true);
      f.store.registerDevice(f.a.serverId, randomUUID(), randomBytes(32).toString('hex'));
      const complete = f.store.enqueue(f.a.serverId, id, randomUUID(), 'Private prompt', 'test/model');
      f.store.claim(); f.store.append(complete.id, 'Private answer'); f.store.finish(complete.id, 'complete');
      const running = f.store.enqueue(f.a.serverId, id, randomUUID(), 'Running prompt', 'test/model'); f.store.claim();
      f.store.enqueue(f.a.serverId, id, randomUUID(), 'Queued prompt', 'test/model');
      if (archived) f.store.archive(f.a.serverId, id);
      const url = `/v1/threads/${id}`;
      assert.equal((await app.inject({ method: 'DELETE', url })).statusCode, 401);
      assert.equal((await app.inject({ method: 'DELETE', url, headers: { ...headers, 'x-openchat-server-id': randomUUID() } })).statusCode, 409);
      assert.equal((await app.inject({ method: 'DELETE', url, headers: { authorization: `Bearer ${f.b.token}` } })).statusCode, 404);
      for (let attempt = 0; attempt < 2; attempt++) {
        const response = await app.inject({ method: 'DELETE', url, headers });
        assert.equal(response.statusCode, 200); assert.deepEqual(response.json(), { deleted: true });
      }
      assert.equal((await app.inject({ url: `${url}?includeArchived=true`, headers })).statusCode, 404);
      assert.equal((await app.inject({ url: `/v1/jobs/${complete.id}`, headers })).statusCode, 404);
      assert.equal((await app.inject({ method: 'POST', url: '/v1/threads', headers, payload: { id, title: 'Stale retry' } })).statusCode, 410);
      assert.equal((await app.inject({ method: 'POST', url: `${url}/messages`, headers, payload: { id: running.id, prompt: running.prompt, model: running.model } })).statusCode, 404);
      assert.equal((await app.inject({ method: 'POST', url: `${url}/restore`, headers })).statusCode, 404);
      assert.equal(f.store.append(running.id, 'late text'), false);
      f.store.finish(running.id, 'complete');
      f.store.recordResponseMetadata(running.id, { responseModel: 'late/model' });
      assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM jobs WHERE threadId=?').get(id)!.n, 0);
      assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 0);
      const reopened = new Store(f.path, f.key);
      try {
        assert.throws(() => reopened.createThread(f.a.serverId, id, 'Stale after restart'), { statusCode: 410 });
        assert.throws(() => reopened.createThread(f.b.serverId, id, 'Other workspace'), { statusCode: 404 });
        assert.throws(() => reopened.deleteThread(f.b.serverId, id), { statusCode: 404 });
      } finally { reopened.close(); }
    }
    assert.deepEqual(f.store.threads(f.a.serverId).map(t => t.id), [kept]);
    assert.deepEqual(f.store.threads(f.a.serverId, true), []);
    assert.equal((await app.inject({ method: 'DELETE', url: `/v1/threads/${randomUUID()}`, headers })).statusCode, 404);
    assert.equal((await app.inject({ method: 'DELETE', url: '/v1/threads/not-a-uuid', headers })).statusCode, 400);
  } finally { await app.close(); f.cleanup(); }
});

test('delete during generation aborts the provider and safely rejects late completion and worker close', async () => {
  const f = fixture();
  let started!: () => void;
  const ready = new Promise<void>(resolve => { started = resolve; });
  let aborted = false;
  const worker = new Worker(f.store, async function* (_key, _model, _history, signal, metadata) {
    started();
    await new Promise<void>(resolve => signal.addEventListener('abort', () => { aborted = true; resolve(); }, { once: true }));
    metadata?.({ responseModel: 'late/model' });
    yield 'late text';
  });
  try {
    const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Running');
    const job = f.store.enqueue(f.a.serverId, id, randomUUID(), 'Prompt', 'test/model');
    f.store.enqueue(f.a.serverId, id, randomUUID(), 'Queued', 'test/model');
    worker.start(); await ready;
    f.store.deleteThread(f.a.serverId, id); worker.abortStopped(); await worker.close();
    assert.equal(aborted, true); assert.equal(f.store.findWorkerJob(job.id), undefined);
    assert.equal(f.store.claim(), undefined);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM jobs').get()!.n, 0);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 0);
  } finally { await worker.close(); f.cleanup(); }
});
