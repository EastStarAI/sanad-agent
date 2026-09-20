---
title: "Plan 50 Cancellation Regression Matrix"
description: "Verified cancellation, cleanup, delivery-order, and restart-hydration regression coverage for Plan 50."
---

# Plan 50 Cancellation Regression Matrix

Date: 2026-08-29
Status: verified on macOS in aggregation branch `feat/plan-50-run-cancellation`

This matrix records repeatable behavior evidence. The daemon-backed cases use
the production daemon, authenticated Local Gateway, real HTTP/SSE transport,
real shell processes, SQLite persistence, WebSocket delivery, and restart
hydration; they do not use the transport-level E2E success shortcut.

## Run scope and provider interruption

| Scenario | Required outcome | Automated evidence |
|---|---|---|
| Registration races cleanup or arrives after terminal cancellation | Cleanup joins the original deadline and runs once without reopening the report | `agent/test/engine/run_cancellation_scope_test.dart` |
| Stop before provider headers | Request-owned client closes and the request terminates as cancellation | `agent/test/engine/adapters/provider_request_transport_test.dart` |
| Stop after headers and partial SSE content | The live HTTP stream is interrupted; no retry or failover of the cancelled provider turn | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.7 |
| No first byte, idle after first byte, or total bound | The matching typed watchdog wins and cancels upstream | `agent/test/engine/adapters/provider_request_transport_test.dart` |
| A second session runs while the first provider stream is hung | Session B completes through its own provider while session A remains cancellable | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.7 |
| Two clients stop the same session | One shared Stop operation and one terminal lifecycle | `agent/test/interfaces/interfaces_test.dart`; daemon-backed duplicate Stop in F.2.8 |

## Tool and process cleanup

| Scenario | Required outcome | Automated evidence |
|---|---|---|
| User Stop during a live shell | One cancelled terminal is emitted before `stopped`, without waiting for the command timeout | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.8 |
| TERM-resistant descendant writes during grace | Output pipes drain; cleanup escalates to KILL; Stop completes without deadlock | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.8; `agent/test/capabilities/shell_execute_cancellation_test.dart` |
| Parent/child/grandchild containment | The owned process group is gone after successful cleanup | F.2.8 parent/child assertion; Linux grandchild case in `agent/test/capabilities/process_tree_controller_test.dart` |
| Wrapper exits while a descendant remains | Natural completion still removes the live descendant before success | `agent/test/capabilities/process_tree_controller_test.dart`; `agent/test/capabilities/shell_execute_cancellation_test.dart` |
| PID start-identity mismatch | Cleanup refuses to signal a live PID whose fingerprint no longer matches | `agent/test/capabilities/process_tree_controller_test.dart` |
| Timeout races Stop | Exactly one terminal reason wins | `agent/test/capabilities/shell_execute_cancellation_test.dart` |
| Foreground registration is released after natural completion | A later Stop cannot kill the completed process | `agent/test/capabilities/shell_execute_cancellation_test.dart`; `agent/test/engine/run_cancellation_scope_test.dart` |

### Platform gate

- macOS: daemon-backed F.2.8 verifies process-group TERM/KILL escalation,
  output drain, descendant removal, canonical delivery, and restart hydration.
- Linux: real `setsid` parent/grandchild containment is covered by
  `agent/test/capabilities/process_tree_controller_test.dart`; the daemon-backed
  F.2.8 case is enabled on Linux CI as well.
- Windows: the shell cancellation path is exercised with the platform command
  in `agent/test/capabilities/shell_execute_cancellation_test.dart`. POSIX
  process-group assertions are explicitly skipped because Windows owns the tree
  through a Job Object/task-tree implementation rather than PGID signals.

## Durable terminal and delivery order

| Scenario | Required outcome | Automated evidence |
|---|---|---|
| Stop terminalizes an executing tool | Checkpoint and history commit one owner-validated `cancelled` result | `agent/test/engine/tool_terminal_record_test.dart`; `agent/test/evolution/authoritative_session_state_repository_test.dart` |
| Late completion loses after cancellation | It cannot overwrite the cancelled terminal or advance its revision | `agent/test/interfaces/runtime/session_restart_checkpoint_test.dart`; `agent/test/engine/agent_runner_test.dart` |
| Stop delivery ordering | Durable cleanup is committed, then clients receive cancelled terminal, `stopped`, and final idle/queued snapshot in that order | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.8; deferred-publication case in `agent/test/evolution/authoritative_session_state_repository_test.dart` |
| Canonical live/history schema | Both paths preserve tool call, run, generation, revision, reason, cleanup outcome, and timestamps | F.2.8 plus `agent/test/interfaces/sanad_bridge_test.dart` |

## Client and recovery parity

| Scenario | Required outcome | Automated evidence |
|---|---|---|
| Live cancelled tool | Terminal presentation has no running spinner for any tool kind | `client/test/unit/services/device_conversation_event_handler_test.dart`; `client/test/widget/tool_group_tile_test.dart` |
| Late progress or success after cancellation | Cancelled precedence rejects reopening and preserves the authoritative revision | `client/test/unit/services/device_conversation_event_handler_test.dart` |
| Navigation/history replacement | A newer live cancelled terminal survives stale history; authoritative history later hydrates the same terminal | `client/test/unit/services/device_conversation_commands_test.dart` |
| Client reconnects during Stop | A newly connected client receives exactly one cancelled terminal, `stopped`, then idle while a duplicate Stop joins the same operation | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.8 |
| New message after Stop | The fresh turn completes while old late events remain rejected | daemon-backed F.2.8; `client/test/unit/services/device_conversation_event_handler_test.dart` |
| Daemon restart hydration | The restarted daemon returns the same single cancelled terminal and identity fields | `agent/e2e_test/durable_recovery_restart_e2e_test.dart` F.2.8 |

## Final regression result

- Agent analyzer: passed.
- Focused cancellation, durable-state, interface, and daemon-backed E2E suites:
  passed.
- Agent fast test suite: passed.
- Client analyzer, focused cancellation/history/widget suites, and client fast
  test suite: passed.
- The daemon-backed suite binds ports and is run sequentially. Fake provider
  servers bind operating-system-assigned ports to avoid collisions.
- Plan 54 background-task ownership remains outside this matrix; Plan 50 covers
  foreground registration and release only.
