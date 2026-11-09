# Long-Running Agent Daemon Memory Retention

## Goal
A long-running source daemon must not grow to multiple gigabytes because of unjustified retention or quadratic
allocation: streamed answers are accumulated without re-copying, per-session caches are bounded by retained text, and a
transport-scoped closure is released with its transport.

## Scope and locked decisions
- Observed: the primary source daemon (JIT, ~22 h uptime, dozens of long delegation sessions, 5 concurrent at peak) held
  a 2104 MB Dart heap against a ~406 MB idle floor and ~519–543 MB on two Test Home daemons.
- The measured amplifier is quadratic streamed-text accumulation: four owners rebuilt the accumulated answer (or
  thought/reasoning) on every provider delta. A 20 MB answer in 4 KB deltas cost 25 s and +176 MB RSS.
- The measured retention defect is the history snapshot cache: bounded by session count (8) only, so eight long
  sessions could pin hundreds of megabytes for the process lifetime.
- A second retention defect is the channel-scoped response emitter in `PlatformRuntimeBridge`: it captures the Client
  socket and survived the socket, so every session the daemon had ever served kept a closed `WebSocket` alive.
- Compaction (#352) and request-dump retention (#354) are prior fixes and are documented, not re-opened. #352 changed
  per-turn working-set size (a failing automatic compaction left a delegation session uncompacted), #354 removed disk
  growth only.
- Locked: no runtime was started, stopped, signalled, or inspected through a VM service. Evidence is `footprint`/`ps`
  read-only observation plus in-process tests.
- Locked: dictation (PR #337) and session-deletion (PR #364) files are untouched.
- Locked: the history cache stays a cache. Eviction costs one `state.db` re-read and never changes correctness.
- Out of scope: JIT heap high-water reclamation (a VM property), AOT baseline measurement (requires a second runtime),
  and any change to compaction, request dumps, or session deletion.

## Gates

### G0 — Static inventory
- [x] Enumerate every per-session, per-turn, and process-scoped structure the daemon retains, with the release boundary
      for each, and rank them by plausible bytes.
- [x] Confirm what #352 and #354 already changed so the primary's older code is not misread as a current defect.
- [x] Establish the JIT baseline from read-only `footprint` observation of an idle daemon and two Test Home daemons.

### G1 — Reproduction
- [x] Drive the real `SessionRunOrchestrator`, `SessionTurnExecutor`, `AgentRunner`, `SessionManager`, and a
      file-backed `state.db` in-process; measure `ProcessInfo.currentRss` across many finished sessions.
- [x] Prove the per-turn path does not leak a finished session's answer (growth stops once the history cache is full).
- [x] Prove the streamed-answer cost is superlinear: 20 MB in 4 KB deltas took 25 s and +176 MB RSS.

### G2 — Fix at the owning layers
- [x] `RunnerStreamCoordinator`: accumulate content, thought, and reasoning in `StringBuffer`s.
- [x] `SessionTurnExecutor`: accumulate the turn's visible answer in a `StringBuffer`.
- [x] `SessionManager`: own the in-flight projection as a buffered stream, materialize only on read, and expose
      identity-only accessors so a stop or recovery check never builds the payload.
- [x] `SessionManager`: bound the history snapshot cache by retained text (32 MiB) as well as by count (8).
- [x] `PlatformRuntimeBridge`: release a channel-scoped response emitter with the channel that registered it, and never
      drop an emitter another channel or the in-process CLI owns.

### G3 — Verification
- [x] `fvm dart analyze` in `agent/`: `No issues found!`.
- [x] New tests: `test/evolution/session_memory_projection_test.dart` (9),
      `test/interfaces/runtime/session_memory_release_test.dart` (2),
      `test/interfaces/runtime/platform_runtime_bridge_channel_release_test.dart` (5).
- [x] Failing-test-first evidence: removing the retained-text bound fails *evicts by retained text, keeping the newest
      history* while the rest pass.
- [x] Affected suites green: `test/engine/`, `test/evolution/`, `test/interfaces/`, `test/guards/`.
- [x] Re-measured the 20 MB streamed answer: 1.5 s and +123 MB RSS (from 25 s and +176 MB).
- [x] Size ratchet holds (`session_turn_executor.dart` stays at its allowlisted 1004 lines).

### G4 — Documentation and delivery
- [x] `docs/technical/agent_daemon_memory.md` owns the ranked inventory, the bounds, and the JIT/AOT baseline guidance.
- [x] `docs/qa_maintenance/agent_daemon_memory_qa.md` owns the regression matrix and the failing-test evidence.
- [x] Durable laws recorded in `agent/lib/evolution/AGENTS.md` and `agent/lib/interfaces/runtime/AGENTS.md`.
- [x] `docs/llms.txt` indexes both pages.
- [x] Pull request [#369](https://github.com/EastStarAI/sanad-agent/pull/369) opened against `main`; merge remains an owner decision.

## Acceptance criteria
- [x] Given a provider that streams an answer in many deltas, when the turn commits, then the committed content equals
      the concatenation of the deltas and no projection retains the text.
- [x] Given a Client that reconnects mid-turn, when it reads the session history, then `in_flight` carries every delta
      received so far.
- [x] Given more cached history text than the budget, when a new history is cached, then the oldest snapshots are
      evicted and the newest is kept.
- [x] Given a Client socket that closes, when the bridge releases its channel, then the emitter that captured that
      socket is gone and an in-process or newer channel emitter survives.
- [x] Given a finished turn, when the session is idle, then `hasInFlightSnapshot` is false for that session.

## Definition of Done
- [x] Analyzer clean; focused and affected suites green.
- [x] Owning contracts and design documentation updated in the same change.
- [x] No runtime started, stopped, or signalled; the primary Home was never touched.
- [x] Pull request open with `type/performance` and `comp/agent`; Public CI green on every required check.

## Implementation record

- Baseline (read-only): idle JIT daemon 406 MB, Test Home 2 519 MB, Test Home 3 543 MB, primary 2104 MB untagged.
- Measured before: 20 MB answer in 4 KB deltas → 25 s wall, +176 MB RSS; 12 × 64 KB streamed sessions left the
  snapshot cache at its count cap with no byte cap.
- Measured after: same 20 MB answer → 1.5 s wall, +123 MB RSS; snapshot cache evicts by retained text.
- Remaining after a turn is the durable copy: the history row in `state.db`, the materialized terminal `Message`, and
  the cached history that the next turn reuses.
