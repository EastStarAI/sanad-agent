---
name: delegate-task-supervisor
description: Bootstrap and orchestrate one or many delegated coding-agent CLI tasks through installed delegate-skills, preserve workspace/project/session identity, expose live task timelines, and wait event-first for the next meaningful transition. Use whenever work is handed to OpenCode, Antigravity/agy, or multiple external implementers, especially for parallel, long-running, resumable, or human-observable delegation. Do not replace the implementer-specific delegate skill; load and follow it.
license: MIT
compatibility: Requires Node.js 18+ and git. The bootstrap helper can install delegate-skills and supported implementer CLIs with explicit approval. Runtime scripts use Node built-ins only and support macOS, Linux, and Windows.
metadata:
  version: 0.2.0
---

# Delegate Task Supervisor

Coordinate external implementers without duplicating their own delegation contracts. This skill owns bootstrap, workspace identity, concurrency, durable task state, human observability, dynamic task queuing, and event-driven wake-up. The selected `*-delegate` skill continues to own briefs, permissions, relay flags, result semantics, review, and resumption.

## Boundaries

- Supported implementers are `opencode`, `agy`/`antigravity`, and `sanad`.
- Load and follow `agy-delegate` for Antigravity, `opencode-delegate` for OpenCode, and `sanad-delegate` for Sanad Agent. Do not copy or reinterpret their operational instructions.
- Use `delegate-setup` only when the user wants reusable fleet lanes. Direct one-off dispatch does not require a lane.
- For Sanad implementation, also load `Sanad Subagent Developer`; use an isolated worktree for every parallel write task.
- Never run two tasks concurrently in the same OpenCode session, Antigravity conversation, or Sanad session.
- Never commit, push, merge, or open a pull request unless the user explicitly authorizes that delivery action.

`<skill-dir>` below means the directory containing this file.

## 1. Bootstrap once per machine

Check prerequisites and installed integrations:

```bash
node "<skill-dir>/scripts/bootstrap.mjs" check
```

If anything is missing, show the complete planned changes and obtain explicit approval. Then run:

```bash
node "<skill-dir>/scripts/bootstrap.mjs" install --yes
```

The installer adds only missing dependencies. Authentication remains user-owned: after installation, complete any browser/keyring login requested by the implementer CLI, then rerun `check`. When `sanad` is missing, refer users to the `install-sanad` skill; the bootstrap script does not attempt automatic Sanad installation.

## 2. Choose workspace and continuity

Every task must declare an absolute `workspace` for process spawning and supervisor identity. For Sanad, this field does not override the CLI targeting contract: choose either a registered `--workspace` or an unregistered temporary `--execution-root` in the task arguments.

Inspect the remembered identity for that workspace:

```bash
node "<skill-dir>/scripts/supervisor.mjs" identity --workspace <absolute-path>
```

Use identity deliberately:

- **Independent task:** start a fresh session/conversation. OpenCode still associates it with the workspace-derived project. For Antigravity, use the remembered `projectId` with `--project` when the user wants the same logical project but a new conversation. For Sanad, use `--workspace` for registered project continuity or `--execution-root` alone for a temporary unregistered filesystem context.
- **Continuation or repair:** pass the exact remembered `sessionId`/`conversationId` to the owning delegate relay.
- **Parallel work:** use separate sessions/conversations. Parallel write tasks also require separate worktrees.

The supervisor records project/session/conversation identifiers from completed relay results in the user config directory. It does not silently resume them.

## 3. Prepare tasks

Write one self-contained brief per task according to the owning delegate skill. Prepare a JSON specification.

### OpenCode Specification Example:

```json
{
  "tasks": [
    {
      "id": "task-01",
      "implementer": "opencode",
      "workspace": "<target-worktree-path>",
      "command": "node",
      "args": ["<path-to-opencode-relay>", "--brief", "<brief-file>", "--model", "provider/model", "--cd", "<target-worktree-path>", "--out-dir", "<task-result-dir>"],
      "resultPath": "<task-result-dir>/result.json",
      "timelinePath": "<task-result-dir>/events.jsonl",
      "timelineFormat": "jsonl"
    }
  ]
}
```

### Sanad Specification Example:

```json
{
  "tasks": [
    {
      "id": "task-02",
      "implementer": "sanad",
      "workspace": "<target-worktree-path>",
      "command": "sanad",
      "args": [
        "run",
        "--brief-file", "<brief-file>",
        "--workspace", "<logical-workspace-id>",
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

For a temporary unregistered Sanad context, replace the `--workspace` pair with `"--execution-root", "<target-worktree-path>"`. If both appear, `--workspace` wins and the execution root is ignored. The supervisor requires at least one; execution-root-only mode must match the task's absolute `workspace` field.

*(Source development checkout fallback from the worktree root: `command: "fvm", args: ["dart", "run", "agent/bin/sanad_agent.dart", "run", ...]`)*.

Build relay arguments from the loaded delegate skill. The supervisor treats non-Sanad relay arguments as opaque; for Sanad it validates only the required machine-contract flags and workspace boundary. Commands are spawned directly except that Windows `.cmd`/`.bat` wrappers require Node's shell mode after shell metacharacters have been rejected. Keep secrets out of briefs, arguments, specs, and logs.

## 4. Run Topology: Start, Add, Enqueue, and Close

The supervisor maintains one long-lived run per reviewing orchestrator. The worker process remains active even when initial tasks settle, allowing dynamic task registration and queueing.

### 4.1. Start a supervisor run

```bash
node "<skill-dir>/scripts/supervisor.mjs" start \
  --spec <tasks.json> \
  --run-dir <absolute-run-directory> \
  [--max-concurrency <n>]
```

The command returns after the detached supervisor publishes a startup handshake. Record its JSON output (`runDir`, `supervisorPid`, and `cursor`). On Windows, the launcher uses an Explorer broker so the supervisor process outlives the initiating agent tool call.

### 4.2. Register held tasks dynamically (`add`)

Register tasks in `held` state without immediately launching them:

```bash
node "<skill-dir>/scripts/supervisor.mjs" add \
  --run <run-directory> \
  --spec <additional-tasks.json>
```

### 4.3. Queue tasks dynamically (`enqueue`)

Move previously held tasks into the execution queue:

```bash
node "<skill-dir>/scripts/supervisor.mjs" enqueue \
  --run <run-directory> \
  --task <task-id>
```

Or append a new specification and queue its tasks immediately in one operation:

```bash
node "<skill-dir>/scripts/supervisor.mjs" enqueue \
  --run <run-directory> \
  --spec <additional-tasks.json>
```

### 4.4. Explicit close (`close`)

When all implementation and review tasks are finished, explicitly close the run. Closing stops accepting new tasks and drains running/queued tasks before the worker completes:

```bash
node "<skill-dir>/scripts/supervisor.mjs" close \
  --run <run-directory> \
  [--wait]
```

## 5. Wait for intervention without scheduling or polling

Wait event-first for one meaningful transition:

```bash
node "<skill-dir>/scripts/watch-once.mjs" \
  --run <run-directory> \
  --since <last-sequence>
```

This command is event-driven. By default, it blocks until a task enters an intervention status (`needs_input`, `needs_permission`) or a terminal status (`completed`, `failed`, `blocked`, `timeout`, `aborted`, `interrupted`, `cancelled`), prints one JSON event, and exits. It does not wake on routine `running` or `resumed` transitions unless `--all` is passed.

It also returns a synthetic `supervisor_stale` intervention event when a manifest says `running` but its supervisor PID is dead, using filesystem events first and a bounded liveness fallback. Review that task or intervention, update the cursor from the returned `seq`, then invoke `watch-once` again.

A watcher can be interrupted and restarted without stopping workers or losing already-journaled events.

## 6. Inspect progress and let the user watch

Current status:

```bash
node "<skill-dir>/scripts/supervisor.mjs" status --run <run-directory>
```

A task's observable action timeline:

```bash
node "<skill-dir>/scripts/supervisor.mjs" timeline --run <run-directory> --task <task-id>
```

When the user asks to watch a particular subagent, open a dedicated terminal window:

```bash
node "<skill-dir>/scripts/supervisor.mjs" view --run <run-directory> --task <task-id>
```

The terminal follows observable events until interrupted. Closing it does not stop the task. On Windows, `view` writes a run-local viewer script and asks the Explorer shell to open it, keeping the terminal outside an Agent-owned kill-on-close Job.

Other useful views:

```bash
node "<skill-dir>/scripts/supervisor.mjs" logs --run <run-directory> --task <task-id> --tail 100
node "<skill-dir>/scripts/supervisor.mjs" inspect --run <run-directory> --task <task-id>
```

Use `--follow` only in a human-owned terminal. Agent tool calls use bounded reads or `watch-once`, never an indefinite follow stream.

## 7. Review every result

A terminal status means the relay exited; it does not prove correctness. Follow the owning delegate skill to inspect the result, diff, touched files, and gates. Surface scope changes and decisions instead of silently absorbing them. Preserve the session/conversation identifier for targeted continuation when rework is required.

## Included scripts

- `scripts/bootstrap.mjs` — discover and check delegate skills or implementer CLIs (`opencode`, `agy`, `sanad`).
- `scripts/supervisor.mjs` — launch runs, dynamically add/enqueue tasks, explicitly close runs, persist state and workspace identity, inspect logs/timelines, and open a viewer terminal.
- `scripts/watch-once.mjs` — race-safe event-driven wait for intervention (`needs_input`, `needs_permission`) or terminal transitions.
