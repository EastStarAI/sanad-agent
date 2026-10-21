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
| 1 | A remembered cloud device that can no longer appear leaves the Client on "No device selected" instead of falling back to the local device. | fixed |
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

## Item 1 — Remembered device that cannot appear

### Root cause

`DeviceCubit._resolveInitialActiveAgent` waited with `DeviceNoActive` whenever a persisted device id was not in inventory, because a cloud inventory might still arrive. That is correct during a normal cold start. But after `sanad-dev` restarts with `--no-cloud`, the Client is built with `ENABLE_CLOUD_GATEWAY=false` and its primary socket is the local transport, so no cloud inventory can ever arrive, and `DeviceManager` never sends `get_devices`. The persisted Test Home 2 id was therefore never reconciled, and the Client stayed on "No device selected" forever. The same happens when the account is signed out, or when the cloud socket ends in `error` or `authFailed`. The conversation cache store only follows `DeviceCubit`, so the codec was not the cause.

### Contract check

`client/lib/features/devices/AGENTS.md` and `docs/technical/client_conversation_cache_schema.md` require the Client to wait for a persisted cloud device "while cloud inventory is pending", and to clear a missing id only on an authoritative inventory. They were silent on the case where no inventory can arrive.

### Decision (conservative, flagged)

- When no cloud inventory can arrive, fall back visibly to the default device: the local device, or the first available registered device.
- Keep the persisted preference. It is overwritten only by an explicit selection: a sidebar pick, or a device-scoped route applied by Home.
- While the fallback is still active, restore the remembered device automatically if it reappears.
- With no available device, stay `DeviceNoActive`.
- A known cloud device that is merely offline is still in inventory, so it stays selected. This is the existing disconnect-continuity rule.

### Fix

- `IDeviceRepository.isCloudInventoryPending` (implemented by `DeviceManager`) is `false` when:
  - the primary socket is the local transport (cloud disabled);
  - no access token exists (`SanadSocketService.hasAccessToken`, which never exposes the token);
  - the cloud socket is in `error` or `authFailed`;
  - an authoritative `devices_response` has already arrived.
- `DeviceCubit` waits only while the inventory is pending. Otherwise it activates the default device and marks the selection as a fallback.
- Internal activations use `_activate`. The public `switchAgent` and `setActiveAgent` end the fallback.
- Cloud lifecycle changes already republish inventory through `DeviceConnectionCoordinator.changes`, so a socket failure that happens after start-up re-evaluates the selection.

### Tests

- `client/test/unit/bloc/device_cubit_test.dart`, group "remembered device that cannot appear":
  - fallback without forgetting the remembered device;
  - fallback when a pending inventory stops being pending;
  - an active cloud device that leaves inventory;
  - restore on reappearance;
  - a user pick replaces the remembered device;
  - no invented selection.
- `client/test/unit/services/device_manager_test.dart`, group `isCloudInventoryPending`: cloud disabled, signed out, connecting or reconnecting, failed, and ready before and after the authoritative inventory.
- Red → green: `temp/g3/item1-red.log` (8 failed), `temp/g3/item1-green.log` (37 passed).
