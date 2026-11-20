import test from 'node:test';
import assert from 'node:assert/strict';
import { createCipheriv, randomBytes, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { APIError, Store } from '../src/db.js';
import { buildServer } from '../src/server.js';
import { Notifications, type Notice } from '../src/push.js';
import { type Generate, validateKey } from '../src/openrouter.js';

const owner = 'test-only-legacy-owner-token-at-least-32-characters';
const legacyKey = 'sk-or-v1-legacy-test-key';
const keyA = 'sk-or-v1-workspace-a-test-key';
const keyB = 'sk-or-v1-workspace-b-test-key';
type Options = Omit<Parameters<typeof buildServer>[0], 'store' | 'token'>;
async function fixture(options: Options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'neon-workspaces-'));
  const path = join(directory, 'data.sqlite');
  const encryptionKey = randomBytes(32);
  const store = new Store(path, encryptionKey);
  store.setKey(store.serverID, legacyKey);
  const app = await buildServer({ store, token: owner, startWorker: false, validateKey: async () => {}, ...options });
  return { store, app, path, encryptionKey, cleanup: async () => { await app.close(); store.close(); rmSync(directory, { recursive: true, force: true }); } };
}
async function session(f: Awaited<ReturnType<typeof fixture>>, key: string, deviceId: string = randomUUID()) {
  const response = await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key, deviceId } });
  assert.equal(response.statusCode, 200, response.body);
  const result = response.json<{ token: string; serverId: string }>();
  return { ...result, deviceId, headers: { authorization: `Bearer ${result.token}`, 'x-openchat-server-id': result.serverId } };
}
async function until(predicate: () => boolean) {
  for (let i = 0; i < 300; i++) { if (predicate()) return; await delay(10); }
  assert.fail('Timed out');
}

test('key-only sessions share one workspace across devices and keep credentials encrypted or hashed', async () => {
  const f = await fixture();
  try {
    const first = await session(f, keyA);
    const retry = await session(f, keyA, first.deviceId.toUpperCase());
    const second = await session(f, keyA);
    const other = await session(f, keyB);
    assert.equal(first.token, retry.token);
    assert.equal(first.serverId, retry.serverId);
    assert.equal(first.serverId, second.serverId);
    assert.notEqual(first.token, second.token);
    assert.notEqual(first.serverId, other.serverId);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS count FROM sessions WHERE workspaceId=?').get(first.serverId)!.count, 2);
    const persisted = JSON.stringify(f.store.db.prepare('SELECT * FROM sessions').all());
    assert.ok(!persisted.includes(first.token));
    assert.ok(!readFileSync(f.path).includes(Buffer.from(keyA)));
    assert.ok(!JSON.stringify(f.store.db.prepare('SELECT * FROM workspaces').all()).includes(keyA));
    assert.deepEqual((await f.app.inject({ url: '/v1/settings/openrouter-key', headers: first.headers })).json(), { configured: true });
    assert.equal((await f.app.inject({ url: '/v1/capabilities', headers: other.headers })).json().serverId, other.serverId);
  } finally { await f.cleanup(); }
});

test('existing owner credentials and the existing provider key resolve only to the preserved legacy workspace', async () => {
  const f = await fixture();
  try {
    const thread = randomUUID();
    f.store.createThread(f.store.serverID, thread, 'Legacy private history');
    const legacy = await session(f, legacyKey);
    const fresh = await session(f, keyA);
    assert.equal(legacy.serverId, f.store.serverID);
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: legacy.headers })).json()[0].id, thread);
    assert.deepEqual((await f.app.inject({ url: '/v1/threads', headers: fresh.headers })).json(), []);
    const ownerHeaders = { authorization: `Bearer ${owner}`, 'x-openchat-server-id': f.store.serverID };
    assert.equal((await f.app.inject({ url: '/v1/capabilities', headers: ownerHeaders })).json().serverId, f.store.serverID);
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: ownerHeaders })).json().length, 1);
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: { ...fresh.headers, 'x-openchat-server-id': legacy.serverId } })).statusCode, 409);
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: { authorization: 'Bearer invalid' } })).statusCode, 401);
  } finally { await f.cleanup(); }
});

test('every conversation and job route rejects a foreign workspace before reads or mutations', async () => {
  const f = await fixture({ push: async () => 'sent' });
  try {
    const a = await session(f, keyA); const b = await session(f, keyB);
    const threadA = randomUUID(); const threadB = randomUUID();
    f.store.createThread(a.serverId, threadA, 'A private prompt');
    f.store.createThread(b.serverId, threadB, 'B private prompt');
    const runningA = f.store.enqueue(a.serverId, threadA, randomUUID(), 'Private A question', 'auto');
    const queuedA = f.store.enqueue(a.serverId, threadA, randomUUID(), 'Private A queued', 'auto');
    f.store.claim(); f.store.append(runningA.id, 'Private A partial');
    const runningB = f.store.enqueue(b.serverId, threadB, randomUUID(), 'B question', 'auto'); f.store.claim();
    const beforeA = JSON.stringify(f.store.jobs(a.serverId, threadA));
    const beforeB = JSON.stringify(f.store.jobs(b.serverId, threadB));
    const cases = [
      { method: 'GET' as const, url: `/v1/threads/${threadA}` },
      { method: 'GET' as const, url: `/v1/jobs/${runningA.id}` },
      { method: 'GET' as const, url: `/v1/jobs/${runningA.id}/events` },
      { method: 'DELETE' as const, url: `/v1/jobs/${queuedA.id}` },
      { method: 'POST' as const, url: `/v1/threads/${threadA}/messages`, payload: { id: randomUUID(), prompt: 'Attack', model: 'auto', steer: true } },
      { method: 'POST' as const, url: `/v1/threads/${threadA}/stop`, payload: {} },
      { method: 'POST' as const, url: `/v1/threads/${threadA}/archive` },
      { method: 'POST' as const, url: `/v1/threads/${threadA}/resume` },
      { method: 'POST' as const, url: `/v1/threads/${threadA}/fork`, payload: { targetJobId: runningA.id, threadId: randomUUID(), jobId: randomUUID(), prompt: 'Attack' } },
      { method: 'POST' as const, url: '/v1/threads', payload: { id: threadA, title: 'Steal thread ID' } },
      { method: 'POST' as const, url: `/v1/threads/${threadB}/messages`, payload: { id: runningA.id, prompt: 'Steal job ID', model: 'auto', steer: true } },
      { method: 'POST' as const, url: `/v1/threads/${threadB}/fork`, payload: { targetJobId: runningA.id, threadId: randomUUID(), jobId: randomUUID(), prompt: 'Foreign source' } },
      { method: 'POST' as const, url: `/v1/threads/${threadB}/fork`, payload: { targetJobId: runningB.id, threadId: threadA, jobId: randomUUID(), prompt: 'Foreign branch ID' } },
      { method: 'POST' as const, url: `/v1/threads/${threadB}/fork`, payload: { targetJobId: runningB.id, threadId: randomUUID(), jobId: runningA.id, prompt: 'Foreign job ID' } },
    ];
    for (const request of cases) {
      const response = await f.app.inject({ ...request, headers: b.headers });
      assert.equal(response.statusCode, 404, `${request.method} ${request.url}: ${response.body}`);
      assert.ok(!response.body.includes('Private A'));
    }
    assert.equal(JSON.stringify(f.store.jobs(a.serverId, threadA)), beforeA);
    assert.equal(JSON.stringify(f.store.jobs(b.serverId, threadB)), beforeB);
    assert.deepEqual((await f.app.inject({ url: '/v1/threads', headers: b.headers })).json().map((t: { id: string }) => t.id), [threadB]);
  } finally { await f.cleanup(); }
});

test('provider-key replacement retains history and sessions, removes old discovery, and rejects a claimed key', async () => {
  const f = await fixture();
  try {
    const a = await session(f, keyA); const b = await session(f, keyB);
    const thread = randomUUID(); f.store.createThread(a.serverId, thread, 'Retain this history');
    const conflict = await f.app.inject({ method: 'PUT', url: '/v1/settings/openrouter-key', headers: a.headers, payload: { key: keyB } });
    assert.equal(conflict.statusCode, 409);
    assert.equal(f.store.getKey(a.serverId), keyA);
    const replacement = 'sk-or-v1-workspace-a-replacement';
    assert.equal((await f.app.inject({ method: 'PUT', url: '/v1/settings/openrouter-key', headers: a.headers, payload: { key: replacement } })).statusCode, 200);
    assert.equal((await session(f, replacement)).serverId, a.serverId);
    assert.notEqual((await session(f, keyA)).serverId, a.serverId);
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: a.headers })).json()[0].id, thread);
    assert.equal(f.store.getKey(b.serverId), keyB);
    assert.deepEqual((await f.app.inject({ method: 'PUT', url: '/v1/settings/openrouter-key', headers: a.headers, payload: { key: '' } })).json(), { configured: false });
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: a.headers })).statusCode, 200);
    assert.notEqual((await session(f, replacement)).serverId, a.serverId);
    assert.equal((await f.app.inject({ method: 'POST', url: `/v1/threads/${thread}/messages`, headers: a.headers, payload: { id: randomUUID(), prompt: 'No configured key', model: 'auto' } })).statusCode, 409);
  } finally { await f.cleanup(); }
});

test('device registration and completion notifications cannot cross workspace boundaries', async () => {
  const f = await fixture({ push: async () => 'sent' });
  try {
    const a = await session(f, keyA); const b = await session(f, keyB);
    const deviceA = randomUUID(); const deviceB = randomUUID();
    f.store.registerDevice(a.serverId, deviceA, 'a'.repeat(64));
    f.store.registerDevice(b.serverId, deviceB, 'b'.repeat(64));
    assert.equal((await f.app.inject({ method: 'PUT', url: `/v1/devices/${deviceA}`, headers: b.headers, payload: { token: 'c'.repeat(64) } })).statusCode, 404);
    assert.equal((await f.app.inject({ method: 'DELETE', url: `/v1/devices/${deviceA}`, headers: b.headers })).statusCode, 404);
    assert.equal((await f.app.inject({ method: 'PUT', url: `/v1/devices/${randomUUID()}`, headers: b.headers, payload: { token: 'a'.repeat(64) } })).statusCode, 409);
    const thread = randomUUID(); f.store.createThread(a.serverId, thread, 'A');
    const job = f.store.enqueue(a.serverId, thread, randomUUID(), 'A answer', 'auto'); f.store.claim(); f.store.finish(job.id, 'complete');
    assert.deepEqual(f.store.db.prepare('SELECT deviceId FROM notifications').all().map(n => n.deviceId), [deviceA]);
    const received: Notice[] = [];
    await new Notifications(f.store, async notice => { received.push(notice); return 'sent'; }).tick();
    assert.equal(received[0]!.serverId, a.serverId);
    assert.equal(received[0]!.token, 'a'.repeat(64));
    // Even a corrupted cross-workspace outbox row cannot be delivered.
    f.store.db.prepare('INSERT INTO notifications(jobId,deviceId) VALUES(?,?)').run(job.id, deviceB);
    await new Notifications(f.store, async notice => { received.push(notice); return 'sent'; }).tick();
    assert.equal(received.length, 1);
    f.store.deleteDevice(a.serverId, deviceA);
    f.store.registerDevice(b.serverId, deviceA, 'a'.repeat(64));
    assert.equal((await f.app.inject({ method: 'DELETE', url: `/v1/devices/${deviceA}`, headers: a.headers })).statusCode, 404);
    assert.equal(f.store.db.prepare('SELECT workspaceId FROM devices WHERE id=?').get(deviceA)!.workspaceId, b.serverId);
  } finally { await f.cleanup(); }
});

test('one global worker budget uses the correct workspace key and history for every job', async () => {
  let active = 0; let peak = 0;
  const calls: { key: string; prompts: string[] }[] = [];
  const provider: Generate = async function* (key, _model, history) {
    active++; peak = Math.max(peak, active); calls.push({ key, prompts: history.map(m => m.content) });
    try { await delay(80); yield key === keyA ? 'A answer' : 'B answer'; } finally { active--; }
  };
  const f = await fixture({ provider, startWorker: true });
  try {
    const a = await session(f, keyA); const b = await session(f, keyB);
    const jobs: string[] = [];
    for (const [workspace, key] of [[a, keyA], [b, keyB]] as const) {
      for (let i = 0; i < 3; i++) {
        const thread = randomUUID(); f.store.createThread(workspace.serverId, thread, key);
        jobs.push(f.store.enqueue(workspace.serverId, thread, randomUUID(), `${key} prompt ${i}`, 'auto').id);
      }
    }
    await until(() => jobs.every(id => f.store.workerJob(id).status === 'complete'));
    assert.equal(peak, 2);
    assert.equal(calls.length, 6);
    for (const call of calls) assert.ok(call.prompts.every(prompt => prompt.startsWith(call.key)));
  } finally { await f.cleanup(); }
});

test('invalid keys, validation failures, and malformed setup never create workspaces or leak errors', async () => {
  let validations = 0;
  const f = await fixture({ validateKey: async key => { validations++; if (key.includes('invalid')) throw new APIError(401, 'OpenRouter rejected this API key'); throw new Error('private-upstream-error'); } });
  try {
    for (const key of ['a'.repeat(64), 'sk-or-key with spaces', '']) {
      assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key, deviceId: randomUUID() } })).statusCode, 400);
    }
    assert.equal(validations, 0);
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: 'sk-or-v1-invalid', deviceId: randomUUID() } })).statusCode, 401);
    const unavailable = await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyA, deviceId: randomUUID() } });
    assert.equal(unavailable.statusCode, 503);
    assert.ok(!unavailable.body.includes('private-upstream'));
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS count FROM workspaces').get()!.count, 1);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS count FROM sessions').get()!.count, 0);
  } finally { await f.cleanup(); }
});

test('key-validation concurrency and per-IP session rate limits bound public provisioning', async () => {
  let release!: () => void; let started = 0;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const f = await fixture({ validateKey: async () => { started++; await gate; } });
  try {
    const pending = Array.from({ length: 4 }, () => f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyA, deviceId: randomUUID() } }));
    await until(() => started === 4);
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 429);
    release(); await Promise.all(pending);
    for (let i = 0; i < 5; i++) assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 200);
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 429);
  } finally { release(); await f.cleanup(); }
});

test('default OpenRouter validation checks metadata without generation and sanitizes provider failures', async () => {
  const originalFetch = globalThis.fetch;
  try {
    let requested = '';
    globalThis.fetch = async (input, init) => { requested = String(input); assert.equal(init?.method, undefined); return Response.json({ data: { label: 'test' } }); };
    await validateKey(keyA); assert.equal(requested, 'https://openrouter.ai/api/v1/key');
    globalThis.fetch = async () => new Response('private-provider-body', { status: 401 });
    await assert.rejects(validateKey(keyA), (error: unknown) => error instanceof APIError && error.statusCode === 401 && !error.message.includes('private-provider'));
    globalThis.fetch = async () => { throw new Error('private-network-details'); };
    await assert.rejects(validateKey(keyA), (error: unknown) => error instanceof APIError && error.statusCode === 503 && !error.message.includes('private-network'));
  } finally { globalThis.fetch = originalFetch; }
});

test('schema v2 migration retains original identity, encrypted key, queue, archive flags and device outbox', () => {
  const directory = mkdtempSync(join(tmpdir(), 'neon-v2-'));
  const path = join(directory, 'data.sqlite'); const encryptionKey = randomBytes(32);
  const serverId = randomUUID(); const thread = randomUUID(); const archived = randomUUID(); const running = randomUUID(); const queued = randomUUID(); const device = randomUUID();
  const old = new DatabaseSync(path);
  old.exec(`PRAGMA foreign_keys=ON;
    CREATE TABLE metadata(name TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE secrets(name TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT NOT NULL,paused INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 0,archived INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE jobs(id TEXT PRIMARY KEY,threadId TEXT NOT NULL REFERENCES threads(id),position INTEGER NOT NULL,prompt TEXT NOT NULL,model TEXT NOT NULL,status TEXT NOT NULL,content TEXT NOT NULL DEFAULT '',error TEXT,created INTEGER NOT NULL,updated INTEGER NOT NULL);
    CREATE TABLE devices(id TEXT PRIMARY KEY,token TEXT NOT NULL UNIQUE);
    CREATE TABLE notifications(id INTEGER PRIMARY KEY,jobId TEXT NOT NULL REFERENCES jobs(id),deviceId TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,attempts INTEGER NOT NULL DEFAULT 0,nextAttempt INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL DEFAULT 'pending',UNIQUE(jobId,deviceId));
    PRAGMA user_version=2;`);
  const iv = randomBytes(12); const cipher = createCipheriv('aes-256-gcm', encryptionKey, iv);
  const encrypted = Buffer.concat([cipher.update(legacyKey), cipher.final()]);
  const keyCipher = Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64');
  old.prepare('INSERT INTO metadata VALUES(?,?)').run('server-id', serverId);
  old.prepare('INSERT INTO secrets VALUES(?,?)').run('openrouter', keyCipher);
  old.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?)').run(thread, 'Old history', 1, 1, 42, 0);
  old.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?)').run(archived, 'Old archive', 1, 1, 73, 1);
  old.prepare('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?)').run(running, thread, 1, 'Old prompt', 'auto', 'running', 'Committed partial', null, 1, 2);
  old.prepare('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?)').run(queued, thread, 2, 'Queued prompt', 'auto', 'queued', '', null, 2, 2);
  old.prepare('INSERT INTO devices VALUES(?,?)').run(device, 'd'.repeat(64));
  old.prepare('INSERT INTO notifications(jobId,deviceId,attempts) VALUES(?,?,?)').run(running, device, 3);
  old.close();
  const migrated = new Store(path, encryptionKey);
  try {
    assert.equal(migrated.serverID, serverId);
    assert.equal(migrated.db.prepare('PRAGMA user_version').get()!.user_version, 8);
    assert.equal(migrated.getKey(serverId), legacyKey);
    assert.equal(migrated.db.prepare('SELECT keyCipher FROM workspaces WHERE id=?').get(serverId)!.keyCipher, keyCipher);
    assert.equal(migrated.db.prepare('SELECT COUNT(*) AS count FROM secrets').get()!.count, 0);
    assert.equal(migrated.thread(serverId, thread).revision, 42);
    assert.equal(migrated.thread(serverId, archived, true).archived, 1);
    assert.equal(migrated.thread(serverId, archived, true).revision, 73);
    assert.throws(() => migrated.thread(serverId, archived), (error: unknown) => error instanceof APIError && error.statusCode === 410);
    assert.equal(migrated.job(serverId, running).content, 'Committed partial');
    assert.equal(migrated.job(serverId, queued).status, 'queued');
    assert.equal(migrated.db.prepare('SELECT attempts FROM notifications').get()!.attempts, 3);
    assert.equal(migrated.createSession(legacyKey, randomUUID()).serverId, serverId);
    migrated.recover(); assert.equal(migrated.job(serverId, running).status, 'stopped');
    assert.equal(migrated.thread(serverId, thread).paused, 1);
  } finally { migrated.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('invalid replacement keys return 422 without invalidating the Neon session or changing history', async () => {
  const f = await fixture({ validateKey: async key => { if (key.endsWith('invalid')) throw new APIError(401, 'Rejected'); } });
  try {
    const a = await session(f, keyA);
    const thread = randomUUID(); f.store.createThread(a.serverId, thread, 'Keep current history');
    const result = await f.app.inject({ method: 'PUT', url: '/v1/settings/openrouter-key', headers: a.headers, payload: { key: 'sk-or-v1-invalid' } });
    assert.equal(result.statusCode, 422);
    assert.equal(f.store.getKey(a.serverId), keyA);
    assert.equal((await session(f, keyA)).serverId, a.serverId);
    assert.equal((await f.app.inject({ url: `/v1/threads/${thread}`, headers: a.headers })).statusCode, 200);
    assert.equal((await f.app.inject({ method: 'PUT', url: '/v1/settings/openrouter-key', headers: { authorization: 'Bearer invalid-session' }, payload: { key: keyA } })).statusCode, 401);
  } finally { await f.cleanup(); }
});

test('workspace and device-session caps preserve existing sessions and reject further provisioning', async () => {
  const f = await fixture();
  try {
    const first = f.store.createSession(keyA, randomUUID());
    const deviceId = randomUUID(); const retained = f.store.createSession(keyA, deviceId);
    for (let i = 2; i < 100; i++) f.store.createSession(keyA, randomUUID());
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 429);
    const retry = await session(f, keyA, deviceId);
    assert.equal(retry.token, retained.token);
    assert.equal(f.store.authenticateSession(first.token), first.serverId);
    f.store.transaction(() => {
      const insert = f.store.db.prepare('INSERT INTO workspaces VALUES(?,NULL,NULL,?)');
      for (let i = 2; i < 1000; i++) insert.run(randomUUID(), Date.now());
    });
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', payload: { key: keyB, deviceId: randomUUID() } })).statusCode, 503);
    assert.equal((await session(f, keyA, deviceId)).token, retained.token);
  } finally { await f.cleanup(); }
});

test('a v3 schema committed before legacy backfill safely resumes ownership and key migration', () => {
  const directory = mkdtempSync(join(tmpdir(), 'neon-backfill-'));
  const path = join(directory, 'data.sqlite'); const encryptionKey = randomBytes(32);
  const initial = new Store(path, encryptionKey);
  const serverId = initial.serverID; const thread = randomUUID(); const device = randomUUID();
  initial.setKey(serverId, legacyKey); initial.createThread(serverId, thread, 'Existing'); initial.registerDevice(serverId, device, 'e'.repeat(64));
  initial.transaction(() => {
    const payload = initial.db.prepare('SELECT keyCipher FROM workspaces WHERE id=?').get(serverId)!.keyCipher as string;
    initial.db.prepare('INSERT INTO secrets VALUES(?,?)').run('openrouter', payload);
    initial.db.exec('ALTER TABLE jobs DROP COLUMN images; ALTER TABLE jobs DROP COLUMN reasoningEffort; ALTER TABLE jobs DROP COLUMN responseModel; ALTER TABLE jobs DROP COLUMN inputTokens; ALTER TABLE jobs DROP COLUMN outputTokens; ALTER TABLE jobs DROP COLUMN totalTokens; ALTER TABLE jobs DROP COLUMN costUSD; ALTER TABLE threads DROP COLUMN pinned; PRAGMA user_version=3; UPDATE threads SET workspaceId=NULL; UPDATE devices SET workspaceId=NULL; DELETE FROM workspaces;');
    initial.db.prepare('DELETE FROM metadata WHERE name=?').run('workspace-backfill-v1');
  });
  initial.close();
  const resumed = new Store(path, encryptionKey);
  try {
    assert.equal(resumed.thread(serverId, thread).title, 'Existing');
    assert.equal(resumed.getKey(serverId), legacyKey);
    assert.equal(resumed.db.prepare('SELECT workspaceId FROM devices WHERE id=?').get(device)!.workspaceId, serverId);
    assert.equal(resumed.db.prepare('SELECT value FROM metadata WHERE name=?').get('workspace-backfill-v1')!.value, 'complete');
  } finally { resumed.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('only configured proxy sockets may supply independent client rate-limit identities', async () => {
  const f = await fixture({ trustedProxyIps: ['172.19.0.5'] });
  const request = (ip: string) => f.app.inject({ method: 'POST', url: '/v1/sessions', remoteAddress: '::ffff:172.19.0.5', headers: { 'x-neon-client-ip': ip }, payload: { key: keyA, deviceId: randomUUID() } });
  try {
    for (let i = 0; i < 10; i++) assert.equal((await request('198.51.100.1')).statusCode, 200);
    assert.equal((await request('198.51.100.1')).statusCode, 429);
    assert.equal((await request('198.51.100.2')).statusCode, 200);
    assert.equal((await request('2001:db8::2')).statusCode, 200);
  } finally { await f.cleanup(); }
});

test('untrusted sockets and malformed proxy headers cannot evade the client rate limit', async () => {
  for (const trustedProxyIps of [[], ['172.19.0.5']]) {
    const f = await fixture({ trustedProxyIps });
    try {
      for (let i = 0; i < 10; i++) {
        assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', remoteAddress: '192.0.2.4', headers: { 'x-neon-client-ip': `198.51.100.${i}`, 'x-forwarded-for': `203.0.113.${i}` }, payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 200);
      }
      assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', remoteAddress: '192.0.2.4', headers: { 'x-neon-client-ip': '198.51.100.240', 'x-forwarded-for': '203.0.113.240' }, payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 429);
    } finally { await f.cleanup(); }
  }
  const f = await fixture({ trustedProxyIps: ['172.19.0.5'] });
  try {
    for (let i = 0; i < 10; i++) {
      const header = i % 2 ? 'invalid' : '198.51.100.1,198.51.100.2';
      assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', remoteAddress: '172.19.0.5', headers: { 'x-neon-client-ip': header }, payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 200);
    }
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/sessions', remoteAddress: '172.19.0.5', headers: { 'x-neon-client-ip': ['198.51.100.1', '198.51.100.2'] }, payload: { key: keyA, deviceId: randomUUID() } })).statusCode, 429);
  } finally { await f.cleanup(); }
});
