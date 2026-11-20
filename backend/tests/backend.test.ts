import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { APIError, Store } from '../src/db.js';
import { Worker } from '../src/worker.js';
import { Notifications, type Notice } from '../src/push.js';
import { buildServer } from '../src/server.js';
import { sseData, type Generate } from '../src/openrouter.js';

const token = 'test-only-owner-token-with-32-characters';
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'openchat-'));
  const path = join(dir, 'db.sqlite'); const key = randomBytes(32);
  const store = new Store(path, key); store.setKey(store.serverID, 'private-test-provider-key');
  const thread = randomUUID(); store.createThread(store.serverID, thread, 'Test');
  return { store, thread, path, key, cleanup: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}
async function until(predicate: () => boolean) {
  for (let i = 0; i < 300; i++) { if (predicate()) return; await delay(10); }
  assert.fail('Timed out');
}

test('persisted API key is authenticated ciphertext, decrypts after restart, and rejects wrong key', () => {
  const f = fixture();
  try {
    assert.equal(f.store.getKey(f.store.serverID), 'private-test-provider-key');
    const value = f.store.db.prepare('SELECT keyCipher AS value FROM workspaces').get()!.value as string;
    assert.ok(!value.includes('private-test'));
    assert.ok(!readFileSync(f.path).includes(Buffer.from('private-test-provider-key')));
    const reopened = new Store(f.path, f.key);
    assert.equal(reopened.getKey(reopened.serverID), 'private-test-provider-key'); reopened.close();
    const wrong = new Store(f.path, randomBytes(32));
    assert.throws(() => wrong.getKey(wrong.serverID)); wrong.close();
    f.store.setKey(f.store.serverID, ''); assert.throws(() => f.store.getKey(f.store.serverID), APIError);
  } finally { f.cleanup(); }
});

test('send retries are idempotent; conflicting IDs fail without duplicating paid work', () => {
  const f = fixture();
  try {
    const id = randomUUID();
    f.store.enqueue(f.store.serverID, f.thread, id, 'Hello', 'model/one');
    f.store.enqueue(f.store.serverID, f.thread, id, 'Hello', 'model/one');
    assert.equal(f.store.jobs(f.store.serverID, f.thread).length, 1);
    assert.throws(() => f.store.enqueue(f.store.serverID, f.thread, id, 'Changed', 'model/one'), /different content/);
  } finally { f.cleanup(); }
});

test('queue maintains turn order, captures selected model, and excludes unsent prompts', () => {
  const f = fixture();
  try {
    const one = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'model/one');
    const two = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Second', 'model/two');
    assert.equal(f.store.claim()!.id, one.id);
    assert.equal(f.store.claim(), undefined);
    assert.deepEqual(f.store.history(one), [{ role: 'user', content: 'First' }]);
    f.store.append(one.id, 'Answer one'); f.store.finish(one.id, 'complete');
    assert.equal(f.store.claim()!.id, two.id);
    assert.equal(two.model, 'model/two');
    assert.deepEqual(f.store.history(two).map(m => m.content), ['First', 'Answer one', 'Second']);
  } finally { f.cleanup(); }
});

test('stop pauses queue and rejects late output; steering runs before existing follow-ups', () => {
  const f = fixture();
  try {
    const one = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'auto'); f.store.claim();
    f.store.append(one.id, 'Partial');
    const two = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Later', 'auto');
    f.store.stop(f.store.serverID, f.thread);
    assert.equal(f.store.claim(), undefined);
    assert.equal(f.store.append(one.id, 'LATE'), false);
    f.store.finish(one.id, 'complete');
    assert.equal(f.store.job(f.store.serverID, one.id).status, 'stopped');
    const steer = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'New direction', 'auto', true);
    assert.equal(f.store.claim()!.id, steer.id);
    assert.deepEqual(f.store.history(steer).map(m => m.content), ['First', 'Partial', 'New direction']);
    f.store.finish(steer.id, 'complete');
    assert.equal(f.store.claim()!.id, two.id);
  } finally { f.cleanup(); }
});

test('repeated steer request cannot stop a replacement or reorder its queue', () => {
  const f = fixture();
  try {
    const steer = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Direction', 'auto', true);
    f.store.claim(); f.store.append(steer.id, 'Started');
    f.store.enqueue(f.store.serverID, f.thread, steer.id, steer.prompt, steer.model, true);
    assert.equal(f.store.job(f.store.serverID, steer.id).status, 'running');
  } finally { f.cleanup(); }
});

test('failure pauses queued follow-ups until explicit resume', () => {
  const f = fixture();
  try {
    const first = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'auto');
    const next = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Next', 'auto');
    f.store.claim(); f.store.finish(first.id, 'failed', 'Provider error');
    assert.equal(f.store.claim(), undefined);
    f.store.resume(f.store.serverID, f.thread); assert.equal(f.store.claim()!.id, next.id);
  } finally { f.cleanup(); }
});

test('restart preserves partial output and does not replay an interrupted paid request', () => {
  const f = fixture();
  try {
    const one = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'auto');
    f.store.claim(); f.store.append(one.id, 'Saved partial');
    f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Pending', 'auto');
    f.store.recover();
    assert.equal(f.store.job(f.store.serverID, one.id).content, 'Saved partial');
    assert.equal(f.store.job(f.store.serverID, one.id).status, 'stopped'); assert.equal(f.store.claim(), undefined);
    f.store.resume(f.store.serverID, f.thread); assert.equal(f.store.claim()!.prompt, 'Pending');
  } finally { f.cleanup(); }
});

test('worker recovers a stale owner PID and excludes concurrent owners until close', async () => {
  const f = fixture();
  const worker = new Worker(f.store);
  const reopened = new Store(f.path, f.key);
  const replacement = new Worker(reopened);
  try {
    f.store.db.exec('CREATE TABLE runtime_lock(id INTEGER PRIMARY KEY, pid INTEGER NOT NULL, instance TEXT NOT NULL)');
    f.store.db.prepare('INSERT INTO runtime_lock VALUES(1,?,?)').run(process.pid, 'stale-container-instance');
    const job = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Interrupted', 'auto');
    f.store.claim(); f.store.append(job.id, 'Saved partial');
    worker.start();
    assert.equal(f.store.job(f.store.serverID, job.id).status, 'stopped');
    assert.equal(f.store.job(f.store.serverID, job.id).content, 'Saved partial');
    assert.throws(() => replacement.start(), /Another backend/);
    await worker.close();
    replacement.start();
    assert.equal(reopened.job(reopened.serverID, job.id).status, 'stopped');
  } finally { await replacement.close(); await worker.close(); reopened.close(); f.cleanup(); }
});

test('worker ownership releases after a process is killed', { timeout: 10_000 }, async () => {
  const f = fixture();
  const child = spawn(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', `
    import { Store } from ${JSON.stringify(new URL('../src/db.ts', import.meta.url).href)};
    import { Worker } from ${JSON.stringify(new URL('../src/worker.ts', import.meta.url).href)};
    const store = new Store(process.argv[1], Buffer.from(process.argv[2], 'hex'));
    new Worker(store).start();
    console.log('ready');
    setInterval(() => {}, 1000);
  `, f.path, f.key.toString('hex')], { stdio: ['ignore', 'pipe', 'inherit'] });
  const exited = once(child, 'exit');
  const replacement = new Worker(f.store);
  try {
    const [output] = await once(child.stdout, 'data');
    assert.equal(output.toString().trim(), 'ready');
    assert.throws(() => replacement.start(), /Another backend/);
    child.kill('SIGKILL');
    await exited;
    replacement.start();
  } finally {
    child.kill('SIGKILL');
    await exited;
    await replacement.close(); f.cleanup();
  }
});

test('editing forks prior history without changing the original conversation', () => {
  const f = fixture();
  try {
    const one = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'One', 'auto'); f.store.claim();
    f.store.append(one.id, 'Answer'); f.store.finish(one.id, 'complete');
    const two = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Old two', 'auto');
    const forkId = randomUUID();
    const edited = f.store.fork(f.store.serverID, f.thread, two.id, forkId, randomUUID(), 'New two');
    assert.deepEqual(f.store.history(edited).map(m => m.content), ['One', 'Answer', 'New two']);
    assert.equal(f.store.jobs(f.store.serverID, f.thread)[1]!.prompt, 'Old two');
    assert.throws(() => f.store.fork(f.store.serverID, f.thread, two.id, forkId, randomUUID(), 'Again'), /already exists/);
  } finally { f.cleanup(); }
});

test('SSE decoder handles byte-split Unicode, CRLF, comments, and multiline data', async () => {
  const encoded = new TextEncoder().encode(': keepalive\r\ndata: hello 🙂\r\ndata: second\r\n\r\ndata: [DONE]\n\n');
  async function* chunks() { for (const byte of encoded) yield new Uint8Array([byte]); }
  const data = []; for await (const event of sseData(chunks())) data.push(event);
  assert.deepEqual(data, ['hello 🙂\nsecond', '[DONE]']);
});

test('worker completes queued turns serially with canonical server history', async () => {
  const f = fixture();
  const history: string[][] = [];
  const provider: Generate = async function* (_key, _model, messages) { history.push(messages.map(m => m.content)); yield 'Answer'; yield ' 🙂'; };
  const worker = new Worker(f.store, provider);
  try {
    const one = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'auto');
    const two = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Second', 'auto');
    worker.start();
    await until(() => f.store.job(f.store.serverID, two.id).status === 'complete');
    assert.equal(f.store.job(f.store.serverID, one.id).content, 'Answer 🙂');
    assert.deepEqual(history, [['First'], ['First', 'Answer 🙂', 'Second']]);
    assert.throws(() => new Worker(f.store, provider).start(), /Another backend/);
  } finally { await worker.close(); f.cleanup(); }
});

test('provider failure saves partial output and does not leak raw provider errors', async () => {
  const f = fixture();
  const provider: Generate = async function* () { yield 'Partial'; throw new Error('private-test-provider-key'); };
  const worker = new Worker(f.store, provider);
  try {
    const job = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Hello', 'auto'); worker.start();
    await until(() => f.store.job(f.store.serverID, job.id).status === 'failed');
    assert.equal(f.store.job(f.store.serverID, job.id).content, 'Partial');
    assert.ok(!f.store.job(f.store.serverID, job.id).error!.includes('private-test'));
  } finally { await worker.close(); f.cleanup(); }
});

test('completion outbox is durable, deduplicated, retries failures, removes invalid tokens', async () => {
  const f = fixture();
  try {
    const device = randomUUID(); f.store.registerDevice(f.store.serverID, device, 'a'.repeat(64));
    const job = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Hi', 'auto'); f.store.claim();
    f.store.finish(job.id, 'complete'); f.store.finish(job.id, 'complete');
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 1);
    const failed = new Notifications(f.store, async () => { throw new Error('Offline'); });
    await failed.tick();
    const row = f.store.db.prepare('SELECT * FROM notifications').get()!;
    assert.equal(row.attempts, 1); assert.equal(row.state, 'pending');
    f.store.db.exec('UPDATE notifications SET nextAttempt=0');
    const received: Notice[] = [];
    const sent = new Notifications(f.store, async n => { received.push(n); return 'sent'; });
    await sent.tick(); await sent.tick();
    assert.equal(received.length, 1);
    f.store.db.exec("UPDATE notifications SET state='pending',nextAttempt=0");
    await new Notifications(f.store, async () => 'invalid').tick();
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM devices').get()!.n, 0);
  } finally { f.cleanup(); }
});

test('API authenticates requests, validates bodies, and replays durable SSE by cursor', async () => {
  const f = fixture(); const app = await buildServer({ store: f.store, token, startWorker: false });
  const headers = { authorization: `Bearer ${token}` };
  try {
    assert.equal((await app.inject('/health')).statusCode, 200);
    assert.equal((await app.inject('/v1/threads')).statusCode, 401);
    assert.equal((await app.inject({ url: '/v1/threads', headers })).statusCode, 200);
    assert.equal((await app.inject({ method: 'POST', url: '/v1/threads', headers, payload: { id: 'bad', title: 'Test' } })).statusCode, 400);
    const id = randomUUID();
    const request = { method: 'POST' as const, url: `/v1/threads/${f.thread}/messages`, headers, payload: { id, prompt: 'Hello', model: 'auto' } };
    assert.equal((await app.inject(request)).statusCode, 202);
    assert.equal((await app.inject(request)).statusCode, 202);
    assert.equal(f.store.jobs(f.store.serverID, f.thread).length, 1);
    f.store.claim(); f.store.append(id, 'Hello 🙂 world'); f.store.finish(id, 'complete');
    const events = await app.inject({ url: `/v1/jobs/${id}/events`, headers: { ...headers, 'last-event-id': '8' } });
    assert.equal(events.statusCode, 200);
    assert.match(events.body, /"text":" world"/);
    assert.match(events.body, /"status":"complete"/);
    assert.equal((await app.inject({ url: `/v1/jobs/${id}/events`, headers: { ...headers, 'last-event-id': '999' } })).statusCode, 409);
    assert.equal((await app.inject({ method: 'PUT', url: `/v1/devices/${randomUUID()}`, headers, payload: { token: 'a'.repeat(64) } })).statusCode, 503);
    assert.equal((await app.inject({ method: 'POST', url: '/v1/threads', headers, payload: { id: randomUUID(), title: 'Test', unexpected: true } })).statusCode, 400);
  } finally { await app.close(); f.cleanup(); }
});

test('late tokens from a stopped provider cannot contaminate the steered answer', async () => {
  const f = fixture();
  const provider: Generate = async function* (_key, _model, messages) {
    if (messages.at(-1)!.content === 'Original') { yield 'Old partial'; await delay(200); yield 'LATE OLD OUTPUT'; }
    else { yield 'New answer'; }
  };
  const worker = new Worker(f.store, provider);
  try {
    const original = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Original', 'auto'); worker.start();
    await until(() => f.store.job(f.store.serverID, original.id).content === 'Old partial');
    worker.flushThread(f.thread);
    const steer = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Steer', 'auto', true); worker.abortStopped();
    await until(() => f.store.job(f.store.serverID, steer.id).status === 'complete'); await delay(250);
    assert.equal(f.store.job(f.store.serverID, original.id).content, 'Old partial');
    assert.equal(f.store.job(f.store.serverID, original.id).status, 'stopped');
    assert.equal(f.store.job(f.store.serverID, steer.id).content, 'New answer');
  } finally { await worker.close(); f.cleanup(); }
});

test('notifications remain in the outbox across a database reopen', async () => {
  const f = fixture();
  try {
    f.store.registerDevice(f.store.serverID, randomUUID(), 'b'.repeat(64));
    const job = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Hi', 'auto'); f.store.claim(); f.store.finish(job.id, 'complete');
    const reopened = new Store(f.path, f.key);
    let count = 0;
    await new Notifications(reopened, async () => { count++; return 'sent'; }).tick();
    assert.equal(count, 1); reopened.close();
    assert.equal(f.store.db.prepare('SELECT state FROM notifications').get()!.state, 'sent');
  } finally { f.cleanup(); }
});

test('conversation revisions advance for each durable change and survive reopening', () => {
  const f = fixture();
  try {
    const before = f.store.thread(f.store.serverID, f.thread).revision as number;
    const job = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Hi', 'auto');
    const accepted = f.store.thread(f.store.serverID, f.thread).revision as number;
    assert.ok(accepted > before);
    f.store.claim(); f.store.append(job.id, 'Partial');
    const streaming = f.store.thread(f.store.serverID, f.thread).revision as number;
    assert.ok(streaming > accepted);
    f.store.finish(job.id, 'complete');
    const completed = f.store.thread(f.store.serverID, f.thread).revision as number;
    assert.ok(completed > streaming);
    const reopened = new Store(f.path, f.key);
    assert.equal(reopened.thread(reopened.serverID, f.thread).revision, completed);
    assert.equal(reopened.serverID, f.store.serverID); reopened.close();
  } finally { f.cleanup(); }
});

test('an older device cannot stop a replacement response', () => {
  const f = fixture();
  try {
    const first = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'auto'); f.store.claim();
    f.store.finish(first.id, 'complete');
    const second = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Second', 'auto'); f.store.claim();
    assert.throws(() => f.store.stop(f.store.serverID, f.thread, first.id), /response changed/);
    assert.equal(f.store.job(f.store.serverID, second.id).status, 'running');
    f.store.stop(f.store.serverID, f.thread, second.id);
    assert.equal(f.store.job(f.store.serverID, second.id).status, 'stopped');
  } finally { f.cleanup(); }
});

test('archive is idempotent, stops pending work, hides sync metadata, and prevents stale resurrection', () => {
  const f = fixture();
  try {
    f.store.registerDevice(f.store.serverID, randomUUID(), 'c'.repeat(64));
    const finished = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Finished', 'auto'); f.store.claim(); f.store.finish(finished.id, 'complete');
    const running = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Running', 'auto'); f.store.claim();
    const queued = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Queued', 'auto');
    f.store.archive(f.store.serverID, f.thread); f.store.archive(f.store.serverID, f.thread);
    assert.equal(f.store.threads(f.store.serverID).length, 0);
    assert.equal(f.store.job(f.store.serverID, running.id).status, 'stopped');
    assert.equal(f.store.job(f.store.serverID, queued.id).status, 'stopped');
    assert.equal(f.store.claim(), undefined);
    assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM notifications').get()!.n, 0);
    assert.throws(() => f.store.createThread(f.store.serverID, f.thread, 'Resurrect'), /archived/);
    assert.throws(() => f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Later', 'auto'), /archived/);
  } finally { f.cleanup(); }
});

test('Swift uppercase UUIDs round-trip through API and settings do not disclose provider keys', async () => {
  const f = fixture(); const app = await buildServer({ store: f.store, token, startWorker: false });
  const headers = { authorization: `Bearer ${token}` };
  try {
    const id = randomUUID().toUpperCase();
    const created = await app.inject({ method: 'POST', url: '/v1/threads', headers, payload: { id, title: 'Swift chat' } });
    assert.equal(created.json().id, id.toLowerCase());
    const jobID = randomUUID().toUpperCase();
    assert.equal((await app.inject({ method: 'POST', url: `/v1/threads/${id}/messages`, headers,
      payload: { id: jobID, prompt: 'Hello from Swift', model: 'auto' } })).statusCode, 202);
    assert.equal((await app.inject({ url: `/v1/jobs/${jobID}`, headers })).json().id, jobID.toLowerCase());
    const state = await app.inject({ url: '/v1/settings/openrouter-key', headers });
    assert.deepEqual(state.json(), { configured: true }); assert.ok(!state.body.includes('private-test'));
    const capabilities = (await app.inject({ url: '/v1/capabilities', headers })).json();
    assert.equal(capabilities.serverId, f.store.serverID);
    assert.equal(capabilities.conversationMetadata, true);
  } finally { await app.close(); f.cleanup(); }
});

test('notification outbox includes a stable server identity for safe cross-server deep links', async () => {
  const f = fixture();
  try {
    f.store.registerDevice(f.store.serverID, randomUUID(), 'd'.repeat(64));
    const job = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Hello', 'auto'); f.store.claim(); f.store.finish(job.id, 'complete');
    let identity: string | undefined;
    await new Notifications(f.store, async notice => { identity = notice.serverId; return 'sent'; }).tick();
    assert.equal(identity, f.store.serverID);
  } finally { f.cleanup(); }
});

test('schema v1 upgrades in place without dropping conversations or partial answers', () => {
  const directory = mkdtempSync(join(tmpdir(), 'openchat-v1-'));
  const path = join(directory, 'db.sqlite'); const id = randomUUID(); const job = randomUUID();
  const old = new DatabaseSync(path);
  old.exec(`CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT NOT NULL,paused INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL);
    CREATE TABLE jobs(id TEXT PRIMARY KEY,threadId TEXT NOT NULL REFERENCES threads(id),position INTEGER NOT NULL,prompt TEXT NOT NULL,
    model TEXT NOT NULL,status TEXT NOT NULL,content TEXT NOT NULL DEFAULT '',error TEXT,created INTEGER NOT NULL,updated INTEGER NOT NULL);
    PRAGMA user_version=1;`);
  old.prepare('INSERT INTO threads VALUES(?,?,?,?)').run(id, 'Existing conversation', 0, 1);
  old.prepare('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?)').run(job, id, 1, 'Original', 'auto', 'running', 'Existing partial', null, 1, 2);
  old.close();
  const upgraded = new Store(path, randomBytes(32));
  try {
    assert.equal(upgraded.db.prepare('PRAGMA user_version').get()!.user_version, 8);
    assert.equal(upgraded.thread(upgraded.serverID, id).title, 'Existing conversation');
    assert.equal(upgraded.job(upgraded.serverID, job).content, 'Existing partial');
    upgraded.recover();
    assert.equal(upgraded.job(upgraded.serverID, job).status, 'stopped');
    assert.ok((upgraded.thread(upgraded.serverID, id).revision as number) > 0);
  } finally { upgraded.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('conditional Stop and archive routes protect replacement work and synchronize across devices', async () => {
  const f = fixture(); const app = await buildServer({ store: f.store, token, startWorker: false });
  const headers = { authorization: `Bearer ${token}` };
  try {
    const first = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'First', 'auto'); f.store.claim(); f.store.finish(first.id, 'complete');
    const second = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Second', 'auto'); f.store.claim();
    const path = `/v1/threads/${f.thread}/stop`;
    assert.equal((await app.inject({ method: 'POST', url: path, headers, payload: { expectedJobId: first.id.toUpperCase() } })).statusCode, 409);
    assert.equal(f.store.job(f.store.serverID, second.id).status, 'running');
    assert.equal((await app.inject({ method: 'POST', url: path, headers, payload: { expectedJobId: second.id.toUpperCase() } })).statusCode, 200);
    assert.equal(f.store.job(f.store.serverID, second.id).status, 'stopped');
    assert.equal((await app.inject({ method: 'POST', url: `/v1/threads/${f.thread}/archive`, headers })).statusCode, 200);
    assert.deepEqual((await app.inject({ url: '/v1/threads', headers })).json(), []);
    assert.equal((await app.inject({ url: `/v1/threads/${f.thread}`, headers })).statusCode, 410);
  } finally { await app.close(); f.cleanup(); }
});

test('pinned server identity rejects stale device writes before settings change', async () => {
  const f = fixture(); const app = await buildServer({ store: f.store, token, startWorker: false });
  try {
    const headers: Record<string, string> = { authorization: `Bearer ${token}`, 'x-openchat-server-id': randomUUID() };
    const result = await app.inject({ method: 'PUT', url: '/v1/settings/openrouter-key', headers, payload: { key: 'wrong-server-key' } });
    assert.equal(result.statusCode, 409);
    assert.equal(f.store.getKey(f.store.serverID), 'private-test-provider-key');
    headers['x-openchat-server-id'] = f.store.serverID.toUpperCase();
    assert.equal((await app.inject({ url: '/v1/capabilities', headers })).statusCode, 200);
  } finally { await app.close(); f.cleanup(); }
});
