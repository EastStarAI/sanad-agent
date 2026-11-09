---
title: "Agent Daemon Memory Retention"
description: "What the long-running sanad-agent daemon retains per session and turn, the release or bound that owns each, the JIT-versus-AOT baseline, and how to measure it."
---

# Agent Daemon Memory Retention

This page owns what the long-running `sanad-agent` daemon keeps in memory for a session and a turn, what releases
it, what is deliberately bounded, and what "normal" looks like for a source (JIT) daemon versus a compiled release
(AOT) binary.

## 1. Scope and the two baselines

The daemon is a single long-lived Dart process that serves many sessions and turns. Every structure described here is
either:

- **turn-scoped** — created by one turn and dropped when that turn ends;
- **session-scoped** — owned per session id and released when the session ends, the run is stopped, or the transport
  that owns it disconnects; or
- **process-scoped** — bounded by construction (a cap, a ring, or a fixed catalog).

Dart's JIT heap keeps a high-water mark: pages that were live during a burst stay allocated (and macOS reports them as
dirty or compressed) even after the objects die. A daemon's `footprint` therefore reflects the **largest** working set
it ever needed, not the current one. That makes two things matter independently:

1. **Retention** — an object that never dies grows the floor permanently.
2. **Allocation churn** — a quadratic copy of a streamed answer raises the high-water mark by roughly an order of
   magnitude over the payload, and the pages do not come back.

Measured baselines (macOS, `footprint <pid>`, "Untagged" = the Dart heap):

| Process | Build | Uptime | Work | Untagged |
| --- | --- | --- | --- | --- |
| Idle source daemon | JIT (`fvm dart run`) | ~1 day | no sessions | ~406 MB |
| Test Home 2 daemon | JIT | ~1 h | testers | ~519 MB |
| Test Home 3 daemon | JIT | ~1 h | testers | ~543 MB |
| Primary source daemon | JIT | ~22 h | dozens of long delegation sessions, 5 concurrent at peak | ~2104 MB |

So the **JIT source baseline is roughly 400–550 MB**, and the primary ran about 1.6 GB above it. A compiled release
binary has no JIT compiler, no kernel service, and no JIT code or metadata in the heap, so its floor is materially
lower; measure it on the installed artifact with the same command rather than assuming a number. An AOT measurement is
not part of this page's evidence because it requires starting a second runtime.

## 2. Ranked retained state

Ranked by the bytes a long delegation workload can plausibly hold. Line references are the owning boundary.

### 2.1 Streamed answer accumulation (largest measured amplifier)

Every provider delta used to be appended with `+=` in three owners and re-serialized in a fourth, so one answer of *n*
characters cost O(n²) copying:

| Owner | Old code | Now |
| --- | --- | --- |
| Engine message content | `fullContent += chunk` | `StringBuffer` (`agent/lib/engine/runtime/runner_stream_coordinator.dart:406`) |
| Engine thought / reasoning | `(thought ?? '') + delta` | `StringBuffer` per stream (`:409`) |
| Turn visible answer | `fullContent += chunk` | `StringBuffer` (`agent/lib/interfaces/runtime/session_turn_executor.dart:326`) |
| In-flight projection | `'${existing['content']}$delta'` | buffered in `SessionManager` (`agent/lib/evolution/session_manager.dart:72`) |

Measured on a 20 MB answer streamed in 4 KB deltas through the real turn executor: **25 s and +176 MB RSS before,
1.5 s and +123 MB after**. The remaining delta is the unavoidable materialization the durable commit and history cache
need.

### 2.2 History snapshot cache (session-scoped, was unbounded by size)

`SessionManager` keeps the last read histories so a turn does not re-read `state.db`:

- `agent/lib/evolution/session_manager.dart:22` — at most 8 sessions.
- `agent/lib/evolution/session_manager.dart:28` — at most 32 MiB of message text in total.

Before this bound the cap was **count-only**, so eight long sessions could pin hundreds of megabytes for the life of
the process. Eviction is safe: a miss re-reads the same rows from `state.db`.

### 2.3 In-flight partial answer (session-scoped, released at the terminal boundary)

`SessionManager` holds one projection per streaming session so a reconnecting Client can restore the partial answer.
It is cleared by the terminal commit, by a stop, and by a blocked or waiting recovery
(`agent/lib/interfaces/runtime/session_turn_executor.dart:668`, `agent/lib/interfaces/runtime/session_stop_coordinator.dart:366`).
The text is buffered and materialized only when a reader asks (`getInFlightSnapshot`); identity reads
(`hasInFlightSnapshot`, `inFlightRunId`) never materialize it.

### 2.4 Suspended runs (session-scoped, holds a whole runner)

`agent/lib/interfaces/runtime/session_run_orchestrator.dart:76` keeps a `SuspendedRun` per session waiting on a
permission or clarifying decision, and that object holds the `AgentRunner` — therefore the session's full in-memory
history. It is removed when the decision resumes the run, when the run is stopped, or when the session's work is
released (`:250`, `:438`). An unresolved interactive wait is intentionally preserved across a managed restart, so this
is the one structure that legitimately holds a history for as long as the user does not answer.

### 2.5 Per-session transport projections (session-scoped, released with the transport)

| Owner | Structure | Release |
| --- | --- | --- |
| `agent/lib/interfaces/runtime/platform_runtime_bridge.dart:86` | session channel + device id | `unregisterChannel` on socket close |
| `agent/lib/interfaces/runtime/platform_runtime_bridge.dart:90` | response emitter closure (captures the Client socket) | `unregisterChannel` when the emitter was channel-scoped |
| `agent/lib/interfaces/runtime/platform_runtime_bridge.dart:88` | permission / platform-tool handlers | `unregisterSession` (in-process CLI teardown) |
| `agent/lib/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart:72` | session → socket, device, hardware id | socket `onDone` (`:357`) |
| `agent/lib/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart:86` | socket → authenticated origin | socket `onDone` (`:351`) |

The emitter closure was the leak: it captures the socket and the command envelope, and it survived the socket, so every
session the daemon had ever served kept a closed `WebSocket` alive. It is now released with the channel that registered
it, and a reconnecting channel keeps the emitter it re-registered.

### 2.6 Small per-session maps (session-scoped, bounded by session count)

These grow with the number of distinct sessions the daemon has seen, not with turns, and each entry is tens of bytes:

- `agent/lib/interfaces/runtime/session_turn_executor.dart:133` — per-session generation counters (no removal; a
  stale callback must still be rejected, so they are kept).
- `agent/lib/core/agent_runtime_service.dart:98` — adapter cache keyed by route signature, documented as no-eviction;
  `:99` records the last route per session for observability.
- `agent/lib/capabilities/permissions/permission_manager.dart:41` — session allow/deny and one-shot approval keys.
- `agent/lib/core/provider_runtime/runtime_recovery_service.dart:37` — active recovery notice, run id, resume timers.
- `agent/lib/interfaces/runtime/session_queue_coordinator.dart:40` — queued input per busy session, drained on idle.
- `agent/lib/core/provider_runtime/provider_rate_limiter.dart:19` — rate-limit windows and cooldowns per provider.

### 2.7 Process-scoped bounded structures

- `agent/lib/core/utils/logger.dart:6` — the log ring keeps 1000 formatted lines (truncated at
  `LOG_MAX_LENGTH`, default 500 characters).
- `agent/lib/evolution/cron_scheduler.dart:52` — schedule events held until the gateway subscribes, then cleared.
- `agent/lib/interfaces/runtime/platform_runtime_bridge.dart:92` — resolved permission records, capped at 256.
- `agent/lib/interfaces/runtime/platform_runtime_bridge.dart:89` — pending permission requests, removed in a `finally`.
- `agent/lib/interfaces/runtime/session_run_orchestrator.dart:158` — queued events, drained per delivery.
- SQLite: one shared connection; the page cache appears in `footprint` as a few megabytes of reclaimable memory.

### 2.8 Provider request dumps (disk, not heap)

`agent/lib/engine/llm_request_dumper.dart` writes dumps under the state Home's `request_dumps`; the dumper never keeps
the payload after writing. Retention is owned by `agent/lib/engine/request_dump_retention.dart` with the policy in
`agent/lib/core/config/request_dump_retention_policy.dart` (default 3 days, one sweep at daemon start then daily).

## 3. What the compaction and dump fixes changed

- **Context compaction anchors (PR #352)** made automatic compaction succeed for `sanad run` sessions. Before it, every
  automatic compaction of a oneshot session failed `continuity_validation_failed`, so a long delegation session grew to
  the model's context limit instead of being summarized. That is a *retention* effect inside a live turn and a *cost*
  effect on every request (a bigger history means a bigger request body per model step), and it is why a daemon running
  the older code carries much larger per-session working sets.
- **Bounded request dumps (PR #354)** capped a 14 GB disk problem. It removed no heap retention; dumps were already
  written and dropped.

Neither change bounded the streamed-answer copying or the history snapshot cache, which is why this page exists.

## 4. Rules that keep the floor bounded

- Accumulate streamed text in a growable buffer; never rebuild an accumulated string per delta.
- A per-session cache is bounded by retained text as well as by entry count.
- A closure that captures a transport is released with that transport, not with the process.
- A projection is released at the boundary that ends it: terminal commit, stop, blocked recovery, socket close.
- Identity reads must not materialize payloads.

## 5. How to measure

```bash
footprint <agent pid>                 # Untagged is the Dart heap; Malloc is native
ps -o pid,rss,etime,command -p <pid>  # RSS is compressed on macOS, so it lags footprint
```

For a heap histogram, connect to the daemon's VM service when it was started with `--enable-vm-service` and call
`getMemoryUsage`/`getAllocationProfile` with `gc=false`. A daemon started by `sanad-dev` does not expose a VM service,
so `footprint` plus the in-process regression suite (`docs/qa_maintenance/agent_daemon_memory_qa.md`) is the supported
evidence path for a normal runtime.
