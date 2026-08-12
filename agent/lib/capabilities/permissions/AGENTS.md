# Capability Permissions Contract

## Scope
This contract applies to `agent/lib/capabilities/permissions/`.

## Policy Ownership
- `PermissionManager` is the sole authority for sensitive runtime and platform-tool approval enforcement.
- UI and transports may present and return decisions but cannot bypass policy or own grant caches.
- Persist workspace policy through the dedicated store and keep permission origin/scope explicit.
- Apply approval grants at once, session, and workspace scope. A denial rejects only the current invocation and never creates a durable or session-wide deny rule; explicit workspace policy deny entries remain authoritative configuration.
- External workspace-file grants are keyed by tool plus canonical target path. Keep original arguments in the durable checkpoint for resume, but expose only sanitized action/path details in the permission payload.

## Durable Suspension
- Write a durable suspended checkpoint before a sensitive tool call waits for user approval.
- Persist enough session, request, run, generation, tool-call, tool, argument, origin, and policy context to redisplay and resume safely.
- Resolve approval with an atomic awaiting-to-resuming-or-denied transition so exactly one responder wins.
- In-memory waiters are projections; restart recovery falls back to durable checkpoint ownership.

## Resume
- Reapply the persisted decision before invoking the gated tool during resume.
- A once decision uses a one-shot in-memory bypass so resumed execution does not immediately ask again.
- Resume through the normal runtime and canonical platform path; do not create an ad-hoc execution or delivery side channel.
- Denial and late/already-resolved responses remain authoritative and must not execute the tool.

## Safety
- Never log raw sensitive arguments, decisions containing secrets, or recovered payload text.
- Platform-provided tools retain platform execution target and cannot be converted into local execution by approval.
