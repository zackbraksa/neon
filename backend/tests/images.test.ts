import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/db.js';
import { buildServer } from '../src/server.js';
import { generate, type ChatMessage, type Generate } from '../src/openrouter.js';
import { maxImageBytes, validateImages } from '../src/images.js';
import { Worker } from '../src/worker.js';
import { setTimeout as delay } from 'node:timers/promises';

const png = 'data:image/png;base64,iVBORw0KGgo=';
const jpeg = 'data:image/jpeg;base64,/9j/2Q==';
const sizedPNG = (size: number) => {
  const data = Buffer.alloc(size); Buffer.from('89504e470d0a1a0a', 'hex').copy(data);
  return `data:image/png;base64,${data.toString('base64')}`;
};
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'neon-images-'));
  const path = join(dir, 'db.sqlite'); const key = randomBytes(32);
  const store = new Store(path, key); store.setKey(store.serverID, 'synthetic-provider-key');
  const thread = randomUUID(); store.createThread(store.serverID, thread, 'Images');
  return { store, path, key, thread, cleanup: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

test('image boundary accepts only bounded canonical base64 with matching PNG/JPEG signatures', () => {
  validateImages(undefined); validateImages([]); validateImages([png, jpeg]); validateImages([sizedPNG(maxImageBytes)]);
  for (const images of [null, png, [1], [png, png, png, png, png], ['https://example.com/image.png'],
    ['data:image/webp;base64,iVBORw0KGgo='], ['data:image/png;base64,/9j/2Q=='], ['data:image/jpeg;base64,iVBORw0KGgo='],
    ['data:image/png;base64,iVBORw0KGgo'], ['data:image/png;base64,iVBORw0KGgo=\n'],
    ['data:image/png;base64,iVBORw0KGgp='], [sizedPNG(maxImageBytes + 1)]]) {
    assert.throws(() => validateImages(images), /image|PNG|JPEG|base64/i);
  }
});

test('API accepts image-only messages, retains immutable attachment payloads and validates both routes', async () => {
  const f = fixture(); const token = 'synthetic-owner-token-with-32-characters';
  const app = await buildServer({ store: f.store, token, startWorker: false });
  const headers = { authorization: `Bearer ${token}` };
  const send = (payload: object) => app.inject({ method: 'POST', url: `/v1/threads/${f.thread}/messages`, headers, payload });
  try {
    assert.equal((await app.inject({ url: '/v1/capabilities', headers })).json().imageInputs, true);
    const payload = { id: randomUUID(), prompt: '', model: 'auto', images: [png, jpeg] };
    const accepted = await send(payload); assert.equal(accepted.statusCode, 202); assert.deepEqual(accepted.json().images, payload.images);
    assert.equal((await send(payload)).statusCode, 202);
    assert.equal((await send({ ...payload, images: [jpeg, png] })).statusCode, 409);
    assert.equal((await send({ ...payload, prompt: 'Describe', images: [] })).statusCode, 409);
    const legacy = { id: randomUUID(), prompt: 'Hello', model: 'auto' };
    assert.equal((await send(legacy)).statusCode, 202);
    assert.equal((await send({ ...legacy, images: [] })).statusCode, 202);
    for (const invalid of [{ ...payload, id: randomUUID(), images: null }, { ...payload, id: randomUUID(), images: [png, png, png, png, png] },
      { ...payload, id: randomUUID(), images: [] }, { ...payload, id: randomUUID(), images: ['https://example.com/a.png'] },
      { ...payload, id: randomUUID(), prompt: 123 }, { ...payload, id: randomUUID(), images: [sizedPNG(maxImageBytes + 1)] }]) {
      assert.equal((await send(invalid)).statusCode, 400);
    }
    assert.equal((await send({ id: randomUUID(), prompt: ' ', model: 'auto' })).statusCode, 400);
    const fork = { targetJobId: payload.id, threadId: randomUUID(), jobId: randomUUID(), prompt: '', images: [jpeg] };
    const forked = await app.inject({ method: 'POST', url: `/v1/threads/${f.thread}/fork`, headers, payload: fork });
    assert.equal(forked.statusCode, 202); assert.deepEqual(forked.json().images, [jpeg]);
    assert.equal((await app.inject({ method: 'POST', url: `/v1/threads/${f.thread}/fork`, headers, payload: { ...fork, threadId: randomUUID(), jobId: randomUUID(), images: ['data:image/png;base64,AAAA'] } })).statusCode, 400);
    const snapshot = await app.inject({ url: `/v1/threads/${fork.threadId}`, headers });
    assert.deepEqual(snapshot.json().jobs[0].images, [jpeg]);
    assert.deepEqual((await app.inject({ url: `/v1/jobs/${payload.id}`, headers })).json().images, [png, jpeg]);
    const large = await send({ id: randomUUID(), prompt: '', model: 'auto', images: Array(4).fill(sizedPNG(maxImageBytes)) });
    assert.equal(large.statusCode, 202);
    assert.equal((await send({ id: randomUUID(), prompt: 'x'.repeat(12 * 1024 * 1024), model: 'auto' })).statusCode, 413);
  } finally { await app.close(); f.cleanup(); }
});

test('provider sends text plus inline image parts while retaining text-only wire format', async t => {
  const bodies: { messages: unknown[] }[] = [];
  t.mock.method(globalThis, 'fetch', async (_url: string, options: RequestInit) => {
    bodies.push(JSON.parse(options.body as string)); return new Response('data: [DONE]\n\n');
  });
  const messages: ChatMessage[] = [{ role: 'user', content: 'Describe', images: [png, jpeg] },
    { role: 'assistant', content: 'Answer' }, { role: 'user', content: '', images: [jpeg] }, { role: 'user', content: 'Text', images: [] }];
  for await (const _chunk of generate('synthetic-key', 'auto', messages, new AbortController().signal)) { /* consume */ }
  assert.deepEqual(bodies[0]!.messages, [
    { role: 'user', content: [{ type: 'text', text: 'Describe' }, { type: 'image_url', image_url: { url: png } }, { type: 'image_url', image_url: { url: jpeg } }] },
    { role: 'assistant', content: 'Answer' }, { role: 'user', content: [{ type: 'image_url', image_url: { url: jpeg } }] }, { role: 'user', content: 'Text' },
  ]);
});

test('forks preserve prior attachments and inherit, replace or remove target attachments', () => {
  const f = fixture();
  try {
    const prior = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Prior', 'auto', false, undefined, [png]);
    f.store.claim(); f.store.append(prior.id, 'Answer'); f.store.finish(prior.id, 'complete');
    const target = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Target', 'auto', false, undefined, [jpeg]);
    for (const images of [undefined, [], [png]]) {
      const branch = randomUUID();
      const edited = f.store.fork(f.store.serverID, f.thread, target.id, branch, randomUUID(), 'Edited', images);
      assert.deepEqual(edited.images, images ?? [jpeg]);
      assert.deepEqual(f.store.jobs(f.store.serverID, branch)[0]!.images, [png]);
      assert.deepEqual(f.store.history(edited), [{ role: 'user', content: 'Prior', images: [png] }, { role: 'assistant', content: 'Answer' },
        { role: 'user', content: 'Edited', ...((images ?? [jpeg]).length ? { images: images ?? [jpeg] } : {}) }]);
    }
    assert.deepEqual(f.store.job(f.store.serverID, target.id).images, [jpeg]);
  } finally { f.cleanup(); }
});

test('migration preserves legacy jobs and revisions; attachments survive restart without replaying work', async () => {
  const f = fixture();
  const legacy = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Legacy', 'auto');
  const revision = f.store.thread(f.store.serverID, f.thread).revision;
  f.store.db.exec('ALTER TABLE jobs DROP COLUMN images; PRAGMA user_version=7;'); f.store.close();
  const migrated = new Store(f.path, f.key);
  assert.equal(migrated.db.prepare('PRAGMA user_version').get()!.user_version, 8);
  assert.deepEqual(migrated.job(migrated.serverID, legacy.id).images, []);
  assert.equal(migrated.thread(migrated.serverID, f.thread).revision, revision);
  migrated.claim(); migrated.finish(legacy.id, 'complete');
  const running = migrated.enqueue(migrated.serverID, f.thread, randomUUID(), 'Running', 'auto', false, undefined, [png]); migrated.claim();
  const queued = migrated.enqueue(migrated.serverID, f.thread, randomUUID(), '', 'auto', false, undefined, [jpeg]); migrated.close();
  const reopened = new Store(f.path, f.key); const histories: ChatMessage[][] = [];
  const provider: Generate = async function* (_key, _model, history) { histories.push(history); yield 'Answer'; };
  const worker = new Worker(reopened, provider);
  try {
    worker.start(); assert.equal(reopened.job(reopened.serverID, running.id).status, 'stopped');
    assert.deepEqual(reopened.job(reopened.serverID, running.id).images, [png]);
    assert.deepEqual(reopened.job(reopened.serverID, queued.id).images, [jpeg]); assert.deepEqual(histories, []);
    reopened.resume(reopened.serverID, f.thread); worker.tick();
    for (let i = 0; i < 100 && reopened.job(reopened.serverID, queued.id).status !== 'complete'; i++) await delay(10);
    assert.equal(reopened.job(reopened.serverID, queued.id).status, 'complete');
    assert.deepEqual(histories, [[{ role: 'user', content: 'Legacy' }, { role: 'user', content: '', images: [jpeg] }]]);
  } finally { await worker.close(); reopened.close(); rmSync(join(f.path, '..'), { recursive: true, force: true }); }
});

test('history excludes queued images and refuses excessive image context before provider generation', async () => {
  const f = fixture(); let calls = 0;
  try {
    const image = sizedPNG(maxImageBytes);
    for (let i = 0; i < 2; i++) {
      const prior = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), '', 'auto', false, undefined, Array(4).fill(image));
      f.store.claim(); f.store.append(prior.id, 'Answer'); f.store.finish(prior.id, 'complete');
    }
    const current = f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Current', 'auto');
    f.store.enqueue(f.store.serverID, f.thread, randomUUID(), 'Later', 'auto', false, undefined, [png]);
    assert.equal(f.store.history(current).length, 5);
    f.store.claim(); f.store.finish(current.id, 'complete');
    const provider: Generate = async function* () { calls++; yield 'Should not run'; };
    const worker = new Worker(f.store, provider);
    try {
      worker.start();
      for (let i = 0; i < 100 && f.store.jobs(f.store.serverID, f.thread).at(-1)!.status !== 'failed'; i++) await delay(10);
      assert.equal(calls, 0); assert.match(f.store.jobs(f.store.serverID, f.thread).at(-1)!.error!, /image context limit/);
    } finally { await worker.close(); }
  } finally { f.cleanup(); }
});
