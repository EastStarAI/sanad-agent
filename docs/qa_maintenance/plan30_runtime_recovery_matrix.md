---
title: "Plan 30 Runtime Recovery Matrix"
description: "Focused QA ownership for runtime recovery, route confirmation, reconnect hydration, and never-trapped-session behavior."
---

# Plan 30 Runtime Recovery Matrix

## Scope

This matrix owns verification for:
- `session.runtime_notice` / `session.runtime_notice_cleared`
- daemon-authoritative provider/model confirmation through `session_preferences_updated`
- queued-message ordering while recovery is active
- reconnect/history hydration for `runtime_notice` + `queued_messages`
- stop/retry/change-provider flows that must never leave the session trapped

## Automated Coverage

- Agent:
  - `agent/test/interfaces/sanad_bridge_provider_test.dart` — includes the resumed-run rate-limit handoff regression.
  - `agent/test/interfaces/gateway_delivery_routing_test.dart`
  - `agent/test/interfaces/interfaces_test.dart`
  - `agent/test/interfaces/gateway_manager_error_containment_test.dart`
  - `agent/test/interfaces/runtime/session_restart_checkpoint_test.dart`
  - `agent/e2e_test/durable_recovery_restart_e2e_test.dart`
  - `agent/test/core/provider_runtime/runtime_recovery_service_test.dart`
  - `agent/test/evolution/persisted_runtime_state_repository_test.dart` (Gate C)
- Client:
  - `client/test/unit/services/device_conversation_commands_test.dart`
  - `client/test/unit/bloc/conversation_input_cubit_test.dart`
  - `client/test/widget/conversation_input_panel_rebuild_test.dart`
  - `client/e2e_test/local_dual_connection_e2e_test.dart`

## Required Scenarios

1. A waiting or blocked session always exposes a working stop path.
2. `get_session_history` restores `runtime_notice` and `queued_messages` together.
3. A stale history response for session A never overwrites active session B.
4. Retry and Change Provider send `provider_instance_id + model_id` atomically.
5. The daemon confirms recovered provider/model changes by rebroadcasting `session_preferences_updated`.
6. A second client on the same session converges to the same confirmed route from daemon events.
7. Suspended work resumes before newer queued messages, and both use the updated route.
8. Rejected provider/model changes fall back to the last confirmed route.
9. A provider error embedded in an HTTP 200 SSE payload (`data: {"error":...}`) is surfaced as a runtime notice instead of an empty assistant reply.
10. HTTP 504 Gateway Timeout is classified by the runtime classifier (no longer an unhandled `unknown` crash).
11. Vertex AI / NVIDIA NIM `ResourceExhausted` (worker request limit) is classified as `rateLimit` so the cooldown/retry path applies.
12. **Session stop run isolation**: stop run A, receive message B while A's subscription cancellation is deliberately blocked, then release A and deliver a late callback. B remains queued, starts with a new generation and stable `run_id`, and A cannot emit chunks/final/errors, clear B's busy state, drain B's queue, replace B's recovery notice, persist suspended state, or generate a title. The single legitimate A terminal event is `Execution stopped.` with canonical type `stopped`; it is not an assistant final for A.
12a. Interrupted tool execution (crash/restart recovery): idempotent tools are re-queued automatically, while non-idempotent tools transition the session to `blocked` state with a notice.
13. Restart restoration of active notices: WAITING notices restore timer from `resume_at`, BLOCKED notices fully restore to UI.
14. FIFO queues are reconstructed from SQL on daemon boot via `session_work_items` sequence indices.
15. **Gate C.1**: `session_work_items` is the single source of truth for queued/active work. Legacy `session_suspended_runs` and `session_pending_runs` are `@Deprecated` and no production code path may call them; the schema keeps them only for migration compatibility and `clearAllForSession()` purges stale rows through raw SQL.
16. **Gate C.2**: A successful resume ends with the work item in `completed` (never silently deleted or stuck in `resuming`); a failed resume leaves the same work item reachable in `blocked` and preserves suspended ownership so a later retry or stop can act on it without a new user message.
17. **Gate C.3**: A pre-Gate-C database opens cleanly with the current `AgentStateDatabase`: `session_work_items` is created on first open, legacy rows are still readable for cleanup, and `clearAllForSession()` converges old state into the new single source of truth in a single call.
18. **Gate C.4**: FIFO order survives a real on-disk restart (five enqueued items reopen in the same order), the partial-unique-index active invariant is enforced on a real on-disk state.db, orphans are cleaned up across restarts, a claimed-but-never-completed work item is recoverable as queued (no loss, no duplication), and a non-idempotent crashed work item is moved to `blocked` instead of being silently re-run.
19. **Gate F.1**: daemon startup attaches the gateway/orchestrator bridge before calling restore, so restored notices and queue-drain responses are emitted through the normal production delivery path before any new gateway event is accepted.
20. **Gate F.1**: if startup restore throws, persisted work is converted into a controllable `blocked` recovery state (`Retry`, `Change Provider`, `Stop`) instead of leaving the daemon running with silent unknown state.
21. **Gate F.2.1**: a real daemon restart preserves a waiting notice in the same state directory, hydrates it through `get_session_history`, and a real `session.runtime_retry` resumes the interrupted turn to a real final answer.
22. **Gate F.2.2**: restart after `after_tool_result` resumes from the durable checkpoint without executing the real tool side effect twice; the daemon-backed E2E now uses `schedule_task` and proves the persisted `scheduled_tasks` row count stays at `1` across restart + retry.
23. **Gate F.2.3**: restart followed by `session.runtime_continue_with_provider` reroutes the resumed turn to the new provider instance only.
24. **Gate F.2.4**: restart followed by `session.runtime_stop` clears notice + active work + queued work + durable rows atomically and emits exactly one `session.runtime_notice_cleared` plus one `stopped` transition per client.
25. **Gate F.2.5**: queue-only sessions stranded in SQL are claimed and drained in FIFO order during startup restore, before any newer message can overtake them.
26. Auto-resume regression: if a restored waiting notice reaches `resume_at` but the suspended owner is missing, the runtime converts the session back to `blocked` instead of clearing the notice silently.
27. Protocol regression: `session.runtime_retry` / `session.runtime_continue_with_provider` keep the session blocked when `resumeSuspended()` cannot claim a suspended owner, so recovery controls remain visible.
28. **Concurrent resume idempotency** (Finding #8/#9/#11): When two `session.runtime_retry` commands (or a Retry+Change-Provider pair) arrive concurrently from two clients, `resumeSuspended()` returns `alreadyResuming` for the second caller. The orchestrator resumes exactly once, no spurious missing-work `blocked` notice is emitted, and the first claimant's route wins consistently across runner and session state. Covered by `sanad_bridge_provider_test.dart`, including the reverse ordering where Retry claims before Change Provider.
29. **Active-wait route handoff** (Finding #13): `session.runtime_continue_with_provider` during a real provider wait updates the active runner, queued route, session default, and client confirmation before aborting the old wait; the resumed request uses the selected provider/model.
30. **Stale recovery command isolation** (Finding #14): a `session.runtime_retry` received during a normal busy turn without an active waiting notice is an idempotent no-op and cannot abort the turn or synthesize recovery events.
31. **Late provider response after Stop**: the orchestrator signals `AgentRunner.requestStop()` before cancelling the outer subscription. If an adapter completes an in-flight response afterward with a tool call, the runner discards it, executes no tool, starts no follow-up LLM request, and leaves the session stopped.
32. **Controlled daemon restart continuation**: `/restart` and source-update restart reply first, allow the tool result and durable checkpoint to be written, then exit without cancelling active work. Startup auto-resumes a recognized `after_tool_result` checkpoint through `resumeStream`, so the model receives the completed restart result and the restart command is not replayed. Permanent `/stop` still invokes `requestStopAll()` and clears active/queued work before exit.
33. **Blocked-history lazy hydration**: a durable blocked notice with no active in-memory notice is still surfaced via `get_session_history`, while a durable-only waiting notice stays hidden until the runtime activates it.
34. **Claim guard invariant**: `claimNextQueuedWorkItem()` must return `null` rather than violating the active-row unique invariant when another active work item already exists for the same session.
35. **Interrupted resume replay safety**: startup auto-resumes an interrupted `resuming` item only when its checkpoint is recognized and every executing tool is explicitly replay-safe; ambiguous or non-idempotent tool execution becomes `blocked` without invoking the runner.
36. **Atomic startup resume ownership**: a safe interrupted resume is claimed through `waiting -> resuming` before execution. Terminal success leaves the work item `completed`, removes the suspended owner, makes the session non-busy, and then permits queued work to drain.
37. **Recovery notice lifetime**: `resuming` remains visible before the first assistant chunk and is cleared once on first progress or terminal success; startup recovery must not emit a duplicate clear.
38. **Terminal commit ordering**: a normal `running` or `resuming` turn persists one assistant result, commits `completed`, and only then emits exactly one final event.
39. **Recovery wins terminal race**: changing the owned work item to `waiting` or `blocked` before terminal commit leaves that state unchanged and emits neither a final answer nor a later error for the same run.
40. **Stale terminal owner isolation**: a mismatched `work_item_id`, `run_id`, or generation cannot persist or deliver a terminal result for the current owner.
41. **Terminal persistence failure**: failure while recording the assistant result returns one controlled pre-final error and leaves the work item non-terminal and recoverable.
42. **Durable admission**: a message arriving while durable work is `running`, `resuming`, `waiting`, or `blocked` is accepted as queued even when in-memory busy/suspended projections are absent; only one active row exists and no SQLite uniqueness exception escapes.
43. **Command failure containment**: one unexpected command Future failure produces a controlled response and a later command is still received by the same daemon event loop.
44. **Atomic 429 failover claim**: `running -> waiting -> resuming -> completed` is the only successful automatic path. Route mutation, non-terminal work rewrite, transition persistence, and execution snapshot update commit together before the candidate provider is called.
45. **Stale failover rejection**: a mismatched work item, run, generation, request, notice, or current provider produces no replacement request and no final; Retry and Stop remain available.
46. **Legacy ambiguous waiting**: startup converts waiting/resuming work without a provable durable owner into visible `blocked` recovery. Stop cancels the work and returns the snapshot to idle without deleting saved conversation history.
47. **Same-route automatic retry ownership**: a transient timeout/network failure that will retry moves `running -> blocked|waiting -> resuming`; the retry validates the exact work/run/generation/request owner before the next provider call. Success commits one final answer and returns the snapshot to idle. During the sequence, the sidebar replaces the error icon with the running indicator at `resuming` and removes it at `idle`; clearing the runtime notice alone never leaves a stale error icon.
48. **Interrupted-wait provider handoff**: changing provider while the active runner is sleeping on a retry timer must claim the exact `waiting -> resuming` owner before the next provider call. The execution event is published, terminal commit succeeds, and the session reaches `idle` instead of `recoveryOwnsState`.
49. **Failure while resuming**: a retryable provider failure during `resuming` returns durable work to `waiting`; a blocking or fatal failure moves it to `blocked`. Notice and execution projections converge before another claim is attempted.
50. **Atomic failover publication**: an automatic failover transaction publishes its committed `resuming` execution snapshot as well as its route transition. The client never remains on an older waiting snapshot while the replacement provider is running.
51. **Resuming notice ownership and lifetime**: manual Retry/Change Provider preserves the active run id on the `resuming` notice. The notice remains until real provider progress and then clears once; command acknowledgement alone cannot clear it.
52. **Controlled restart checkpoint grace**: a restart request received from an executing tool waits for the tool result to reach a recognized `after_tool_result` checkpoint before process exit. Startup resumes that checkpoint without re-executing the restart command or classifying it as an interrupted non-idempotent tool.
53. **Global restart drain**: Restart scans every active session. The exact requester tool may be excluded before the one HTTP response, but an unsafe tool in any other session blocks normal restart.
54. **Restart timeout policy**: the default timeout is 60 seconds and an explicit bounded `timeout_seconds` overrides it. A non-forced timeout returns one failure containing blocker identities, cancels drain, starts no new process exit, and resumes queued work.
55. **Forced restart policy**: `force=true` still waits for the requested timeout, returns one forced-success response, and exits only after that response is flushed. Ambiguous tool state remains durable and startup does not replay non-idempotent side effects.
56. **Requester handshake**: a tool-origin restart carries exact session/tool-call identity. After the response, normal restart waits until that tool has a completed result and an `after_tool_result` checkpoint; no other tool is hidden by the exemption.
57. **Manual ambiguous recovery**: automatic startup blocks an executing non-idempotent tool with no result. Explicit Retry or Change Provider restores the durable assistant tool-call batch even when `resume_history_length` points to the preceding model request, preserves completed results, adds a neutral unknown-outcome result only for started unsafe calls, executes never-started calls once in sequential order, clears executing metadata, and gives the provider exactly one result for every original call without replaying an ambiguous side effect.
58. **Suspended input restart classification**: a running work item whose unresolved executing tool calls are all owned by `awaiting_permission` checkpoints restores as `waiting`, emits no interrupted-tool notice, and retains the inline permission or clarifying question.
59. **Suspended history preservation**: runner construction does not heal a tool call with `Tool execution cancelled by user.` while an unresolved checkpoint owns that tool-call id.
60. **Persisted answer terminal ownership**: after restart, the first permission or ask-user answer claims `waiting -> resuming`, restores the original run/generation owner, and commits `completed` before the final response is delivered.
61. **Orphan notice reconciliation**: startup deletes a runtime notice when no active running/resuming/waiting/blocked work item exists, while preserving notices backed by active recovery work.
62. **Bounded restore fallback**: a startup restoration exception blocks only active non-terminal work and never adds an error notice to sessions whose work history is entirely completed or cancelled.
63. **Terminal-history startup bound**: large completed or cancelled work-item payloads are excluded from recovery session/item queries, while queued/running/waiting/blocked/resuming work still reconstructs normally.
64. **Legacy false-block repair**: a `blocked` work item left by the older interactive-restart bug returns to `waiting` when every executing tool call still has an unresolved checkpoint, and its stale interruption notice is deleted.
58. **No implicit force fallback**: client and supervisor restart failures never fall back to process kill or stop/start. Force exit occurs only when the request explicitly carries `force=true`.
59. **Worktree client restart identity**: with primary and linked clients running together, `sanad-dev restart client` from the linked worktree targets only its matching VM service and preserves the same local gateway URL, Sanad Home, preferences prefix, cloud mode, worktree marker, branch, config file, target, and device.
60. **Lossless client launch arguments**: run a linked client whose repository, config, or Sanad Home contains spaces; restart and reload preserve each original argument as one value on Linux, macOS, and Windows.
61. **Client attach identity fails closed**: a missing launch argument, preferences prefix inconsistent with the canonical Sanad Home, or incomplete native process snapshot aborts before attach and returns a nonzero CLI status; linked `--home user` and absolute custom-home profiles remain valid when their namespace is consistent. The only omission exception is a native-discovered primary IDE profile using the canonical primary daemon port, primary Sanad Home, and empty preferences namespace; explicit conflicts, non-default primary ports/homes, and linked-worktree omissions still fail closed.
62. **Client attach completion status**: a failed Flutter attach or a session that exits without reporting the requested restart/reload completion returns a nonzero CLI status.
63. **Client attach fail-closed**: missing launch arguments, an unrecognized client path, a conflicting branch/worktree marker, or a local gateway port that does not match the worktree agent aborts restart/reload before attach; port `58085` is never synthesized as fallback.
64. **FVM attach boundary**: client restart/reload executes through FVM and never invokes a global Flutter executable or injects `config/local.json`.
65. **Closed restart admission**: once the global drain begins, completion of an active turn cannot promote its queued successor, and Retry/Change Provider/auto-resume cannot claim suspended work. Cancelling the drain releases the original FIFO exactly once.
66. **Responsive restart transport**: while a restart waits on an unsafe tool, `/health` and unrelated WebSocket upgrades remain responsive, a concurrent restart receives `already_in_progress`, and permanent `/stop` cancels the pending restart before taking exit ownership.
67. **Restart CLI failure status**: timeout, connection loss, non-JSON response, or any response that does not explicitly confirm `success=true` returns a nonzero `sanad-dev restart agent` status.
68. **Resumable component shutdown**: `sanad-dev stop agent` closes admission, waits for the global safe checkpoint, exits the source supervisor without `requestStopAll()`, and leaves the launcher plus Clients active. `sanad-dev run agent` reclaims checkpoint-safe work exactly once and preserves queued FIFO input. A timeout leaves all components running; `stop agent --force` uses terminal cancellation and produces no later resume.
69. **Bounded multi-provider failover**: one model invocation records every provider instance that fails before streaming. With three qualified same-model instances, failures on A and B route exactly once to C; no failed instance becomes eligible again within that invocation. If every candidate fails, the session reaches its normal controllable recovery state instead of producing an unbounded route-transition cycle.
70. **Staged route label coherence**: when the composer stages a provider/model pair that differs from the selected session route, the chip resolves the staged provider through daemon-owned instance metadata and never pairs the staged model with stale session provider display metadata. An unknown UUID remains hidden.
71. **Known provider failure checkpoint settlement**: a definitive live failure such as HTTP 429 clears `model_request_in_flight`, restores the preceding safe checkpoint, and retains established waiting, Change Provider, Retry, and Stop behavior across daemon restart.
72. **Provider-only restart ownership**: ordinary Restart remains pending across repeated timeout windows and never cancels an in-flight provider request. Explicit Force Restart binds interruption to the exact work-item, run, and generation; a stale blocker cannot cancel or block a completed/replaced owner, and a matching owner transitions to blocked recovery before its stream is cancelled.
73. **Unknown provider outcome replay prevention**: a process interruption while `model_request_in_flight` remains durable restores as blocked, makes Retry, Change Provider, and Stop available, and issues no automatic provider request.
74. **Safe missing-checkpoint repair**: an owned durable user message with no provider/tool/result/deferred evidence is repaired once to `initial_model_request`; ambiguous evidence still blocks, and a failed resume emits no final answer.
75. **Repeated ask-user force stop**: a daemon-backed isolated test issues `system_ask_user`, kills the daemon with `SIGKILL` twice, reopens the same on-disk state after each kill, and observes the same pending request in `waiting` without a blocked notice. One answer then produces one tool result and one final answer.
76. **Typed shell interruption**: explicit Stop alone reports `cancelled_by_user`; shutdown reports `agent_interrupted`; timeout reports `timed_out`. Timeout and shutdown preserve bounded partial stdout/stderr, and a structured timeout result remains `isError=true` in the completion event, checkpoint output, and history metadata.
77. **Crashed shell settlement**: persisted redacted progress, original arguments, and process fingerprint let startup verify/reclaim the owned containment, atomically commit one `interrupted` tool result with unknown outcome, and continue without recovery replay by restoring the original `tool use + tool result` pair to canonical history before provider invocation. A later provider-issued call remains a separate pair; a reused or unverifiable PID is never signaled.
78. **Notice revision convergence**: a runtime notice older than the accepted execution snapshot is rejected or removed, and a stale notice clear cannot erase a newer notice.
79. **Force-interrupted provider Retry**: Retry or Change Provider atomically claims the blocked work as `resuming` and restores its recognized `checkpoint_before_model_request` before invoking the provider. Missing or unknown predecessor evidence leaves the session blocked and issues no provider request.
80. **Atomic provider admission under restart drain**: when drain starts before a turn, the provider call count remains zero. When it starts while a provider/tool loop is active, the current provider response and durable tool result may finish, but the run parks before its next provider request. Cancelling drain releases exactly one next request; successful restart exits without consuming it in the old process.

## Current Status

- **Gate C — Durable Work State Machine**: Complete and verified. `session_work_items` is the single source of truth; legacy `session_suspended_runs` / `session_pending_runs` helpers are `@Deprecated` and the central cleanup path uses raw SQL to avoid internal deprecation cycles. Real-disk FIFO, active invariant on disk, orphan cleanup, crash recovery, non-idempotent crash, and pre-Gate-C migration are all covered.
- **Durable Checkpoints (Gate D)**: Fully implemented in `AgentRunner` and verified via targeted unit tests plus the new suspended-owner regressions that prove a failed resume keeps the same work item reachable for the next retry.
- **Restart Restoration & FIFO (Gate E)**: Rebuilt `SessionRunOrchestrator.restorePersistedState()` and verified via unit tests that now also cover the missing-owner auto-resume fallback back to `blocked`.
- **Production Activation (Gate F)**: Complete and verified. Startup now calls durable restore before `GatewayManager.start()`, startup restore failure is surfaced as a controllable blocked notice, and the real daemon-backed restart matrix is covered by `agent/e2e_test/durable_recovery_restart_e2e_test.dart` (waiting+retry, post-tool-result single side effect, change-provider after restart, stop cleanup after restart, queue-only FIFO drain). Additional startup-fallback and protocol regressions live in `agent/test/interfaces/interfaces_test.dart`, `agent/test/interfaces/sanad_bridge_provider_test.dart`, and `agent/test/interfaces/gateway_delivery_routing_test.dart`. The final verification run passed agent analysis, 604 agent tests with 1 existing skip, all 5 daemon-backed E2E cases, client analysis, and all 360 client tests.

- **Concurrent Resume Idempotency (Final Review #8-#14)**: Complete and verified. `ResumeSuspendedResult` prevents duplicate claims; the first claimant alone may mutate and broadcast a recovery route. The bridge requires an authoritative `waiting` notice before rerouting/aborting an active run, preserves normal busy turns from stale commands, and supports Change Provider during a live rate-limit wait. Regressions cover Retry+Retry, both relevant Retry/Change ordering behavior, active-wait handoff, and stale Retry isolation.
- **Task 35 — Terminal Commit and Safe Admission**: Implemented. Terminal transport is gated by the durable owned commit, active-state admission is transactional, durable busy state overrides missing in-memory projections, active-index conflicts are reclassified to queued, and command Future errors are contained without terminating the daemon loop.
