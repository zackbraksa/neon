# Neon backend

Read README.md and the parent instructions. Node.js 24, Fastify, TypeScript, built-in node:sqlite. Use this directory's npm lockfile. Run npm run typecheck, npm test, and npm run build. Tests use fake provider/push transports; do not make paid provider requests or send actual notifications during verification.

Preserve durable acceptance before responding, idempotency by job ID, chronological execution per thread, exclusion of queued prompts from provider history, and status guards against late tokens. A subscriber disconnect must not cancel a job. Interrupted paid requests must not be replayed automatically after restart. Keep the provider key encrypted, owner token authenticated, and notification payloads free of private chat text. Hosting and native client integration are separate work.
