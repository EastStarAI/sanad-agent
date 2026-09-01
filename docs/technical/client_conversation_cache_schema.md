---
title: "Client Conversation Cache Schema"
description: "Ownership, persistence schema, pagination rules, draft correlation, and stable consumer APIs for the Flutter conversation cache."
---

# Client Conversation Cache Schema

> **Parent contract:** `sanad-agent/client/lib/features/AGENTS.md`
> **Owning task:** `docs/plans/tasks/32b-client-conversation-cache-and-drafts.md`
> **Scope:** Flutter client conversation cache, drafts, and per-device state ownership.

## 1. Ownership Model

`ConversationCacheStore` (`lib/features/conversations/domain/stores/conversation_cache_store.dart`) is the single in-memory owner of:

- Active device context.
- Cached workspace list per device. Ready, refreshing, or stale-error workspace snapshots project immediately into both the sidebar and composer selector; a create/update mutation must not wait for the selector popup to open.
- Unscoped conversation page per device.
- Per-workspace conversation pages per `deviceId + workspaceId`.
- Cursors, `hasMore`, loading/error state, and last-refresh time per resource.
- Last typed `ConversationDestination` per device for restart routing.
- Last selected session per device as context inheritance only; it is not a restart-routing source.
- Workspace expansion preference per `deviceId + workspaceId`.
- Draft per session (`deviceId + sessionId`) and New Conversation draft per device.
- Last manually viewed event per `deviceId + sessionId` for conversation viewport restoration.

The daemon remains authoritative. This cache is a display/recovery layer, not a competing source of truth. Widgets and cubits never touch persistence, serialization, or cursor merging directly.

## 2. Snapshot Hierarchy

```
DeviceConversationCacheSnapshot
├── activeDeviceId
├── contexts: Map<deviceId, DeviceConversationContext>
│   ├── lastDestination: ConversationDestination?
│   ├── lastSelectedSessionId (context inheritance only)
│   ├── workspaces: CachedWorkspaceSection
│   ├── unscopedConversations: ConversationSectionPage
│   ├── workspaceConversationPages: Map<workspaceId, ConversationSectionPage>
│   ├── workspaceExpansion: Map<workspaceId, bool>
│   └── newConversationDraft* fields
├── sessionDrafts: Map<"deviceId|sessionId", ConversationDraft>
└── sessionViewportAnchors: Map<"deviceId|sessionId", eventId>
```

## 2.1 Device Selection & Cold-Start Restore Invariants

These two invariants keep the restored device/session coherent across a cold
start and across device switches:

- **Persisted-device-first cold start.** `DeviceCubit` distinguishes "no
  device id persisted" from "a device id is persisted but its config has not
  loaded yet" via `IDeviceRepository.getActiveAgentId()`. When an id IS
  persisted but absent from the still-empty inventory (before the cloud
  device list arrives), the cubit waits with `DeviceNoActive` instead of
  falling back to a default (e.g. the local device). Falling back would
  switch `activeDeviceId` to the wrong device and make the client fetch the
  previously open conversation's history from the local device. Only when no
  id is persisted at all does it fall back to a default device. A successful
  cloud inventory response is authoritative for cloud membership: if the
  persisted cloud id is absent, `DeviceManager` clears it before publishing
  the merged inventory so the cubit can select a valid fallback. This
  reconciliation excludes the local-device id because temporary local-daemon
  unreachability is not authoritative deletion.
- **Cross-device selection invalidation.** `SessionCubit` treats a
  `selectedSession` whose `deviceId` differs from the snapshot's
  `activeDeviceId` as no selection for the new device. It then restores the
  new device's own `lastDestination` session so the sidebar highlights the
  conversation that is actually open. A foreign-device selection must never
  survive a device switch. Sidebar rows compare both device and session
  identity.
- **Disconnect continuity.** A temporary state with known inventory but no
  resolved active device does not replace the cache's active device with null
  or clear the presented timeline. Same-hardware cloud and local inventory
  entries recognize the cloud id represented by the canonical `local-agent`
  entry before deciding that a persisted device was deleted. The canonical
  `local-agent` conversation cache refreshes only while the local transport is
  reachable; a stale cloud-online flag during daemon restart must not replace
  its cached sections with empty cloud responses.

## 3. Resource Lifecycle States

Each resource (workspace section, conversation page) carries a `ConversationResourceState`:

| State | Meaning |
|---|---|
| `notLoaded` | No data ever loaded. |
| `loading` | First load in flight; no snapshot yet. |
| `refreshing` | Snapshot exists; background refresh running. |
| `ready` | Snapshot available; no refresh running. |
| `staleError` | Last refresh failed; a stale snapshot remains. |

This implements stale-while-revalidate: the UI renders the memory/persistent snapshot immediately, then the store refreshes in the background. A resource containing cached rows is always treated as `refreshing`, even if an older lifecycle marker says `notLoaded`; loading indicators must never replace non-empty cached rows.

## 4. Pagination Merge Rules

- Item identity is `deviceId + sessionId`.
- The stale first-page snapshot remains visible while refresh is running, then the first authoritative response replaces it. Rows absent from that response are removed.
- Appended pages deduplicate by session id.
- Server ordering is preserved; the store re-sorts by `lastMessageAt` desc → `updatedAt` desc → `id` asc.
- A response carrying a stale `RequestGeneration` is rejected and does not clobber a newer snapshot.
- Canonical create/update/delete/user-message mutations received while the current section request is in flight are replayed over that response before it becomes visible. This prevents an older first-page or load-more payload from undoing a newer live event.
- Workspace-list and conversation-section generations are independent, and duplicate load-more requests for one section are coalesced by the in-flight guard.
- A successful workspace creation advances the workspace-list generation before inserting the returned workspace, so a list request started earlier cannot remove the created row when it completes.
- The unscoped section always queries with `unscoped_only`; a null workspace id alone is not treated as an unscoped filter.
- A device sidebar refresh always refreshes the unscoped section, but it skips the first conversation-page request for collapsed workspaces. Previously loaded collapsed pages may still revalidate while keeping their cached rows.

### 4.1. Transport Correlation

Sidebar refreshes intentionally request the unscoped section and eligible workspace sections concurrently. Every client-originated conversation command therefore carries a UUID-backed `request_id` that is independent of wall-clock precision. `ConversationCommandGateway` correlates each response to exactly one pending request and rejects a duplicate pending identifier rather than replacing an earlier waiter. Responses may arrive in any order without changing section ownership.

## 5. Drafts

- Existing session draft key: `deviceId + sessionId`.
- New Conversation draft: standalone per-device fields on `DeviceConversationContext`.
- Draft text is preserved through a failed send and cleared only after the daemon emits authoritative acceptance whose `request_id` matches the draft's persisted pending request id. A normal turn is accepted by canonical `user_message`; an auto-delivered steer is accepted by `session.pending_steer_changed` in `pending`, `delivering`, or `delivered` state. Cancelled/recovered steer lifecycles and unrelated request ids never clear the draft.
- A Stop draft-recovery outcome is applied only to the matching
  `deviceId + sessionId` draft and only once for its `stop_request_id`. Recovered inputs are
  prepended in daemon order before any text already present, joined by one
  newline only when both sides are non-empty.
- The cache write completes before the client acknowledges the Stop recovery
  outcome. A transport replay before acknowledgement must produce the same
  draft, not duplicate the recovered prefix.
- Creating a session transfers the New Conversation draft binding to the new session id, then clears the new draft. Session creation is always eager and client-initiated: the first send calls `createSession` (with or without a Workspace) before dispatching the message, so the draft binding moves to the new session immediately rather than waiting for a daemon-side `session_created` correlation.
- Deleting a session clears its draft.
- Composer edits flush before dispatch and before changing device/session ownership. A device switch saves against the previously bound device rather than reading the already-selected replacement device.
- Workspace, provider, model, and thinking mode are persisted with the per-device New Conversation draft and restored with its text. Permission mode is not draft-owned; restoration reloads the selected Workspace policy and never writes a permission mutation.
- Editing after dispatch clears the pending request marker before writing newer text, so acceptance of the older request cannot clear a newer draft.
- Snapshot consumers detect canonical cleanup from the immutable snapshot event itself; an unrelated cache emission while a debounce is pending never clears the editor.

## 6. Timeline History Pagination

Sidebar pagination remains owned by `ConversationCacheStore`; transcript pages
are a separate transient resource owned by the per-device
`DeviceConversationStore` behind `ConversationClient`. The store keeps the
current session's opaque older cursor and `hasMore`, never exposes the cursor to
widgets, and clears that resource on session activation.

The initial tail replaces the timeline atomically. Older pages prepend only
canonical event ids not already present and advance only when the returned
cursor differs from the requested cursor. A matching in-flight request is
coalesced; session/device switches and newer hydration generations reject late
results. Failure leaves the visible timeline and runtime projections unchanged.
Cursor and loaded transcript pages are intentionally not persisted; only the
stable viewport event id survives restart and may trigger an anchored request.

## 7. Persistence

- Backend: `SharedPreferencesConversationCachePersistence` (cross-platform, no secrets).
- Codec: `ConversationCacheCodec` — single namespaced JSON blob under the stable key `sanad_conversation_cache`. Schema compatibility and safe invalidation are owned by the payload codec.
- Schema version: `4`. `lastDestination` is encoded as a typed object containing `kind` plus the valid identity field (`sessionId` or nullable `workspaceId`). Unknown or malformed destination objects decode as absent and therefore default to New Conversation at routing time; `lastSelectedSessionId` is never promoted into a destination.
- `sessionViewportAnchors` stores stable event ids rather than pixel offsets. It is written only after manual scrolling settles, ignored while a session has authoritative active work, cleared by a newly accepted user message, and removed with session/device cleanup.
- Unknown future versions and corrupt payloads invalidate safely.
- Debounced writes via `ConversationCachePersistor` (default 500ms); `flush()` on lifecycle pause/close.
- Bootstrap awaits hydration before `runApp`, and serialized persistence writes prevent an older delayed save from overwriting a newer snapshot.
- At most 50 session summaries per section are persisted. If an in-memory section exceeds that limit, its cursor is discarded so restart cannot skip omitted rows; the next refresh restores authoritative pagination.
- Persisted session summaries include the confirmed provider, exact model id, thinking mode, and
  `route_revision`. `thinking_mode` is the only persisted key and no alternate-key fallback is
  supported. A cached route is only a reconnect projection: live/list/history confirmations still
  pass through the session route reducer before replacing it.
- Execution snapshots, runtime notices, pending permission requests, and
  pending-steer timeline projections are not
  persisted in this cache. They remain per-session state in the active device
  conversation store and are rehydrated from daemon list/history snapshots.
- The durable draft may record applied Stop request ids needed for idempotent
  recovery acknowledgement. It does not persist pending-steer text as draft
  content before an authoritative Stop recovery outcome.
- Session drafts persist `stopRecoveryClaimIds`, keyed by Stop request id, so a
  client that claimed daemon-restart recovery can recognize its own
  `claimed_by` response after a client restart. Claim ids are metadata, not
  recovered user text, and are removed after successful apply/acknowledgement.
- No tokens, credentials, or raw transport payloads are stored.

## 8. Logout / Cleanup Boundary

- `clearCloudUserScope(Set<String> cloudDeviceIds)` removes cloud-device cache and drafts while preserving local desktop inventory.
- `clearDevice(deviceId)` removes all keys for one device.

## 9. Consumer API

`ConversationCacheRepository` (`lib/features/conversations/data/repositories/conversation_cache_repository.dart`) is the intent-based facade. Widgets/cubits call:

- `selectDevice`, `snapshotStream`, `sidebarSnapshotFor`
- `refreshWorkspaces`, `refreshUnscopedConversations`, `refreshWorkspaceConversations`, `refreshDeviceSidebar`
- `loadMore`
- `createWorkspace`
- `setWorkspaceExpansion`
- `recordLastDestination(ConversationDestination)`, `lastDestination(deviceId)`, and `restartDestination(deviceId)`; the restart resolver defaults missing destinations to New Conversation and drops only workspaces authoritatively known to be removed
- `lastSelectedSession(deviceId)` only for inheriting New Conversation context
- `sessionDraft`, `setSessionDraft`, `clearSessionDraft`
- `sessionViewportAnchor`, `recordSessionViewportAnchor`
- `newConversationDraft`, `setNewConversationDraft`, `clearNewConversationDraft`
- `transferNewConversationDraftToSession`
- `applySessionCreated`, `applySessionUpdated`, `applySessionDeleted`, `applyUserMessageAccepted`
- `markSessionDraftAwaitingAcceptance`, `markNewConversationDraftAwaitingAcceptance`
- `prependRecoveredSessionDraft` and Stop-recovery acknowledgement correlation
  keyed by `deviceId + sessionId + stopRequestId`

## 10. Pending input projection boundary (Task 36)

`DeviceConversationStore` owns the live per-session projections for queued
messages and pending steers. Pending steers are keyed by the daemon's raw
`request_id` and accept only increasing lifecycle revisions. The timeline
renders `pending` as one temporary user bubble, transforms that same identity
to delivered, and removes it only after authoritative cancellation. History,
live events, navigation, and reconnect must not create duplicate bubbles.

This projection is deliberately separate from `ConversationCacheStore` draft
ownership. A pending steer is not editable draft text and cannot be copied into
a draft because of navigation, reconnect, or queue clearance. Only a Stop
recovery outcome transfers still-unexecuted text into the draft.

## 10. Stop recovery ownership (Task 36)

The client that initiated Stop applies the outcome correlated to its Stop
request id. It updates the cache even when that session is not currently open;
the visible composer synchronizes only if it is bound to the same device and
session. Another session's composer is never overwritten. Local and cloud
delivery of the same outcome share one idempotency identity, and acknowledgement
is emitted only after the cache persistor has durably accepted the new draft.

For `recovery_reason = daemon_restart`, the first hydrated payload has
`claim_required = true` and no recovered text. The client generates and flushes
a draft-scoped claim id before sending `session.stop_recovery_claim`. It may
apply the returned items only when `claim_required = false` and `claimed_by`
matches either its live claim map or the draft's persisted
`stopRecoveryClaimIds` entry. A losing client never sees or applies the text.
The winning client clears its claim metadata only after draft persistence and
recovery acknowledgement succeed.

## 11. Compaction lifecycle projection (Plan 53)

Compaction lifecycle is a typed per-session timeline projection rather than a
user or assistant message. Live and history transitions fold under the logical
`compaction_id`; started may advance once to completed or failed, but one
terminal status cannot replace the other. History ordering follows the
daemon-provided retained-tail causal position, so cache hydration must preserve
list order instead of sorting these events by timestamps.

## 12. DI Composition

Registered in `lib/core/di/injection.dart`:

- `ConversationCacheStore` — lazy singleton.
- `ConversationCachePersistence` — lazy singleton (SharedPreferences-backed).
- `ConversationCacheRepository` — lazy singleton used by production conversation consumers.
- `ConversationCachePersistor` — lazy singleton hydrated by `AppBootstrap` before the widget tree is created.

`SessionCubit` subscribes to cache snapshots and exposes its legacy flat `agentSessions` field only as a derived compatibility projection until the grouped sidebar migration lands in 32c. It no longer owns a competing session cache in production.
