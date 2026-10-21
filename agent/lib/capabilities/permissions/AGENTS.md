# Capability Permissions Contract

## Scope
This contract applies to `agent/lib/capabilities/permissions/`.

## Policy Ownership
- `PermissionManager` is the sole authority for sensitive runtime and platform-tool approval enforcement.
- UI and transports may present and return decisions but cannot bypass policy or own grant caches.
- Persist workspace policy through the dedicated store and keep permission origin/scope explicit.
- Apply approval grants at once, session, and workspace scope. A denial rejects only the current invocation and never creates a durable or session-wide deny rule; explicit workspace policy deny entries remain authoritative configuration.
- External workspace-file grants are keyed by tool plus canonical target path. Keep original arguments in the durable checkpoint for resume, but expose only sanitized action/path details in the permission payload.
- A session has at most one unresolved interactive permission request. Concurrent authorization checks queue FIFO per session and re-evaluate current policy when they reach the front; different sessions remain independent.

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

## Policy Authority
- Workspace permission mode, execution mode, host discovery policy, and durable grants live only in the Agent state database (`WorkspaceSecurityPolicyRepository` behind `WorkspacePolicyStore`), keyed by registered workspace UUID or a validated `exec_root:` key. Policy stays with the workspace id across relocation.
- Derive the governing policy only from the validated tool root (`WorkspacePolicyStore.resolveForRoot`), never from workspace display metadata: the innermost containing registered workspace owns writes, else the root's `exec_root:` key, and every containing scope combines most restrictively.
- Never read, seed from, or write policy in `<workspace>/.sanad/settings.json` or any other model-writable file.
- Authority is `CommandAuthority`, derived by transport ingress and stamped into payloads and turn metadata; payload content can never raise it. Every authenticated client transport (loopback Local Gateway, Cloud Gateway relay, in-process CLI) is `owner`; any other transport is `unverified` and fails closed. Widening any policy axis requires `owner`; narrowing does not.
- Turn-level `allow_all_tools` bypasses approval only on an `owner` turn. Session metadata `permission_mode` grants nothing. Explicit workspace deny entries win over every bypass.
- Policy writes are compare-and-swap on `revision`; unknown stored values resolve to the restrictive posture. Schema changes to the policy table are additive only.
- `ProcessEnvironmentPolicy` is the single owner of model-requested child environments. It removes Sanad credentials derived from the provider registry and `Config`, never strips developer variables by suffix, and rejects protected overrides by key without logging values.

- A refusal (user denial, session or workspace deny) raises `ToolPermissionDeniedException`; the tool result records the typed `permission_denied` code so clients render it as not run.

## Safety
- Never log raw sensitive arguments, decisions containing secrets, or recovered payload text.
- Platform-provided tools retain platform execution target and cannot be converted into local execution by approval.
