import { DatabaseSync } from 'node:sqlite';
import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';
import { realpathSync } from 'node:fs';
import type { ResponseMetadata, ReasoningEffort, ChatMessage } from './openrouter.js';

export type Status = 'queued' | 'running' | 'complete' | 'stopped' | 'failed';
export interface Job extends ResponseMetadata {
  id: string; threadId: string; workspaceId: string; position: number; prompt: string; images: string[]; model: string; reasoningEffort: ReasoningEffort | null;
  status: Status; content: string; error: string | null; created: number; updated: number;
}
export class APIError extends Error {
  constructor(public statusCode: number, message: string) { super(message); }
}
export class Store {
  readonly db: DatabaseSync;
  private runtimeLock?: DatabaseSync;
  constructor(path: string, private key: Buffer) {
    if (key.length !== 32) throw new Error('Encryption key must contain 32 bytes');
    this.db = new DatabaseSync(path);
    const version = this.db.prepare('PRAGMA user_version').get() as { user_version: number };
    if (version.user_version > 8) { this.db.close(); throw new Error('Database was created by a newer backend'); }
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY, title TEXT NOT NULL, paused INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, threadId TEXT NOT NULL REFERENCES threads(id), position INTEGER NOT NULL,
        prompt TEXT NOT NULL, model TEXT NOT NULL, status TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', error TEXT,
        created INTEGER NOT NULL, updated INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(status, threadId, position);
      CREATE UNIQUE INDEX IF NOT EXISTS one_running_per_thread ON jobs(threadId) WHERE status='running';
      CREATE TABLE IF NOT EXISTS metadata(name TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS secrets(name TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, token TEXT NOT NULL UNIQUE);
      CREATE TABLE IF NOT EXISTS notifications(id INTEGER PRIMARY KEY, jobId TEXT NOT NULL REFERENCES jobs(id),
        deviceId TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE, attempts INTEGER NOT NULL DEFAULT 0,
        nextAttempt INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'pending', UNIQUE(jobId,deviceId));
      `);
    this.db.prepare('INSERT OR IGNORE INTO metadata VALUES(?,?)').run('server-id', randomUUID());
    if (version.user_version < 2) this.transaction(() => {
      this.db.exec(`ALTER TABLE threads ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE threads ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;
        PRAGMA user_version=2;`);
    });
    if (version.user_version < 3) this.transaction(() => {
      this.db.exec(`CREATE TABLE workspaces(id TEXT PRIMARY KEY, keyFingerprint TEXT UNIQUE, keyCipher TEXT, created INTEGER NOT NULL);
        CREATE TABLE sessions(workspaceId TEXT NOT NULL REFERENCES workspaces(id), deviceId TEXT NOT NULL,
          tokenHash TEXT NOT NULL UNIQUE, created INTEGER NOT NULL, PRIMARY KEY(workspaceId,deviceId));
        ALTER TABLE threads ADD COLUMN workspaceId TEXT REFERENCES workspaces(id);
        ALTER TABLE devices ADD COLUMN workspaceId TEXT REFERENCES workspaces(id);
        CREATE INDEX threads_workspace ON threads(workspaceId,archived,created);
        CREATE INDEX devices_workspace ON devices(workspaceId,id);
        PRAGMA user_version=3;`);
    });
    if (version.user_version < 4) this.transaction(() => {
      this.db.exec(`ALTER TABLE threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
        PRAGMA user_version=4;`);
    });
    if (version.user_version < 5) this.transaction(() => {
      this.db.exec(`ALTER TABLE jobs ADD COLUMN responseModel TEXT;
        ALTER TABLE jobs ADD COLUMN inputTokens INTEGER;
        ALTER TABLE jobs ADD COLUMN outputTokens INTEGER;
        ALTER TABLE jobs ADD COLUMN totalTokens INTEGER;
        ALTER TABLE jobs ADD COLUMN costUSD REAL;
        PRAGMA user_version=5;`);
    });
    if (version.user_version < 6) this.transaction(() => {
      this.db.exec(`ALTER TABLE jobs ADD COLUMN reasoningEffort TEXT;
        PRAGMA user_version=6;`);
    });
    if (version.user_version < 7) this.transaction(() => {
      this.db.exec(`CREATE TABLE IF NOT EXISTS deleted_threads(id TEXT PRIMARY KEY, workspaceId TEXT NOT NULL REFERENCES workspaces(id));
        PRAGMA user_version=7;`);
    });
    if (version.user_version < 8) this.transaction(() => {
      this.db.exec(`ALTER TABLE jobs ADD COLUMN images TEXT NOT NULL DEFAULT '[]';
        PRAGMA user_version=8;`);
    });
    // A separately versioned backfill can resume after the schema transaction commits.
    if (!this.db.prepare('SELECT value FROM metadata WHERE name=?').get('workspace-backfill-v1')) this.transaction(() => {
      const legacy = this.db.prepare('SELECT value FROM secrets WHERE name=?').get('openrouter') as { value: string } | undefined;
      const fingerprint = legacy ? this.fingerprint(this.decrypt(legacy.value)) : null;
      this.db.prepare('INSERT OR IGNORE INTO workspaces VALUES(?,?,?,?)').run(this.serverID, fingerprint, legacy?.value ?? null, Date.now());
      this.db.prepare('UPDATE threads SET workspaceId=? WHERE workspaceId IS NULL').run(this.serverID);
      this.db.prepare('UPDATE devices SET workspaceId=? WHERE workspaceId IS NULL').run(this.serverID);
      this.db.prepare('DELETE FROM secrets WHERE name=?').run('openrouter');
      this.db.prepare('INSERT INTO metadata VALUES(?,?)').run('workspace-backfill-v1', 'complete');
    });
    this.db.exec(`CREATE TRIGGER IF NOT EXISTS job_insert_revision AFTER INSERT ON jobs BEGIN
        UPDATE threads SET revision=revision+1 WHERE id=NEW.threadId; END;
      CREATE TRIGGER IF NOT EXISTS job_update_revision AFTER UPDATE ON jobs BEGIN
        UPDATE threads SET revision=revision+1 WHERE id=NEW.threadId; END;`);
  }
  transaction<T>(operation: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = operation(); this.db.exec('COMMIT'); return value; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  get serverID(): string { return this.db.prepare('SELECT value FROM metadata WHERE name=?').get('server-id')!.value as string; }
  acquireRuntimeLock(): () => void {
    if (this.runtimeLock) throw new Error('Another backend process owns this database');
    const path = this.db.location();
    const lock = new DatabaseSync(path ? `${realpathSync(path)}.lock` : ':memory:');
    try { lock.exec('BEGIN EXCLUSIVE'); }
    catch (error) {
      lock.close();
      if ([5, 6].includes((error as { errcode?: number }).errcode ?? 0))
        throw new Error('Another backend process owns this database');
      throw error;
    }
    this.runtimeLock = lock;
    return () => {
      if (this.runtimeLock !== lock) return;
      lock.close();
      this.runtimeLock = undefined;
    };
  }
  close() { this.runtimeLock?.close(); this.runtimeLock = undefined; this.db.close(); }
  private fingerprint(value: string): string {
    return createHmac('sha256', this.key).update('neon-provider-key\0').update(value).digest('hex');
  }
  private encrypt(value: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64');
  }
  private decrypt(value: string): string {
    const data = Buffer.from(value, 'base64');
    const decipher = createDecipheriv('aes-256-gcm', this.key, data.subarray(0, 12));
    decipher.setAuthTag(data.subarray(12, 28));
    return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString('utf8');
  }
  hasKey(workspaceId: string): boolean {
    return Boolean(this.db.prepare('SELECT keyCipher FROM workspaces WHERE id=?').get(workspaceId)?.keyCipher);
  }
  setKey(workspaceId: string, value: string) {
    const fingerprint = value ? this.fingerprint(value) : null;
    this.transaction(() => {
      const existing = fingerprint ? this.db.prepare('SELECT id FROM workspaces WHERE keyFingerprint=?').get(fingerprint) : undefined;
      if (existing && existing.id !== workspaceId) throw new APIError(409, 'This key already opens another private workspace');
      this.db.prepare('UPDATE workspaces SET keyFingerprint=?,keyCipher=? WHERE id=?')
        .run(fingerprint, value ? this.encrypt(value) : null, workspaceId);
    });
  }
  getKey(workspaceId: string): string {
    const row = this.db.prepare('SELECT keyCipher FROM workspaces WHERE id=?').get(workspaceId) as { keyCipher: string | null } | undefined;
    if (!row?.keyCipher) throw new APIError(409, 'Configure an OpenRouter key first');
    return this.decrypt(row.keyCipher);
  }
  createSession(key: string, deviceId: string): { token: string; serverId: string } {
    return this.transaction(() => {
      const fingerprint = this.fingerprint(key);
      let workspace = this.db.prepare('SELECT id FROM workspaces WHERE keyFingerprint=?').get(fingerprint) as { id: string } | undefined;
      if (!workspace) {
        if ((this.db.prepare('SELECT COUNT(*) AS count FROM workspaces').get()!.count as number) >= 1000)
          throw new APIError(503, 'New workspace registration is temporarily unavailable');
        workspace = { id: randomUUID() };
        this.db.prepare('INSERT INTO workspaces VALUES(?,?,?,?)').run(workspace.id, fingerprint, this.encrypt(key), Date.now());
      }
      const token = createHmac('sha256', this.key).update('neon-session\0').update(workspace.id).update('\0').update(deviceId).digest('base64url');
      const tokenHash = createHash('sha256').update(token).digest('hex');
      const existing = this.db.prepare('SELECT tokenHash FROM sessions WHERE workspaceId=? AND deviceId=?').get(workspace.id, deviceId);
      if (!existing) {
        if ((this.db.prepare('SELECT COUNT(*) AS count FROM sessions WHERE workspaceId=?').get(workspace.id)!.count as number) >= 100)
          throw new APIError(429, 'This workspace has reached its device limit');
        this.db.prepare('INSERT INTO sessions VALUES(?,?,?,?)').run(workspace.id, deviceId, tokenHash, Date.now());
      }
      return { token, serverId: workspace.id };
    });
  }
  authenticateSession(token: string): string | undefined {
    return this.db.prepare('SELECT workspaceId FROM sessions WHERE tokenHash=?').get(createHash('sha256').update(token).digest('hex'))?.workspaceId as string | undefined;
  }
  createThread(workspaceId: string, id: string, title: string, pinned = false) {
    const deleted = this.db.prepare('SELECT workspaceId FROM deleted_threads WHERE id=?').get(id);
    if (deleted) throw new APIError(deleted.workspaceId === workspaceId ? 410 : 404,
      deleted.workspaceId === workspaceId ? 'Conversation was deleted' : 'Conversation not found');
    const existing = this.db.prepare('SELECT * FROM threads WHERE id=?').get(id);
    if (existing) return this.thread(workspaceId, id);
    this.db.prepare('INSERT INTO threads(id,title,created,workspaceId,pinned) VALUES(?,?,?,?,?)').run(id, title, Date.now(), workspaceId, Number(pinned));
    return this.thread(workspaceId, id);
  }
  updateThread(workspaceId: string, id: string, change: { title?: string; pinned?: boolean }) {
    return this.transaction(() => {
      const previous = this.thread(workspaceId, id);
      const title = change.title ?? previous.title as string;
      const pinned = change.pinned === undefined ? previous.pinned as number : Number(change.pinned);
      if (title !== previous.title || pinned !== previous.pinned)
        this.db.prepare('UPDATE threads SET title=?,pinned=?,revision=revision+1 WHERE id=? AND workspaceId=?').run(title, pinned, id, workspaceId);
      return this.thread(workspaceId, id);
    });
  }
  thread(workspaceId: string, id: string, includeArchived = false) {
    const row = this.db.prepare('SELECT * FROM threads WHERE id=? AND workspaceId=?').get(id, workspaceId);
    if (!row) throw new APIError(404, 'Conversation not found');
    if (row.archived && !includeArchived) throw new APIError(410, 'Conversation was archived');
    return row;
  }
  threads(workspaceId: string, archived = false) { return this.db.prepare('SELECT * FROM threads WHERE workspaceId=? AND archived=? ORDER BY created DESC').all(workspaceId, Number(archived)); }
  jobs(workspaceId: string, threadId: string, includeArchived = false): Job[] {
    this.thread(workspaceId, threadId, includeArchived);
    return this.db.prepare('SELECT j.*,t.workspaceId FROM jobs j JOIN threads t ON t.id=j.threadId WHERE j.threadId=? AND t.workspaceId=? ORDER BY j.position').all(threadId, workspaceId).map(row => this.decodeJob(row));
  }
  job(workspaceId: string, id: string): Job {
    const row = this.db.prepare('SELECT j.*,t.workspaceId FROM jobs j JOIN threads t ON t.id=j.threadId WHERE j.id=? AND t.workspaceId=?').get(id, workspaceId) as unknown as Job | undefined;
    if (!row) throw new APIError(404, 'Job not found');
    return this.decodeJob(row);
  }
  private decodeJob(row: unknown): Job {
    const stored = row as Omit<Job, 'images'> & { images: string };
    return { ...stored, images: JSON.parse(stored.images) as string[] };
  }
  enqueue(workspaceId: string, threadId: string, id: string, prompt: string, model: string, steer = false, reasoningEffort?: ReasoningEffort, images: string[] = []): Job {
    return this.transaction(() => {
      this.thread(workspaceId, threadId);
      this.checkJobID(workspaceId, id);
      const previous = this.db.prepare('SELECT * FROM jobs WHERE id=?').get(id) as unknown as Job | undefined;
      if (previous) {
        if (previous.threadId !== threadId || previous.prompt !== prompt || previous.model !== model || previous.reasoningEffort !== (reasoningEffort ?? null) || JSON.stringify(this.decodeJob(previous).images) !== JSON.stringify(images))
          throw new APIError(409, 'Request ID already used with different content');
        return this.job(workspaceId, id);
      }
      this.getKey(workspaceId);
      const jobs = this.jobs(workspaceId, threadId);
      if (jobs.filter(j => j.status === 'queued').length >= 100) throw new APIError(429, 'Conversation queue is full');
      // A steer instruction occupies the next chronological position, before queued turns.
      let position = (jobs.at(-1)?.position ?? 0) + 1;
      if (steer) {
        this.stopInside(workspaceId, threadId);
        const queued = jobs.find(j => j.status === 'queued');
        if (queued) {
          position = queued.position;
          this.db.prepare("UPDATE jobs SET position=position+1 WHERE threadId=? AND status='queued'").run(threadId);
        }
      }
      const now = Date.now();
      this.db.prepare('INSERT INTO jobs(id,threadId,position,prompt,model,status,created,updated,reasoningEffort,images) VALUES(?,?,?,?,?,?,?,?,?,?)')
        .run(id, threadId, position, prompt, model, 'queued', now, now, reasoningEffort ?? null, JSON.stringify(images));
      // New explicit sends also release a previously paused queue.
      this.db.prepare('UPDATE threads SET paused=0,revision=revision+1 WHERE id=?').run(threadId);
      return this.job(workspaceId, id);
    });
  }
  private stopInside(workspaceId: string, threadId: string) {
    this.thread(workspaceId, threadId);
    this.db.prepare("UPDATE jobs SET status='stopped',updated=? WHERE threadId=? AND status='running'").run(Date.now(), threadId);
    this.db.prepare('UPDATE threads SET paused=1,revision=revision+1 WHERE id=?').run(threadId);
  }
  stop(workspaceId: string, threadId: string, expectedJobId?: string) {
    this.transaction(() => {
      this.thread(workspaceId, threadId);
      if (expectedJobId) {
        const running = this.db.prepare("SELECT id FROM jobs WHERE threadId=? AND status='running'").get(threadId);
        if (running && running.id !== expectedJobId) throw new APIError(409, 'The running response changed; refresh before stopping');
      }
      this.stopInside(workspaceId, threadId);
    });
  }
  archive(workspaceId: string, threadId: string) {
    this.transaction(() => {
      const thread = this.thread(workspaceId, threadId, true);
      if (thread.archived) return;
      this.stopInside(workspaceId, threadId);
      this.db.prepare("UPDATE jobs SET status='stopped',updated=? WHERE threadId=? AND status='queued'").run(Date.now(), threadId);
      this.db.prepare('DELETE FROM notifications WHERE jobId IN (SELECT id FROM jobs WHERE threadId=?)').run(threadId);
      this.db.prepare('UPDATE threads SET archived=1,revision=revision+1 WHERE id=?').run(threadId);
    });
  }
  deleteThread(workspaceId: string, threadId: string) {
    this.transaction(() => {
      const deleted = this.db.prepare('SELECT workspaceId FROM deleted_threads WHERE id=?').get(threadId);
      if (deleted?.workspaceId === workspaceId) return;
      this.thread(workspaceId, threadId, true);
      this.db.prepare('INSERT INTO deleted_threads(id,workspaceId) VALUES(?,?)').run(threadId, workspaceId);
      this.db.prepare('DELETE FROM notifications WHERE jobId IN (SELECT id FROM jobs WHERE threadId=?)').run(threadId);
      this.db.prepare('DELETE FROM jobs WHERE threadId=?').run(threadId);
      this.db.prepare('DELETE FROM threads WHERE id=? AND workspaceId=?').run(threadId, workspaceId);
    });
  }
  restore(workspaceId: string, threadId: string) {
    return this.transaction(() => {
      const thread = this.thread(workspaceId, threadId, true);
      if (thread.archived)
        this.db.prepare('UPDATE threads SET archived=0,revision=revision+1 WHERE id=? AND workspaceId=?').run(threadId, workspaceId);
      return { ...this.thread(workspaceId, threadId), jobs: this.jobs(workspaceId, threadId) };
    });
  }
  resume(workspaceId: string, threadId: string) { this.thread(workspaceId, threadId); this.db.prepare('UPDATE threads SET paused=0,revision=revision+1 WHERE id=?').run(threadId); }
  cancelQueued(workspaceId: string, id: string) {
    const job = this.job(workspaceId, id);
    if (job.status !== 'queued') throw new APIError(409, 'Only queued jobs can be removed');
    this.db.prepare("UPDATE jobs SET status='stopped',updated=? WHERE id=?").run(Date.now(), id);
  }
  claim(): Job | undefined {
    return this.transaction(() => {
      const candidate = this.db.prepare(`SELECT j.* FROM jobs j JOIN threads t ON t.id=j.threadId
        WHERE j.status='queued' AND t.paused=0 AND t.archived=0
        AND NOT EXISTS(SELECT 1 FROM jobs r WHERE r.threadId=j.threadId AND r.status='running')
        AND NOT EXISTS(SELECT 1 FROM jobs q WHERE q.threadId=j.threadId AND q.status='queued' AND q.position<j.position)
        ORDER BY j.created,j.position LIMIT 1`).get() as unknown as Job | undefined;
      if (!candidate) return;
      this.db.prepare("UPDATE jobs SET status='running',updated=? WHERE id=?").run(Date.now(), candidate.id);
      return this.workerJob(candidate.id);
    });
  }
  history(job: Job) {
    const result: ChatMessage[] = [];
    for (const previous of this.jobs(job.workspaceId, job.threadId)) {
      if (previous.position >= job.position) break;
      // Cancelled queued jobs never reached the provider and have no answer.
      if (previous.status !== 'complete' && !previous.content) continue;
      result.push({ role: 'user', content: previous.prompt, ...(previous.images.length ? { images: previous.images } : {}) });
      if (previous.content) result.push({ role: 'assistant', content: previous.content });
    }
    result.push({ role: 'user', content: job.prompt, ...(job.images.length ? { images: job.images } : {}) });
    if (result.reduce((n, message) => n + message.content.length, 0) > 400_000)
      throw new APIError(413, 'Conversation exceeds the context limit; start a new conversation');
    const imageBytes = result.reduce((total, message) => total + (message.images ?? []).reduce((bytes, image) => bytes + Buffer.byteLength(image.slice(image.indexOf(',') + 1), 'base64'), 0), 0);
    if (imageBytes > 16 * 1024 * 1024)
      throw new APIError(413, 'Conversation exceeds the image context limit; start a new conversation');
    return result;
  }
  append(id: string, text: string) {
    return this.db.prepare("UPDATE jobs SET content=content||?,updated=? WHERE id=? AND status='running'").run(text, Date.now(), id).changes > 0;
  }
  recordResponseMetadata(id: string, metadata: ResponseMetadata) {
    const fields = (['responseModel', 'inputTokens', 'outputTokens', 'totalTokens', 'costUSD'] as const)
      .filter(field => metadata[field] !== undefined && metadata[field] !== null);
    if (!fields.length) return;
    const values = fields.map(field => metadata[field]!);
    this.db.prepare(`UPDATE jobs SET ${fields.map(field => `${field}=?`).join(',')},updated=?
      WHERE id=? AND status='running' AND (${fields.map(field => `${field} IS NOT ?`).join(' OR ')})`)
      .run(...values, Date.now(), id, ...values);
  }
  finish(id: string, status: 'complete' | 'failed', error: string | null = null) {
    this.transaction(() => {
      const job = this.findWorkerJob(id);
      if (!job || job.status !== 'running') return;
      this.db.prepare('UPDATE jobs SET status=?,error=?,updated=? WHERE id=?').run(status, error, Date.now(), id);
      if (status === 'failed') this.db.prepare('UPDATE threads SET paused=1,revision=revision+1 WHERE id=?').run(job.threadId);
      else this.db.prepare('INSERT OR IGNORE INTO notifications(jobId,deviceId) SELECT ?,id FROM devices WHERE workspaceId=?').run(id, job.workspaceId);
    });
  }
  recover() {
    this.transaction(() => {
      this.db.prepare("UPDATE threads SET paused=1,revision=revision+1 WHERE id IN (SELECT threadId FROM jobs WHERE status='running')").run();
      this.db.prepare("UPDATE jobs SET status='stopped',error='Server restarted; continue explicitly',updated=? WHERE status='running'").run(Date.now());
    });
  }
  fork(workspaceId: string, threadId: string, targetId: string, newThreadId: string, newJobId: string, prompt: string, images?: string[]) {
    return this.transaction(() => {
      this.thread(workspaceId, threadId);
      this.checkJobID(workspaceId, newJobId);
      if (this.db.prepare('SELECT id FROM jobs WHERE id=?').get(newJobId)) throw new APIError(409, 'Job ID already exists');
      const target = this.job(workspaceId, targetId);
      if (target.threadId !== threadId) throw new APIError(404, 'Message not in conversation');
      if (this.db.prepare('SELECT id FROM threads WHERE id=?').get(newThreadId)) {
        this.thread(workspaceId, newThreadId, true);
        throw new APIError(409, 'Branch ID already exists');
      }
      this.createThread(workspaceId, newThreadId, 'Edited conversation');
      for (const old of this.jobs(workspaceId, threadId).filter(j => j.position < target.position && (j.status === 'complete' || j.content))) {
        this.db.prepare('INSERT INTO jobs(id,threadId,position,prompt,model,status,content,created,updated,responseModel,inputTokens,outputTokens,totalTokens,costUSD,reasoningEffort,images) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)')
          .run(randomUUID(), newThreadId, old.position, old.prompt, old.model, old.status === 'running' ? 'stopped' : old.status, old.content, old.created, Date.now(), old.responseModel ?? null, old.inputTokens ?? null, old.outputTokens ?? null, old.totalTokens ?? null, old.costUSD ?? null, old.reasoningEffort, JSON.stringify(old.images));
      }
      this.getKey(workspaceId);
      const position = target.position;
      this.db.prepare('INSERT INTO jobs(id,threadId,position,prompt,model,status,created,updated,reasoningEffort,images) VALUES(?,?,?,?,?,?,?,?,?,?)')
        .run(newJobId, newThreadId, position, prompt, target.model, 'queued', Date.now(), Date.now(), target.reasoningEffort, JSON.stringify(images ?? target.images));
      return this.job(workspaceId, newJobId);
    });
  }
  checkJobID(workspaceId: string, id: string) {
    const existing = this.db.prepare('SELECT t.workspaceId FROM jobs j JOIN threads t ON t.id=j.threadId WHERE j.id=?').get(id);
    if (existing && existing.workspaceId !== workspaceId) throw new APIError(404, 'Job not found');
  }
  workerJob(id: string): Job {
    const job = this.findWorkerJob(id);
    if (!job) throw new APIError(404, 'Job not found');
    return job;
  }
  findWorkerJob(id: string): Job | undefined {
    const row = this.db.prepare('SELECT j.*,t.workspaceId FROM jobs j JOIN threads t ON t.id=j.threadId WHERE j.id=?').get(id);
    return row ? this.decodeJob(row) : undefined;
  }
  workerJobs(threadId: string): Job[] {
    return this.db.prepare('SELECT j.*,t.workspaceId FROM jobs j JOIN threads t ON t.id=j.threadId WHERE j.threadId=? ORDER BY j.position').all(threadId).map(row => this.decodeJob(row));
  }
  workerStop(threadId: string) {
    const thread = this.db.prepare('SELECT workspaceId FROM threads WHERE id=?').get(threadId) as { workspaceId: string };
    this.stop(thread.workspaceId, threadId);
  }
  registerDevice(workspaceId: string, id: string, token: string) {
    this.transaction(() => {
      const device = this.db.prepare('SELECT workspaceId FROM devices WHERE id=?').get(id);
      if (device && device.workspaceId !== workspaceId) throw new APIError(404, 'Device not found');
      const registered = this.db.prepare('SELECT workspaceId FROM devices WHERE token=?').get(token);
      if (registered && registered.workspaceId !== workspaceId) throw new APIError(409, 'Device is registered to another workspace');
      this.db.prepare('DELETE FROM devices WHERE workspaceId=? AND token=? AND id<>?').run(workspaceId, token, id);
      this.db.prepare('INSERT INTO devices(id,token,workspaceId) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET token=excluded.token').run(id, token, workspaceId);
    });
  }
  deleteDevice(workspaceId: string, id: string) {
    const device = this.db.prepare('SELECT workspaceId FROM devices WHERE id=?').get(id);
    if (device && device.workspaceId !== workspaceId) throw new APIError(404, 'Device not found');
    this.db.prepare('DELETE FROM devices WHERE id=? AND workspaceId=?').run(id, workspaceId);
  }
}
