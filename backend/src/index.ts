import { mkdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { isIP } from 'node:net';
import { Store } from './db.js';
import { buildServer } from './server.js';
import { apnsSender } from './push.js';

process.umask(0o077);
const token = process.env.API_TOKEN ?? '';
const encryption = process.env.ENCRYPTION_KEY ?? '';
if (token.length < 32 || !/^[a-fA-F0-9]{64}$/.test(encryption))
  throw new Error('Set API_TOKEN (32+ characters) and ENCRYPTION_KEY (64 hex characters)');
const proxySetting = process.env.TRUSTED_PROXY_IPS?.trim() ?? '';
const trustedProxyIps = proxySetting ? proxySetting.split(',').map(ip => ip.trim()) : [];
if (trustedProxyIps.some(ip => !isIP(ip))) throw new Error('TRUSTED_PROXY_IPS must contain comma-separated literal IP addresses');
const path = process.env.DATABASE_PATH ?? './data/openchat.sqlite';
mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
const apnsFields = ['APNS_TEAM_ID', 'APNS_KEY_ID', 'APNS_TOPIC', 'APNS_KEY_FILE'] as const;
const configured = apnsFields.filter(name => process.env[name]);
if (configured.length > 0 && configured.length !== apnsFields.length) throw new Error('Configure all APNS_* credentials or none');
if (configured.length && !['sandbox', 'production'].includes(process.env.APNS_ENVIRONMENT ?? ''))
  throw new Error('Set APNS_ENVIRONMENT to sandbox or production');
const push = configured.length ? apnsSender({
  teamId: process.env.APNS_TEAM_ID!, keyId: process.env.APNS_KEY_ID!, topic: process.env.APNS_TOPIC!,
  privateKey: readFileSync(process.env.APNS_KEY_FILE!, 'utf8'), production: process.env.APNS_ENVIRONMENT === 'production',
}) : undefined;
const store = new Store(path, Buffer.from(encryption, 'hex'));
const app = await buildServer({ store, token, push, trustedProxyIps, logger: true });
let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  // Close SSE connections before waiting for Fastify's graceful close.
  app.server.closeAllConnections();
  await app.close(); store.close();
}
process.once('SIGTERM', () => { void shutdown(); });
process.once('SIGINT', () => { void shutdown(); });
try { await app.listen({ host: process.env.HOST ?? '127.0.0.1', port: Number(process.env.PORT ?? 8080) }); }
catch { await app.close(); store.close(); process.exitCode = 1; console.error('Neon backend failed to start. Check configuration and database ownership.'); }
