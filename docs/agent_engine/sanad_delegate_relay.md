---
title: "Sanad Delegate CLI Relay Specification"
description: "Machine contract for the native `sanad run` relay: argument/workspace security boundaries, versioned result and event artifacts, exit codes, and supervisor lifecycle with event-first intervention, queue control, cancellation, multi-run cursor watching, launch verification, mid-turn steering, task continuation, and silence/dead-worker detection."
---

# Sanad Delegate CLI Relay Specification

## 1. Overview

The `sanad run` command provides the native, daemon-backed execution machine contract for delegating autonomous tasks to Sanad Agent from external orchestrators (such as `delegate-task-supervisor`, OpenCode, Antigravity, or CI/CD systems).

Instead of requiring an external runner script or language runtime, the execution relay is implemented directly within the Agent's compiled binary (`sanad run`). Orchestrators drive the CLI through standard arguments, prompt files/pipes, and structured artifact output directories.

---

## 2. Architecture & System Boundaries

```
┌────────────────────────────────────────────────────────┐
│   Supervisor / Orchestrator (e.g. OpenCode / agy)      │
└──────────────────────────┬─────────────────────────────┘
                           │ executes `sanad run ...`
                           ▼
┌────────────────────────────────────────────────────────┐
│                   sanad run (CLI)                      │
│  - Brief file / stdin ingestion (argv safety)          │
│  - Decoupled execution root via request metadata       │
│  - Serialized artifact coordinator (FIFO queue)        │
│  - Scoped lifecycle & timeout supervisor               │
└──────────────┬──────────────────────────┬──────────────┘
               │ Local Gateway WebSocket  │
               ▼                          ▼
┌────────────────────────────────────────────────────────┐
│              Sanad Agent Local Daemon                  │
│  - Resolves workspace tools & MCP to execution root    │
│  - Binds conversation & persistence to workspace ID    │
│  - Survives suspended decisions & restart recovery     │
└────────────────────────────────────────────────────────┘
```

### 2.1. Strict Separation Pact Boundary
- **`sanad-delegate` Skill:** Global instruction skill that teaches external orchestrators how to formulate invocations, handle prompt transport, and observe results.
- **`sanad run` Command:** Agent-owned native CLI implementation that manages headless turn execution, child process signal handling, timeout-triggered scoped cancellation, and serialized artifact writes.
- **Higher-Level Supervisors:** Multi-agent orchestrators (`delegate-task-supervisor`) that own task graphs, worktree life-cycle, concurrency, and human oversight.

---

## 3. Invocation Protocol & Security Boundaries

### 3.1. Parameter Ingestion & Validation
Deterministic validation ensures invalid or contradictory options fail early with exit code `2`:

| Parameter | Type | Required | Description |
|---|---|---|---|
| `--brief-file` / `-b` | Path | Conditional | Path to file containing the task prompt. Avoids argv length limits and shell escaping. |
| Positional prompt / stdin | Text / Pipe | Conditional | One-shot prompt or redirected standard input. Cannot be combined with `--brief-file`; the exit-2 error names each unexpected argument (often a value given to a flag that takes none). |
| `--workspace` / `-w` | String | Alternative | Registered persistent workspace used for conversation identity and continuity. It may accompany `--execution-root`. |
| `--execution-root` | Path | Alternative | Existing directory used as the filesystem/tool context. When combined with `--workspace`, it targets an isolated worktree without registering another logical workspace. |
| `--out-dir` / `-o` | Path | Optional | Output directory where structured artifacts (`result.json`, `events.jsonl`) are written. |
| `--session` / `-s` | UUID | Optional | Pre-allocated session identifier; generated automatically if omitted. |
| `--provider` | String | Optional | LLM provider override. |
| `--model` / `-m` | String | Optional | Model name override. |
| `--thinking-mode` | Enum | Optional | Explicit thinking option id such as `medium`, `off` or `on` (the product option ids plus legacy aliases); forwarded unchanged to the daemon, which validates it against the route before dispatch. A rejected value fails the run with exit `1` and the specific code. Legacy `--thinking` remains a shorthand for `deep`. |
| `--timeout` | Seconds | Optional | Whole number of seconds (1–86400). Scoped session stop is triggered upon expiry. |
| `--reconnect-timeout` | Seconds | Optional | Whole number of seconds (1–86400, default `60`). Bounded window that an attached `sanad run` spends reconnecting to the same Home's daemon and re-attaching to its own in-flight turn across a restart. |
| `--events` | Flag | Optional | Streams real-time NDJSON events to standard output. |
| `--allow-all-tools` | Flag | Optional | Auto-approves ordinary tool execution requests. Questions (`system_ask_user`) remain pending. |
| `--quiet` / `-q` | Flag | Optional | Suppresses banners and tool output, printing only the final assistant text. |
| `--json` | Flag | Optional | Emits structured JSON response envelope upon completion. |

### 3.2. Workspace or Temporary Execution Context

Every run must select at least one targeting mode:

1. Use `--workspace` for a registered persistent project. Its identity, path, policy, context, and tools remain aligned.
2. Use `--execution-root` alone for a one-run filesystem context. The Local Gateway flattens transported session metadata into `AgentTurnRequest.metadata`, where `execution_root` drives tools and context, survives suspended-decision recovery, and is never registered as a workspace.
3. Use both for delegated development: `--workspace` retains the existing logical conversation owner while `--execution-root` independently drives tools and runtime context in the target worktree. The CLI validates and records both; the daemon preserves both identities.
4. Neither mode creates, selects, or switches a workspace, and neither the CLI nor daemon mutates `Directory.current`.

### 3.3. Runtime Attachment & Daemon Discovery Deadlines

Without `--standalone`, a run resolves its runtime mode by probing the Local Gateway `/health` endpoint of the selected Sanad Home. That probe is the only evidence used to decide between attaching to the running daemon and starting an in-process runtime, so the CLI owns two distinct bounded deadlines:

| Probe scope | Target | Deadline |
|---|---|---|
| Targeted | An explicitly supplied endpoint: `--gateway-url`, or a gateway URL/port from the environment (`SANAD_GATEWAY_URL`, `LOCAL_GATEWAY_URL`, `LOCAL_GATEWAY_PORT`) | 2 s |
| Speculative | The default port and the worktree port scan, whose cost multiplies across the scanned range | 300 ms |

An explicitly targeted endpoint is the only evidence that the requested gateway is served, so a healthy but busy daemon whose first health response is slower than the speculative bound still attaches instead of being mistaken for an absent daemon. The wider bound stays far below the WebSocket connect timeout, and an unreachable loopback endpoint still fails fast with a refused connection. Speculative probes keep the cheaper bound so that an absent daemon cannot turn discovery into a long startup delay.

Discovery remains fail-closed and bounded in every other case. It never bypasses health, authentication or Home ownership, never rewrites the requested endpoint, and never starts another daemon, Home or runtime. An explicitly supplied probe deadline still overrides both scopes.

Reaching the in-process standalone path without `--standalone` means no healthy daemon could be confirmed for that Home. When another runtime owns that Home, the run stops with exit code `78` and reports that the daemon endpoint for the Home could not be confirmed, rather than blaming a `--standalone` flag the caller never passed. `--standalone` stays an explicit guarded choice: a forced standalone run refuses a Home whose daemon is healthy, and the exclusive ownership lease remains the authoritative backstop. The forced-standalone ownership pre-check applies the same scope policy as attachment through one run-scoped discovery, so an explicitly targeted endpoint keeps the 2 s targeted deadline and a healthy but busy daemon is never mistaken for an absent one on that path.

---

## 4. Versioned Structured Artifact Contract

When `--out-dir <dir>` is supplied, artifacts are managed by `RunArtifactCoordinator` via an internal FIFO write queue. Terminal states (`completed`, `failed`, `timeout`, `interrupted`, `cancelled`) lock the coordinator so that late asynchronous events never overwrite final results.

### 4.1. `result.json` Schema (v1.0.0)

A result records the effective target only: `workspace_id` for workspace mode or `execution_root` for temporary mode, never both.

Published from a complete temporary file (`result.json.tmp`) through serialized replacement; readers never observe partial JSON, although replacement may briefly remove the target on platforms that cannot rename over it:

```json
{
  "$schema": "https://sanad.dev/schemas/run-result-v1.json",
  "version": "1.0.0",
  "session_id": "8fa27f42-498c-4573-8d07-285698b671a9",
  "workspace_id": "ws-prod-123",
  "status": "completed",
  "exit_code": 0,
  "error": null,
  "provider": "OpenCode Go",
  "model": "deepseek-v4-flash",
  "started_at": "2026-09-22T04:00:00.000Z",
  "ended_at": "2026-09-22T04:02:15.120Z",
  "duration_ms": 135120,
  "text": "Task finished successfully.",
  "terminal_output": {
    "session_id": "8fa27f42-498c-4573-8d07-285698b671a9",
    "status": "completed",
    "exit_code": 0,
    "model": "deepseek-v4-flash",
    "provider": "OpenCode Go"
  }
}
```

### 4.2. `events.jsonl`
Appended newline-delimited event records matching status transitions:

```json
{"timestamp":"2026-09-22T04:00:00.000Z","type":"running","session_id":"8fa27f42-498c-4573-8d07-285698b671a9","data":{"workspace_id":"ws-prod-123"}}
{"timestamp":"2026-09-22T04:01:20.000Z","type":"needs_input","session_id":"8fa27f42-498c-4573-8d07-285698b671a9","data":{"kind":"needs_input","request_id":"req-1","questions":[{"question":"Confirm?"}]}}
{"timestamp":"2026-09-22T04:01:30.000Z","type":"resumed","session_id":"8fa27f42-498c-4573-8d07-285698b671a9","data":{"status":"running"}}
{"timestamp":"2026-09-22T04:02:15.120Z","type":"completed","session_id":"8fa27f42-498c-4573-8d07-285698b671a9","data":{"session_id":"8fa27f42-498c-4573-8d07-285698b671a9","status":"completed","exit_code":0}}
```

A restart adds up to three non-terminal lifecycle records between `running` and the terminal record, so a supervisor can tell an attached run that is crossing a restart from one that is hung:

| Type | Meaning |
|---|---|
| `reconnecting` | The gateway dropped mid-turn. `data.window_seconds` is the reconnect window that bounds the wait. |
| `reconnected` | A same-Home endpoint answered and the transport is live again. `data.attempts` and `data.elapsed_ms` bound the cost. |
| `re_attached` | The durable turn was reclaimed and is being followed. `data.state` is the snapshot state, `data.request_id` the followed turn, and `data.recovery_scheduled` whether the daemon owns automatic recovery. |
| `refused` | A dispatch was refused before sending anything. `data.reason` is the typed cause. |

### 4.3. Exit Codes & Scoped Cancellation

`sanad session stop <session_id>` is session-scoped and transport-confirmed: the daemon-backed CLI dispatches one `stop` immediately (naming the in-flight `run_id` when the session projection reports one), then keeps its Local Gateway connection open through ordered state reads and returns success only after the target is authoritatively idle. A matching `stopped` event is only a signal to re-read; it never counts as confirmation on its own, a stop event for another session cannot complete the command, and an unconfirmed active stop fails instead of reporting false success. The owning contract is [Sanad CLI Architecture § 9.3](../technical/sanad_cli_architecture.md).

- **`0`**: Successful turn completion (`status: "completed"`).
- **`1`**: Execution failure or prompt error (`status: "failed"`). Also returned at once when the daemon blocks the turn (`cause: "blocked"`, no Stop sent; the blocked work awaits Retry, Change Provider or `sanad session stop`) or refuses it with a typed `error_code` such as `turn_failed`.
- **`2`**: Validation error (invalid arguments or missing paths).
- **`3`**: Refused before dispatch because the target session's durable turn still owns it (`cause: "turn_in_flight"`). No `think` is sent and no turn is admitted; the refusal names the daemon's own `execution_snapshot.state`.
- **`78`**: Configuration/ownership error. Returned when a `--standalone` run cannot confirm the Home's daemon endpoint, when a forced standalone run meets a healthy daemon, when the state-root lock is already owned, and when a reconnect discovers an endpoint serving a different Sanad Home (`cause: "home_identity_mismatch"`).
- **`124`**: Execution timeout (`status: "timeout"`). Automatically sends `sanad session stop <session_id>`.
- **`130` / `143`**: Process interrupted via `SIGINT` or `SIGTERM` (`status: "interrupted"`). Automatically sends `sanad session stop <session_id>`.
- **`130`**: Execution cancelled externally via daemon stop (`status: "cancelled"`). Triggered by `sanad session stop <session_id>`.

Attached runs also report these reconnect reason codes in `--json` `error_code` and in the terminal event's `cause`:

| Cause | Exit | Meaning |
|---|---|---|
| `reconnect_window_expired` | `1` | The gateway dropped mid-turn and no healthy endpoint for the same Home answered within `--reconnect-timeout`. The turn may still be running headless in the daemon; re-dispatch after verifying daemon health. |
| `turn_lost` | `1` | Reconnection succeeded, but the durable snapshot shows another turn's `request_id` or an idle session with no recorded result. The brief is never re-sent. |
| `home_identity_mismatch` | `78` | The endpoint discovered after the drop belongs to a different Sanad Home. Fatal isolation error; do not retry against that endpoint. |
| `connection_lost` | `1` | The gateway dropped before a turn was dispatched, or the reconnect sequence itself could not complete. |

### 4.4. Following a Turn Across a Daemon Restart

An attached `sanad run` treats a mid-turn gateway drop as a restart, not a failure. It enters one bounded window per drop (`--reconnect-timeout`), re-discovers the selected Home's live endpoint, and only connects when the discovered daemon proves the same Home identity. It then reads the durable execution snapshot from `get_session_history` and compares `execution_snapshot.request_id` with the request id it dispatched, because restart recovery reclaims the same work item and request lineage.

| Snapshot state | Attached run behaviour |
|---|---|
| `running`, `resuming`, `waiting`, `queued`, `stopping` | Re-subscribe and keep following to the turn's own terminal outcome. |
| `blocked` | Exit `1` with `cause: blocked`, unchanged from Task 125. The daemon schedules automatic resume only for `waiting`, so a blocked turn is parked, not transient. |
| `idle` | Exit `0` when the last recorded assistant message is a result; otherwise exit `1` with `cause: turn_lost`. |
| no snapshot | Keep following without claiming the turn was lost. |

Re-dispatch onto a session whose durable turn is still in flight is refused with exit `3` (`turn_in_flight`) rather than attached: a non-interactive run cannot prove the caller still wants the in-flight turn's result, and silently attaching would drop the newly supplied brief. A queued or parked (blocked) turn does not own the session and is never refused.

---

## 5. Supervisor Integration (`delegate-task-supervisor`)

The `delegate-task-supervisor` skill natively supports `implementer: "sanad"` by driving the installed `sanad run` machine contract.

### 5.1. Task Specification Shape
```json
{
  "tasks": [
    {
      "id": "task-01",
      "implementer": "sanad",
      "workspace": "<target-worktree-path>",
      "command": "sanad",
      "args": [
        "run",
        "--brief-file", "<path-to-brief-file>",
        "--workspace", "<logical-workspace-id>",
        "--thinking-mode", "medium",
        "--out-dir", "<task-result-dir>",
        "--events"
      ],
      "resultPath": "<task-result-dir>/result.json",
      "timelinePath": "<task-result-dir>/events.jsonl",
      "timelineFormat": "jsonl"
    }
  ]
}
```

For source development, `delegate-task-supervisor` spawns `fvm dart run <entry>/sanad_agent.dart run` from the declared `sourceRoot` (or task workspace when both coincide) with the task's brief, targeting, and `home` flags. A Sanad task may declare `"home": "<absolute-custom-sanad-home>"`; the supervisor validates the path (absolute, existing directory) and injects `--home` so a detached worker never falls back to a different default Home (observed standalone/exit 78). Declaring `--home` inside `args` is ambiguous and fails closed; `home` is valid only for Sanad tasks, and credentials never belong in it.

A task may also declare `"autoRetry": true|false` to opt into or out of the run's automatic retry policy (§5.11); omitting the field inherits the run default.

For temporary execution without logical continuity, use `--execution-root <target-worktree-path>` alone. For delegated work tied to an existing logical workspace, supply both `--workspace <logical-workspace-id>` and `--execution-root <target-worktree-path>`; the latter must match the supervisor task's filesystem `workspace` and remains the tool/context boundary.

### 5.2. Long-Lived Dynamic Run Lifecycle
1. **`start --spec <tasks.json> --run-dir <dir> [--max-concurrency <n>] [--queued-stall-ms <n>] [--progress-stall-sec <n>] [--verify-sec <n>] [--auto-retry] [--close-when-idle]`:** Spawns a detached worker process that stays alive across multiple task settlement phases while the run remains open. Concurrency is never a hidden default: the handshake prints the effective `maxConcurrency`, `queuedStallMs`, `progressStallMs`, `autoRetry`, `closeWhenIdle`, and `tasks` count, and omitting `--max-concurrency` means one slot per spec task (no artificial queueing). `--verify-sec` (default `15`) makes the launch observed rather than assumed (§5.6). `--auto-retry` enables the blocked-task recovery policy for the run (§5.11); `--auto-retry-grace-ms`, `--auto-retry-backoff-ms`, `--auto-retry-max-attempts`, `--launch-retry-backoff-ms`, and `--launch-retry-max-attempts` override its documented defaults for compressed-time diagnosis.
2. **`add --run <dir> --spec <tasks.json>`:** Registers additional tasks in `held` state without immediate execution, and reports each added task as `held` with the live active/max counts.
3. **`enqueue --run <dir> (--task <id> | --tasks <id1,id2> | --spec <tasks.json>) [--verify-sec <n>]`:** Transitions held tasks to `queued` or appends and queues a new spec in one operation, launching available tasks up to `--max-concurrency`. Every enqueued task is reported individually as `started` or `queued at position N of M`, with the reason it is waiting and the active/max counts (text and `--json`), and the observation is re-verified like `start`.
4. **`cancel --run <dir> --task <id>`:** Cancels one task without closing the run. A `queued` or `held` task becomes `aborted` and never starts; an in-flight task is signalled and recorded as `cancelled` (see §5.4).
5. **`set-concurrency --run <dir> --max <n>`:** Changes the slot ceiling of a live run, reports `previous -> maxConcurrency`, and starts queued tasks when the ceiling rises.
6. **`close --run <dir> [--abort-queued]`:** Explicitly closes the run, disallowing further task registrations and draining in-flight/queued tasks before the supervisor process terminates. `--abort-queued` additionally aborts every `queued` task (held tasks are always aborted on close) so a run can finish without waiting for work that has not started.
7. **`continue --run <dir> --task <id> --brief-file <path> [--new-session] [--verify-sec <n>]`:** Re-dispatches a task that already finished as a numbered new attempt of the same task id, in the same workspace, with a delta brief (§5.7).
8. **`steer --run <dir> --task <id> (--message <text> | --message-file <path>)`:** Sends a mid-turn message to a running task's live daemon session without stopping it (§5.8).
9. **`retry --run <dir> --task <id> [--provider <instance-id>] [--model <model-id>]`:** Resumes a `blocked` or `waiting` task by sending `sanad session retry` to its recorded session (§5.11).
10. **`watch --run <dir> [--run <dir> ...] --cursor <file> [--once] [--timeout-sec <n>] [--all] [--json]`:** The multi-run coordinator interface with a durable cursor (§5.5).

### 5.3. Event-First Intervention & Timeline Observation
- The supervisor monitors child `events.jsonl` files event-first via directory watchers with race-closing rescans.
- Intervention events (`needs_input`, `needs_permission`) are immediately promoted into the supervisor's `manifest.json` and monotonic `events.jsonl` journal.
- Resumed turns (`resumed`) transition tasks back to `running`.
- Terminal child process exit is authoritative and locks the final state (`completed`, `failed`, `timeout`, `interrupted`, `cancelled`). An operator cancellation is the one exception: once `cancel` is recorded, the terminal state is `cancelled` even if the signalled child publishes `interrupted` or exits non-zero.
- `watch-once` wakes by default on `needs_input`, `needs_permission`, `blocked`, `waiting`, `resuming`, `queued_stall`, `progress_stall`, or terminal states. Routine `running` transitions still require `--all`.
- **Quiet watch continuity:** a caller tool timeout on `watch-once` ends only the caller's wait; the worker and supervised tasks keep running. Re-enter from the cursor (`--since <last returned seq>`, or read `seq` from a bounded `status --json`) and keep using bounded status/inspect reads. Never schedule polling or stop the worker because a watcher call timed out.

### 5.4. Queue Visibility, Stall Detection, and Cancellation

**Queue order and reasons.** Entering `queued` stamps a FIFO sequence and a queue timestamp in `manifest.json`. `status` reports, for every queued task, its position, how long it has been waiting, and why: `awaiting_slot` when every slot is busy, `launch_pending` when a slot is free but the launch has not happened yet. The same data is machine-readable under `queue` (run snapshot) and `tasks[<id>].queue` (per task) in `status --json`.

**Queued stall.** A task that stays queued past `--queued-stall-ms` (default `120000`) while slots are occupied is a stall, not progress. The worker journals exactly one `queued_stall` notice per task per queue episode, carrying the queue age, position, active/max counts, and the reason; `watch-once` returns it as a wake-up event, and `status` repeats the condition on read (`QUEUED_STALL` in text, `stalled: true` in JSON) so a caller that never watched is not left blind. A stall notice never changes task state; entering `running` clears it.

**Cancellation path.** `cancel` records the request in the journal (`cancel_requested`), then follows the relay's own timeout semantics: the child receives `SIGTERM` (force-killed with `SIGKILL` after a bounded grace period if it ignores the signal), and its daemon session is stopped explicitly by session id when one is already known (`sanad session stop <id>` built from the task's own invocation form, including its declared `--home`). Remote `sanad-client` tasks and non-Sanad implementers have no local daemon session, so only the signal path applies. The session id is captured from any timeline event that carries one, not just from launch, so the stop can target a turn that was already running before the cancel.

**Lowering concurrency never kills.** `set-concurrency` down to a lower ceiling applies to future fills only: running tasks are not signalled or aborted, `active` stays honest (it can exceed the new ceiling until tasks settle), and the queue drains from the new limit onward.

### 5.5. Multi-Run Watch with a Durable Cursor (W1, W7)

`watch` is the interface a coordinator uses for several runs at once. `watch-once` remains the single-run, single-event, read-only primitive; `watch` adds a persisted cursor and a per-event line stream.

- **Cursor:** `--cursor <file>` stores the last *handled* sequence per run (`{"version": "delegate-watch-cursor.v1", "runs": {"<run-dir>": {"seq": N}}}`). It is written atomically (temp file + rename) and **advanced only after the line it belongs to has been flushed**, so a watcher that dies mid-print replays that event instead of losing it.
- **Replay:** on start, every journal record after the cursor is evaluated. Anything that happened while no watcher ran is therefore reported, and anything already handled is never printed twice.
- **Modes:** `--once` prints the batch of new actionable events and exits (for an orchestrator that is re-invoked when the watcher exits); without `--once` the process streams exactly one line per actionable event. `--timeout-sec <n>` bounds a wait (exit code `4` with a stderr note, no partial line); `--all` also prints non-actionable records for debugging; `--json` emits one JSON object per line (`version: delegate-watch-event.v1`).
- **Actionable** means: every terminal state, `blocked`, `needs_input`/`needs_permission`, `queued_stall` (§5.4), `progress_stall` (§5.6), `worker_lost` (§5.6), `supervisor_dead` (§5.6), and `retry_exhausted` (§5.11). Routine `running` transitions, tool progress, `progress_resumed`, `steer_sent`, `retry_sent`, `auto_retry`, `continue_requested`, and `launch_retry` are never wake-ups. The vocabulary is shared with `watch-once` through `scripts/supervisor-events.mjs` so both readers cannot drift apart.
- **Rich completion line (W7):** a terminal event carries the result status, the `result.json` path, and — when present in that file — `branch`, `head_sha`, `pr_url`, and the first line of the final summary, plus the elapsed time. The coordinator triages a completion from the line itself.
- **Idle/ended runs:** a run whose manifest is `completed`, `stale`, or closed with every task terminal ends the watch instead of blocking forever. An open run with no pending actionable events blocks until one arrives — use `--timeout-sec` for a bounded wait, or `close` the run.

### 5.6. Silence and Dead-Worker Detection (W2, W3)

**Progress silence.** A running task that publishes no progress for its threshold is silent, not busy. The threshold is a run default (`start --progress-stall-sec`, default `900`) that a spec may override per task (`"progressStallSec"`; `progressStallMs` is accepted for compressed-time diagnosis). The worker journals exactly one `progress_stall` notice per stall episode — carrying `silentForMs`, `thresholdMs`, `lastProgressAt`, and the task status — and clears it with a non-actionable `progress_resumed` notice when progress returns, so a later stall is reported again. `status` recomputes the same condition on read (`PROGRESS_STALL` in text, `tasks[<id>].progress.stalled` in JSON), so a caller that never watched still sees a silent turn.

**Worker loss.** A task is never left `running` forever:

- While the supervisor is alive, a task whose process is gone, whose handle is lost, and whose `result.json` is not terminal transitions to `failed` with `cause: "worker_lost"` and a journaled `worker_lost` record.
- When the supervisor itself is gone, the run is marked `stale` and `status`/`watch` repair it — they are the only writers left. Each non-terminal, non-queued task with no terminal artifact becomes `failed`/`worker_lost` (the journaled record is what wakes a coordinator), while a task whose `result.json` *is* terminal is adopted with `cause: "result_recorded_after_exit"` instead, so a completion that landed after the supervisor died is never reported as a failure. A repair also recomputes `active` and keeps the orphan pid (`orphanPid`) for the operator when the task process outlived its supervisor.
- A late terminal artifact for a task already repaired to `failed`/`worker_lost` upgrades the task on the next read and journals a `recovered` record. An artifact is only adopted when it belongs to *this* attempt: if its `started_at` is later than the task's `finishedAt`, it was produced by a later attempt that reused the same `--out-dir`, so the task keeps its own outcome and the other artifact is reported as `later-result` for triage instead.
- **Supervisor death.** When the manifest's `supervisorPid` is gone while any task is still non-terminal, the repair journals exactly one run-level `supervisor_dead` record (carrying the lost pid and the non-terminal task ids), which is actionable: nothing will ever advance those tasks again. `watch` prints it as `RUN supervisor_dead (...)`, and `watch-once` reports the same fact instead of blocking. It is deliberately distinct from `progress_stall`, which only says one task went quiet under a live supervisor. A run whose tasks all settled emits nothing, because no decision is left.

**Launch verification (W5).** `start`, `enqueue`, and `continue` wait up to `--verify-sec` (default `15`) and print the observed state of every submitted task: `running`, `queued` with its position and reason, or `failed to spawn` with the spawn diagnostic. A task that is merely `launch_pending` is not accepted as resolved — that state is exactly what produced a launch report that never ran. The command exits non-zero when a task failed to spawn (`cause: "spawn_failed"`).

**Launch retry (W11).** A spawn that exits `78` (`Could not confirm a healthy Sanad daemon`) within `60 s` of launch never reached a turn: it is a launch race, not a task failure. The worker journals `launch_retry` (attempt, exit code, elapsed time, backoff), records the attempt under `tasks[<id>].launchRetries`, returns the task to `queued` with `cause: "daemon_unavailable"` and a `launchRetryAt` deadline, and relaunches it after an exponential backoff (`2 s` base, capped at `30 s`) up to `3` times. Any other exit code, or a `78` produced after the window, keeps the normal failure path. A relaunch is the same attempt (`attempt` is unchanged); the run's `active` count stays honest while the task waits out its backoff.

**Idle runs (W8).** `status` reports a live run with no active or queued tasks as `idle` (text and `run.idle` in JSON), and `start --close-when-idle` closes the run automatically once every task is terminal and nothing is queued.

### 5.7. Continuing a Finished Task (W6)

`continue --run <dir> --task <id> --brief-file <path> [--new-session]` re-dispatches a task that already finished, in the same workspace, as a numbered new attempt of the same task id:

- The delta brief replaces the task's declared brief input (`--brief-file`, `-b`, or `--prompt-file`, including the `--flag=value` form). A task without a brief argument is refused rather than guessed at.
- The previous attempt's artifacts (`result.json`, `events.jsonl`, stdout/stderr) are archived under `<run>/attempts/<task>/attempt-<n>/`, and `tasks[<id>].attempts` keeps every attempt's status, exit code, cause, session id, and result digest. `attempt` increments.
- **One session per task:** the re-dispatch is refused while the task's worker process is still alive, while the supervisor still holds a child handle, or while a daemon-session stop for that task is still in flight. The refusal is checked both client-side (fail fast, before the control request) and authoritatively in the worker.
- `--new-session` drops `--session`/`-s`/`--continue` pins so the new attempt starts a fresh daemon session. Local `sanad run` always starts a new session, so the flag matters for relayed `sanad-client` tasks.
- The re-dispatch is verified like a launch (§5.6), and the journal records `continue_requested` with the attempt number, brief path, and brief digest.

### 5.8. Steering a Running Task (W6b)

`steer --run <dir> --task <id> (--message <text> | --message-file <path>)` delivers a mid-turn message to a task that is already running, without cancelling or re-dispatching it:

- The supervisor resolves the task's recorded session id and refuses with a clear error when none is known yet (the id is captured from any relayed lifecycle event, so it may not exist in the first moments of a turn).
- The CLI invocation is built by one helper (`sessionSteerInvocation`) that mirrors the task's own invocation form and pins: `sanad session steer --session <id> --message-file <path> --json`, the same `--home` the task spawned with, the same `--gateway-url` when the spec pinned one, or `sanad-client -d <device> session steer …` for a relayed task. Steering a non-Sanad implementer is refused.
- The message body is transient: the journal records `steer_sent` with the supervisor's control-request id, the CLI's request id when it reports one, the message's `sha256` and length, the session id, and the command result — never the text. A temporary message file is written inside the run and removed afterwards.
- `steer_sent` is not actionable: a coordinator is not woken by its own instruction. The command refuses a task that is not `running`; a finished task is the `continue` path (§5.7).
- Steering depends on the `sanad session steer` CLI contract (added by the B5 work) and the `sanad-client` device relay for remote tasks. The supervisor binds to that contract in one place, so a change there is a one-line fix.

### 5.9. Reading Status Across Runs (W4)

`status` accepts several `--run` flags and a `--brief` mode:

- `status --run <dir> [--run <dir> ...]` reads each run in one call; `--json` keeps the single-run manifest shape for one run and returns `{version: "delegate-status.v1", runs: [...]}` for several.
- `status --brief` prints one line per task: id, status, elapsed, progress age, queue position/reason, attempt number, retry facts (`retries <used>/<max>`, `next-retry <iso>`, `RETRY_EXHAUSTED`, `launch-retries <n>`), and — when terminal — the result status plus PR URL, head SHA, branch, and the first summary line. A foreign artifact is printed as `later-result <status>` instead of as the task's result. `status --brief --json` returns the same facts as `delegate-status-brief.v1`, with a `retry` object per task.
- The verbose output remains the default, so existing callers are unaffected.
- `status` is read-only for a live run and repairs a run whose supervisor is gone (§5.6): that repair is the only write it performs, and it is journaled like any worker transition.

### 5.10. Supervisor Tooling Notes

- `scripts/supervisor-events.mjs` owns the shared journal vocabulary (terminal states, actionable notices, the `watch-once` wake set). `scripts/supervisor-retry.mjs` owns the retry policy. Both readers import them; no script keeps a private copy.
- `watch-once.mjs` stays the single-run primitive. A run already marked `stale` is reported by `watch-once` instead of blocking, exactly like a run whose supervisor just died; with non-terminal work it reports `supervisor_dead`.
- Compressed-time switches (`--queued-stall-ms`, `--progress-stall-ms`, `--verify-ms`, `--auto-retry-grace-ms`, `--auto-retry-backoff-ms`, `--launch-retry-backoff-ms`, plus fractional `--*-sec` values) exist so the same code paths can be exercised in milliseconds by tests; production callers use the documented second-based flags and defaults.
- **Never kill supervisor processes by pattern or name.** `pkill -f supervisor.mjs`, `killall node`, and `taskkill /IM node.exe` match every run on the machine, including a coordinator's live supervisors; doing exactly that during the 2026-10-22 live round froze four runs' bookkeeping for about an hour. To stop a run, use the owned control path: `close --run <dir> [--wait]`, or `cancel --run <dir> --task <id>`. To stop a worker whose supervisor is already gone, address it by the pid recorded in that run's `manifest.json`/`task.pid` after confirming the command line names that run directory.
- Tests may only signal a process they spawned: `test/process_guard.mjs` keeps a pid registry, refuses any pid it did not spawn, refuses a pid whose command line no longer names its fixture (pid reuse), and refuses pattern kills outright. Its `sweepOrphanedFixtures()` repairs a fixture whose test process died, proving ownership from the command line and the manifest instead of from a process name. A failing test can therefore not leak a worker or reach someone else's.

### 5.11. Retrying Blocked Work (B4 round 2)

A worker the daemon leaves `blocked` cannot resume itself: the daemon spends its own automatic retry budget before it publishes `blocked`, and a headless `sanad run` has no Client to press Retry. The supervisor closes that gap in two ways.

**Manual retry.** `retry --run <dir> --task <id> [--provider <instance-id>] [--model <model-id>] [--json]` resolves the task's recorded session id and sends `sanad session retry <session-id> [--provider <id>] [--model <id>] --json` through the same helper that builds `session stop` and `session steer`, so it reaches the same binary, source entry, `--home`, and `--gateway-url` the task spawned with (and `sanad-client -d <device> session retry …` for a relayed task). The command:

- refuses a task that is not `blocked` or `waiting` (`retry` resumes a turn; it never starts one — a finished task is the `continue` path, §5.7), and refuses when no session id is known yet;
- reports the daemon's own verdict from the CLI exit code: `0` `retrying`, `1` `transport_error`, `3` `not_blocked` (nothing was sent), `4` `rejected`, `5` `unacknowledged`, `8` `state_unreadable`;
- journals `retry_sent` with the session id, attempt number, provider/model, result, exit code, and the CLI's own request id when it printed one. `retry_sent` is never actionable: a coordinator is not woken by its own instruction.

The worker repeats the `blocked`/`waiting` check authoritatively, so a raw control request cannot retry a healthy turn either.

**Automatic policy.** `--auto-retry` (or `"autoRetry": true` at spec level; a task may opt out with `"autoRetry": false`) retries a blocked task without a coordinator:

| Rule | Value |
|---|---|
| Transient causes | `provider_timeout`, `network_error`, `rate_limit` (plus the runtime spellings `networkError`, `rateLimit`, `upstream_rate_limit`, `overloaded`) |
| Grace before the first retry | `180000 ms` (`--auto-retry-grace-ms`) |
| Backoff between attempts | `30000 ms` doubling per attempt, capped at `300000 ms` (`--auto-retry-backoff-ms`) |
| Attempts per block | `3` (`--auto-retry-max-attempts`) |
| Never retried | `auth_error`, `provider_quota`, `needs_input`, `needs_permission`, and any unknown cause |

- A rate-limit notice that carries `retry_after` is not retried before that deadline; the grace period is the larger of the two.
- Each block is its own episode (`retryEpisode`), so a retry that recovers the turn restores the full budget for the next block; attempts are counted per episode in `retryAttempts`.
- Every send journals `auto_retry` (attempt, max, cause, backoff, provider/model, result, exit code, CLI request id) — never actionable — and `status --brief` shows `retries <used>/<max>`, `next-retry <iso>` while a backoff is pending.
- When the budget is spent and the task is still blocked, the worker journals one **actionable** `retry_exhausted` with the attempts, the cause, and the last result, and stops: the next decision (switch provider, `continue` with a delta brief, or `cancel`) belongs to a coordinator.
