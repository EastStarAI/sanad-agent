---
name: delegate-task-supervisor
description: Bootstrap and orchestrate one or many delegated coding-agent CLI tasks through installed delegate-skills, preserve workspace/project/session identity, expose live task timelines, and wait event-first for the next meaningful transition. Use whenever work is handed to OpenCode, Antigravity/agy, or multiple external implementers, especially for parallel, long-running, resumable, or human-observable delegation. Do not replace the implementer-specific delegate skill; load and follow it.
license: MIT
compatibility: Requires Node.js 18+ and git. The bootstrap helper can install delegate-skills and supported implementer CLIs with explicit approval. Runtime scripts use Node built-ins only and support macOS, Linux, and Windows.
metadata:
  version: 0.1.0
---

# Delegate Task Supervisor

Coordinate external implementers without duplicating their own delegation contracts. This skill owns bootstrap, workspace identity, concurrency, durable task state, human observability, and event-driven wake-up. The selected `*-delegate` skill continues to own briefs, permissions, relay flags, result semantics, review, and resumption.

## Boundaries

- Load and follow `agy-delegate` for Antigravity and `opencode-delegate` for OpenCode. Do not copy or reinterpret their operational instructions.
- Use `delegate-setup` only when the user wants reusable fleet lanes. Direct one-off dispatch does not require a lane.
- For Sanad implementation, also load `Sanad Subagent Developer`; use an isolated worktree for every parallel write task.
- Never run two tasks concurrently in the same OpenCode session or Antigravity conversation.
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

The installer adds only missing dependencies. Authentication remains user-owned: after installation, complete any browser/keyring login requested by the implementer CLI, then rerun `check`.

## 2. Choose workspace and continuity

Every task must declare an absolute `workspace`. This is the filesystem root passed to the delegate relay as `--cd`; never rely on the supervisor's current directory.

Inspect the remembered identity for that workspace:

```bash
node "<skill-dir>/scripts/supervisor.mjs" identity --workspace <absolute-path>
```

Use identity deliberately:

- **Independent task:** start a fresh session/conversation. OpenCode still associates it with the workspace-derived project. For Antigravity, use the remembered `projectId` with `--project` when the user wants the same logical project but a new conversation.
- **Continuation or repair:** pass the exact remembered `sessionId`/`conversationId` to the owning delegate relay.
- **Parallel work:** use separate sessions/conversations. Parallel write tasks also require separate worktrees.

The supervisor records project/session/conversation identifiers from completed relay results in the user config directory. It does not silently resume them.

## 3. Prepare tasks

Write one self-contained brief per task according to the owning delegate skill. Prepare a JSON specification:

```json
{
  "tasks": [
    {
      "id": "task-01",
      "implementer": "opencode",
      "workspace": "/absolute/path/to/worktree",
      "command": "node",
      "args": ["/installed/opencode-delegate/scripts/relay.mjs", "--brief", "/path/brief.txt", "--model", "provider/model", "--cd", "/absolute/path/to/worktree", "--out-dir", "/path/run/task-01/result"],
      "resultPath": "/path/run/task-01/result/result.json",
      "timelinePath": "/path/run/task-01/result/events.jsonl",
      "timelineFormat": "jsonl"
    }
  ]
}
```

Build relay arguments from the loaded delegate skill; the supervisor treats them as opaque argv and never invokes a shell. Keep secrets out of briefs, arguments, specs, and logs.

## 4. Start one or many tasks

```bash
node "<skill-dir>/scripts/supervisor.mjs" start \
  --spec <tasks.json> \
  --run-dir <absolute-run-directory>
```

The command returns after a detached supervisor starts. Record its JSON output, especially `runDir`, `supervisorPid`, and `cursor`. Artifacts remain outside the source workspace so relay bookkeeping does not dirty the repository.

Default concurrency is the task count. Bound expensive queues with `--max-concurrency <n>`. Run dependent tasks sequentially, landing or verifying each prerequisite before dispatching its dependent.

## 5. Wait for intervention without scheduling or polling

Wait for one meaningful transition:

```bash
node "<skill-dir>/scripts/watch-once.mjs" \
  --run <run-directory> \
  --since <last-sequence>
```

This command is event-driven. It blocks until a task enters `completed`, `failed`, `blocked`, `timeout`, or `aborted`, prints one JSON event, and exits. Review that task, update the cursor from the returned `seq`, then invoke `watch-once` again for remaining tasks.

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

The terminal follows observable events until interrupted. Closing it does not stop the task. OpenCode normally exposes structured tool events. Antigravity visibility is limited to the lifecycle and log data emitted by its relay; never claim unavailable private reasoning or tool detail.

Other useful views:

```bash
node "<skill-dir>/scripts/supervisor.mjs" logs --run <run-directory> --task <task-id> --tail 100
node "<skill-dir>/scripts/supervisor.mjs" inspect --run <run-directory> --task <task-id>
```

Use `--follow` only in a human-owned terminal. Agent tool calls use bounded reads or `watch-once`, never an indefinite follow stream.

## 7. Review every result

A terminal status means the relay exited; it does not prove correctness. Follow the owning delegate skill to inspect the result, diff, touched files, and gates. Surface scope changes and decisions instead of silently absorbing them. Preserve the session/conversation identifier for targeted continuation when rework is required.

## Included scripts

- `scripts/bootstrap.mjs` — discover and explicitly install missing delegate skills or implementer CLIs.
- `scripts/supervisor.mjs` — launch tasks, persist state and workspace identity, inspect logs/timelines, and open a human viewer terminal.
- `scripts/watch-once.mjs` — race-safe event-driven wait for one terminal transition.
