---
title: "Account Sessions and Devices QA"
description: "Automated and interactive verification for account-scoped Client sessions, Agent devices, revocation, and Local event identity."
---

# Account Sessions and Devices QA

## Automated acceptance matrix

| Scenario | Expected result |
|---|---|
| Sessions snapshot loads | Current Client, platform/version, last-active value, and authoritative Online/Offline/Unavailable states render without creating another device store. |
| Refresh fails after a snapshot | The last known rows remain visible and the failure is actionable; unavailable presence is never rewritten as Offline. |
| Current-session confirmation is cancelled | No revoke request is sent and the Client remains signed in. |
| Remote Client revoke is confirmed | Exactly that opaque session id is submitted once and the authoritative snapshot is fetched again. |
| Agent row opens Overview | Settings changes inspection scope only; it does not change the active conversation device. |
| Account-backed Agent revoke is confirmed | Exactly its Backend account `device_id` is submitted once; a hardware-keyed local-only row has no revoke action. |
| Legacy Client-local state exists | Active selection, provider/model/thinking preferences, conversation context/drafts/viewport anchors move idempotently to `hardware_id`, destinations are rebound, hardware-keyed collisions win, and credentials/history are untouched. |
| Local platform-family event precedes the first Client command | The event is stamped with Agent `hardware_id` so the local Client receives it; a session-captured explicit device id remains authoritative. |

## Interactive desktop scenarios

Run from the owning linked worktree with its isolated Home and a driver-enabled Client. Confirm `worktree_runtime_badge` before any action. Source-managed mobile/Simulator fixtures expose the same badge in a compact bottom strip; Production has no strip. With multiple Clients, bind every `sanad-dev ui` command to the intended explicit `--vm-url`.

1. Open Settings → Sessions & Devices and verify Client Sessions and Connected Agents against the authoritative account snapshot.
2. Inspect Online, Offline, Status unavailable, Current, and Last active presentation without interpreting a registry outage as Offline.
3. Open an Agent row through its keyed action and verify only Settings inspection changes; return to Sessions & Devices.
4. Open revoke for a non-current Client, cancel, and verify the row remains and no success is claimed.
5. Reopen non-current revoke and confirm only when using disposable test account/session data; verify the row disappears after authoritative refresh.
6. Open current-session Sign out, cancel, and verify authentication remains active. Confirming this destructive path is optional and requires disposable credentials because it ends the test Client session.
7. If an account-backed disposable Agent is available, cancel then confirm its revoke and prove the hardware-keyed local-only row is never sent as Backend authority.
8. Verify compact layout exposes the same destination, rows, confirmation actions, and status meaning.

## Safety boundaries

- Use a linked-worktree isolated Sanad Home; never use the primary user Home for interactive verification.
- Do not mutate tracked endpoint configuration to point at a test stack. Runtime/profile selection owns endpoints.
- Do not confirm revocation against a production session or device. Cancellation paths are safe against real inventory; destructive confirmations require disposable fixtures.
- Use `sanad-dev ui snapshot/find/tap` and descriptive widget keys. Coordinate taps are not acceptance evidence.
