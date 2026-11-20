# Neon backend

Fastify + TypeScript on Node.js 24, using its built-in SQLite database. A backend with private workspaces for the native Neon client. Generation runs independently of HTTP subscribers, so closing the client does not cancel paid requests. No Redis, Firebase, or separate database service is required.

Run your own Neon backend and connect the native client with your OpenRouter key. The same key opens the same private chats on another device; different keys have separate histories and provider credentials. The native app retains its durable outbox, conversation sync, stream recovery, and notification navigation; see [the app README](../README.md).

## Run locally

```sh
cd backend
npm ci
cp .env.example .env
```

Generate two independent secrets with the command below. Put one in `API_TOKEN` and the other in `ENCRYPTION_KEY` in your local `.env` (never commit it):

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

Remove all `APNS_*` lines for now if you are not enabling push, then:

```sh
npm run build
npm start
```

For development, `npm run dev`. The default listener is `127.0.0.1:8080`. Remote clients require HTTPS. `/health` and `POST /v1/sessions` are public; other routes require `Authorization: Bearer <Neon session token>`. The server resolves the private workspace from that credential. Requests for another workspace’s resources return 404 without changing them.

`API_TOKEN` remains a compatibility credential for the original owner’s workspace. Keep it on the server and in existing authorized clients; never bundle it in the app or distribute it to other users.

### Key-only setup

A new installation sends its OpenRouter key and a persistent installation UUID to `POST /v1/sessions`. The server validates the key using OpenRouter’s read-only `GET /api/v1/key` endpoint, finds or creates its private workspace, and returns an opaque Neon session token and `serverId`. No model generation occurs during setup. Validation uses bounded timeouts, request limits, and concurrent-validation limits; unavailable validation returns a retryable error instead of creating a workspace.

Save the returned credential in Keychain. On an uncertain response, retry the same key and `deviceId`; the result reuses the same session rather than allocating more sessions. Sessions have no scheduled expiry. Only session hashes are stored in SQLite; provider-key lookup uses a separate keyed fingerprint. The OpenRouter key itself remains encrypted and is never returned.

`serverId` is the stable identity of the authenticated workspace on this backend. Native clients retain it in `X-OpenChat-Server-ID`; a mismatch returns 409 before mutations. Existing clients retain their original identity. New private workspaces receive different identities, keeping on-device caches, durable outboxes, streams, and notification navigation separate even at the same endpoint.

People who share an OpenRouter key share its workspace. Replacing that key through an authenticated `PUT /v1/settings/openrouter-key` retains the workspace, sessions, and history, and removes the previous key’s discovery mapping. A replacement already linked to another workspace returns 409 instead of merging histories. A provider-rejected replacement returns 422 and leaves the existing connection and key unchanged; on this authenticated route, 401 means the Neon credential is invalid. Public session enrollment uses 401 for an invalid OpenRouter key, 400 for malformed input, 429 for limits, and 503 when validation is unavailable. Removing the key disables new generation and key-based discovery without erasing history or invalidating existing sessions. A person who loses every session credential and the current key has no automatic history-recovery mechanism.

## API

JSON request/response bodies use camelCase. Use client-generated UUIDs for conversation and job IDs. Reuse the **same** job ID when retrying an uncertain send; never invent a replacement merely because the HTTP response was lost.

| Method | Path | Body / result |
| --- | --- | --- |
| GET | `/health` | Public liveness check |
| POST | `/v1/sessions` | Public `{ "key": "sk-or-…", "deviceId": "UUID" }`; returns `{ "token": "opaque Neon credential", "serverId": "UUID" }` |
| GET | `/v1/capabilities` | Workspace-scoped `serverId`, backend features, `multiUser: true`, `conversationMetadata: true`, `archiveBrowsing: true`, `conversationDeletion: true`, `reasoningEffort: true`, `imageInputs: true`, and whether push is configured |
| GET | `/v1/settings/openrouter-key` | Returns only `{ "configured": true/false }`, never the key |
| GET | `/v1/settings/openrouter-allowance` | Returns `{ "configured": boolean, "limit": number/null, "remaining": number/null }` for the authenticated workspace’s key |
| PUT | `/v1/settings/openrouter-key` | Replace this workspace’s key with `{ "key": "sk-or-…" }`; empty removes it; preserves history and never returns the key |
| GET | `/v1/threads` | Active conversations by default; `?archived=true` returns archived-only in the authenticated workspace |
| POST | `/v1/threads` | `{ "id": "UUID", "title": "New chat", "pinned": false }`; pin is optional and creation is idempotent by ID |
| PATCH | `/v1/threads/:id` | `{ "title": "Renamed chat", "pinned": true }`; either field or both |
| GET | `/v1/threads/:id` | Canonical snapshot with jobs; `?includeArchived=true` permits read-only archived snapshots, otherwise archived returns 410 |
| POST | `/v1/threads/:id/messages` | `{ "id": "UUID", "prompt": "Hello", "model": "openrouter/auto", "steer": false, "reasoningEffort": "high" }`; effort is optional; returns job, HTTP 202 |
| POST | `/v1/threads/:id/stop` | Optional `{ "expectedJobId": "UUID" }`; conflict if another response is now running |
| POST | `/v1/threads/:id/archive` | Idempotently archive, cancel unfinished turns, hide from sync, retain stored history |
| DELETE | `/v1/threads/:id` | Permanently delete active or archived conversation, jobs and notification rows; `{ "deleted": true }` |
| POST | `/v1/threads/:id/restore` | Idempotently restore visibility; returns canonical snapshot with jobs without resuming stopped work |
| POST | `/v1/threads/:id/resume` | Release pending queue; does not regenerate a stopped job |
| POST | `/v1/threads/:id/fork` | `{ "targetJobId": "UUID", "threadId": "NEW_UUID", "jobId": "NEW_UUID", "prompt": "Edited message" }` |
| GET | `/v1/jobs/:id` | Durable job snapshot, including partial answer |
| GET | `/v1/jobs/:id/events` | Reconnectable SSE; optional `Last-Event-ID` header |
| DELETE | `/v1/jobs/:id` | Remove a queued turn from execution by marking it stopped |
| PUT | `/v1/devices/:id` | `{ "token": "APNS_HEX_TOKEN" }`; requires configured APNs |
| DELETE | `/v1/devices/:id` | Unregister device and remove its notification outbox |

Conversation titles are trimmed and
must contain 1 to 200 UTF-16 code units. Pin requests use booleans; list/snapshot
responses use integer `pinned: 0/1`. Metadata updates require the owning workspace,
reject archived conversations, and increment revision once only when a value
changes. Existing-ID create retries never overwrite metadata. See the scoped
[OpenAPI description](openapi.json).

Archive browsing and restore query flags accept only `true` or `false`; malformed or repeated values
are rejected. Restore retains title, pin, pause state, job IDs, committed text and
stopped jobs, and increments revision only when clearing the archived flag. It
does not resume work, enqueue a request, call a provider or create a notification.
All existing conversation mutation routes continue to reject archived chats until
restored. Restore introduces no schema migration.

The `conversationDeletion` capability enables the native Delete action. Deletion
removes the conversation, its prompts, answers, queued jobs and notification
rows, and aborts running generation. A repeated DELETE of the same owned ID is
successful; unknown or foreign IDs return 404. Only the deleted conversation UUID
and workspace UUID remain as a tombstone, so a stale create retry returns 410
instead of resurrecting the conversation or issuing paid work. Deleted snapshots
and jobs return 404. Existing backups, SQLite free pages and already delivered
notifications are outside this logical deletion; it is not a secure disk wipe.

Conversation metadata includes a monotonically increasing `revision`, incremented when jobs, pause state, archive state, title or pin metadata change. Clients fetch snapshots only for changed conversations. UUIDs are normalized to lowercase, including Swift’s uppercase encoding. The capabilities endpoint includes the authenticated workspace’s stable `serverId`, retained with database backups.

A job contains `id`, `threadId`, `position`, `prompt`, `model`, `status`, `content`, `error`, `created`, and `updated`. Timestamps are Unix milliseconds. Status is `queued`, `running`, `complete`, `stopped`, or `failed`. The model is captured when enqueuing; the server constructs history from preceding executed turns, excluding unsent queued prompts. The public model catalog remains available directly at `https://openrouter.ai/api/v1/models`.

An optional `reasoningEffort` on message submission accepts `none`, `minimal`,
`low`, `medium`, `high`, `xhigh`, or `max`. Omit it for the provider default;
`none` is an explicit choice. Jobs expose the captured effort as a nullable field,
including queued and interrupted jobs. Retries must retain the same effort.
The worker sends `reasoning: { effort: ... }` only for an explicit selection.
Provider and model support varies; this capability does not guarantee support for
every value. Forked history copies efforts, and an edited turn inherits its
original target job’s effort. Clients should send the field only when capabilities
advertise `reasoningEffort: true`.

Jobs also expose nullable `responseModel`, `inputTokens`, `outputTokens`,
`totalTokens`, and `costUSD`. `model` always remains the requested model, including
`openrouter/auto`; `responseModel` is the routed model reported by OpenRouter.
Usage and USD cost come only from OpenRouter's stream, including final usage-only
events. Missing or malformed fields remain unknown and never erase known values;
zero is retained. No cost estimate, deprecated usage flag or extra billing request
is used. Partial metadata survives interruption, and stopped jobs reject late
metadata. Forked history retains the source response metadata.

SSE `status` events include all five nullable fields on initial connection,
metadata or status changes, and terminal close. Reconnect returns current full
metadata without changing delta offsets. Clients should accept missing fields
from older backends.


Sending while another response is running queues the turn. `steer: true` stops the current response and puts the new instruction ahead of existing queued turns. This starts a new provider request with the saved partial history; OpenRouter does not offer universal live steering. New sends release a paused queue; use `/resume` to release it without adding a turn. To continue a partial answer, enqueue a **new** user message asking the model to continue. A fork preserves the original conversation; retrying an existing fork ID returns 409, after which the client can fetch that deterministic thread ID.

### Image inputs

Message submissions and forks accept optional `images: string[]`. Each item must
be an inline `data:image/png;base64,...` or `data:image/jpeg;base64,...` URL with
canonical base64 and a matching PNG/JPEG signature. Up to four images of at most
2 MiB decoded each are accepted; only message and fork routes accept bodies up
to 12 MiB. Remote image URLs are rejected and never fetched. A prompt may be
empty when images are attached. Clients send images only when capabilities
advertise `imageInputs: true`.

Jobs return the stored images in original order, including snapshots and queued
jobs. Omitted images and `[]` are equivalent for immutable message retries;
changing an image or its order returns 409. Forks preserve images in prior
history. The edited turn inherits target images if omitted, replaces them if
provided, and removes them for explicit `[]`. On a 409 retry, clients must compare
both prompt and images against the fetched deterministic branch before recovering.

The worker includes images only from eligible completed/partial history and the
current turn, never later queued turns. Text-only provider messages retain their
string content; image messages use ordered text and `image_url` parts containing
the inline data URLs. Context above 16 MiB of decoded image data fails explicitly
before generation; images are never silently dropped. Model image support varies.
Images are stored unencrypted in SQLite alongside conversation text and sent to
OpenRouter/providers for generation.

### Key allowance

`GET /v1/settings/openrouter-allowance` uses the existing session/owner bearer
credential and optional `X-OpenChat-Server-ID` workspace pin. With no configured
provider key it returns `configured: false` and null amounts without contacting
OpenRouter. Otherwise it reads only the authenticated workspace’s key and returns
its USD spending limit and remaining allowance. A null limit means no key limit.
No key, provider label, usage history or raw upstream response is returned.

The read-only OpenRouter `/api/v1/key` request has an eight-second timeout, rejects
redirects and limits its response to 64 KiB. Provider key rejection returns 422,
rate limiting returns 429, and malformed/unavailable upstream data returns 503;
401 remains Neon authentication failure. Responses are not cached. The scoped
[OpenAPI description](openapi.json) documents this endpoint.

This endpoint reports key allowance. OpenRouter’s account-credit API requires a
management key, which Neon does not request. See the official
[key-limit documentation](https://openrouter.ai/docs/api_reference/limits) and
[account-credit documentation](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits).

### Streaming protocol

The stream reads committed database state; disconnecting a subscriber does not stop a job. Events include the job ID so a client can reject updates for another response. Clients should use the snapshot endpoint to discover status after foregrounding, then subscribe to unfinished jobs.

```text
id: 8
event: delta
data: {"jobId":"…","offset":0,"text":"First 🙂"}

id: 8
event: status
data: {"jobId":"…","status":"running","error":null}
```

Event IDs and `offset` count **UTF-16 code units**, matching JavaScript `String.length` and Swift `String.utf16.count`. Persist a cursor only after applying its delta. On reconnect, send `Last-Event-ID: 8`; only the remaining suffix is emitted. Without a cursor, replay starts at zero. The client must apply a delta only at its expected offset; fetch a fresh job snapshot if they differ. Status events do not advance the text cursor. A terminal status ends the stream; queued/running jobs send heartbeats. Snapshot retrieval and stream replay make push delivery unnecessary for correctness.

## Persistence and request safety

SQLite uses WAL and FULL synchronous commits. One backend process owns a local database, with at most two concurrent provider requests and one running request per thread. Startup refuses a second process using the same file. Do not use Node cluster, multiple replicas, or a network filesystem. Moving to multiple hosts would require a distributed worker lease and database design.

The adjacent `<database>.lock` SQLite file holds the process ownership lock.
Keep it on the same local persistent volume and never remove or replace it
while the backend runs. The operating system releases ownership after a crash,
including container restarts that reuse a process ID.

An accepted message is committed before HTTP 202. Retrying its ID with the same thread, prompt, model, reasoning effort, and image array returns the original job; conflicting content returns 409. The model history is constructed server-side when a job starts. Later tokens and completions are rejected once a job is stopped. Queue length is capped at 100 pending turns per conversation; prompt, context, response, HTTP body, subscription, and request-rate limits bound resource usage.

Response text is committed at 100 ms intervals and on completion/explicit stop. An abrupt kill may lose the latest uncommitted interval. On restart, running jobs become stopped and their threads pause; the backend never automatically repeats a possibly billed provider call. Accepted jobs that were still queued may run after restart if their thread was not interrupted or paused. There is no way to recover an original provider stream after a server crash.

The OpenRouter key is encrypted with AES-256-GCM before storage. `ENCRYPTION_KEY` must remain separate from database backups; losing it makes the saved provider key unreadable. Encryption at rest does not protect against a compromised running server. Conversation text is stored unencrypted locally and sent to OpenRouter/providers for generation. Request bodies, authorization headers, keys, and provider error bodies are not logged. The startup entry point creates data files with owner-only permissions. Back up SQLite using its online backup API or stop the process before copying; copying only the main `.sqlite` file while WAL is active can omit committed data. Keep backups of the encryption key separately. Workspace ownership scopes conversations, jobs, keys, device registrations, and notification delivery. The server operator still controls the database and running service; workspace isolation does not conceal data from that operator.

## Push notifications

Push goes **directly to Apple's APNs**, without Firebase. Provide an Apple Developer push signing `.p8` file, Team ID, Key ID, and app bundle ID (`APNS_TOPIC`). Set `APNS_ENVIRONMENT=sandbox` for development builds or `production` for distribution. An endpoint serves one APNs environment; separate development and production device registrations accordingly.

The native app includes Push Notifications entitlements, permission requests, APNs delegate callbacks, device token upload, and notification navigation. A developer signing team and provisioning with the capability must still be configured and tested. Leave all `APNS_*` variables unset until credentials are ready; partial credentials fail startup and device registration returns 503 when push is disabled.

Completion and notification creation commit in the same database transaction. Only devices registered to the completed job’s workspace receive an outbox entry; payload identities identify that workspace. A persistent outbox retries failures with exponential backoff (up to eight attempts); invalid device tokens are removed. Payloads contain a generic “Your answer is ready” alert and the job/server IDs, never prompt/answer text. Delivery is at least once: a crash after APNs accepts a request but before recording success can cause a duplicate alert. Collapse IDs reduce duplicate presentation. APNs acceptance does not guarantee delivery. Register devices before generation completes; previously completed jobs do not produce retroactive alerts for new devices. Failed deliveries remain in the database for diagnosis.

## Verification

```sh
npm run typecheck
npm test
npm run build
```

The suite uses temporary on-disk databases and fake providers. It covers encryption, idempotency, queue order, pause/resume, steering, rejection of late tokens, recovery, history forks, byte-split Unicode SSE, authentication, validation, cursor replay, durable notification retries, ownership after process termination, and a real loopback HTTP disconnect/reconnect. Workspace tests cover isolation, session/key handling, migration, the shared worker budget and trusted proxy rate limits. Tests do not make paid OpenRouter calls or contact APNs. Actual provider access and Apple push delivery remain unverified; see the app README for native verification.

Independent functional QA passed against the exact Linux AMD64 runtime image
with fake key validation, generation and push transports. Disposable artifact
checks passed v2-to-v3 migration, old-binary refusal, full-volume backup restore,
and forced container termination/recreation. The scoped Caddy header fixture
also passes its five synthetic peer cases.

## Schema upgrades

Schema v3 adds private workspaces, provider-key fingerprints, hashed sessions, and ownership for existing conversations and devices. Versioned schema changes and a separate resumable backfill preserve the original workspace identity, encrypted provider key, thread/job IDs, revisions, archived state, queue order, and committed response text. The process-lifetime lock remains on the same persistent volume.

The original `API_TOKEN` still opens only the original workspace. The existing provider key discovers that same workspace through key-only setup. Older binaries refuse the upgraded schema. Retain a stopped-volume backup before this upgrade; switching to an old image alone is not a safe rollback. Prefer a reviewed forward migration. Restoring an older database requires explicit authorization and a decision about data created since the backup.

Schema v4 adds a non-null pin column with default 0 through an additive transaction; older conversations remain unpinned and retain titles, history, revisions and ownership. This migration is forward-only; keep a database backup when rolling back to a backend that supports only schema v3. No live migration has been run for this local implementation.

Schema v5 adds five nullable response-metadata columns to jobs in one additive
transaction. Historical job IDs, text, ordering, requested models and thread
revisions are preserved; old usage remains unknown. This migration is forward-only.
Older binaries refuse this newer schema. Back up the database before release
upgrades; rollback requires a schema-v5-compatible binary or restoring a
pre-upgrade backup, never dropping columns. No live migration was run here.

Schema v6 adds nullable `jobs.reasoningEffort` in an additive transaction. Legacy
jobs retain provider defaults, IDs, text, order and thread revisions. Older
binaries refuse the upgraded schema; keep a backup before release and use a
schema-v6-compatible binary for rollback or explicitly restore a backup. No live
migration was run for this local implementation.

Schema v2 adds conversation revisions, archival state, and revision triggers. Opening a v1 database upgrades it transactionally without dropping chats or partial answers. New server identities are stored in metadata and retained on subsequent opens. Archive prevents queued work and stale client retries from resurrecting hidden threads, but does not erase their contents. Back up the database before release upgrades.

## Host your backend

Build the included Dockerfile or run the Node service directly. Keep the database
on a persistent volume and expose the service through an HTTPS reverse proxy.
Set `TRUSTED_PROXY_IPS` only to addresses of proxies you control, and configure
those proxies to replace the incoming `X-Neon-Client-IP` header with the client
address. Keep `API_TOKEN` and `ENCRYPTION_KEY` private and back up the database
and encryption key separately.
