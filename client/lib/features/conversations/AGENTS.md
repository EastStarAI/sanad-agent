# Conversations Feature Contract

## Scope
This contract applies to `client/lib/features/conversations/`.

## Canonical Flow
`UI -> Conversation Cubit -> Conversation Repository -> ManagedConversationClientRegistry -> SocketConversationClient -> ConversationCommandGateway -> SanadSocketService -> Runtime`

Incoming events follow:

`Transport -> EventRouter -> Conversation Client -> UnifiedDeviceMapper -> DeviceConversationStore -> Presentation`

- Presentation must never bypass the repository/client chain or parse transport payloads.
- Preserve exactly one managed conversation client per device.
- Reverse tool execution and tool results remain transport/runtime concerns; presentation never owns that protocol.

## Session Identity
- Represent sessions with `Session` from `client/lib/features/conversations/domain/models/session.dart`.
- A session may carry `deviceId` for routing context but must not carry agent/device runtime-type discriminators.
- Route commands by explicit `device_id`; do not reintroduce type-based routing.
- Create the session eagerly before the first dispatch, with or without a workspace, then activate and select it. Do not send client-generated placeholder session ids to `think`.
- Mark an automatically derived first-message title as placeholder ownership; explicit user titles remain final.
- Immediately synchronize `SessionCubit.selectedSession` after local session creation; do not wait for the remote `session_created` event.

## Runtime Authority
- The daemon alone classifies automatic delivery, resolves queue/steer intent, owns execution and recovery snapshots, and confirms provider/model routes.
- Do not infer authoritative work from presentation flags, create optimistic queue/timeline rows, or clear recovery state before daemon confirmation.
- Session state, drafts, processing, attention, suspension, and recovery remain isolated by device and session identity.
- Reconnect history hydration must reject stale generations, retain live events received while the snapshot is in flight, and reconcile by canonical event identity before replacing the visible snapshot.
- Raw `request_id` is the wire identity. Display prefixes must never become transport ids.
- Replay Edit/Retry eligibility is the latest active root user turn identified by `message_id`, `turn_id`, and `request_id`. Steer events are not replay targets even when they appear as user timeline rows.
- Clients send `expected_history_revision` with replay commands and reconcile accepted replay by hiding superseded identities. They must not truncate the original turn from cache before `accepted`.
- Fork appears under every durable active terminal final answer with `message_id` and `turn_id`. Steer-superseded thoughts and superseded rows do not expose Fork. The client sends those identities only, never the loaded transcript, and must not mutate the parent timeline after success.
- A committed fork is inserted first in the sidebar, selected immediately, and opened at its trailing daemon-derived `session.forked` marker after history hydration. The marker uses the context-compaction timeline-event treatment and never becomes client-authored model context.

## Provider and Capability Boundary
- Device capabilities contain runtime feature flags and lightweight supported-option lists; they are not provider model catalogs.
- Provider/model selection must use daemon-owned provider runtime surfaces.
- Never render an internal provider-instance UUID as a user-facing provider name; resolve daemon-owned display metadata and preserve the previous display value during temporary lookup misses.
