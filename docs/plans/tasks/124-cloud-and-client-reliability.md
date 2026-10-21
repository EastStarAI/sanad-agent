---
id: 124
title: Cloud and Client reliability follow-ups (G3)
status: in_review
gate: G4 (coordinator review) open
created: 2026-10-21
parent_task: none
depends_on: []
delivery: own PR
---

# Task 124 — Cloud and Client Reliability (G3)

## Goal

Fix four reliability defects that were found live on Test Homes. All four predate the recent work: three are the pre-existing gaps recorded by [Task 110](docs/plans/tasks/done/110-critical-priority-srp-refactoring.md), and one is a navigation hang.

## Items

| # | Defect | Status |
|---|---|---|
| 1 | A remembered cloud device that can no longer appear leaves the Client on "No device selected" instead of falling back to the local device. | pending |
| 2 | After a cloud reconnect the session-list request races the device re-announce, and the open conversation stays on "Processing…" until it is reopened. | pending |
| 3 | An `emitWithResponse` late timeout calls `off(event)` and removes a newer same-event listener. | fixed |
| 4 | Opening a search result, then pressing "+" for a new conversation, stops navigation until a Client restart. | pending |

## Item 3 — `emitWithResponse` removes only its own listener

### Root cause

`SocketCommandTransport.emitWithResponse` cleaned up with `_connection.socket?.off(responseEvent)`. Socket.IO's `off(event)` without a handler removes every listener for that event. When a call timed out after a newer call for the same event had registered, the timeout removed the newer call's listener, and the newer call then timed out too even though its response arrived.

### Fix

- The call keeps a reference to the listener it registered and cleans up with `off(responseEvent, listener)` on success and on timeout. Cleanup still targets the connection's current socket, so the Task 110 live-socket guard holds.
- The listener ignores a second delivery after it has completed.
- The test fake socket now mirrors `socket_io_common`'s `EventEmitter`: `off(event, handler)` removes only that handler.
- Agent side: no same-event `off(event)` pattern exists. The only Agent `off` calls (`agent/lib/infrastructure/voice/voice_transport_channel.dart`) already pass their handler.

### Known limit (unchanged)

Response correlation is still by event name. Two concurrent calls for the same event both receive the first response. Only cleanup ownership changed.

### Tests

- `client/test/unit/services/socket_service_decomposition_test.dart`: the skipped test "late timeout keeps a same-event call's response listener on the live socket" is un-skipped, and "a timed-out call removes only its own handler on the same socket" is new.
- Red → green: `temp/g3/item3-red.log` (2 failed), `temp/g3/item3-green.log` (13 passed).
