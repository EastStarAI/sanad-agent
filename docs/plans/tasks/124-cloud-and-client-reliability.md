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

## Verification

| Gate | Result | Log |
|---|---|---|
| `fvm flutter analyze` (client) | no issues | — |
| `fvm dart analyze` (agent) | no issues | — |
| Client full suite | 1,952 passed | `temp/g3/final-client-suite.log` |
| Agent full suite | 3,231 passed, 14 skipped | `temp/g3/final-agent-suite.log` |
| Client E2E (`local_dual_connection`, `hosted_attachment_relay`), `--concurrency=1` | 14 passed | `temp/g3/final-e2e.log` |
| `fvm dart run scripts/lint_wiki.dart` | success | — |

## Live Scenarios (two Test Homes on the candidate)

Topology: Home A runs the cloud Agent. Home B runs the Client and its own local Agent. Both are signed in to the same account. The Agent suppresses cloud replies to a locally connected Client, so every cloud check runs from Home B against Home A's device.

1. **Device fallback, cloud disabled.** On Home B, select Home A's device, then restart Home B with `--no-cloud`. The Client must show Home B's local device as selected, not "No device selected". Restart Home B with cloud enabled. While no device was picked in between, the Client must return to Home A's device after inventory loads. Repeat, but open a local conversation during the fallback: the Client must then stay on the local device.
2. **Device fallback, signed out.** With Home A's device selected, sign out on Home B. The local device must become selected. The cloud device must not reappear until sign-in.
3. **Pending inventory still waits.** Cold-start Home B with cloud enabled and Home A's device remembered. There must be no transient switch to the local device before the cloud inventory arrives.
4. **Reconnect re-sync.** From Home B, start a long turn on Home A's device. Cut the Gateway connection for both sides, for example by dropping the network briefly. Let the turn finish while disconnected, then reconnect. Once Home A shows Online, the session list must refresh and the open conversation must leave "Processing…" without being reopened. The Client log must show a second `get_sessions` after the device turns Online.
5. **`emitWithResponse` cleanup.** Covered by unit tests. No dedicated live step is needed beyond scenarios 1–4 passing without request timeouts.
6. **Navigation repro (item 4).** On Home B, from a New Conversation and again from an open session:
   - open a search result by click, then press "+" (top New Session, then the workspace "+");
   - repeat the same steps opening the result with Enter;
   - repeat in compact (drawer) layout.

   After each "+" the URL and the main pane must show a New Conversation, and later sidebar clicks must still navigate. If it hangs, capture `sanad-dev logs client` from the search selection through the failed "+" (see Item 4, "Needed to close").

## Live Round 1 Follow-ups

Live r1 on `a725bfbb` (TH2 = A cloud, TH3 = B Client). Results:

- passed: S1a, S3, and the S4 mechanism;
- failed: S1b (D1);
- not reproduced again: item 4.

The live report is outside this repository.

### D1 — An automatic Home restore overwrote the remembered device (High)

**Root cause.** On a cold start with no route, `_HomeScreenContentState._applyInitialSessionSelection` restores the fallback device's last destination with `context.go`. The route change then reaches `_HomeScreenState._applyInitialDestination`, which called `DeviceCubit.setActiveAgent(dest.deviceId)` for every route. That call persisted the local id and ended the fallback through `switchAgent`. Within seconds of start-up, and with no user action, `active_device_id` changed from A to the local device. The `DeviceCubit` unit tests could not see this because the sequence crosses Home.

**Fix.**
- Home marks the routes it produces on its own: the no-route restore, the New Conversation alignment, the conversations-list resolution, the missing-device fallback, and the first-send promotion.
- `_applyInitialDestination` skips `setActiveAgent` for a marked route. User-opened routes still persist their device and end the fallback.
- `DeviceCubit` logs `device.fallback entered`, `device.fallback restored`, and `device.fallback ended by explicit selection` once each at info level, with 8-character id prefixes only. They are info rather than fine because the Client pins the root logger to info in debug builds and turns it off in release builds, so a fine line would never reach a live run.

**Tests.** `client/test/widget/conversation_navigation_back_forward_test.dart`, group "remembered device fallback through Home (Task 124 D1)":
- remembered A, cloud unavailable, fallback to local, Home's automatic restore, cloud back: A is restored and the persisted id stays A;
- a user-opened local route during the fallback persists local, and it wins when cloud returns.

Red → green: `temp/g3/r2-d1-red.log` (1 failed), `temp/g3/r2-d1-green.log` (2 passed).

### D2 — A reply after a Client cloud reconnect was dropped (Medium, pre-existing)

**Root cause.** The fault is on the Agent side, in this repository:
- `ServerSanadGatewayPlatform._emitAgentEvent` gated every cloud emission on `DeliveryPresenceController.claimCloudEgress()`.
- When B's cloud socket drops, the Gateway sends A an interest set without B. A fresh empty `cloud - local` difference suppresses cloud egress.
- After B reconnects, it sends `get_sessions` or `list_workspaces` right after `auth_success`, before the Gateway re-adds B to the interest set.
- A handles the command, and the reply is suppressed by the same gate as a broadcast. Nothing ever retries it.

The `get_appearance` request that was answered 64 ms later arrived after the refreshed interest. The private Gateway does not decide the drop.

**Fix.**
- Agent: replies to commands received on the cloud socket go through `_emitCommandReply`. A reply that carries the request's `request_id` skips the interest gate. Uncorrelated egress, meaning session channel events and `sendResponse` broadcasts, keeps the gate.
- Client: a failed atomic history load (for example one lost in the disconnect) is re-issued when the device store publishes again, for example when the reconnect re-sync lands the history.
- A timed-out request is not retried on the Client. With replies no longer dropped, the reconnect re-sync is answered. Correlated retries would only mask an Agent that never answers. An Agent from before this fix still drops the reply until the next re-announce or re-sync. That mixed-version case is not covered.

**Tests.**
- Agent, `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`: "answers a cloud request even before the requester is back in delivery interest". It also asserts that an uncorrelated broadcast stays suppressed. Red → green: `temp/g3/r2-d2-agent-red.log` (1 failed), `temp/g3/r2-d2-agent-green.log` (227 passed).
- Client, `client/test/widget/conversation_navigation_back_forward_test.dart`: "a failed history load is re-issued once the transport delivers again". Red → green: `temp/g3/r2-d2-client-red.log` (1 failed), `temp/g3/r2-d2-client-green.log` (19 passed).

**Overlap with Plan 83.** `feat/83-port` adds an `ingressAuthority` override and an import to `server_sanad_gateway_platform.dart`, near the top of the class. This change touches only the emit helpers and their call sites, so the textual merge should be trivial.

### D3 — Compact layout overflow (Low)

**Root cause.** The live log points to `client/lib/features/conversations/presentation/widgets/conversation_input_panel.dart` (the New Conversation context-chip `Row`). `ConversationContextChips` already scrolls horizontally. But it sat unflexed inside that outer `Row`, so its scroll view got unbounded width and laid its chips out at their natural size. A long device or workspace name overflows.

A narrow-width test exposed a second overflow at the same width: the desktop status bar's gateway summary (`client/lib/features/home/presentation/widgets/status_bar.dart`).

**Fix.**
- The chips are `Expanded` in their row, so they scroll inside the available width.
- The status-bar gateway button is `Flexible`, and its summary is one line with an ellipsis.

**Test.** `client/test/widget/conversation_navigation_back_forward_test.dart`: "compact New Conversation context chips never overflow". It uses a 420-pixel window and a long device name. Red → green: `temp/g3/r2-d3-red.log` (both overflows), `temp/g3/r2-d3-green.log` (20 passed).

### Testability

- **Fallback lifecycle logs:** added with D1 (`device.fallback entered`, `restored`, and `ended by explicit selection`).
- **Driver Enter action: skipped.**
  - The driver contract (`docs/technical/flutter_vm_driver_cli.md`) has no key-event primitive. Adding one would need a new Client VM extension, a controller action, a CLI command, and a `sanad-dev ui` passthrough, each with its own tests. That is not a small, clean addition.
  - A synthetic framework key event would also bypass the platform text-input path, which is exactly what the Enter-double-delivery hypothesis concerns.

### Round 2 Verification

`origin/main` is unchanged (`4fa4dd72`), so no merge was needed.

| Gate | Result | Log |
|---|---|---|
| `fvm flutter analyze` (client) | no issues | — |
| `fvm dart analyze` (agent) | no issues | — |
| Client full suite | 1,956 passed | `temp/g3/r2-final-client-suite.log` |
| Agent full suite, including the gateway E2E files | 3,232 passed, 14 skipped | `temp/g3/r2-final-agent-suite.log` |
| Client E2E (`local_dual_connection`, `hosted_attachment_relay`), `--concurrency=1` | 14 passed | `temp/g3/r2-final-e2e.log` |
| `fvm dart run scripts/lint_wiki.dart` | success | — |

### Round 2 Live Checks

- **D1:** repeat S1b. On B with cloud on, pick A, then `run --no-cloud`. `active_device_id` must stay A, and the log must show `device.fallback entered`. `run` with cloud on must restore A, and the log must show `device.fallback restored`. Opening a different local conversation during the fallback must log `ended by explicit selection` and keep local.
- **D2:** after a spontaneous or induced Client-only cloud reconnect:
  - the first `get_sessions` and `list_workspaces` after `auth_success` must be answered, with no 10 s timeout and no "Could not refresh" banner;
  - a history load lost in the disconnect must reload without pressing Retry.
- **D3:** the compact layout (phone-size window) must log no RenderFlex overflow.

## Round Log

| Round | Candidate | Result |
|---|---|---|
| r1 | `a725bfbb` | S1a, S3, and the S4 mechanism passed. S1b failed (D1). D2 and D3 found. Item 4 not reproduced. |
| r2 | `39061cd3` | D1 and D3 passed. The D2 Agent fix worked, but acceptance failed because of a new defect, D4. D5 and D6 found. Item 4 not reproduced. |
| r3 | `ad8adae6` (merged with main as `43652814`) | D4 passed live. D5 failed live (below). R1a, R4, and S3 passed. D7 found (already on main). D8 found (relay throughput). |
| r4 | `dc7ee42f` (merged with main `d3040b9a`) | D5 and D7 addressed (below) and both passed live. The D4 and send smokes passed. D8 recorded as a follow-up. One Low observation: a `model.snapshot` is sent during the Offline transition and is answered with `error`. |

### D4 — Cloud replies stalled behind `model.snapshot_result` (High)

**Measurement.** A read-only query of TH2's Agent state database (`provider_model_cache`, 7 instances, 491 cached models) gave these sizes:

| Content | Size |
|---|---|
| Raw cached models | 1,531,209 bytes. One aggregator instance alone held 417 models in 1,018,911 bytes. |
| Same models without `model_metadata` | 285,348 bytes |
| `thinking_control` within that | 192,574 bytes |

The snapshot relayed every cached entry unchanged, including `model_metadata`: the provider's raw `/models` record, with descriptions, pricing, parameters, and links. So each `model.snapshot_result` carried about 1.5 MB.

B also sent two concurrent `model.snapshot` requests per screen (provider setup and the usage catalog), so about 3 MB crossed the relay before the replies queued behind them. Live r2 timings:

- A emitted the result in under 60 ms;
- B received it after 18–60 s, which is roughly 25–80 KB/s through the relay;
- the five `sessions_list` replies queued behind it arrived 40–60 s late, past the 10 s timeout.

**Root cause.** The Agent relayed Agent-internal cache data that is not part of the snapshot contract. The Client only reads `id`/`value`, `name`/`label`, `owned_by`, `supports_reasoning(_output)`, and `thinking_control`.

**Fix (smallest change that removes the head-of-line block).**
- Agent: `_normalizeModelEntry` drops `model_metadata` from the snapshot projection. That is a 5.4× reduction on the measured catalog, with no protocol field the Client reads removed.
- Client: `ProviderSetupClientImpl.modelSnapshot` coalesces concurrent requests for the same device into one in-flight request. That halves the relayed volume on screen open.

**Alternatives not chosen.**
- Delaying the snapshot until after the session list would leave the oversized payload in place for every later reply.
- A split or paged snapshot would change the protocol for no extra gain once the internal record is gone.

**The "5× `get_sessions`".** These are not duplicates. TH2 has 4 workspaces, so one sidebar refresh issues 1 unscoped and 4 workspace-scoped section queries. Each section is already one in-flight request (covered by `conversation_cache_repository_pagination_efficiency_test.dart`). Collapsing them into one request would need a new multi-section query in the protocol. That is not done here, because the section replies are small and only stalled behind the snapshot.

**Tests.**
- Agent, `agent/test/interfaces/sanad_bridge_provider_test.dart`, "model.snapshot stays a bounded client projection of a large aggregator catalog": 400 models with raw metadata. It asserts no `model_metadata` in the reply, the fields the Client reads preserved, and the serialized envelope under 150 KB. Red → green: `temp/g3/r3-d4-agent-red.log` (1 failed), `temp/g3/r3-d4-agent-green.log` (34 passed).
- Client, `client/test/unit/provider_setup/provider_setup_client_impl_test.dart`, "concurrent snapshots for one device share a single request": one `model.snapshot` command for two callers, and a fresh request after completion. Red → green: `temp/g3/r3-d4-client-red.log` (1 failed), `temp/g3/r3-d4-client-green.log` (17 passed).

### D5 — Stale banners after a later success (Low)

**Root cause.**
- "Could not refresh all sections" comes from sidebar sections in `staleError`. Only a refresh of that same section cleared it. The reconnect re-sync (`synchronizeAfterReconnect`) fetches the default session list, not the sections, so the banner stayed.
- The thinking-mode "Retry" chip cleared only on a tap or a model-cache update. A later successful snapshot loaded by another consumer was ignored.

**Fix.**
- `ConversationCacheRepository` watches each refreshed device's session-list publications. On a publication, it refreshes only the sections and workspace list still in `staleError`, once each. Nothing stale means no request. `dispose()` cancels the subscriptions.
- `ProviderSetupClient.modelSnapshots` publishes each successful snapshot under the resolved device id. That is the same id used for coalescing: the explicit device, or this machine's id when the caller passed none. `null` is used only when no id resolves at all, and `isCurrentDevice` marks a request that targeted this machine. A selector on its fetch-failure surface adopts a matching snapshot without a new request.
  - Review fix: the first version published `agent?.id`. An agent-less load therefore never matched a selector whose `activeAgent` is the current device, and its Retry stayed up.

**Tests.**
- `client/test/unit/repositories/conversation_cache_repository_pagination_efficiency_test.dart`: "a failed section refresh is retried when the device publishes its session list". It also checks that no request is sent when nothing is stale. Red → green: `temp/g3/r3-d5-sidebar-red.log`, `temp/g3/r3-d5-sidebar-green.log` (28 passed).
- `client/test/widget/route_thinking_mode_selector_test.dart`: "a later successful snapshot for the device clears the Retry chip". Red → green: `temp/g3/r3-d5-thinking-red.log`, `temp/g3/r3-d5-thinking-green.log` (58 passed).
- `client/test/widget/route_thinking_mode_selector_test.dart`: "an agent-less snapshot load clears the Retry of a selector on the current device". It uses the real `ProviderSetupClientImpl`: the selector's own load times out, then an `agent: null` load is answered. Red → green: `temp/g3/r3b-d5-red.log` (1 failed), `temp/g3/r3b-d5-green.log` (77 passed, together with the provider-setup unit tests).
- `client/test/unit/provider_setup/provider_setup_client_impl_test.dart`: "an agent-less load publishes under the resolved current device id".

### D6 — `device.fallback restored` is in-process only (Low, by design)

The fallback marker lives in memory. `device.fallback restored` can only fire when the remembered device reappears while the same process is running, for example when a failed cloud socket recovers. A `stop`/`run` restart resolves the persisted device directly and logs no fallback line. That is the expected outcome, and it is proved by the selected device and `active_device_id`, not by the log line. The wording is now in `client/lib/features/devices/AGENTS.md`.

### Round 3 Verification

`origin/main` is unchanged (`4fa4dd72`).

| Gate | Result | Log |
|---|---|---|
| `fvm flutter analyze` (client) | no issues | — |
| `fvm dart analyze` (agent) | no issues | — |
| Client full suite | 1,959 passed | `temp/g3/r3-final-client-suite.log` |
| Agent full suite | 3,233 passed, 14 skipped | `temp/g3/r3-final-agent-suite.log` |
| Client E2E (`local_dual_connection`, `hosted_attachment_relay`), `--concurrency=1` | 14 passed | `temp/g3/r3-final-e2e.log` |
| `fvm dart run scripts/lint_wiki.dart` | success | — |

### Round 3 Live Checks

- **D4:** with B on cloud and A selected, run `sanad-dev restart client` on B.
  - B must send one `model.snapshot` where it used to send two concurrent ones.
  - `model.snapshot_result` must reach B in seconds, not 18–60 s.
  - All five section `sessions_list` replies must arrive before the 10 s timeout, with no "Failed to get sessions".
- **D5:** force a section failure, then let a later `get_sessions` succeed (for example through the R4 Agent restart). The "Could not refresh all sections" banner and a thinking-mode "Retry" chip must clear without a tap.

## Live Round 3 Summary

Live r3 on `43652814` (TH2 = A cloud, TH3 = B Client). The live report is outside this repository.

- **D4 passed.** Each B restart sent one `model.snapshot`, the result reached B 0.4–6 s after A emitted it (18–60 s in r2), and every section `get_sessions` was answered in time. A snapshot is now about 0.29 MB.
- **D4 follow-on.** Search and click-to-open passed. A 3.75 MB corpus history missed the 10 s timeout twice while the relay ran at roughly 20–40 KB/s, and loaded in 1.5 s later (D8).
- **D5 failed.** Clean repro (d5-e): A's daemon was frozen right after B's `auth_success`. `list_workspaces`, the default `get_sessions`, the history load, and the snapshot timed out. The section queries sent after that timeout succeeded, and later an A restart re-synced B. "Could not refresh all sections", "Could not refresh workspaces", the history "Could not load", and the thinking Retry all stayed until the user navigated.
- **D7 found.** An A restart while B's section queries were in flight made the Gateway answer each with a correlated `error` event. Every section showed "No conversations" with no banner, and later re-syncs did not repair it.
- **R1a, R4 (mechanism), and S3 passed.**

## Round 4

`origin/main` moved to `d3040b9a` (Plan 84). It merged with no conflicts as `73433fbc`.

### D5 — Stale sidebar surfaces after a later success (Medium)

**Root cause.**
- Round 3 recovered stale sections only from `SocketConversationClient.sessions`, which publishes only the *default* (legacy, unscoped, paged) session list. The successful replies in d5-e were *scoped section queries* (`unscoped_only` and `workspace_id`). They never publish, so nothing refreshed the stale workspace list.
- The default-list publication is also fragile as the only trigger. It is dropped whenever the client's default generation moves during the fetch (any section refresh calls `refreshSessions`, which invalidates it, and so do session events). Also, the watcher captured the device config from the first refresh and never re-subscribed after its stream closed.
- `SessionCubit` refreshes the sidebar only when the active device *id* changes, so the device coming back Online refreshed nothing.
- The thinking control retried only on a tap, a model-cache update, or another consumer's snapshot. Nothing loads a snapshot when the device comes back Online.
- Live evidence limit: the r3 client log ends at 00:14:01. It shows the R4 re-sync (3 default pages) followed by one `list_workspaces` and a second history load, both answered. The log does not show why the banners then stayed. The fix below does not depend on that one path.

**Fix.**
- `ConversationCacheRepository.refreshStaleResources(device)` refreshes, once each, the workspace list and then every section still in `staleError`. It is called after any successful sidebar fetch for the device (workspace list, section first page, next page), on a default-list publication, and by `SessionCubit` when the active device comes back Online. Only successes trigger it, so a failing device cannot loop. The watcher now uses the latest device config and re-subscribes when its stream closes.
- `RouteThinkingModeSelector` retries a failed snapshot once when its active device goes from offline to Online.
- The history "Could not load" overlay already re-issues on a store publication (round 2, D2). The r3 log shows that re-issue being sent at 00:13:58.910 and answered, but the log ends before the outcome. That behavior is unchanged here; live r4 must confirm the overlay clears.

**Tests (red → green).**
- `client/test/unit/repositories/conversation_cache_repository_stale_recovery_test.dart`. Real wiring (cache repository, `SocketConversationRepository`, `ConversationClientRegistryImpl`, `SocketConversationClient`, command gateway, fake cloud socket), with timeouts on the fake clock:
  - "a successful scoped reply refreshes a workspace list that timed out" reproduces d5-e: `list_workspaces` and the default `get_sessions` time out, then the section replies succeed. Red: no `list_workspaces` was ever sent again.
  - "the device Online re-sync refreshes sections that timed out" and "… a workspace list that timed out": the R4 path through `retainClientsFor` offline → Online. These passed before the fix in this wiring and guard the publication path.
  - Red: `temp/g3/r4/d5-sidebar-red.log` (1 failed). Green: `temp/g3/r4/d5-sidebar-green.log` (3 passed).
- `client/test/unit/bloc/session_cubit_test.dart`: "the active device coming back Online refreshes a stale workspace list once". It uses the real `SessionCubit` and cache repository: the workspace list fails, then the device goes offline and Online. It also checks that a later Online update with nothing stale sends nothing. Red: `temp/g3/r4/d5-online-red.log` (expected 4 calls, got 3). Green: `temp/g3/r4/d5-online-green.log`.
- `client/test/widget/route_thinking_mode_selector_test.dart`: "the active device coming back Online refetches a failed snapshot once". Red: `temp/g3/r4/d5-thinking-red.log` (expected 2 calls, got 1). Green: `temp/g3/r4/d5-thinking-green.log` (60 passed).

### D7 — A correlated Gateway `error` reply became an empty list (Medium, on main)

**Root cause.** `ConversationCommandGateway._handleIncomingEvent` completes a pending request with any event that carries its `request_id`, including `error`. Several `ConversationCommands` helpers read their success field with a default:
- `getSessions` (`payload['sessions'] ?? []`), `getWorkspaces`, and `searchSlashCommands` returned empty lists;
- `loadSessionHistory` and the older/newer page loads checked only a payload `error` object, so an `error` event hydrated an empty history;
- `searchSessions` checked only a payload `error` object;
- `createSession` parsed the error payload as a session, `updateSessionPreferences` treated any reply as success, and `deleteSession` and `updateSessionTitle` logged success.

The section was therefore marked `ready` and empty instead of `staleError`. No banner was shown, and because the section was not stale, nothing ever refreshed it.

**Fix.** One shared helper, `ConversationCommands._responseError`, recognizes both shapes: a correlated `error` event and a payload `error` object. `_throwIfErrorResponse` turns it into a `StateError`. All of the helpers above use it, and `searchSessions` keeps its coded `SessionSearchException`. A section answered with an error now becomes `staleError` and keeps its cached rows, its banner, and its Retry, and the D5 recovery refreshes it after the next success. Already safe and unchanged: workspace/folder mutations (`WorkspaceCommandFailure`), `attachment.admit` (requires `accepted`), and replay, fork, and compact (an error payload has no `outcome`, so it parses as `invalid_response` or `failed`).

**Tests (red → green).**
- `client/test/unit/services/device_conversation_commands_test.dart`, group "a correlated Gateway error is a failure, never an empty success": `getSessions`, `getWorkspaces`, `searchSessions`, `searchSlashCommands`, `loadSessionHistory`, `createSession`/`deleteSession`, and `updateSessionPreferences`.
- `client/test/unit/repositories/conversation_cache_repository_stale_recovery_test.dart`: "marks the section stale instead of empty, and a later success repairs it" (live d5-b on the real wiring).
- Red: `temp/g3/r4/d7-red.log` (8 failed). Green: `temp/g3/r4/d7-green.log` (68 passed).

### D8 — Large cloud replies exceed the 10 s timeout on a slow relay (follow-up, out of scope)

In live r3, a 3.75 MB `session_history` took 12.8 s and 17.5 s from A's emit to B's receipt, and 1.5 s later in the same run. A emits in about 0.1 s, so the delay is in the Gateway relay (roughly 20 KB/s to MB/s during the run). Not changed in this task. Candidate directions for a separate task: a byte-bounded first history page, a size-aware request timeout, or relay throughput work in the private Gateway.

### Round 4 Verification

| Gate | Result | Log |
|---|---|---|
| `fvm flutter analyze` (client) | no issues | — |
| `fvm dart analyze` (agent) | no issues | — |
| Client full suite | 2,009 passed | `temp/g3/r4/final-client-suite.log` |
| Agent full suite | 3,395 passed, 15 skipped | `temp/g3/r4/final-agent-suite.log` |
| Client E2E (`local_dual_connection`, `hosted_attachment_relay`), `--concurrency=1` | 14 passed | `temp/g3/r4/final-e2e.log` |
| `scripts/lint_wiki.dart` | not run (this round's rules forbid `fvm dart run`) | — |

### Round 4 Live Checks

- **D5:** repeat d5-e (freeze A right after B's `auth_success` for longer than 10 s, then resume).
  - After the section replies succeed, B must send one more `list_workspaces`, and "Could not refresh workspaces" and "Could not refresh all sections" must clear with no tap.
  - Then restart A. After A shows Online, the thinking Retry must turn into the control after one new `model.snapshot`, and the history "Could not load" must clear.
- **D7:** repeat d5-b (restart A while B's section queries are in flight). Sections answered with an `error` must keep their rows and show "Could not refresh all sections", never "No conversations". After A is back, they must refresh with no tap.

## Live Round 4 Summary

Live r4 on `dc7ee42f` (TH2 = A, cloud; TH3 = B, Client on cloud for the test, then back to `--no-cloud`). The live report is outside this repository.

- **D5 passed.**
  - d5-g: A's verified daemon child was frozen 2 s after B's restart, for 18 s. `list_workspaces` and the unscoped `get_sessions` timed out. The section replies succeeded after resume, and B then sent exactly one more `list_workspaces`. "Could not refresh all sections" cleared about 3 s later, with no tap.
  - d5-e2 and d5-g2: after an A restart, when A showed Online, B sent one `model.snapshot`. The thinking Retry became the control, and the history "Could not load" cleared within about 2 s, with no tap. That closes the r3 history gap.
- **D7 passed.**
  - d7-a and d7-b: A's frozen daemon child was killed with `kill -KILL` while B's sections were syncing. The Gateway answered the section `get_sessions` with correlated `error` events, and the Client logged each one as a failure (`code=error`).
  - The sidebar kept all 26 rows and showed "Could not refresh all sections", never "No conversations". After A's supervisor respawned the child and A showed Online, B refreshed the workspaces and every section with no tap.
- **Smoke passed.**
  - D4: after a B restart, the single `model.snapshot` reached B 0.25 s after A emitted it, and all 8 `get_sessions` were answered in about 1 s.
  - A deepseek-v4.1-flash send from B was answered in under 4 s. The new session shows in both sidebars.
  - R1a held at teardown: with `--no-cloud`, B shows "This device", not "No devices".
- **Observation (Low).** On the Offline transition, B sends a `model.snapshot` to the offline device, and the Gateway answers it with `error`. This is harmless, because the Online retry follows.

