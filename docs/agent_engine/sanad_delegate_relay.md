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
| Positional prompt / stdin | Text / Pipe | Conditional | One-shot prompt or redirected standard input. Mutually exclusive with `--brief-file`. |
| `--workspace` / `-w` | String | Alternative | Registered persistent workspace used for conversation identity and continuity. It may accompany `--execution-root`. |
| `--execution-root` | Path | Alternative | Existing directory used as the filesystem/tool context. When combined with `--workspace`, it targets an isolated worktree without registering another logical workspace. |
| `--out-dir` / `-o` | Path | Optional | Output directory where structured artifacts (`result.json`, `events.jsonl`) are written. |
| `--session` / `-s` | UUID | Optional | Pre-allocated session identifier; generated automatically if omitted. |
| `--provider` | String | Optional | LLM provider override. |
| `--model` / `-m` | String | Optional | Model name override. |
| `--thinking-mode` | Enum | Optional | Explicit reasoning effort such as `medium`; forwarded unchanged to the daemon. Legacy `--thinking` remains a shorthand for `deep`. |
| `--timeout` | Seconds | Optional | Whole number of seconds (1–86400). Scoped session stop is triggered upon expiry. |
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

### 4.3. Exit Codes & Scoped Cancellation

`sanad session stop <session_id>` is session-scoped and transport-confirmed: the daemon-backed CLI keeps its Local Gateway connection open through an ordered history query, then returns success only after the target is authoritatively idle or a matching `stopped` event arrives. A stop event for another session cannot complete the command, and an unconfirmed active stop fails instead of reporting false success.

- **`0`**: Successful turn completion (`status: "completed"`).
- **`1`**: Execution failure or prompt error (`status: "failed"`).
- **`2`**: Validation error (invalid arguments or missing paths).
- **`124`**: Execution timeout (`status: "timeout"`). Automatically sends `sanad session stop <session_id>`.
- **`130` / `143`**: Process interrupted via `SIGINT` or `SIGTERM` (`status: "interrupted"`). Automatically sends `sanad session stop <session_id>`.
- **`130`**: Execution cancelled externally via daemon stop (`status: "cancelled"`). Triggered by `sanad session stop <session_id>`.

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

For temporary execution without logical continuity, use `--execution-root <target-worktree-path>` alone. For delegated work tied to an existing logical workspace, supply both `--workspace <logical-workspace-id>` and `--execution-root <target-worktree-path>`; the latter must match the supervisor task's filesystem `workspace` and remains the tool/context boundary.

### 5.2. Long-Lived Dynamic Run Lifecycle
1. **`start --spec <tasks.json> --run-dir <dir>`:** Spawns a detached worker process that stays alive across multiple task settlement phases while the run remains open.
2. **`add --run <dir> --spec <tasks.json>`:** Registers additional tasks in `held` state without immediate execution.
3. **`enqueue --run <dir> (--task <id> | --spec <tasks.json>)`:** Transitions held tasks to `queued` or appends and queues a new spec in one operation, launching available tasks up to `--max-concurrency`.
4. **`close --run <dir>`:** Explicitly closes the run, disallowing further task registrations and draining in-flight/queued tasks before the supervisor process terminates.

### 5.3. Event-First Intervention & Timeline Observation
- The supervisor monitors child `events.jsonl` files event-first via directory watchers with race-closing rescans.
- Intervention events (`needs_input`, `needs_permission`) are immediately promoted into the supervisor's `manifest.json` and monotonic `events.jsonl` journal.
- Resumed turns (`resumed`) transition tasks back to `running`.
- Terminal child process exit is authoritative and locks the final state (`completed`, `failed`, `timeout`, `interrupted`, `cancelled`).
- `watch-once` wakes by default on `needs_input`, `needs_permission`, `blocked`, `waiting`, `resuming`, or terminal states. Routine `running` transitions still require `--all`.
- **Quiet watch continuity:** a caller tool timeout on `watch-once` ends only the caller's wait; the worker and supervised tasks keep running. Re-enter from the cursor (`--since <last returned seq>`, or read `seq` from a bounded `status --json`) and keep using bounded status/inspect reads. Never schedule polling or stop the worker because a watcher call timed out.
