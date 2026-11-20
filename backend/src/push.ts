import { connect } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';
import { Store } from './db.js';

export interface Notice { id: number; jobId: string; deviceId: string; token: string; serverId: string; workspaceId: string; attempts: number }
export type PushSender = (notice: Notice) => Promise<'sent' | 'invalid'>;
export function apnsSender(config: { teamId: string; keyId: string; topic: string; privateKey: string; production: boolean }): PushSender {
  const key = createPrivateKey(config.privateKey);
  if (key.asymmetricKeyType !== 'ec') throw new Error('APNs requires an EC signing key');
  let cached = ''; let expires = 0;
  return async notice => {
    if (Date.now() > expires) {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: config.keyId })).toString('base64url');
      const payload = Buffer.from(JSON.stringify({ iss: config.teamId, iat: Math.floor(Date.now() / 1000) })).toString('base64url');
      const input = `${header}.${payload}`;
      cached = `${input}.${sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
      expires = Date.now() + 45 * 60_000;
    }
    const client = connect(config.production ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com');
    try {
      return await new Promise<'sent' | 'invalid'>((resolve, reject) => {
        client.on('error', reject);
        client.setTimeout(10_000, () => client.destroy(new Error('APNs connection timed out')));
        const request = client.request({ ':method': 'POST', ':path': `/3/device/${notice.token}`,
          authorization: `bearer ${cached}`, 'apns-topic': config.topic, 'apns-push-type': 'alert',
          'apns-priority': '10', 'apns-collapse-id': notice.jobId });
        request.setTimeout(10_000, () => request.destroy(new Error('APNs timed out')));
        request.on('error', reject);
        let status = 0; let body = '';
        request.on('response', headers => { status = Number(headers[':status']); });
        request.on('data', chunk => { if (body.length < 4096) body += String(chunk); });
        request.on('end', () => {
          if (status === 200) resolve('sent');
          else if (status === 410 || (status === 400 && /BadDeviceToken|DeviceTokenNotForTopic/.test(body))) resolve('invalid');
          else reject(new Error(`APNs HTTP ${status}`));
        });
        // No prompt or answer text in lock-screen alerts.
        request.end(JSON.stringify({ aps: { alert: { title: 'Neon', body: 'Your answer is ready.' }, sound: 'default' }, jobId: notice.jobId, serverId: notice.serverId }));
      });
    } finally { client.destroy(); }
  };
}

export class Notifications {
  private timer?: NodeJS.Timeout;
  private busy?: Promise<void>;
  constructor(private store: Store, private sender?: PushSender) {}
  start() { if (this.sender) this.timer = setInterval(() => { void this.tick(); }, 1000); this.timer?.unref(); }
  tick(): Promise<void> {
    if (this.busy) return this.busy;
    this.busy = this.deliver().finally(() => { this.busy = undefined; });
    return this.busy;
  }
  private async deliver() {
    if (!this.sender) return;
    const notice = this.store.db.prepare(`SELECT n.*,d.token,t.workspaceId FROM notifications n JOIN devices d ON d.id=n.deviceId
      JOIN jobs j ON j.id=n.jobId JOIN threads t ON t.id=j.threadId AND t.workspaceId=d.workspaceId
      WHERE n.state='pending' AND n.nextAttempt<=? ORDER BY n.id LIMIT 1`).get(Date.now()) as unknown as Notice | undefined;
    if (!notice) return;
    try {
      const result = await this.sender({ ...notice, serverId: notice.workspaceId });
      if (result === 'invalid') this.store.deleteDevice(notice.workspaceId, notice.deviceId);
      else this.store.db.prepare("UPDATE notifications SET state='sent' WHERE id=?").run(notice.id);
    } catch {
      const attempts = notice.attempts + 1;
      this.store.db.prepare('UPDATE notifications SET attempts=?,nextAttempt=?,state=? WHERE id=?')
        .run(attempts, Date.now() + Math.min(3600_000, 1000 * 2 ** attempts), attempts >= 8 ? 'failed' : 'pending', notice.id);
    }
  }
  async close() { clearInterval(this.timer); await this.busy; }
}
