import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Store } from '../src/db.js';
import { buildServer } from '../src/server.js';

async function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'neon-archive-'));
  const path = join(directory, 'data.sqlite'), encryptionKey = randomBytes(32);
  const store = new Store(path, encryptionKey);
  const a = store.createSession('sk-or-synthetic-archive-a', randomUUID());
  const b = store.createSession('sk-or-synthetic-archive-b', randomUUID());
  const owner = 'synthetic-archive-owner-token-at-least-32-chars';
  let providerCalls = 0;
  const app = await buildServer({ store, token: owner, startWorker: false,
    provider: async function* () { providerCalls++; yield 'unexpected'; } });
  const headers = (session = a) => ({ authorization: `Bearer ${session.token}`, 'x-openchat-server-id': session.serverId });
  return { app, store, a, b, owner, headers, path, encryptionKey, calls: () => providerCalls,
    cleanup: async () => { await app.close(); store.close(); rmSync(directory, { recursive: true, force: true }); } };
}

test('archive lists and snapshots are scoped, opt-in and compatible with active defaults', async () => {
  const f = await fixture();
  try {
    const active = randomUUID(), archived = randomUUID(), foreign = randomUUID();
    f.store.createThread(f.a.serverId, active, 'Active');
    f.store.createThread(f.a.serverId, archived, 'Archived', true);
    f.store.createThread(f.b.serverId, foreign, 'Private');
    f.store.archive(f.a.serverId, archived); f.store.archive(f.b.serverId, foreign);
    const get = (url: string) => f.app.inject({ url, headers: f.headers() });
    assert.equal((await get('/v1/capabilities')).json().archiveBrowsing, true);
    for (const url of ['/v1/threads', '/v1/threads?archived=false'])
      assert.deepEqual((await get(url)).json().map((r: { id: string }) => r.id), [active]);
    assert.deepEqual((await get('/v1/threads?archived=true')).json().map((r: { id: string }) => r.id), [archived]);
    assert.equal((await get(`/v1/threads/${archived}`)).statusCode, 410);
    assert.equal((await get(`/v1/threads/${archived}?includeArchived=false`)).statusCode, 410);
    assert.equal((await get(`/v1/threads/${archived}?includeArchived=true`)).json().archived, 1);
    assert.equal((await get(`/v1/threads/${active}?includeArchived=true`)).json().archived, 0);
    assert.equal((await get(`/v1/threads/${foreign}?includeArchived=true`)).statusCode, 404);
    assert.equal((await f.app.inject({ method: 'POST', url: `/v1/threads/${foreign}/restore`, headers: f.headers() })).statusCode, 404);
    const secondDevice = f.store.createSession('sk-or-synthetic-archive-a', randomUUID());
    assert.equal((await f.app.inject({ url: '/v1/threads?archived=true', headers: f.headers(secondDevice) })).json()[0].id, archived);
  } finally { await f.cleanup(); }
});

test('restore preserves history and paused jobs, increments once, persists and never claims work', async () => {
  const f = await fixture();
  try {
    const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Pinned history', true);
    f.store.registerDevice(f.a.serverId, randomUUID(), 'a'.repeat(64));
    const complete = f.store.enqueue(f.a.serverId, id, randomUUID(), 'First prompt', 'test/model');
    f.store.claim(); f.store.append(complete.id, 'Finished answer'); f.store.finish(complete.id, 'complete');
    const running = f.store.enqueue(f.a.serverId, id, randomUUID(), 'Second prompt', 'test/model');
    f.store.claim(); f.store.append(running.id, 'Partial answer');
    f.store.enqueue(f.a.serverId, id, randomUUID(), 'Queued prompt', 'test/model');
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 1);
    assert.equal((await f.app.inject({ method: 'POST', url: `/v1/threads/${id}/archive`, headers: f.headers() })).statusCode, 200);
    const before = (await f.app.inject({ url: `/v1/threads/${id}?includeArchived=true`, headers: f.headers() })).json();
    assert.deepEqual(before.jobs.map((j: { status: string }) => j.status), ['complete', 'stopped', 'stopped']);
    assert.equal(before.paused, 1);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 0);
    assert.throws(() => f.store.jobs(f.a.serverId, id), { statusCode: 410 });
    const response = await f.app.inject({ method: 'POST', url: `/v1/threads/${id}/restore`, headers: f.headers() });
    assert.equal(response.statusCode, 200);
    const after = response.json();
    assert.equal(after.archived, 0); assert.equal(after.revision, before.revision + 1);
    assert.equal(after.title, before.title); assert.equal(after.pinned, 1); assert.equal(after.paused, 1);
    assert.deepEqual(after.jobs, before.jobs);
    assert.deepEqual((await f.app.inject({ method: 'POST', url: `/v1/threads/${id}/restore`, headers: f.headers() })).json(), after);
    assert.deepEqual((await f.app.inject({ url: `/v1/threads/${id}`, headers: f.headers() })).json(), after);
    assert.equal(f.store.claim(), undefined); assert.equal(f.calls(), 0);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 0);
    const reopened = new Store(f.path, f.encryptionKey);
    try { assert.deepEqual(JSON.parse(JSON.stringify(reopened.restore(f.a.serverId, id))), after); } finally { reopened.close(); }
  } finally { await f.cleanup(); }
});

test('archive routes enforce auth, workspace pin, strict query strings and legacy owner compatibility', async () => {
  const f = await fixture();
  try {
    const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Archived'); f.store.archive(f.a.serverId, id);
    for (const [method, url] of [['GET', '/v1/threads?archived=true'], ['GET', `/v1/threads/${id}?includeArchived=true`], ['POST', `/v1/threads/${id}/restore`]] as const) {
      assert.equal((await f.app.inject({ method, url })).statusCode, 401);
      assert.equal((await f.app.inject({ method, url, headers: { authorization: 'Bearer invalid' } })).statusCode, 401);
      assert.equal((await f.app.inject({ method, url, headers: { ...f.headers(), 'x-openchat-server-id': randomUUID() } })).statusCode, 409);
    }
    for (const [url, flag] of [['/v1/threads', 'archived'], [`/v1/threads/${id}`, 'includeArchived']]) {
      for (const value of ['', '1', '0', 'TRUE', 'yes', 'null', 'true&' + flag + '=false'])
        assert.equal((await f.app.inject({ url: `${url}?${flag}=${value}`, headers: f.headers() })).statusCode, 400);
      assert.equal((await f.app.inject({ url: `${url}?unknown=true`, headers: f.headers() })).statusCode, 400);
    }
    const legacyID = randomUUID(); f.store.createThread(f.store.serverID, legacyID, 'Owner history'); f.store.archive(f.store.serverID, legacyID);
    const headers = { authorization: `Bearer ${f.owner}`, 'x-openchat-server-id': f.store.serverID };
    assert.equal((await f.app.inject({ url: '/v1/threads?archived=true', headers })).json()[0].id, legacyID);
    assert.equal((await f.app.inject({ method: 'POST', url: `/v1/threads/${legacyID}/restore`, headers })).json().archived, 0);
  } finally { await f.cleanup(); }
});

test('archive browsing leaves all existing conversation mutations guarded', async () => {
  const f = await fixture();
  try {
    const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Archived'); f.store.archive(f.a.serverId, id);
    assert.equal((await f.app.inject({ url: `/v1/threads/${id}?includeArchived=true`, headers: f.headers() })).statusCode, 200);
    const requests = [
      { method: 'PATCH' as const, url: `/v1/threads/${id}`, payload: { title: 'Renamed' } },
      { method: 'POST' as const, url: '/v1/threads', payload: { id, title: 'Retry' } },
      { method: 'POST' as const, url: `/v1/threads/${id}/messages`, payload: { id: randomUUID(), prompt: 'No send', model: 'test/model' } },
      { method: 'POST' as const, url: `/v1/threads/${id}/stop`, payload: {} },
      { method: 'POST' as const, url: `/v1/threads/${id}/resume` },
      { method: 'POST' as const, url: `/v1/threads/${id}/fork`, payload: { targetJobId: randomUUID(), threadId: randomUUID(), jobId: randomUUID(), prompt: 'No fork' } },
    ];
    for (const request of requests) assert.equal((await f.app.inject({ ...request, headers: f.headers() })).statusCode, 410);
    assert.equal(f.store.claim(), undefined);
  } finally { await f.cleanup(); }
});
