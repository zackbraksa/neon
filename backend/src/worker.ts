import { Store, type Job } from './db.js';
import { generate, type Generate } from './openrouter.js';

interface Running { controller: AbortController; flush: () => void; promise: Promise<void> }
export class Worker {
  private running = new Map<string, Running>();
  private timer?: NodeJS.Timeout;
  private releaseRuntimeLock?: () => void;
  constructor(private store: Store, private provider: Generate = generate, private concurrency = 2) {}
  start() {
    // Keep ownership in a separate SQLite file so OS locks survive PID reuse safely.
    this.releaseRuntimeLock = this.store.acquireRuntimeLock();
    try { this.store.recover(); }
    catch (error) { this.releaseRuntimeLock(); throw error; }
    this.timer = setInterval(() => this.tick(), 100);
    this.timer.unref();
    this.tick();
  }
  tick() {
    while (this.running.size < this.concurrency) {
      const job = this.store.claim();
      if (!job) break;
      const controller = new AbortController();
      let pending = '';
      const flush = () => {
        if (!pending) return;
        const text = pending; pending = '';
        if (!this.store.append(job.id, text)) controller.abort();
      };
      const entry: Running = { controller, flush, promise: Promise.resolve() };
      this.running.set(job.id, entry);
      entry.promise = this.run(job, entry, text => { pending += text; });
    }
  }
  private async run(job: Job, entry: Running, append: (text: string) => void) {
    const timer = setInterval(() => {
      try {
        if (this.store.workerJob(job.id).status !== 'running') entry.controller.abort();
        else entry.flush();
      } catch { entry.controller.abort(); }
    }, 100);
    let length = 0;
    try {
      for await (const text of this.provider(this.store.getKey(job.workspaceId), job.model, this.store.history(job), entry.controller.signal,
        metadata => this.store.recordResponseMetadata(job.id, metadata), job.reasoningEffort ?? undefined)) {
        entry.controller.signal.throwIfAborted();
        length += text.length;
        if (length > 2_000_000) throw new Error('Response exceeded the output size limit');
        append(text);
      }
      entry.controller.signal.throwIfAborted();
      entry.flush();
      this.store.finish(job.id, 'complete');
    } catch (error) {
      entry.flush();
      // Store's status guard rejects stale output/completions after stop or steer.
      const safeError = error instanceof Error && /^(OpenRouter HTTP \d+;|Provider |Response exceeded|Conversation exceeds)/.test(error.message)
        ? error.message : 'Generation interrupted; partial response saved. Continue explicitly.';
      this.store.finish(job.id, 'failed', safeError);
    } finally { clearInterval(timer); this.running.delete(job.id); }
  }
  flushThread(threadId: string) {
    for (const job of this.store.workerJobs(threadId)) this.running.get(job.id)?.flush();
  }
  stop(workspaceId: string, threadId: string, expectedJobId?: string) {
    this.store.thread(workspaceId, threadId);
    this.flushThread(threadId);
    this.store.stop(workspaceId, threadId, expectedJobId);
    this.abortStopped();
  }
  abortStopped() {
    for (const [id, entry] of this.running) if (this.store.findWorkerJob(id)?.status !== 'running') entry.controller.abort();
  }
  async close() {
    clearInterval(this.timer);
    for (const [id, entry] of this.running) {
      entry.flush();
      const job = this.store.findWorkerJob(id);
      if (job?.status === 'running') this.store.workerStop(job.threadId);
      entry.controller.abort();
    }
    await Promise.allSettled([...this.running.values()].map(entry => entry.promise));
    this.releaseRuntimeLock?.();
  }
}
