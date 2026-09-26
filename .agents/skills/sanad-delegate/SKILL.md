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
  [--thinking-mode <effort>] \
  [--timeout <seconds>] \
  [--events] \
  [--allow-all-tools]
```

For a temporary unregistered filesystem context, replace the `--workspace` line with `--execution-root <existing-directory>`. For delegated work that must retain an existing logical workspace while targeting an isolated worktree, send both: `--workspace` owns conversation continuity and `--execution-root` owns filesystem tools/context.

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
  [--thinking-mode <effort>] \
  [--timeout <seconds>] \
  [--events] \
  [--allow-all-tools]
```

For CLI-only delegation, the managed runtime needs the Agent daemon only. Do not launch a Flutter Client unless the delegated scenario explicitly exercises Client UI behavior.

---

## 3. Parameter Reference

| Option / Flag | Short | Type | Description |
|---|---|---|---|
| `--brief-file` | `-b` | File Path | Path to brief file containing task prompt instructions. Avoids shell argv text exposure. Mutually exclusive with positional prompt. |
| `--workspace` | `-w` | String | Registered persistent Sanad workspace. Use for normal project conversation continuity. It is authoritative if both targeting options are supplied. |
| `--execution-root` | | Directory Path | Existing directory used as the filesystem tool/context boundary; it may accompany `--workspace` without registering another workspace. |
| `--out-dir` | `-o` | Directory Path | Directory where `result.json` and `events.jsonl` are written. Automatically created if missing. |
| `--session` | `-s` | String | Pre-allocated session ID (e.g. UUID v4). Allows concurrent observers to attach and monitor the turn. |
| `--events` | | Flag | Stream real-time newline-delimited JSON (NDJSON) events to standard output. |
| `--timeout` | | Seconds | Whole number of seconds (1–86400). Scoped session stop is triggered upon expiry, exiting code 124. |
| `--allow-all-tools` | | Flag | Auto-approves ordinary tool execution permissions. Questions (`system_ask_user`) ALWAYS remain pending. |
| `--provider` | | String | Target LLM provider override. |
| `--model` | `-m` | String | Target LLM model override. |
| `--home` | | Path | Absolute Sanad Home directory. Authoritative when supplied: the CLI attaches to this Home instead of the default. A source-development task against a managed custom Home must pass it explicitly (the `delegate-task-supervisor` injects it from the task `home` field); without it a detached worker can fall back to an unrelated default Home and fail closed with exit 78 when that Home's daemon is active. Relative or malformed paths are rejected. |
| `--thinking-mode` | | Enum | Select explicit reasoning effort, including `medium`; the value is forwarded to the daemon. |
| `--thinking` | | Flag | Backward-compatible shorthand for deep reasoning. |
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
   - At least one mode is required. Supply both when an existing logical workspace should own the conversation while the explicit execution root independently targets an isolated worktree; both identities are dispatched and recorded.
   - Neither mode creates, selects, or switches a workspace, and the CLI never mutates `Directory.current`.

3. **Pre-allocated Session Tracking & External Intervention:**
   - Allocating a known `session_id` before dispatch allows external supervisors to monitor progress via `sanad session show <session_id>`.
   - Clarifications and gated permissions are resolved via `sanad session answer` and `sanad session permission` without interrupting the running `sanad run` process.

4. **Serialized Artifact Coordination:**
   - All disk writes to `result.json` and `events.jsonl` are managed by `RunArtifactCoordinator` via an internal FIFO write queue.
   - Terminal events (`completed`, `failed`, `timeout`, `interrupted`, `cancelled`, `incomplete`, `needs_review`) lock the artifact coordinator, ensuring terminal results are never overwritten by late asynchronous events.
   - Semantic terminal validation enforces data fidelity: a run completing without a substantive final summary (missing or progress-only text) is tagged `incomplete` with `cause: "missing_final"` and exit code 1, preventing false terminal success.
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

---

## 6. Remote Delegation via `sanad-client`

When a task targets a remote machine or worker device rather than the local daemon, external orchestrators drive the installed `sanad-client` CLI tool. `sanad-client` communicates over an authenticated loopback channel with the running desktop Sanad Client, which securely relays commands and streams output to the target remote Agent.

### 6.1. Architectural Topology

```
┌─────────────────────────────────────────────────────────────┐
│                 External Orchestrator                       │
│        (delegate-task-supervisor / agy / scripts)           │
└──────────────┬──────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────┐
│                      sanad-client                           │
│   `sanad-client -d <device-id> run --brief-file <f> ...`    │
└──────────────┬──────────────────────────────────────────────┘
               │ Loopback HTTP / WebSocket (auth token via runtime file)
               ▼
┌─────────────────────────────────────────────────────────────┐
│                   Desktop Sanad Client                      │
│   - Loopback Host (port dynamic, isolated by SANAD_HOME)    │
│   - Permission check (Default dialog prompt vs Full Access) │
│   - Cloud Gateway / Local Socket Relay                      │
└──────────────┬──────────────────────────────────────────────┘
               │ End-to-end WebSocket command relay
               ▼
┌─────────────────────────────────────────────────────────────┐
│                    Target Remote Agent                      │
│   - In-memory `SanadCommandRunner` dispatch (no shell eval) │
│   - Streamed stdout / stderr / events                       │
└─────────────────────────────────────────────────────────────┘
```

### 6.2. Remote Device Discovery

List all connected remote devices registered under the Client's active account:

```bash
# Human-readable table format
sanad-client devices

# Machine-readable JSON output
sanad-client devices --json
```

Output JSON example:
```json
{
  "devices": [
    {
      "id": "dev-linux-build-node",
      "name": "Linux Build Node",
      "platform": "linux",
      "status": "online",
      "is_current": false
    }
  ]
}
```

### 6.3. Remote Workspace Discovery

List workspaces on the remote target device:

```bash
sanad-client -d dev-linux-build-node ws list --json
```

### 6.4. Remote Task Execution

Delegate a task to the remote device by passing a brief file:

```bash
sanad-client -d dev-linux-build-node run \
  --workspace ws-backend-repo \
  --brief-file briefs/task_migration.md \
  --events \
  --json
```

Key execution guarantees:
- **Transparent I/O Forwarding:** Standard output, standard error, JSON streams, and exit codes match direct `sanad run` execution.
- **Brief Transport:** `--brief-file` content is read locally by `sanad-client` and transmitted securely over the authenticated relay, avoiding shell argv size limits or process sniffing on the target host.
- **Standard Input:** Piped stdin (`cat input.txt | sanad-client -d <device> run ...`) is forwarded to the remote agent.

### 6.5. Remote Session Observation, Intervention, and Cancellation

- **Inspect Running Session:**
  ```bash
  sanad-client -d dev-linux-build-node session show <session-id> --json
  ```
- **Answer Clarifying Question:**
  ```bash
  sanad-client -d dev-linux-build-node session answer <session-id> "Option 2"
  ```
- **Stop / Cancel Remote Session:**
  ```bash
  # Via session stop command:
  sanad-client -d dev-linux-build-node session stop <session-id>

  # Via process signal:
  # Sending SIGINT (Ctrl+C) to `sanad-client` sends a cancellation message
  # to the Client host, which forwards `device.cli.cancel` to the remote agent.
  ```

### 6.6. Permission Modes and Configuration

The desktop Sanad Client governs `sanad-client` execution through **Settings > Client CLI**:

1. **Disabled (Default):**
   `sanad-client` calls fail immediately with exit code 77 (`Client CLI is disabled in Sanad Client settings`).
2. **Default Mode (Approval Prompt):**
   Each command invocation displays an approval overlay in the Sanad Client with command arguments, target device, and hotkey choices:
   - `1`: Allow this time (`allowOnce`)
   - `2`: Allow for this session (`allowSession`) — subsequent invocations within the same session ID execute without re-prompting.
   - `3` or `Esc`: Deny (`deny`) — returns non-zero rejected result immediately.
3. **Full Access Mode:**
   Commands execute immediately without desktop approval prompts. Recommended for unattended automation and CI environments.

### 6.7. Sanad Home and Client Instance Resolution

`sanad-client` locates the active desktop Client endpoint via the following resolution precedence:
1. Explicit `--home <path>` flag: `sanad-client --home /path/to/custom_home devices`
2. Environment variable: `SANAD_HOME`
3. Default Home: `~/.sanad`

The endpoint record is read from `<SANAD_HOME>/runtime/client_cli.json` and authenticated via the ephemeral token recorded during Client startup. If no live Client is running for that Home, `sanad-client` exits with code 69 (`No live Sanad Client is running for Home ...`).
