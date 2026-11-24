# Neon

Shared native SwiftUI app for iOS 17+ and macOS 14+; generate the Xcode project from project.yml with XcodeGen. Keep API keys in Keychain. Never include queued messages in a current request, and preserve the user/assistant order when completing queued turns. Stale callbacks must pass the conversation's active request ID guard. Editing must preserve the original branch. Run the README macOS tests and iOS simulator build on a Mac; do not claim Apple validation from Linux.

DirectChatStore owns direct mode; RemoteChatStore owns backend sync and the durable client outbox. ChatStore is the UI facade. Keep direct and endpoint/server-identity caches separate. Backgrounding in backend mode disconnects subscribers and must never call stop. Retry sends with immutable IDs/payloads, validate job/offset identity before applying stream deltas, and preserve pending notification taps until the matching server can open the chat. Use scripts/verify-apple.sh on a Mac for native verification.

## Working rules

- Read the repository README and any deeper applicable agent instructions before editing. Verify assumptions against current source.
- Keep changes scoped, preserve unrelated edits, and use project-local tooling and lockfiles.
- Verify the affected behavior before delivery. For substantial changes, use specialist planning, independent review and functional QA. Keep simple work with one agent.
- Prefer the in-app Browser for web QA. Boot simulators on demand and shut down only the devices you booted.
- Use `gh` for GitHub operations and verify the active identity is `zackbraksa`, including the identity used for pushes. External writes and deployments require authorization for the action and target.

## GitHub recommendations

- Never recommend a small or little-known GitHub repository whose legitimacy
  cannot be independently verified. Check maintainer provenance, maintenance and
  release history, real adoption, and working official distribution channels;
  a README, star count, or signed release alone is insufficient. Apply extra
  scrutiny to tools handling secrets, production access, or privileged execution.
