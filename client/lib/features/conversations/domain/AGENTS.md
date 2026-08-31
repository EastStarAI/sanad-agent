# Conversations Domain Contract

## Scope
This contract applies to `client/lib/features/conversations/domain/`.

## Store Ownership
- `ConversationCacheStore` is the sole in-memory owner of conversation cache, drafts, workspace expansion, pagination state, and per-device destinations.
- `DeviceConversationStore` owns canonical timeline state; `ProcessingStore` and attention/execution registries own their respective authoritative projections.
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
- Scope pending steers by session, raw request id, and monotonic revision.
- Pending renders one projection; delivered reuses it; cancelled or recovered removes it.
- Background-session outcomes must not mutate the active timeline.
- Stop-draft recovery removes matching pending-steer projections before offering recovered text to the draft owner.
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
- Preserve steer ordering after its associated tool and before the post-steer final answer; later tool results merge without moving the steer event.
- Fold compaction transitions by logical `compaction_id`; terminal status is immutable, so hydration or retry may enrich the same terminal status but cannot switch `completed` and `failed`.

## Snapshot and Attention Safety
- Apply execution, attention, suspension, route, queue, and runtime-notice updates only to their matching session.
- Equal revisions are idempotent only when authoritative payloads agree; a newer elapsed-time observation may refresh the same execution revision without becoming competing execution state. Reject stale or otherwise conflicting snapshots.
- Runtime notices carry the authoritative execution revision. Reject a notice older than the accepted execution snapshot, remove an older notice when a newer snapshot arrives, and reject a stale clear that targets a newer notice.
- Provider/model route confirmation changes only from the daemon-rebroadcast authoritative session preference.
- Context usage is a latest typed snapshot, not an accumulated total; preserve cached-input reporting and never synthesize cache-write usage.
