---
title: "Conversation Cache and Draft Recovery QA"
description: "QA scenarios for persistent conversation snapshots, draft acceptance, pagination recovery, cleanup, and lifecycle flush behavior."
---

# QA: Conversation Cache and Drafts Recovery

> **Parent:** `docs/qa_maintenance/`
> **Owning task:** `docs/plans/tasks/32b-client-conversation-cache-and-drafts.md`

## Recovery Scenarios

### Cold Start

1. Close the app with a populated sidebar (workspaces + conversations cached).
2. Reopen the app.
3. **Expected:** The sidebar renders the persisted snapshot before any remote response arrives. Workspaces, conversation pages, and drafts are visible immediately.
4. A background refresh then updates the data without blanking the list.
5. Verify the first authoritative response removes cached rows no longer returned by the daemon.

### Device Switch

1. Open device A, let its sidebar load.
2. Switch to device B.
3. **Expected:** Device B's cached slice renders instantly (if previously loaded). Device A's data is preserved in the cache but not rendered. No data leaks between devices.

### Refresh Failure

1. With a loaded sidebar, simulate a network failure (e.g. disconnect daemon).
2. Trigger a refresh.
3. **Expected:** The existing data remains visible. The resource state transitions to `staleError`. No blank intermediate state.

### Restart Restoration

1. Expand a workspace, select a session, type a draft.
2. Restart the app.
3. **Expected:** Workspace expansion, last selected session, and draft text are restored.

### Agent-Late Client Restart

1. Keep a local conversation selected, restart Agent then Client, and delay Agent availability until the Client has rendered the route with an offline `DeviceConfig` snapshot.
2. Allow Local Gateway to reconnect and reach `ready`.
3. **Expected:** The retained conversation client hydrates the authoritative session list and then the selected session history without requiring navigation or manual refresh. Stale `isOnline=false` metadata must not suppress reconnect hydration.

### User Message Reordering

1. With multiple sessions listed, send a message in a session that is not at the top.
2. **Expected:** That session moves to the top of its section immediately upon canonical `user_message` acceptance, with updated `lastMessageAt`.

### Session Deletion

1. Delete a session.
2. **Expected:** The session is removed from all pages, its draft is cleared, and if it was the last-selected session, the pointer is cleared.

### Logout Boundary

1. With local and cloud devices cached, log out of the cloud account.
2. **Expected:** Cloud-device cache and drafts are removed. Local desktop inventory cache survives.

### Schema Migration / Invalidation

1. Manually corrupt the persisted JSON blob (or bump the schema version beyond what the client understands).
2. Restart the app.
3. **Expected:** The corrupt/unknown payload is invalidated safely. The app starts with an empty cache and does not crash.

### Debounce Flush

1. Type rapidly in a draft field.
2. Immediately close the app (before the debounce window elapses).
3. **Expected:** The last typed text is flushed on lifecycle close and survives restart.

### Acceptance Correlation

1. Save a draft and mark it pending for request A.
2. Deliver a canonical `user_message` for request B.
3. **Expected:** The draft remains unchanged.
4. Deliver the canonical acceptance for request A.
5. **Expected:** The draft is cleared and the session is reordered.

### Persistence Size and Ordering

1. Load more than 50 sessions into one section and restart.
2. **Expected:** No more than 50 summaries are restored and no stale cursor can skip the omitted rows before refresh.
3. Trigger two overlapping flushes while the first storage write is delayed.
4. **Expected:** The newest snapshot remains persisted after both writes finish.

## Long-History Pagination Matrix

| Scenario | Expected result |
|---|---|
| Open a 10,000-row session | Initial daemon query returns at most 100 rows and 1 MiB of persisted JSON; Client paints the tail without building remote rows. |
| Scroll upward with mouse, trackpad, or touch | One older request starts near the top; repeated notifications coalesce by cursor. |
| Keyboard activate **Show earlier** | The same older request path runs and focus remains usable while loading. |
| Older page arrives | Stable event ids prepend once and the first visible event retains its pixel position. |
| Live append during older request | The live event remains once at the tail after the older merge. |
| Network failure | Existing messages and viewport remain; **Retry earlier messages** appears and automatic retry stops. |
| Response repeats its cursor or returns no progress | Pagination becomes exhausted and cannot loop. |
| Switch session/device during request | Late command and Cubit generations are ignored; no foreign timeline mutation appears. |
| Restore an old saved viewport event | Client sends `anchor_event_id`, opens that bounded page, and aligns the event near the visible top. |
| Missing/deleted/compacted anchor | Agent returns `anchor_not_found`; Client retains the newest tail without repeated requests. |
| Tool-heavy row at a page boundary | Reasoning, thought, tool use/results, and final projection remain one stable fan-out group. |
| Compact and large window resize | No geometry jump, stale inline edit, overflow, or unintended tail-follow activation. |

## Automated Test Coverage

| Scenario | Test file |
|---|---|
| Codec round-trip + invalidation | `test/unit/persistence/conversation_cache_codec_test.dart` |
| Store merge/events/drafts/cleanup | `test/unit/stores/conversation_cache_store_test.dart` |
| Persistor hydration/debounce/flush | `test/unit/persistence/conversation_cache_persistor_test.dart` |
| Repository facade integration | `test/unit/repositories/conversation_cache_repository_test.dart` |
| Production `SessionCubit` cache projection | `test/unit/bloc/session_cubit_test.dart` |
| Agent-late reconnect active-history hydration | `test/unit/services/connection_registries_test.dart` |
| Agent keyset/cursor/anchor/10k bounds | `agent/test/evolution/session_history_pagination_test.dart` |
| Canonical fan-out and compaction page placement | `agent/test/interfaces/sanad_bridge_test.dart`, `agent/test/interfaces/compaction_history_parity_test.dart` |
| Client coalescing/merge/failure/stale generation | `client/test/unit/services/device_conversation_commands_test.dart`, `client/test/unit/bloc/session_cubit_test.dart` |
| Pixel anchoring, auto-fill, manual action, saved anchor | `client/test/widget/brain_activity_view_scroll_test.dart` |
| Spawned-daemon local socket pagination | `client/e2e_test/local_dual_connection_e2e_test.dart` |
