import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Store } from '../src/db.js';
import { buildServer } from '../src/server.js';

async function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'neon-thread-metadata-'));
  const encryptionKey = randomBytes(32);
  const path = join(directory, 'data.sqlite');
  const store = new Store(path, encryptionKey);
  const a = store.createSession('sk-or-synthetic-metadata-a', randomUUID());
  const b = store.createSession('sk-or-synthetic-metadata-b', randomUUID());
  const app = await buildServer({ store, token: 'synthetic-metadata-owner-token-at-least-32-chars', startWorker: false });
  const headers = (session: typeof a) => ({ authorization: `Bearer ${session.token}`, 'x-openchat-server-id': session.serverId });
  return { app, store, a, b, headers, path, encryptionKey, cleanup: async () => { await app.close(); store.close(); rmSync(directory, { recursive: true, force: true }); } };
}

test('thread pin and rename persist with one revision per change and idempotent create retries', async () => {
  const f = await fixture();
  try {
    const id = randomUUID();
    const created = await f.app.inject({ method: 'POST', url: '/v1/threads', headers: f.headers(f.a), payload: { id, title: '  Original title  ', pinned: true } });
    assert.equal(created.statusCode, 200);
    assert.equal(created.json().title, 'Original title');
    assert.equal(created.json().pinned, 1);
    const revision = created.json().revision;
    const retry = await f.app.inject({ method: 'POST', url: '/v1/threads', headers: f.headers(f.a), payload: { id, title: 'Other title', pinned: false } });
    assert.equal(retry.json().title, 'Original title');
    assert.equal(retry.json().pinned, 1);
    assert.equal(retry.json().revision, revision);
    const changed = await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: f.headers(f.a), payload: { title: '  Renamed title  ', pinned: false } });
    assert.equal(changed.statusCode, 200);
    assert.equal(changed.json().title, 'Renamed title');
    assert.equal(changed.json().pinned, 0);
    assert.equal(changed.json().revision, revision + 1);
    const noOp = await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: f.headers(f.a), payload: { title: 'Renamed title', pinned: false } });
    assert.equal(noOp.json().revision, revision + 1);
    const pinned = await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: f.headers(f.a), payload: { pinned: true } });
    assert.equal(pinned.json().revision, revision + 2);
    const secondDevice = f.store.createSession('sk-or-synthetic-metadata-a', randomUUID());
    assert.equal(secondDevice.serverId, f.a.serverId);
    const onOtherDevice = await f.app.inject({ url: `/v1/threads/${id}`, headers: f.headers(secondDevice) });
    assert.equal(onOtherDevice.json().pinned, 1);
    assert.equal(onOtherDevice.json().title, 'Renamed title');
    assert.equal(onOtherDevice.json().revision, revision + 2);
    assert.equal((await f.app.inject({ url: '/v1/threads', headers: f.headers(f.a) })).json()[0].pinned, 1);
    const reopened = new Store(f.path, f.encryptionKey);
    try {
      assert.equal(reopened.thread(f.a.serverId, id).pinned, 1);
      assert.equal(reopened.thread(f.a.serverId, id).title, 'Renamed title');
      assert.equal(reopened.thread(f.a.serverId, id).revision, revision + 2);
    } finally { reopened.close(); }
  } finally { await f.cleanup(); }
});

test('metadata routes reject malformed titles, empty patches and nonboolean pin values', async () => {
  const f = await fixture();
  try {
    const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Original');
    for (const payload of [{}, { title: '' }, { title: ' \n\t' }, { title: 'x'.repeat(201) }, { title: 1 }, { pinned: 1 }, { pinned: 'true' }, { pinned: null }, { title: null }, { unknown: true }, { pinned: true, unknown: 1 }]) {
      const response = await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: f.headers(f.a), payload });
      assert.equal(response.statusCode, 400, JSON.stringify(payload));
    }
    for (const payload of [{ id: randomUUID(), title: '  ' }, { id: randomUUID(), title: 'x'.repeat(201) }, { id: randomUUID(), title: 'Valid', pinned: 1 }])
      assert.equal((await f.app.inject({ method: 'POST', url: '/v1/threads', headers: f.headers(f.a), payload })).statusCode, 400);
    const original = f.store.thread(f.a.serverId, id);
    assert.equal(original.title, 'Original'); assert.equal(original.pinned, 0); assert.equal(original.revision, 0);
  } finally { await f.cleanup(); }
});

test('metadata updates require auth and owning workspace and cannot change archived conversations', async () => {
  const f = await fixture();
  try {
    const id = randomUUID(); f.store.createThread(f.a.serverId, id, 'Private title');
    assert.equal((await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, payload: { title: 'Attack' } })).statusCode, 401);
    assert.equal((await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: f.headers(f.b), payload: { title: 'Attack', pinned: true } })).statusCode, 404);
    assert.equal((await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: { ...f.headers(f.a), 'x-openchat-server-id': f.b.serverId }, payload: { pinned: true } })).statusCode, 409);
    assert.equal(f.store.thread(f.a.serverId, id).title, 'Private title');
    f.store.archive(f.a.serverId, id);
    const before = f.store.thread(f.a.serverId, id, true);
    assert.equal((await f.app.inject({ method: 'PATCH', url: `/v1/threads/${id}`, headers: f.headers(f.a), payload: { title: 'Resurrect', pinned: true } })).statusCode, 410);
    assert.deepEqual(f.store.thread(f.a.serverId, id, true), before);
  } finally { await f.cleanup(); }
});

test('v3 migration adds unpinned metadata without changing history ownership or revisions', () => {
  const directory = mkdtempSync(join(tmpdir(), 'neon-v3-pin-migration-'));
  const path = join(directory, 'data.sqlite'); const encryptionKey = randomBytes(32);
  const original = new Store(path, encryptionKey);
  const workspace = original.serverID; const id = randomUUID(); const job = randomUUID();
  original.setKey(workspace, 'sk-or-synthetic-migration');
  original.createThread(workspace, id, 'Retain title');
  original.enqueue(workspace, id, job, 'Retain prompt', 'auto');
  const revision = original.thread(workspace, id).revision;
  original.db.exec('ALTER TABLE jobs DROP COLUMN images; ALTER TABLE jobs DROP COLUMN reasoningEffort; ALTER TABLE jobs DROP COLUMN responseModel; ALTER TABLE jobs DROP COLUMN inputTokens; ALTER TABLE jobs DROP COLUMN outputTokens; ALTER TABLE jobs DROP COLUMN totalTokens; ALTER TABLE jobs DROP COLUMN costUSD; ALTER TABLE threads DROP COLUMN pinned; PRAGMA user_version=3;');
  original.close();
  const migrated = new Store(path, encryptionKey);
  try {
    assert.equal(migrated.db.prepare('PRAGMA user_version').get()!.user_version, 8);
    assert.equal(migrated.thread(workspace, id).pinned, 0);
    assert.equal(migrated.thread(workspace, id).title, 'Retain title');
    assert.equal(migrated.thread(workspace, id).revision, revision);
    assert.equal(migrated.job(workspace, job).prompt, 'Retain prompt');
    assert.equal(migrated.thread(workspace, id).workspaceId, workspace);
  } finally { migrated.close(); rmSync(directory, { recursive: true, force: true }); }
});
