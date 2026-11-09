---
title: "Agent Daemon Memory Retention QA"
description: "Regression matrix for streamed-text accumulation, the in-flight partial answer, the bounded history snapshot cache, and transport-scoped emitter release."
---

# Agent Daemon Memory Retention QA

Verification matrix for the retention rules in
[docs/technical/agent_daemon_memory.md](../technical/agent_daemon_memory.md). Every automated check runs in-process; no
check starts, stops, or signals a live runtime.

## Automated coverage

| Contract | Test | Asserts |
| --- | --- | --- |
| Streamed deltas of one stream accumulate into the whole partial answer | `agent/test/evolution/session_memory_projection_test.dart` — *accumulates deltas of one stream into the whole partial answer* | `getInFlightSnapshot` content equals the concatenation, with the run/turn/step/type identity and timestamps |
| A new run, turn, model step, or stream type starts a fresh projection | same file — *a new run, turn, step, or stream type starts a fresh projection* | the previous text is never carried into a new stream |
| A whole snapshot seeded by a caller is continued only for the same identity | same file — *a whole snapshot seeded for the same stream continues, else resets* | seeding keeps `saveInFlightSnapshot` semantics |
| Identity reads never materialize the payload | same file — *identity reads never materialize the accumulated text* | `hasInFlightSnapshot`/`inFlightRunId` answer without building the string; the later read is still complete |
| Clearing releases the projection | same file — *clearing releases the projection* | `getInFlightSnapshot` is null afterwards |
| The history cache is bounded by count | same file — *keeps the newest eight sessions* | the newest eight survive, older ones are evicted |
| The history cache is bounded by retained text | same file — *evicts by retained text, keeping the newest history* | 4 × 12 MiB histories stay inside the 32 MiB budget and the newest is kept |
| Cache accounting replaces rather than accumulates | same file — *a re-cached history replaces its own accounting* | `historySnapshotChars` reflects the newest history only |
| A finished turn releases its partial answer and commits the whole answer | `agent/test/interfaces/runtime/session_memory_release_test.dart` — *many finished sessions keep no partial answer and a bounded cache* | 12 streamed turns: no in-flight projection remains, the committed assistant message equals the concatenation of deltas, cache bounds hold |
| A reconnecting Client sees the whole partial answer mid-turn | same file — *a reconnecting Client sees the whole partial answer mid-turn* | the live projection is every delta received so far, and is released at the terminal boundary |
| A channel-scoped emitter dies with its channel | `agent/test/interfaces/runtime/platform_runtime_bridge_channel_release_test.dart` — *a channel-scoped emitter is released with its own channel* | the closure that captured the closed socket is dropped |
| An in-process emitter survives a disconnect | same file — *an in-process emitter survives a channel disconnect* | the CLI transport keeps its emitter |
| A reconnecting channel keeps the emitter it registered | same file — *a reconnecting channel keeps the emitter it registered* | closing the older channel does not drop the newer emitter |
| Only the closed channel's sessions are released | same file — *only sessions of the closed channel are released* | a cloud channel is untouched by a local disconnect |
| Session teardown releases every projection | same file — *unregistering the session releases every projection* | `unregisterSession` drops the emitter |

Run them with:

```bash
cd agent
fvm dart test test/evolution/session_memory_projection_test.dart \
  test/interfaces/runtime/session_memory_release_test.dart \
  test/interfaces/runtime/platform_runtime_bridge_channel_release_test.dart
```

## Failing-test evidence

The retained-text bound is a real gate: with the budget condition removed from `SessionManager._cacheHistory`,
*evicts by retained text, keeping the newest history* fails while every other check still passes.

## Manual evidence

1. Start a source runtime and note `footprint <pid>` after startup with no sessions. This is the JIT floor
   (~400–550 MB on macOS for this codebase).
2. Serve a long streamed turn, then read `footprint` again. The untagged heap may rise; it must not rise by an order of
   magnitude over the answer size, and a second identical turn must not raise it by the same amount again.
3. After the turn ends, `session show` must not report `in_flight`, and a Client that reconnects must not restore a
   stale partial answer.
4. Disconnect a Client and confirm the daemon does not keep the session's socket projection: a reconnecting Client
   re-registers its channel and keeps receiving live events.

## Boundaries

- Never start, stop, or signal a live runtime to gather this evidence; use `footprint`/`ps` read-only inspection and the
  in-process suite.
- The in-process suite uses a temporary `SANAD_HOME` and a file-backed `state.db` under it, so a large test payload is
  never held by an in-memory database (which would be measured as retention that does not exist in production).
