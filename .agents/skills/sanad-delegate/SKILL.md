---
name: sanad-delegate
description: Instruction-only skill guiding external orchestrators to drive the native installed `sanad run` CLI machine contract for delegated tasks, including safe brief transport, separate execution roots, structured artifact coordination, intervention, and cancellation.
license: MIT
compatibility: Uses the native installed Sanad CLI (`sanad run`). Requires no skill-bundled binaries or runtime packages. Cross-platform support for macOS, Linux, and Windows.
metadata:
  version: 0.2.0
---

# Sanad Delegate Execution Skill

The `sanad-delegate` skill teaches external orchestrators (such as `delegate-task-supervisor`, OpenCode, Antigravity, or CI/CD pipelines) how to drive the native, daemon-backed `sanad run` CLI machine contract for delegated tasks.

## 1. System Topology & Responsibilities

```
┌─────────────────────────────────────────────────────────────┐
│                 delegate-task-supervisor                    │
│      (Orchestrator: Concurrency, Timelines, State)          │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
               ▼                               ▼
┌──────────────────────────────┐ ┌───────────────────────────┐
│        sanad-delegate        │ │    opencode / agy-delegate │
│   (Instruction & Contract)   │ │    (Other Implementers)   │
└──────────────┬───────────────┘ └───────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────┐
│                       Sanad CLI                             │
│       `sanad run --brief-file <f> --out-dir <d> ...`        │
│        (attached to the active local daemon)                │
└─────────────────────────────────────────────────────────────┘
```

- **Separation of Concerns:**
  - `delegate-task-supervisor`: Orchestrates task queues, concurrency limits, supervisor runs, and unified event timelines.
  - `sanad-delegate`: Global instruction skill that guides orchestrators to invoke the native `sanad run` machine contract with proper prompt transport, workspace separation, and artifact tracking.
  - `sanad run`: Built directly into the Sanad binary. Manages brief ingestion, registered-workspace or temporary-root targeting, serialized artifact emission, timeout handling, and signal termination without requiring auxiliary scripts or packages.

---

## 2. Command Invocation

### 2.1. Production / Installed Usage (Standard)

Orchestrators invoke the installed `sanad` binary directly:

```bash
sanad run \
  --brief-file <path-to-brief-file> \
  --workspace <logical-workspace-id> \
  --out-dir <output-directory> \
  --session <preallocated-session-uuid> \
  [--provider <provider-name>] \
  [--model <model-name>] \
  [--timeout <seconds>] \
  [--events] \
  [--allow-all-tools]
```

For a temporary unregistered filesystem context, replace the `--workspace` line with `--execution-root <existing-directory>`. Do not send both unless testing precedence; `--workspace` wins and the execution root is ignored.

### 2.2. Source Development Fallback (Explicitly Labeled)

When running directly from a source checkout without an installed binary, use `fvm dart run` inside the `agent/` directory:

```bash
cd agent && fvm dart run bin/sanad_agent.dart run \
  --brief-file <path-to-brief-file> \
  --workspace <logical-workspace-id> \
  --out-dir <output-directory> \
  --session <preallocated-session-uuid> \
  [--provider <provider-name>] \
  [--model <model-name>] \
  [--timeout <seconds>] \
  [--events] \
  [--allow-all-tools]
```

---

## 3. Parameter Reference

| Option / Flag | Short | Type | Description |
|---|---|---|---|
| `--brief-file` | `-b` | File Path | Path to brief file containing task prompt instructions. Avoids shell argv text exposure. Mutually exclusive with positional prompt. |
| `--workspace` | `-w` | String | Registered persistent Sanad workspace. Use for normal project conversation continuity. It is authoritative if both targeting options are supplied. |
| `--execution-root` | | Directory Path | Existing directory used as a temporary, unregistered filesystem context only when `--workspace` is absent. |
| `--out-dir` | `-o` | Directory Path | Directory where `result.json` and `events.jsonl` are written. Automatically created if missing. |
| `--session` | `-s` | String | Pre-allocated session ID (e.g. UUID v4). Allows concurrent observers to attach and monitor the turn. |
| `--events` | | Flag | Stream real-time newline-delimited JSON (NDJSON) events to standard output. |
| `--timeout` | | Seconds | Whole number of seconds (1–86400). Scoped session stop is triggered upon expiry, exiting code 124. |
| `--allow-all-tools` | | Flag | Auto-approves ordinary tool execution permissions. Questions (`system_ask_user`) ALWAYS remain pending. |
| `--provider` | | String | Target LLM provider override. |
| `--model` | `-m` | String | Target LLM model override. |
| `--thinking` | | Flag | Enable deep reasoning / thinking mode. |
| `--quiet` | `-q` | Flag | Suppress banners, headers, and tool output, printing only the final assistant text. |
| `--json` | | Flag | Output structured JSON response envelope to stdout upon completion. |

---

## 4. Operational & Safety Guarantees

1. **Brief Transport Security (No Shell Argv Exposure):**
   - Task briefs must be passed via `--brief-file <path>` or piped into `stdin`.
   - Never pass large or sensitive prompts as positional argv arguments. Passing both `--brief-file` and a positional prompt immediately exits with code 2.

2. **Choose One Targeting Mode:**
   - Use `--workspace` for a registered project whose conversation identity, system context, tools, policies, and filesystem root should remain persistent.
   - Use `--execution-root` alone for a one-run filesystem context that must not be registered as a Sanad workspace.
   - At least one mode is required. If both are supplied, `--workspace` is authoritative and `--execution-root` is ignored in dispatch and artifacts.
   - Neither mode creates, selects, or switches a workspace, and the CLI never mutates `Directory.current`.

3. **Pre-allocated Session Tracking & External Intervention:**
   - Allocating a known `session_id` before dispatch allows external supervisors to monitor progress via `sanad session show <session_id>`.
   - Clarifications and gated permissions are resolved via `sanad session answer` and `sanad session permission` without interrupting the running `sanad run` process.

4. **Serialized Artifact Coordination:**
   - All disk writes to `result.json` and `events.jsonl` are managed by `RunArtifactCoordinator` via an internal FIFO write queue.
   - Terminal events (`completed`, `failed`, `timeout`, `interrupted`, `cancelled`) lock the artifact coordinator, ensuring terminal results are never overwritten by late asynchronous events.
   - Post-initialization errors always write terminal artifacts and preserve their specific exit codes before process termination.

5. **Scoped Signal & Timeout Termination:**
   - When a timeout occurs, `sanad run` dispatches a scoped session stop to the daemon for only its targeted `session_id`, records `status: "timeout"` with exit code 124 in `result.json`, and exits.
   - When receiving `SIGINT` (Ctrl+C) or `SIGTERM`, it dispatches the same scoped session stop, records `status: "interrupted"` with exit code 130 or 143, and terminates cleanly.
   - It never stops, restarts, or disrupts the daemon or concurrent sessions.

6. **External Stop / Cancellation:**
   - When stopped externally via `sanad session stop <session_id>`, `sanad run` receives the daemon stop event, records `status: "cancelled"` with exit code 130 in `result.json`, and exits cleanly.
   - External stop affects only the targeted session and never overwrites prior timeout or signal interruptions.

---

## 5. Artifact Formats

When `--out-dir <dir>` is provided, the following artifacts are generated:

### 5.1. `result.json`
Published from a complete temporary file at startup and updated through serialized lifecycle transitions:

```json
{
  "$schema": "https://sanad.dev/schemas/run-result-v1.json",
  "version": "1.0.0",
  "session_id": "c1f76d49-4114-4a4b-8e10-c48c48a91f54",
  "workspace_id": "ws-core-project",
  "execution_root": "worktrees/feature-branch",
  "status": "completed",
  "exit_code": 0,
  "error": null,
  "provider": "OpenCode Go",
  "model": "deepseek-v4-flash",
  "started_at": "2026-09-22T04:30:00.000Z",
  "ended_at": "2026-09-22T04:30:45.000Z",
  "duration_ms": 45000,
  "text": "Completed task successfully.",
  "terminal_output": {
    "session_id": "c1f76d49-4114-4a4b-8e10-c48c48a91f54",
    "status": "completed",
    "exit_code": 0,
    "model": "deepseek-v4-flash",
    "provider": "OpenCode Go"
  }
}
```

### 5.2. `events.jsonl`
Appended newline-delimited event records:

```json
{"timestamp":"2026-09-22T04:30:00.000Z","type":"running","session_id":"c1f76d49-4114-4a4b-8e10-c48c48a91f54","data":{"workspace_id":"ws-core-project","execution_root":"worktrees/feature-branch"}}
{"timestamp":"2026-09-22T04:30:45.000Z","type":"completed","session_id":"c1f76d49-4114-4a4b-8e10-c48c48a91f54","data":{"session_id":"c1f76d49-4114-4a4b-8e10-c48c48a91f54","status":"completed","exit_code":0}}
```
