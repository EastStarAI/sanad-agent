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
- MCP handlers remain transport-neutral for local configuration, but the cloud
  adapter rejects remote list, inspect, save, delete, and replace-config
  admission before session registration or bridge dispatch. Every rejection
  preserves request correlation and returns `remote_mcp_management_disabled`.
  This boundary does not filter MCP tools from cloud-origin turns or prevent
  execution of servers already configured by the local user.
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

## Cloud Device Authentication
- A key-bound `sanad_agent` Device Credential never registers by bearer possession alone. Request a one-use Gateway challenge, then send an ES256 proof over `SOCKET`, the canonical Gateway registration target, nonce, bounded issue time, and fresh JTI.
- Agent registration preserves the device-runtime `capabilities` object and negotiates transport features separately through `transport_capabilities`; delivery-presence advertisement must never replace or change the runtime capability schema.
- The registration proof uses the same Agent-owned P-256 key approved during Device Authorization. Never send the private key, device code, or proof through logs or durable protocol state.
- One-command pairing is a separate provisioning grant but has the same final possession boundary: request a challenge before claim, send pairing token plus public JWK and proof, and retain the same key/credential for fresh-proof lost-response recovery.
- User `sanad_client` access credentials are not an Agent registration fallback for new key-bound enrollment. Their login or rotation must not start Agent registration, and an Agent registration rejection must never refresh the User credential family.

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
- After an authenticated Local WebSocket upgrade, a new Client may send one bounded `client.hello` with protocol/version, Client instance UUID, allowlisted display metadata, capabilities, and an optional Gateway-minted device-bound presence assertion. Only an assertion-bearing hello contributes to the Agent full local-presence snapshot; the hello remains correlation-only, grants no command authorization, and absent/invalid proof preserves legacy Cloud delivery.
- Native desktop authentication reconciliation is local-only. Accept exactly `{"type":"authentication_exchange"}` with no additional fields, reload owner-only `auth.json`, and broadcast no credentials. Reject unexpected fields before payload logging; never route this event through the cloud platform. CLI writers retry the authenticated HTTP trigger within a strict bound, require an explicit credential-free acknowledgment, treat an absent daemon as expected, and surface a restart instruction when a reachable daemon does not reconcile.
- Automatic co-located coupling uses the authenticated loopback HTTP surface only. It may return bounded status, expiry, and non-secret enrollment request identity; it must never return or accept User tokens, Device Credentials, private device codes, proofs, or account identity. Authenticated body-free `DELETE` cancels the current pending enrollment through the Agent-owned private device code and proof, invalidates stale redemption completion, and returns only bounded status so the next start owns a fresh request. Query-bearing and unsupported-method requests fail closed.
- Explicit Agent logout is admitted only as an authenticated local Desktop `POST /auth/logout` with no query or body. It delegates to `AuthManager.logout()`, returns bounded credential-free status, disconnects cloud authorization through the normal auth change signal, and never stops the Local Gateway.
- Keep streaming events at fine/debug log level and lifecycle, command, and terminal events concise at info level. Command lifecycle logs may format only the typed Gateway-authored `origin_client` kind/platform display; malformed or absent origin falls back to `authenticated client`, and ids, free-form metadata, command envelopes, and payloads never enter logs.
- Daemon restart and permanent stop use the shared restart coordinator so local HTTP and protocol callers preserve acknowledgment delay and supervisor exit semantics.
- Long-running restart safety evaluation must not serialize local HTTP acceptance; health, stop, and unrelated WebSocket upgrades remain responsive while a restart waits.
- Never log secrets, raw recovery text, pending steer text, Client instance ids, event ids, presence assertions, origin projections, command/event content, or full envelopes/tool payloads.
