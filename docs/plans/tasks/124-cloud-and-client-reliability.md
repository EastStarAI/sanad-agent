---
id: 124
title: Cloud and Client reliability follow-ups (G3)
status: in_review
gate: G4 (coordinator review) open; item 4 open
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
| 2 | After a cloud reconnect the session-list request races the device re-announce, and the open conversation stays on "Processing…" until it is reopened. | fixed |
| 3 | An `emitWithResponse` late timeout calls `off(event)` and removes a newer same-event listener. | fixed |
| 4 | Opening a search result, then pressing "+" for a new conversation, stops navigation until a Client restart. | not reproduced; guards added, needs the live NavTrace log |

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

## Item 2 — Cloud reconnect re-sync

### Root cause

`ConversationClientRegistryImpl` called `SocketConversationClient.synchronizeAfterReconnect` exactly once, when the device transport became ready (the Client's cloud socket reached `ready` after `auth_success`). When the Gateway connection drops for both sides, the Client can be ready before the Agent has re-announced its device. That first `get_sessions` is then never answered and only times out. Nothing re-synced when the device later turned Online. The open conversation kept its pre-disconnect execution snapshot ("Processing…") until it was reopened.

A second sync would not have helped either. `getSessions` deduplicates an in-flight default request, so it would have joined the unanswered request.

### Fix

- The registry tracks each managed device's inventory Online flag. In `retainClientsFor`, it re-syncs a client when its device turns Online (the re-announce) and its transport is ready. An inventory update that keeps the device Online does not re-sync.
- `synchronizeAfterReconnect` first invalidates the session snapshot and any in-flight session-list request. It then fetches the list and reloads the open conversation's history, which carries its execution state.
- `DeviceCubit` already passes every merged inventory update to `retainClientsFor`, and a `device_status_changed` event republishes inventory. No new wiring was needed.

### Tests

- `client/test/unit/services/connection_registries_test.dart`: "cloud reconnect re-syncs again once the device re-announces online". Its first request races the re-announce, the Online flip triggers a second request, and a further Online-to-Online update does not.
- `client/test/unit/services/socket_conversation_client_test.dart`: "a re-sync supersedes an unanswered reconnect request and hydrates the open conversation".
- Red → green: `temp/g3/item2-red.log` (2 failed), `temp/g3/item2-green.log` (23 passed).

## Item 4 — Navigation after a search result (not reproduced)

### What the log means

The router logs `NavTrace router.redirect` when it parses every navigation and refresh (`AppRouter.handleRedirect`). It logs `router.buildHome` only when it builds a page (`AppRouter._buildHomePage`). `GoRouterDelegate.setNewRoutePath` (go_router 17.3.0) skips the rebuild when the parsed `RouteMatchList` equals `currentConfiguration`. So "redirect without buildHome" after "+" means one of three things:

- the router was already at the New Conversation location;
- a newer route information superseded it in the same frame;
- the log line came from a refresh, and the "+" handler never called `context.go`.

The main pane follows `SessionCubit` and `SessionMessagesCubit`, not the route. A stuck UI therefore also needs the cubits to keep, or restore, the search result's selection.

### Investigation

A widget harness drives the real `HomeScreen`, `AppRouter`, `ConversationHistoryController`, cache store, and cubits. It covers:

- search from a session and from a New Conversation, with and without an anchor;
- a hit that is not cached, a hit for the session that is already open, and a hit in another or no workspace;
- the top New Session button and the workspace "+";
- a "+" press while the anchored history load is still pending;
- drawer (compact) mode;
- navigation after the "+".

Every variant navigates correctly on current code, so no red test could be written. The following candidates were checked and ruled out by code reading or the harness:

- a double `onSelected` from Enter: on desktop, a handled key event is not passed to the text input, so it cannot also fire `onSubmitted`;
- `context.mounted` early returns (the sidebar subtree is not remounted on these paths);
- the HomeScreen selection "promote" listener;
- the `startNewChat` early-return branch;
- `onEnter` (not configured);
- a search hit whose session carries a missing or foreign `device_id`.

### Kept as regression guards

`client/test/widget/conversation_navigation_back_forward_test.dart`, group "search result then New Conversation (Task 124 item 4)". Log: `temp/g3/item4-guards.log` (16 passed).

### Needed to close

The full Client NavTrace and AppRouterRedirect log of a live repro (`sanad-dev logs client`), including the lines from the search selection through the first failed "+". The decisive lines are `session.selectSession`, `nav.navigateTo`, `home.applyRoute`, `home.applySession`, `session.startNewChat`, `home.selectionListener`, and any `AppRouterRedirect ... redirectPath=` line that is not `allow`. Also record whether the result was opened by click or by Enter, which "+" was pressed, the layout (wide or compact), and the device scope (local or cloud).

### Observed in passing (not changed)

The unscoped "+" (`sidebar_new_unscoped_conversation_btn`, tooltip "New conversation without a workspace") calls `startNewChat(workspaceId: null)`. When it leaves an open session, that restores the open session's workspace, so the new draft is workspace-bound. Pressing a "+" whose resolved destination equals the current New Conversation is a deliberate no-op (redirect with no build). Either effect can look like a dead "+" and deserves a product decision.
