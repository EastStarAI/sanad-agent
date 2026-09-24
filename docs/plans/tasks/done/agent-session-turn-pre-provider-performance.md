---
status: completed
priority: high
current_gate: done
platforms: windows-primary, macos-linux-regression
depends_on: agent-windows-intermittent-tool-and-history-latency
follow_up: agent-windows-intermittent-tool-and-history-latency
---

# Agent Session Turn Pre-Provider Performance

## Goal

Reduce long-session latency from accepted input to the first provider request by eliminating repeated full-history reads and rewrites and by reusing revision-validated history, without weakening durable admission, message identity, history revision, authorization, or recovery.

## Locked Decisions and Scope

- Implement four evidence-backed changes: metadata-only session reads, one-pass session-record flow, atomic root-user append, and bounded revision-validated history reuse without a process-global `AgentRunner`.
- Preserve `SessionRunOrchestrator` as admission authority and `AgentRunner` as the owner of one active conversation history and model loop.
- Do not introduce a long-lived global `AgentRunner` singleton. Reusable history snapshots are keyed by session identity and `history_revision`, limited to eight recently used sessions, and rejected after any external canonical history mutation.
- Root-user append is one database transaction, is idempotent by raw `request_id`, assigns canonical message/turn identity once, advances `history_revision` once only for a new row, updates canonical session ordering, and returns the committed message.
- Keep full-history replacement for semantic rewrites, healing, replay, compaction, and metadata-patch paths that require it.
- Defer workspace instruction/skill/MCP cache changes. MCP already has configuration-fingerprint caching, while instruction/skill invalidation still requires filesystem discovery. No additional cache is justified until the Windows tool/event-loop investigation measures the shared filesystem/runtime cost.
- Route slow `file_edit` execution and delayed local/cloud socket receipt during tools to the existing `agent-windows-intermittent-tool-and-history-latency` task. Treat Windows as the primary reproduction platform but design the eventual responsiveness fix cross-platform.
- Also deferred: context/compaction algorithm changes, broad timing infrastructure, prebuilt development runtimes, and Flutter profiling.
- Do not switch or restart the user's current runtime from this worktree without a separate explicit request.

## Baseline Evidence

- Post-WAL Windows samples take approximately 14.3–19.2 seconds from incoming session event to `AgentRunner` thinking.
- Warm admission is approximately 2.4–2.7 seconds; classified-to-user publication is approximately 2.9–3.2 seconds; durable user publication-to-thinking is approximately 8.7–13.1 seconds.
- The inspected session has 486 active messages. The former normal-turn path repeatedly hydrated that full history and `replaceMessages` JSON-compared the unchanged prefix before inserting one user row.
- A separate Windows observation shows `file_edit` itself is slow and commands arriving through local/cloud transports may not be logged until the tool finishes, while `shell_execute` does not show the same behavior. That evidence may identify a broader Windows filesystem/event-loop bottleneck and therefore precedes speculative runtime-context caching.
- Live Windows verification used an isolated copied test Home (separate identity and no active execution state), Agent port `58117`, Client VM Service port `51250`, and session `72947eee-dd44-408b-a027-99d019546492`. Two completed turns against that long session measured **10.222s** (`20:06:49.590` → `20:06:59.812`) and **5.581s** (`20:08:30.354` → `20:08:35.935`) from incoming session event to `AgentRunner` thinking. The first sample included one-time healing of an unanswered historical tool call; the second was the clean warm reuse path. Both are below the 14.3–19.2s baseline.
- A separate new-session sample measured **4.974s** from its matching request event (`20:10:13.504`) to thinking (`20:10:18.478`), or **5.012s** when including the session-creation event at `20:10:13.466`. It is recorded separately and is not represented as a long-session sample. A third long-session provider turn was deliberately not sent after the user requested avoiding unnecessary context-token consumption; the evidence requirement is therefore two long-session samples plus one new-session control, not a claim of three long-session samples.
- The same launch exposed a high-priority Windows provider-readiness delay: the Client could show **Provider setup required** before four configured providers finished hydrating and later reported `READY`. The root Agent startup/list delay and secondary Client gating race are delegated to `agent-windows-intermittent-tool-and-history-latency`; this task does not mask the delay with a speculative cache.
- **Windows Tool-Shell sanad-dev Background Launch Fix**: When `sanad-dev run agent --background` was executed from a Windows subshell or agent tool shell (`shell_execute`) constrained by a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, closing the tool shell killed the detached launcher process and daemon child, causing `sanad-dev status` to report `Runtime class: stopped` despite the previous command output claiming `managed`. The issue was resolved in `scripts/sanad_dev`:
  1. `startup_attempt.dart`: Switched Windows background detachment to use CIM `Win32_Process.Create` with `CurrentDirectory` and fixed PowerShell raw-string exit propagation (`exit $LASTEXITCODE`).
  2. `runtime_background.dart`: Eliminated premature `managed` declarations by requiring proven launcher survival (`processRunning(childPid)`) and verified managed component readiness before declaring success.
  3. Verified with 10 focused tests (`sanad_dev_startup_attempt_test.dart` and `sanad_dev_runtime_background_test.dart`), clean analyzer, full package suite with 156 passing and 18 skipped tests, and a live run sequence (`run agent --background` -> `status` -> `logs agent -n 20` -> `stop agent`) where the runtime survived tool-shell exit and reported managed running state.

## Gates

### G0 — Confirm owners and regression seams

- [x] Map pre-provider `getSession` and history-replacement calls on the normal root-turn path.
- [x] Identify focused persistence, runner, runtime-orchestration, and revision-invalidation tests.
- [x] Confirm that runtime catalog caching is not required to complete the evidence-backed history fix.
- [x] Record the technical and QA documentation affected by the implementation.

### G1 — Metadata-only reads and one-pass session flow

- [x] Add an explicit session-record read that never queries or decodes message rows.
- [x] Use metadata-only reads for admission, workspace fallback, routing, and compaction route metadata that do not consume history.
- [x] Reuse the already-read session record through normal admission instead of repeating the lookup.
- [x] Add a regression test proving metadata-only reads succeed without decoding deliberately invalid message JSON.

### G2 — Atomic root-user append

- [x] Add a transaction-owned append operation for a canonical root-user message.
- [x] Prove same-`request_id` retry returns the existing row without duplicate insertion or revision advancement.
- [x] Preserve `message_id`, `turn_id`, `request_id`, `received_at`, active status, session ordering timestamp, and one-step `history_revision` advancement.
- [x] Update `AgentRunner.commitUserMessage` to append and update its owned history without full replacement/reload on the ordinary path.
- [x] Preserve prior message row ids and serialized data during a root append.

### G3 — Revision-validated bounded history reuse

- [x] Reuse up to eight recent session histories only when the persisted `history_revision` still matches.
- [x] Refresh LRU position on a valid hit and evict the oldest session at the bound.
- [x] Invalidate transaction-owned semantic rewrites and deleted sessions.
- [x] Add a regression test proving a direct external history mutation changes the revision and forces authoritative reload.
- [x] Keep `AgentRunner` factory-scoped rather than process-global.

### G4 — Verification, documentation, and evidence

- [x] Run focused persistence, runner, and runtime-orchestration tests.
- [x] Run `fvm dart analyze` with bounded output.
- [x] Run the full fast Agent suite without unrelated Windows baseline failures.
- [x] Update database, engine/runtime, interface-runtime, and QA documentation with ownership, durability, and revision-invalidation behavior.
- [x] Update the parent Windows latency task with explicit slow-tool socket-responsiveness evidence and acceptance coverage.
- [x] Record that `graphify-out/graph.json` is absent; no graph build or update is required.
- [x] Measure two Windows turns on the same long session plus one new-session control and compare incoming-event-to-thinking latency with the recorded baseline. A third long-session turn was intentionally waived at the user's request to avoid unnecessary context-token consumption; it is not claimed as completed.

## Acceptance Criteria

- [x] Given a session containing hundreds of messages, metadata-only reads perform no message-row JSON decoding.
- [x] Given a normal new root turn, the durable user row is inserted without scanning or rewriting the unchanged historical prefix.
- [x] Given a retried raw `request_id`, the same committed message identity is returned and `history_revision` does not advance twice.
- [x] Given an external canonical history mutation, a stale in-memory snapshot is rejected by revision and the authoritative active history is reloaded.
- [x] Existing admission, restart/recovery, replay, compaction, and title behavior remains covered and passing.
- [x] The two measured Windows long-session incoming-event-to-thinking samples, 10.222s including one-time history healing and 5.581s on clean warm reuse, are materially below the 14.3–19.2s baseline; focused durability/recovery regressions pass.

## Definition of Done

- [x] G0–G4 and all acceptance criteria are checked with evidence.
- [x] Focused tests and Agent analysis pass using the FVM-managed SDK.
- [x] Relevant full fast-suite coverage passes; port-binding integration tests remain sequential.
- [x] `docs/technical/agent_database_schema.md`, `docs/technical/agent_runtime.md`, `docs/technical/agent_interface_runtime.md`, and a focused QA matrix describe the implemented behavior.
- [x] The parent Windows latency task owns follow-up investigation of slow `file_edit` execution, socket responsiveness, and delayed provider readiness; this branch contains no speculative catalog cache.
- [x] No current-runtime source handoff, unsafe restart, durability weakening, or authorization caching is included.
- [x] The branch contains only task-related source, tests, and documentation and is ready for review.
