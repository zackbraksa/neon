import Fastify, { LogController, type FastifyRequest } from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { createHash, timingSafeEqual } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';
import { isIP } from 'node:net';
import { APIError, Store } from './db.js';
import { Worker } from './worker.js';
import { Notifications, type PushSender } from './push.js';
import { validateKey, reasoningEfforts, type ReasoningEffort, type Generate, type ValidateKey } from './openrouter.js';
import { imagesSchema, validateImages, validatePrompt } from './images.js';
import { readKeyAllowance, type ReadKeyAllowance } from './allowance.js';

declare module 'fastify' { interface FastifyRequest { workspaceId: string } }

const uuid = { type: 'string', pattern: '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' };
const model = { type: 'string', minLength: 1, maxLength: 200, pattern: '^[a-zA-Z0-9._:/-]+$' };
const object = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', additionalProperties: false, properties, required });
const params = (key: string) => object({ [key]: uuid });
const booleanQuery = (key: string) => ({
  preValidation: async (request: FastifyRequest) => {
    const value = (request.query as Record<string, unknown>)[key];
    if (value !== undefined && value !== 'true' && value !== 'false') throw new APIError(400, `${key} must be true or false`);
  },
  querystring: object({ [key]: { type: 'string', enum: ['true', 'false'] } }, []),
});
const threadTitle = (value: string) => {
  const title = value.trim();
  if (!title || title.length > 200) throw new APIError(400, 'Conversation title must contain 1 to 200 characters');
  return title;
};
const validateThreadMetadata = async (request: FastifyRequest) => {
  const body = request.body;
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new APIError(400, 'Conversation metadata must be an object');
  if ('title' in body && typeof body.title !== 'string') throw new APIError(400, 'Conversation title must be text');
  if ('pinned' in body && typeof body.pinned !== 'boolean') throw new APIError(400, 'Conversation pin must be a boolean');
};
export async function buildServer(config: { store: Store; token: string; trustedProxyIps?: string[]; provider?: Generate; validateKey?: ValidateKey; keyAllowance?: ReadKeyAllowance; push?: PushSender; startWorker?: boolean; logger?: boolean }) {
  if (config.token.length < 32) throw new Error('API token must be at least 32 characters');
  const app = Fastify({ logger: config.logger ?? false, bodyLimit: 150_000,
    logController: new LogController({ disableRequestLogging: true }), requestTimeout: 30_000,
    ajv: { customOptions: { removeAdditional: false } } });
  const expected = createHash('sha256').update(config.token).digest();
  app.decorateRequest('workspaceId', '');
  const normalizeIP = (ip: string) => ip.toLowerCase().startsWith('::ffff:') && isIP(ip.slice(7)) === 4 ? ip.slice(7) : ip.toLowerCase();
  if (config.trustedProxyIps?.some(ip => !isIP(ip))) throw new Error('Trusted proxy addresses must be literal IP addresses');
  const proxies = new Set((config.trustedProxyIps ?? []).map(normalizeIP));
  await app.register(rateLimit, { max: 300, timeWindow: '1 minute', keyGenerator: request => {
    const remote = normalizeIP(request.raw.socket.remoteAddress ?? request.ip);
    const forwarded = request.headers['x-neon-client-ip'];
    return proxies.has(remote) && typeof forwarded === 'string' && isIP(forwarded) ? normalizeIP(forwarded) : remote;
  } });
  app.addHook('onRequest', async (request, reply) => {
    if (request.url === '/health' || (request.method === 'POST' && request.routeOptions.url === '/v1/sessions')) return;
    const header = request.headers.authorization;
    const supplied = header?.startsWith('Bearer ') ? header.slice(7) : '';
    request.workspaceId = timingSafeEqual(expected, createHash('sha256').update(supplied).digest())
      ? config.store.serverID : config.store.authenticateSession(supplied) ?? '';
    if (!request.workspaceId)
      return reply.code(401).header('WWW-Authenticate', 'Bearer').send({ error: 'Unauthorized' });
    const expectedServer = request.headers['x-openchat-server-id'];
    if (expectedServer !== undefined && (typeof expectedServer !== 'string' || expectedServer.toLowerCase() !== request.workspaceId))
      return reply.code(409).send({ error: 'Server identity changed; reconnect before sending commands' });
  });
  app.addHook('preValidation', async request => {
    // Foundation encodes UUIDs in uppercase; SQLite IDs use canonical lowercase.
    for (const value of [request.params, request.body]) {
      if (value && typeof value === 'object') for (const [key, field] of Object.entries(value)) {
        if (['id', 'threadId', 'jobId', 'targetJobId', 'expectedJobId', 'deviceId'].includes(key) && typeof field === 'string')
          (value as Record<string, unknown>)[key] = field.toLowerCase();
      }
    }
  });
  app.addHook('onSend', async (_request, reply, payload) => { reply.header('Cache-Control', 'no-store'); return payload; });
  app.setErrorHandler((error, _request, reply) => {
    const status = error instanceof APIError ? error.statusCode : (error as { statusCode?: number }).statusCode ?? 500;
    reply.code(status).send({ error: error instanceof APIError ? error.message : status >= 500 ? 'Internal server error' : (error as Error).message });
  });
  const store = config.store;
  const worker = new Worker(store, config.provider);
  const notifications = new Notifications(store, config.push);
  let started = false;
  app.addHook('onReady', async () => {
    if (config.startWorker !== false) { worker.start(); started = true; notifications.start(); }
  });
  app.addHook('onClose', async () => { if (started) { await worker.close(); await notifications.close(); } });
  let validations = 0;
  const checkKey = async (key: string, replacing = false) => {
    if (!/^sk-or-[A-Za-z0-9_-]+$/.test(key) || key.length > 512) throw new APIError(400, 'Enter an OpenRouter API key');
    if (validations >= 4) throw new APIError(429, 'Too many key validations; retry shortly');
    validations++;
    try { await (config.validateKey ?? validateKey)(key); }
    catch (error) {
      if (error instanceof APIError && [401, 403].includes(error.statusCode))
        throw new APIError(replacing ? 422 : 401, 'OpenRouter rejected this API key');
      throw new APIError(503, 'OpenRouter key validation is temporarily unavailable');
    }
    finally { validations--; }
  };
  app.post<{ Body: { key: string; deviceId: string } }>('/v1/sessions', {
    bodyLimit: 2048, config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    schema: { body: object({ key: { type: 'string', minLength: 1, maxLength: 512 }, deviceId: uuid }) },
  }, async request => {
    const key = request.body.key.trim();
    await checkKey(key);
    return store.createSession(key, request.body.deviceId);
  });
  app.get('/health', async () => ({ ok: true }));
  app.get('/v1/capabilities', async request => ({ serverId: request.workspaceId, backgroundJobs: true, queue: true, stopAndSteer: true, nativeSteering: false, push: Boolean(config.push), multiUser: true, conversationMetadata: true, archiveBrowsing: true, conversationDeletion: true, reasoningEffort: true, imageInputs: true }));
  app.get('/v1/settings/openrouter-key', async request => ({ configured: store.hasKey(request.workspaceId) }));
  app.get('/v1/settings/openrouter-allowance', {
    config: { rateLimit: { max: 30, timeWindow: '1 minute' } },
  }, async request => {
    if (!store.hasKey(request.workspaceId)) return { configured: false, limit: null, remaining: null };
    const allowance = await (config.keyAllowance ?? readKeyAllowance)(store.getKey(request.workspaceId));
    return { configured: true, limit: allowance.limit, remaining: allowance.remaining };
  });
  app.put<{ Body: { key: string } }>('/v1/settings/openrouter-key', {
    schema: { body: object({ key: { type: 'string', maxLength: 512 } }) },
  }, async request => {
    const key = request.body.key.trim();
    if (key) await checkKey(key, true);
    store.setKey(request.workspaceId, key); return { configured: Boolean(key) };
  });
  const archivedQuery = booleanQuery('archived');
  app.get<{ Querystring: { archived?: string } }>('/v1/threads', {
    preValidation: archivedQuery.preValidation, schema: { querystring: archivedQuery.querystring },
  }, async request => store.threads(request.workspaceId, request.query.archived === 'true'));
  app.post<{ Body: { id: string; title: string; pinned?: boolean } }>('/v1/threads', {
    preValidation: validateThreadMetadata,
    schema: { body: object({ id: uuid, title: { type: 'string', minLength: 1 }, pinned: { type: 'boolean' } }, ['id', 'title']) },
  }, async request => store.createThread(request.workspaceId, request.body.id, threadTitle(request.body.title), request.body.pinned));
  app.patch<{ Params: { id: string }; Body: { title?: string; pinned?: boolean } }>('/v1/threads/:id', {
    preValidation: validateThreadMetadata,
    schema: { params: params('id'), body: { ...object({ title: { type: 'string', minLength: 1 }, pinned: { type: 'boolean' } }, []), minProperties: 1 } },
  }, async request => store.updateThread(request.workspaceId, request.params.id, {
    ...(request.body.title === undefined ? {} : { title: threadTitle(request.body.title) }),
    ...(request.body.pinned === undefined ? {} : { pinned: request.body.pinned }),
  }));
  const includeArchivedQuery = booleanQuery('includeArchived');
  app.get<{ Params: { id: string }; Querystring: { includeArchived?: string } }>('/v1/threads/:id', {
    preValidation: includeArchivedQuery.preValidation, schema: { params: params('id'), querystring: includeArchivedQuery.querystring },
  }, async request => ({ ...store.thread(request.workspaceId, request.params.id, request.query.includeArchived === 'true'), jobs: store.jobs(request.workspaceId, request.params.id, request.query.includeArchived === 'true') }));
  app.delete<{ Params: { id: string } }>('/v1/threads/:id', { schema: { params: params('id') } }, async request => {
    store.deleteThread(request.workspaceId, request.params.id);
    worker.abortStopped();
    return { deleted: true };
  });
  app.post<{ Params: { id: string } }>('/v1/threads/:id/restore', { schema: { params: params('id') } }, async request => store.restore(request.workspaceId, request.params.id));
  app.post<{ Params: { id: string }; Body: { id: string; prompt: string; model: string; steer?: boolean; reasoningEffort?: ReasoningEffort; images?: string[] } }>('/v1/threads/:id/messages', {
    bodyLimit: 12 * 1024 * 1024,
    preValidation: async request => {
      validateImages(request.body?.images);
      validatePrompt(request.body?.prompt, request.body?.images ?? []);
      if (request.body && request.body.reasoningEffort !== undefined && typeof request.body.reasoningEffort !== 'string')
        throw new APIError(400, 'reasoningEffort must be a supported string');
    },
    schema: { params: params('id'), body: object({ id: uuid, prompt: { type: 'string', maxLength: 100_000 }, images: imagesSchema, model, reasoningEffort: { type: 'string', enum: reasoningEfforts }, steer: { type: 'boolean', default: false } }, ['id', 'prompt', 'model']) },
  }, async (request, reply) => {
    const { id, prompt, model, steer, reasoningEffort, images } = request.body;
    store.thread(request.workspaceId, request.params.id);
    store.checkJobID(request.workspaceId, id);
    // Flush before stopping so steering preserves the most recent partial text.
    if (steer) worker.flushThread(request.params.id);
    const job = store.enqueue(request.workspaceId, request.params.id, id, prompt, model, steer, reasoningEffort, images);
    worker.abortStopped();
    reply.code(202); return job;
  });
  app.post<{ Params: { id: string }; Body: { expectedJobId?: string } | undefined }>('/v1/threads/:id/stop', { schema: { params: params('id'), body: object({ expectedJobId: uuid }, []) } }, async request => {
    worker.stop(request.workspaceId, request.params.id, request.body?.expectedJobId); return { paused: true };
  });
  app.post<{ Params: { id: string } }>('/v1/threads/:id/archive', { schema: { params: params('id') } }, async request => {
    const thread = store.thread(request.workspaceId, request.params.id, true);
    if (thread && !thread.archived) worker.flushThread(request.params.id);
    store.archive(request.workspaceId, request.params.id); worker.abortStopped(); return { archived: true };
  });
  app.post<{ Params: { id: string } }>('/v1/threads/:id/resume', { schema: { params: params('id') } }, async request => {
    store.resume(request.workspaceId, request.params.id); return { paused: false };
  });
  app.post<{ Params: { id: string }; Body: { targetJobId: string; threadId: string; jobId: string; prompt: string; images?: string[] } }>('/v1/threads/:id/fork', {
    bodyLimit: 12 * 1024 * 1024,
    preValidation: async request => {
      validateImages(request.body?.images);
      if (typeof request.body?.prompt !== 'string') throw new APIError(400, 'Message must be text');
    },
    schema: { params: params('id'), body: object({ targetJobId: uuid, threadId: uuid, jobId: uuid, prompt: { type: 'string', maxLength: 100_000 }, images: imagesSchema }, ['targetJobId', 'threadId', 'jobId', 'prompt']) },
  }, async (request, reply) => {
    const b = request.body;
    store.thread(request.workspaceId, request.params.id);
    validatePrompt(b.prompt, b.images ?? store.job(request.workspaceId, b.targetJobId).images);
    reply.code(202); return store.fork(request.workspaceId, request.params.id, b.targetJobId, b.threadId, b.jobId, b.prompt, b.images);
  });
  app.get<{ Params: { id: string } }>('/v1/jobs/:id', { schema: { params: params('id') } }, async request => store.job(request.workspaceId, request.params.id));
  app.delete<{ Params: { id: string } }>('/v1/jobs/:id', { schema: { params: params('id') } }, async request => {
    store.cancelQueued(request.workspaceId, request.params.id); return { cancelled: true };
  });
  let subscribers = 0;
  app.get<{ Params: { id: string } }>('/v1/jobs/:id/events', { schema: { params: params('id') } }, async (request, reply) => {
    const initial = store.job(request.workspaceId, request.params.id);
    const header = request.headers['last-event-id'];
    if (header !== undefined && (typeof header !== 'string' || !/^\d{1,8}$/.test(header))) throw new APIError(400, 'Invalid Last-Event-ID');
    let offset = header === undefined ? 0 : Number(header);
    // Offsets count UTF-16 code units (JavaScript String.length), not UTF-8 bytes.
    if (offset > initial.content.length) throw new APIError(409, 'Cursor is ahead of this response');
    if (subscribers >= 20) throw new APIError(429, 'Too many stream subscribers');
    subscribers++;
    reply.hijack();
    reply.raw.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no', Connection: 'keep-alive' });
    const disconnected = new AbortController();
    reply.raw.once('close', () => disconnected.abort());
    const emit = async (event: string, data: unknown, cursor: number) => {
      if (disconnected.signal.aborted) return;
      if (!reply.raw.write(`id: ${cursor}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`))
        await once(reply.raw, 'drain', { signal: disconnected.signal });
    };
    let previousStatus = ''; let ticks = 0;
    try {
      while (!disconnected.signal.aborted) {
        const job = store.job(request.workspaceId, initial.id);
        if (job.content.length > offset) {
          const from = offset; offset = job.content.length;
          await emit('delta', { jobId: job.id, offset: from, text: job.content.slice(from) }, offset);
        }
        const status = { jobId: job.id, status: job.status, error: job.error,
          responseModel: job.responseModel ?? null, inputTokens: job.inputTokens ?? null,
          outputTokens: job.outputTokens ?? null, totalTokens: job.totalTokens ?? null, costUSD: job.costUSD ?? null };
        const signature = JSON.stringify(status);
        if (signature !== previousStatus) {
          await emit('status', status, offset);
          previousStatus = signature;
        }
        if (!['queued', 'running'].includes(job.status)) break;
        if (++ticks % 150 === 0) reply.raw.write(': heartbeat\n\n');
        await delay(100, undefined, { signal: disconnected.signal });
      }
    } catch { /* A closed subscriber never changes the underlying job. */ }
    finally { subscribers--; reply.raw.end(); }
  });
  app.put<{ Params: { id: string }; Body: { token: string } }>('/v1/devices/:id', {
    schema: { params: params('id'), body: object({ token: { type: 'string', pattern: '^[a-fA-F0-9]{64,256}$' } }) },
  }, async request => {
    if (!config.push) throw new APIError(503, 'APNs is not configured');
    store.registerDevice(request.workspaceId, request.params.id, request.body.token.toLowerCase()); return { registered: true };
  });
  app.delete<{ Params: { id: string } }>('/v1/devices/:id', { schema: { params: params('id') } }, async request => { store.deleteDevice(request.workspaceId, request.params.id); return { registered: false }; });
  return app;
}
