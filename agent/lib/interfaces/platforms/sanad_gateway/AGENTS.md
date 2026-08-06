# Sanad Gateway Protocol Contract

## Scope
This contract applies to `agent/lib/interfaces/platforms/sanad_gateway/`.

## Bridge Ownership
- `SanadProtocolBridge` dispatches and translates only; focused handlers own domain command/query workflows.
- Local and cloud Sanad platforms share translators, envelopes, handlers, session channels, and canonical behavior.
- Handler dependencies are explicit constructor inputs. Handlers must not resolve runtime owners through `getIt`.
- Optional runtime owners remain nullable composition inputs and are resolved lazily by the bridge.
- Local runtime query handlers remain transport-neutral.

## Canonical Envelope
- Use device-first canonical envelopes with explicit device, hardware, session, request, origin, and typed delivery identity.
- Do not emit legacy agent type fields or legacy thread identity in new payloads.
- Preserve opaque event id across transport copies and preserve run/model-step/tool-call distinctions.
- `thinking_mode` is the only session/persistence/protocol field name; do not accept or emit aliases.
- Every request-correlated response carries the original request id.

## Local Runtime Context
- Rebuild per-turn workspace tools before assembling fresh runtime-owned system context for the runner.
- A workspace context cache may be reused only for identical workspace identity and must invalidate when the workspace changes.
- Persist per-turn route/workspace metadata required for canonical history without persisting the ephemeral system prompt.

## Turn Admission and Echoes
- Translate `think` into a typed runtime request preserving session, message, workspace, provider/model, thinking mode, request id, and delivery intent.
- The orchestrator alone classifies automatic input as immediate, queued, or steer from durable state plus current active run.
- Sanad local and cloud transports consume orchestrator-authored user echoes; clients must not synthesize acceptance or queue rows.
- A queued echo preserves raw request id and queued marker; promoted execution uses the same id without the marker.
- Steering targets the active runner, preserves command/target/run identities, and reconstructs tool-boundary placement from structured metadata.
- Late steering after the final tool boundary continues within the same active run and resets pre-continuation terminal accumulation.

## Session and History
- `create_session` bootstraps without execution and preserves an explicit supplied title.
- Workspace-associated session events include workspace identity and recoverable display metadata.
- Session lists use keyset ordering by last accepted user message then session id; only canonical user acceptance advances ordering.
- Reject incompatible filters, malformed cursors, and non-positive limits explicitly.
- History omits absent optional runtime, metadata, and request fields rather than emitting null.
- Hydrate durable pending steer, unacknowledged draft recovery, runtime notice, route transitions, canonical reasoning/tool/final events, and latest context usage.
- Tool input/output appears once in canonical fields and is not duplicated in content.
- Route-transition history snapshots provider display names and anchors ordering to durable request identity.

## Recovery Commands
- Retry/continue route changes broadcast authoritative session preference confirmation to the Sanad client family only after runtime ownership succeeds.
- Concurrent resume is idempotent; already-resuming never mutates or publishes a competing route.
- Restart draft recovery is text-free until a first-writer claim succeeds; only the winning direct response carries recovered items.
- User-stop recovery requires its private owner token for acknowledgment. Restart recovery requires the durable winning claimant id.
- History and broadcasts never grant recovery ownership or expose claimed text.
- Turn edit/retry classifies replay safety before cancellation, requires explicit unsafe/unknown confirmation, establishes authoritative idle, then truncates and dispatches replacement.

## Runtime Queries and Provider Commands
- Shared handlers own workspace list/create/tree, MCP list/save/delete/replace/inspect, skills, slash commands, device settings, provider setup, models, session queries, recovery, and replay.
- Provider account usage limits (Task 55) are read-only and instance-first: `provider.usage.get` fetches a `ProviderUsageResult` typed `available | unsupported | unavailable | auth_required | failed`; `provider.usage.support` returns per-instance capability flags so clients never hardcode a catalog. Result snapshots never carry credentials or raw provider payloads. Usage failure is fully contained — it must not change instance status, readiness, or the ability to execute model requests.
- Keep workspace and MCP commands in the single workspace command owner unless architecture documentation explicitly replaces that ownership; do not fragment it by convenience.
- Workspace browsing starts from real host roots and returns parent metadata; path-only workspace creation derives display name from the folder basename.
- Workspace filesystem handlers remain transport-neutral for local runtime use,
  but the cloud adapter rejects remote create, relocate, browse, folder-create,
  folder-rename, and folder-delete admission before session registration or
  bridge dispatch. Every rejection preserves request correlation and returns
  `remote_workspace_management_disabled`.
- Device settings expose a whitelist only, never secrets, validate the complete mutation before write, report process-environment overrides as externally managed, and acknowledge restart-requiring mutation before scheduling controlled restart.
- Capabilities remain safe with zero configured providers and do not instantiate adapters or perform provider model discovery.
- Provider templates hide unimplemented auth flows.
- Provider auth start requires instance identity; default selection requires ready status.
- Model refresh remains multi-stage under one request id and model snapshots expose authoritative instance readiness with normalized instance-local model ids.

## Permission and Platform Tools
- Sensitive approval uses canonical permission request/response and persists enough state for restart recovery.
- `think` and `steer` never mutate Workspace permission policy. Only the
  explicit `workspace.set_permission_mode` command may select `default` or
  `full_access`, and it resolves the daemon-owned path from a registered
  `workspace_id` rather than trusting a client-supplied path.
- Platform-provided tools use canonical platform call/result and remain distinct from daemon-local execution.
- Permission resolution is first-writer-wins and resumed execution reapplies the persisted decision before invoking the gated tool.

## Logging and Restart
- Local Gateway binds only to loopback and authenticates every HTTP request and
  WebSocket upgrade before route handling. The credential is owner-only in the
  active Sanad Home and appears only in the dedicated header. Host must match
  the configured loopback authority and port; any supplied Origin must be in
  the explicit allowlist.
- Source-development health responses expose the inherited launcher id and
  runtime nonce only as local ownership evidence; neither value is an
  authentication credential, and managed mutation still requires the complete
  launcher lease and client identity to agree.
- Keep streaming events at fine/debug log level and lifecycle, command, and terminal events concise at info level.
- Daemon restart and permanent stop use the shared restart coordinator so local HTTP and protocol callers preserve acknowledgment delay and supervisor exit semantics.
- Long-running restart safety evaluation must not serialize local HTTP acceptance; health, stop, and unrelated WebSocket upgrades remain responsive while a restart waits.
- Never log secrets, raw recovery text, pending steer text, or full sensitive tool payloads.
