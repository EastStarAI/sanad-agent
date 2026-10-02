---
title: "Task 104: Prevent Repeated session.stop_recovery_ack Dispatch on User Stop"
status: "completed"
current_gate: "G2"
priority: "high"
---

# Task 104: Prevent Repeated session.stop_recovery_ack Dispatch on User Stop

## Goal

Ensure that `session.stop_recovery_ack` is dispatched exactly once per user-initiated stop event by cancelling existing `_stopRecoverySubscription` listeners on agent re-subscription in `SessionMessagesCubit`, adding an in-flight acknowledgment guard for `user_stop` recovery items, and verifying with unit tests and interactive UI runtime testing under home `~/.sanad-test`.

## Locked Decisions and Scope

- Work is isolated in worktree `.agent/worktrees/104-stop-recovery-ack-multi-dispatch`.
- Fix the broadcast subscription leak in `SessionMessagesCubit._subscribeToAgent` by explicitly cancelling `_stopRecoverySubscription` before re-subscribing.
- Add an in-memory dedup guard (`_inFlightStopRecoveryAckIds` or check in `_applyStopRecovery`) in `SessionMessagesCubit` so that even if duplicate recovery events are delivered, only the first one executes acknowledgment.
- Keep `_initiatedStopRequestIds` clean and ensure `_applyStopRecovery` cleans up properly.
- Run `fvm flutter analyze` and focused unit tests in `client/`.
- Launch a matched agent and client runtime using `sanad-dev` with `--home ~/.sanad-test` and `--driver` from the worktree.
- Perform interactive UI testing using `sanad-dev ui` to verify that stopping a running session emits exactly one `session.stop_recovery_ack`.
- Document any runtime obstacles, test outcomes, and diagnostics in this task plan.

## Gates

### G0 — Discovery and Root Cause Reproduction
- [x] Trace incoming `stop` command and subsequent burst of 35 `session.stop_recovery_ack` commands in daemon logs.
- [x] Verify in `SessionMessagesCubit._subscribeToAgent` that `_stopRecoverySubscription?.cancel()` is omitted while `_messageSubscription`, `_queuedMessagesSubscription`, `_attentionSubscription`, and `_workspacePolicySubscription` are cancelled.
- [x] Confirm that `_stopRecoveryController` in `DeviceConversationStore` is a broadcast stream controller where uncancelled subscriptions leak indefinitely across agent changes / updates.

### G1 — Implementation and Unit Testing
- [x] Cancel `_stopRecoverySubscription` in `_subscribeToAgent` in `client/lib/features/conversations/presentation/bloc/session_messages_cubit.dart`.
- [x] Add an in-flight / synchronous acknowledgment deduplication guard in `_applyStopRecovery` to guarantee at-most-once acknowledgment dispatch for any `stopRequestId`.
- [x] Add unit test coverage in `client/test/unit/bloc/session_messages_cubit_stop_recovery_test.dart` proving that multiple agent updates do not leak stop recovery listeners and that single `session.stop_draft_recovery` triggers only one `session.stop_recovery_ack`.
- [x] Run `fvm flutter analyze` and relevant unit tests bounded by tail 5 (0 issues found, all 3 tests pass).

### G2 — Interactive Verification and Runtime Scenarios (`sanad-dev`)
- [x] Run matched daemon and client runtime via `sanad-dev run --background --driver --home ~/.sanad-test`.
- [x] Verify runtime status via `sanad-dev status` (Agent port 58090, Client VM service 51979, Worktree 104-stop-recovery-ack-multi-dispatch).
- [x] Send a message that triggers a tool execution or thinking run, then click Stop via `sanad-dev ui tap --key stop_message_btn`.
- [x] Inspect daemon logs via `sanad-dev logs agent -n 60` to verify that `session.stop_recovery_ack` is received exactly once:
  ```
  21:57:31.403 [INFO] [LocalDaemonServerPlatform]: ⬆️ [clients] Sending device_event response: session.stop_draft_recovery
  21:57:31.421 [INFO] [LocalDaemonServerPlatform]: ⬇️ [desktop/macos#MXSC66K8] Received execute_command: session.stop_recovery_ack
  ```
- [x] Test terminal tool execution (`shell_execute` with `sleep`) and 4 consecutive repetitions of stop in the same session:
  - Iteration 1 (`sleep 15`): tool cancelled -> `tool_result` -> `stopped` -> `session.stop_draft_recovery` -> 1 ACK (22:10:13.236).
  - Iteration 2 (`sleep 20`): tool cancelled -> `tool_result` -> `stopped` -> `session.stop_draft_recovery` -> 1 ACK (22:10:46.296).
  - Iteration 3 (`sleep 25`): tool cancelled -> `tool_result` -> `stopped` -> `session.stop_draft_recovery` -> 1 ACK (22:11:24.921).
  - Iteration 4 (`sleep 30`): tool cancelled -> `tool_result` -> `stopped` -> `session.stop_draft_recovery` -> 1 ACK (22:11:50.442).
  - Confirmed 0 listener accumulation or burst duplicates across repeated stop operations.
- [x] Stop the test runtime cleanly using `sanad-dev stop`.

## Acceptance Criteria

- Given an active session with an executing run, when the user clicks Stop, then the daemon receives exactly one `session.stop_recovery_ack`.
- Given multiple calls to `_subscribeToAgent` in `SessionMessagesCubit`, then previous `_stopRecoverySubscription` instances are cancelled and not leaked.
- Given duplicate or replayed `session.stop_draft_recovery` events with the same `stopRequestId`, then `SessionMessagesCubit` acknowledges at most once.
- `fvm flutter analyze` passes with 0 issues.
- All focused client unit tests pass.
- Live interactive verification under `~/.sanad-test` confirms single ACK in daemon logs.

## Definition of Done

- Task gates G0 through G2 completed.
- Code changes verified with automated tests and live interactive driver testing.
- Task plan in `docs/plans/tasks/104-stop-recovery-ack-multi-dispatch.md` updated with evidence and closed gates.
- No dirty temporary artifacts left behind.
