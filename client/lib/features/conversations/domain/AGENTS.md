# Conversations Domain Contract

## Scope
This contract applies to `client/lib/features/conversations/domain/`.

## Store Ownership
- `ConversationCacheStore` is the sole in-memory facade for conversation cache, drafts, workspace expansion, pagination state, and per-device destinations. Internally, responsibilities are decomposed across cohesive owners behind this facade:
  - `CacheGenerationGuard` owns device, workspace, and section generations, and staleness rejection.
  - `WorkspaceCacheProjection` owns workspace lifecycle mutations (creation, update, removal, refresh, error) and expansion projection.
  - `SessionSectionCache` owns conversation sections, session collections, selection, loading and error flags, and viewport anchors.
  - `ConversationDraftCache` owns draft read, write, recovery, and clear operations for existing sessions and New Conversation. Its device-context callbacks (`getContext`, `updateContext`, `ensureDeviceContext`) are required, so a New Conversation draft write can never be silently skipped.
  Owners receive dependencies through explicit constructor parameters or typed callbacks and never reach into another owner's private state; per-device context slices stay owned by `SessionSectionCache` and the other owners read or write them only through its context accessors.
- `DeviceConversationStore` owns canonical timeline state; `ProcessingStore` and attention/execution registries own their respective authoritative projections. It owns independent older/newer history cursors for an anchored slice and may retain at most two recently visited timelines exhausted in both directions so same-runtime navigation does not discard pages the user explicitly loaded; this retention is not persisted cache authority.
- `PendingSteerProjection` owns the pending-steer lifecycle map, the request ids a stop already recovered, and the pending/delivered/cancelled/recovered projection of those rows onto the canonical timeline. It receives the store's timeline state, its selected session id, and its message-emit callback, so a lifecycle row can only project into, re-anchor in, or disappear from the owning conversation timeline.
- Cubits and widgets must not create parallel cache maps, cursors, drafts, processing sets, or recovery stores.
- `SessionCubit.agentSessions` is a compatibility projection from the cache store, not a second owner.

## Device Context and Destinations
- Keep cache contexts and last destinations isolated per device.
- A selected session from another device cannot remain selected after the active cache device changes.
- Persist typed session and New Conversation destinations; conversation-list routes are not restart destinations.
- While New Conversation is active, retain `lastSelectedSessionId` only as context reference and do not reselect it.

## Draft Invariants
- Key existing-session drafts by device plus session and New Conversation drafts by device.
- Preserve drafts after dispatch failure, cancellation, unrelated acceptance, or recovered steer outcomes.
- Clear a draft only when its persisted pending request id matches canonical normal-message acceptance or accepted non-terminal steer lifecycle.
- A newer edit clears the previous pending marker so an older acceptance cannot discard new text.
- Session deletion removes that session's draft; transfer the first New Conversation draft atomically when the runtime session is created.

## Queue, Steer, and Recovery
- Project queue and pending-steer state only from daemon lifecycle/mutation outcomes.
- Scope pending steers by session, raw request id, and monotonic revision, in the dedicated `PendingSteerProjection` owner.
- Pending renders one projection at the live activity tail; delivered reuses it and moves it to the daemon-provided causal anchor; cancelled or recovered removes it.
- Background-session outcomes must not mutate the active timeline.
- Stop-draft recovery removes matching pending-steer projections before offering recovered text to the draft owner, and the recovered request ids are retained by `PendingSteerProjection` so a late lifecycle replay cannot resurrect them.
- Stop-draft recovery also clears the session queued-messages projection atomically, mirroring the daemon's queue cleanup during stop.
- User-stop recovery requires the separately persisted owner token and acknowledgment only after draft persistence succeeds.
- Restart recovery requires an atomic claim; apply text only when `claimed_by` matches this client's claim id.
- A generic stopped event must not discard recoverable text.

## Canonical Identity
- Use `model_step_id` for thinking/final segments and `tool_call_id` for tool pairs; use `run_id` only for execution correlation.
- Never infer tool-call identity from the tool name. Merge a tool terminal only through its canonical call identity, preserve terminal generation/revision metadata, and reject stale or conflicting terminal observations.
- `tool_use` closes only its matching model-step thought.
- `final_answer` and `stopped` remove only the matching running model-step projection and preserve completed prior thoughts.
- A stop without active model-step identity clears runtime controls only.
- Unresolved pending steers follow the latest live activity and remain visible across session navigation. Once delivered, preserve steer ordering after its daemon-provided tool/message anchor and before the post-steer final answer; multiple delivered steers sharing one anchor retain daemon receive order, canonical reconciliation folds lifecycle and durable copies by domain identity even when event ids differ, and later tool-result merges must not move them.
- Accepted replay removes only the matched visible tail and retains turn/run/message tombstones against late events; identity-incomplete legacy events remain blocked until authoritative reconciliation.
- Fold compaction transitions by logical `compaction_id`; terminal status is immutable, so hydration or retry may enrich the same terminal status but cannot switch `completed` and `failed`.

## Snapshot and Attention Safety
- Apply execution, attention, suspension, route, queue, and runtime-notice updates only to their matching session.
- Equal revisions are idempotent only when authoritative payloads agree; a newer elapsed-time observation may refresh the same execution revision without becoming competing execution state. Reject stale or otherwise conflicting snapshots.
- Runtime notices carry the authoritative execution revision. Reject a notice older than the accepted execution snapshot, remove an older notice when a newer snapshot arrives, and reject a stale clear that targets a newer notice.
- Provider/model route confirmation changes only from the daemon-rebroadcast authoritative session preference.
- Context usage is a latest typed snapshot, not an accumulated total; preserve cached-input reporting and never synthesize cache-write usage.
