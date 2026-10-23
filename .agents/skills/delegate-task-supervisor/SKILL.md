---
name: delegate-task-supervisor
description: Bootstrap and orchestrate one or many delegated coding-agent CLI tasks through installed delegate-skills, preserve workspace/project/session identity, expose live task timelines, follow a Sanad daemon session after its worker process exits, and wait event-first for the next meaningful transition. Use whenever work is handed to OpenCode, Antigravity/agy, or Sanad Agent either locally or remotely through `sanad-client`, especially for parallel, long-running, resumable, or human-observable delegation. Do not replace the implementer-specific delegate skill; load and follow it.
license: MIT
compatibility: Requires Node.js 18+ and git. The bootstrap helper can install delegate-skills and supported implementer CLIs with explicit approval. Runtime scripts use Node built-ins only and support macOS, Linux, and Windows.
metadata:
  version: 0.4.0
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

`check` distinguishes the installed Sanad CLI from a validated source-development fallback. When the installed binary is absent but the invoking checkout contains `agent/bin/sanad_agent.dart` and `fvm` (or `dart`) resolves on PATH, the report names the fallback as validated and actionable instead of treating the missing CLI as a blocker; `install-sanad` is then only needed when a release binary is required. An installed `sanad` command always remains the preferred delegation path.

If anything is missing, show the complete planned changes and obtain explicit approval. Then run:

```bash
node "<skill-dir>/scripts/bootstrap.mjs" install --yes
```

The installer adds only missing dependencies. Authentication remains user-owned: after installation, complete any browser/keyring login requested by the implementer CLI, then rerun `check`. When `sanad` is missing, refer users to the `install-sanad` skill; the bootstrap script does not attempt automatic Sanad installation.

## 2. Choose workspace and continuity

Every task must declare an absolute `workspace` for supervisor identity and as the delegated execution boundary. It is also the default process spawn directory. A Sanad source-development task may additionally declare an absolute `sourceRoot`; the supervisor then spawns the validated `fvm dart run <entry>/sanad_agent.dart run` command from that checkout while preserving `workspace` as the target execution root. For Sanad, neither field overrides the CLI targeting contract: choose either a registered `--workspace` or an unregistered temporary `--execution-root` in the task arguments.

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
      "home": "<absolute-custom-sanad-home>",
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

For a temporary unregistered Sanad context, replace the `--workspace` pair with `"--execution-root", "<target-worktree-path>"`. For an isolated worktree that must retain an existing logical conversation owner, supply both; `--workspace` owns conversation continuity while `--execution-root` owns tools and runtime context. The supervisor requires at least one and validates every supplied execution root against the task's absolute `workspace` field.

For source development, use `command: "fvm"`, `args: ["dart", "run", "agent/bin/sanad_agent.dart", "run", ...]`, and optionally `sourceRoot: "<sanad-source-checkout>"` when that checkout differs from the target `workspace`. `sourceRoot` is accepted only for this FVM form, must contain the requested entry point, and is recorded with the effective spawn directory in the run manifest. Installed `sanad run` tasks and non-Sanad implementers must not declare it.

### Remote Sanad (`sanad-client`) Specification Example:

```json
{
  "tasks": [
    {
      "id": "task-03",
      "implementer": "sanad",
      "workspace": "<caller-side-orchestration-root>",
      "command": "sanad-client",
      "args": [
        "-d", "<remote-device-id>",
        "run",
        "--workspace", "<remote-workspace-id>",
        "--brief-file", "<absolute-local-brief-file>",
        "--session", "<preallocated-session-id>",
        "--events",
        "--json"
      ]
    }
  ]
}
```

A remote task drives the same `run` machine contract on another machine through the loopback Client CLI relay. `command` is `sanad-client` or an explicit absolute path to a built binary. The supervisor requires the canonical prefix `-d|--device <device-id> run` (or `--device=<id> run`), plus `--brief-file`, `--session`, `--events`, and `--json`; it accepts `--workspace <remote-workspace-id>` or `--execution-root <remote-path>` and rejects `--out-dir`, a second device flag, and `timelinePath`.

Device ids, remote workspace ids, and remote execution roots describe the target machine and are never resolved, canonicalized, or compared with the local `workspace` field, which remains the supervisor's identity and spawn directory on the caller machine. `--brief-file` is the one caller-side path and must exist locally, because `sanad-client` reads it and relays only its content. Declaring `home` selects the caller-side Sanad Home whose Client owns the relay endpoint; it is injected as `--home` and exported exactly like a local task.

Remote tasks are streamed rather than file-tailed: the supervisor spawns them with stdin closed (`sanad-client` waits for stdin EOF), mirrors the relayed streams into the run directory, journals lifecycle events live, and captures the terminal `--json` envelope from stdout into `resultPath` (default `<run-dir>/<task-id>.result.json`). The observed timeline is the task's stdout log. Exit codes map to supervisor states instead of the generic success/failure split: `0` completed, `124` timeout, `130` cancelled, `69` blocked (`cause: client_unavailable`), `77` blocked (`cause: client_cli_disabled`), and exit `0` without an envelope `incomplete` (`cause: missing_result_envelope`), so a closed control socket never reads as success. The relay window is the relayed command's `--timeout` plus 30 seconds (300 seconds without one), so set `--timeout` to the expected run length; a run that outlives the window reports `timeout`.

A Sanad task running against a managed custom Home must declare `home: "<absolute-sanad-home>"`. The supervisor validates the path (absolute, existing directory), injects `--home` into the worker invocation, and spawns the worker with `SANAD_HOME` set to that Home and any inherited `SANAD_STATE_HOME` removed, so a detached worker and everything it starts never fall back to the caller's or the default Home (observed standalone/exit 78 and a migrated default Home). Declaring `--home` inside `args` is rejected as ambiguous, and `home` is valid only for Sanad tasks. Secrets and tokens never belong in `home`, briefs, arguments, or specs.

Build relay arguments from the loaded delegate skill. The supervisor treats non-Sanad relay arguments as opaque; for Sanad it validates only the required machine-contract flags and workspace boundary. Commands are spawned directly except that Windows `.cmd`/`.bat` wrappers require Node's shell mode after shell metacharacters have been rejected. Keep secrets out of briefs, arguments, specs, and logs.

### Sanad Runner Exit & Reason Codes across Restarts
When a Sanad task crosses an Agent daemon restart, `sanad run` reconnects within its reconnect window and follows the reclaimed turn. If failure occurs, it emits typed reason and exit codes:
- **`turn_in_flight` (exit code 3):** The target session is still owned by an active durable turn (`running`, `resuming`, `waiting`, or `stopping`). The supervisor must not immediately re-dispatch the same task or send another prompt to that session; inspect the session status or wait for the active turn to settle. A parked `blocked` turn and a `queued` turn never refuse a dispatch.
- **`reconnect_window_expired` (exit code 1):** Gateway connection was lost during execution and the daemon did not recover within the configured `--reconnect-timeout` (default 60s). The turn may still be running headless in the daemon; verify daemon health before retrying.
- **`turn_lost` (exit code 1):** Reconnection succeeded, but the restored session history no longer contains the original turn lineage.
- **`home_identity_mismatch` (exit code 78):** Reconnection discovered an endpoint belonging to a different Sanad Home. This is a fatal isolation error; do not retry against the same misconfigured endpoint.

While the run crosses the restart it stays alive and emits `reconnecting`, `reconnected`, and `re_attached` lifecycle records on its event stream. Treat those as liveness evidence and do not cancel or re-dispatch the task while they appear; a `blocked` cause still ends the run at once with exit 1.

## 4. Run Topology: Start, Add, Enqueue, and Close

The supervisor maintains one long-lived run per reviewing orchestrator. The worker process remains active even when initial tasks settle, allowing dynamic task registration and queueing.

### 4.1. Start a supervisor run

```bash
node "<skill-dir>/scripts/supervisor.mjs" start \
  --spec <tasks.json> \
  --run-dir <absolute-run-directory> \
  [--max-concurrency <n>]
```

The command returns after the detached supervisor publishes a startup handshake. Record its JSON output (`runDir`, `supervisorPid`, and `cursor`). Artifacts remain outside the source workspace so relay bookkeeping does not dirty the repository. On Windows, the launcher uses the existing Explorer shell as a broker so an Agent-owned kill-on-close Job does not terminate the supervisor when the initiating tool call returns; a missing broker handshake is a launch failure, never a reported running task.

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

This command is event-driven. By default, it blocks until a task enters an intervention status (`needs_input`, `needs_permission`) or a terminal status (`completed`, `failed`, `blocked`, `timeout`, `aborted`, `interrupted`, `cancelled`, `incomplete`, `needs_review`, `follow_lost`), prints one JSON event, and exits. It does not wake on routine `running` or `resumed` transitions unless `--all` is passed. It also returns a synthetic `supervisor_stale` intervention event when a manifest says `running` but its supervisor PID is dead, using filesystem events first and a one-second bounded liveness fallback so callers cannot block forever on stale state. Review that task or intervention, update the cursor from the returned `seq`, then invoke `watch-once` again.

A watcher can be interrupted and restarted without stopping workers or losing already-journaled events.

**Caller timeout does not mean worker failure.** If an agent tool call that blocks on `watch-once` times out, the worker and the supervised tasks keep running; a watcher timeout only ends the caller's wait. Re-enter with the cursor from the last returned event (or `supervisor status --run <dir> --json` to read the current `seq`), then resume with `--since <seq>`. Use only bounded `status`/`inspect` reads between waits; never schedule polling or stop the worker because a watcher call timed out.

### 5.1. Keep watching after a worker exits

A `sanad run` process is only the transport for one daemon turn. When it exits while the daemon still owns that turn — a transient provider timeout, a daemon restart that reclaims the turn, or a signal that ended the transport — the supervisor keeps the task non-terminal as `following` and polls `sanad session show <session-id> --json` instead of reporting a failure. Nothing is required in the specification: the behaviour is on by default for every Sanad task whose session id is known.

The poll journals the same events an attached worker produces: `needs_input` and `needs_permission` (with request id, tool name, and questions), `blocked` and `waiting` (with their cause), `retrying`, `resuming`, and the terminal outcome. `watch-once` wakes on every attention state exactly as it does for an attached task, and the automatic retry policy applies to a followed block with the same grace, attempts, and transient-cause set. `following` itself is progress, never a wake-up.

**A retry in progress is not a failure.** The daemon owns recovery, and it tells observers what it is doing: a retryable failure it schedules is a `waiting` notice carrying `retry_attempt`/`retry_budget`, and the runtime notice stays on the projection while it retries. The supervisor reports such a task as `retrying (n/N)` — live, non-actionable progress — and only reports `blocked` when the daemon will not continue on its own: a non-retryable reason, a spent budget, or a cancelled resume. The same rule applies to `sanad run`, which prints `retrying (n/N)` and keeps following instead of exiting. Evidence for the reading lives in `session show <id> --json`: `execution_state`, `runtime_notice`, and the derived `retry` object (`pending`, `stopped`, `attempt`, `budget`, `label`). `retry --task` still accepts a `retrying` task, because a manual retry shortens the scheduled wait; an unknown session id is a `session_not_found` error from the CLI, never an `idle` session. A durable `idle` snapshot ends the turn, so a notice it left behind never reads as `retrying`: the follow settles instead of waiting for a retry that will never arrive.

| Control | Default | Meaning |
|---|---|---|
| `--follow-poll-ms` | `30000` | How often the durable session is read |
| `--follow-deadline-ms` | `3600000`, or the task's own `--timeout` | How long a followed turn may stay in flight before the task ends `timeout` |
| `--follow-lost-polls` | `3` | Consecutive unreadable reads after which the task ends `follow_lost` |
| `--cancel-force-kill-ms` | `10000` | Grace between the cancelling `SIGTERM` and the forced `SIGKILL`, both sent to the process group |

Start the run with `--follow-poll-ms 5000` when a question must reach a human quickly, and set the task's `--timeout` when the work has a known bound: that timeout becomes the follow window.

**`completed` needs evidence.** An `idle` session is not a verdict: it only says nothing is publishing the turn any more. `sanad session show <id> --json` carries no terminal turn record, so the verdict comes from the durable message accounting in `summary` — `final_answers` counts the assistant's finished replies and `user_messages` counts the turns sent to the session. A turn that finished normally leaves a final answer behind; one that was stopped, cancelled, or interrupted leaves its user message and whatever tool activity it produced, and no answer. So a followed task ends `completed` only when a final answer appeared inside the follow window or the session holds one for every user turn, and otherwise ends `failed` with `cause: turn_interrupted` (or the daemon's own cause) and an event a watcher can act on. The verdict is recorded under `follow.evidence` (`finalAnswers`, `userMessages`, `reason`). The result the task reports is that same verdict, so a status line can never show `completed` next to a worker artifact's `interrupted`: a late artifact is reported as `later-result` for triage.

**A group, not a pid.** A Sanad spec commonly runs through a wrapper (`fvm dart run …`, `npm …`), and the process that talks to the daemon is its child. Every task is therefore spawned in its own process group, `pgid` is recorded in the manifest, and cancel, the forced kill, and a graceful supervisor shutdown signal the whole group. After the direct child exits the group is verified with signal `0` before the exit is accepted: a group that outlives its child journals an actionable `worker_group_alive` and the follow reports `worker_exited_group_alive` instead of `worker_exited_turn_in_flight`. A cancelled group whose wrapper exits first is still force-killed on schedule. Never signal a task by name or pattern; use the recorded pid or `pgid`.

The final state is the turn's own durable outcome — and only a final assistant reply proves a completion. If the daemon reported a block, a stop, or a completed turn with its reply, that is what the task records; a terminal `result.json` written during the follow wins over it, and every terminal event names its `resultSource` (`worker_artifact` or `daemon_session`). When the session cannot be read at all, the worker's own verdict is kept; when a confirmed follow loses the session, the task ends `follow_lost` with the reason, which is terminal and actionable.

One boundary is worth knowing before you rely on it: the follow starts only when the daemon still owns the turn, and it never invents a turn that the daemon has already dropped. A transport that dies before the turn reaches a suspendable state (a question, a permission request, a block) takes its turn with it, so the task keeps the worker's own verdict (`follow.reason: turn_not_in_flight`) instead of waiting for work that no longer exists. A turn that reached a pending request or a block survives its transport, which is the case the follow exists for.

**Answering a followed task.** The event carries the session id and the request id, so the answer goes to the exact request, with the same Home the task was launched with:

```bash
sanad session answer <session-id> -r <request-id> --answer "<answer>" --home <task-Home>
sanad session permission <session-id> -r <request-id> --allow --home <task-Home>
```

Report the request to the user first and let them decide; the supervisor never answers on an operator's behalf, and it never journals the answer. A followed task is still cancelled with `cancel --run <dir> --task <id>`: the daemon session is stopped and the task settles `cancelled` without waiting for a process that no longer exists. `continue` needs a terminal task, so it applies after the follow ends, never during it.

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

The terminal follows observable events until interrupted. Closing it does not stop the task. On Windows, `view` writes a run-local viewer script and asks the existing Explorer shell to open it, keeping the terminal outside an Agent-owned kill-on-close Job; the window pauses instead of disappearing if the viewer exits with an error. OpenCode normally exposes structured tool events. Antigravity visibility is limited to the lifecycle and log data emitted by its relay; never claim unavailable private reasoning or tool detail.

Other useful views:

```bash
node "<skill-dir>/scripts/supervisor.mjs" logs --run <run-directory> --task <task-id> --tail 100
node "<skill-dir>/scripts/supervisor.mjs" inspect --run <run-directory> --task <task-id>
```

`status`, `timeline`, and `logs` human outputs include a bounded **Session Observability** footer reporting true session state (`working`, `waiting for input`, `waiting for permission`, `waiting`, `retrying (n/N)`, `resuming`, `blocked`, `stopped`, `completed`, `following the daemon turn`, `follow lost`, or `unknown`), error cause (`provider_timeout`, `rate_limit`, `network_error`, `provider_quota`, `auth_error`), state-since, last progress timestamp, elapsed duration, observation source, current time, and — for a followed task — the follow start, deadline, poll count, and last poll. PID liveness is shown only as observation metadata and never establishes `working`; without persisted progress the state is `unknown`. Timelines strictly display full ISO timestamps with timezone (`YYYY-MM-DDTHH:mm:ss.sssZ`), distinguish stream receipt time (`(received: <ISO>)`), and label missing historical timestamps as `[unknown time]` without manufacturing fake times from file mtime. Observer attachments persist timing records in `observers/<pid>.json`, tracking start and cancellation cleanly without manufacturing durations when hard kills occur.

Default `watch-once` wakes on blocked, waiting, retrying, resuming, intervention, and terminal transitions; use `--all` only when routine transitions are also relevant. Use `--follow` only in a human-owned terminal. Agent tool calls use bounded reads or `watch-once`, never an indefinite follow stream. A task that is `following` a daemon-owned turn is observed through the session, so `status` reports where the observation came from instead of implying a live worker; plain progress still never wakes a watcher.

## 7. Review every result

A terminal status means the relay exited; it does not prove correctness. Follow the owning delegate skill to inspect the result, diff, touched files, and gates. Surface scope changes and decisions instead of silently absorbing them. Preserve the session/conversation identifier for targeted continuation when rework is required. For Sanad tasks, inspect `cause` and `error_code` before retrying: `turn_in_flight` (exit 3) indicates that the session's prior turn is still active, while `reconnect_window_expired` indicates follow failure across daemon restart.

## Included scripts

- `scripts/supervisor.mjs` — the CLI entrypoint and `__worker`. It owns the command contract (flags, `HELP`, `main`), `start`, the worker loop, and the process-group lifecycle; every command it dispatches lives in the module that owns that responsibility.
- `scripts/supervisor-spec.mjs` — `validateTask`/`validateSpec`: the only place a submitted spec is accepted.
- `scripts/supervisor-core.mjs` — the shared primitives every other script imports: fail-fast errors and option helpers, run paths and the run manifest, atomic JSON, time parsing, and the `result.json` digest a terminal task is reported from.
- `scripts/supervisor-registry.mjs` — run identity and the workspace registry: the project/session remembered per workspace, keyed by the canonical workspace path.
- `scripts/supervisor-windows.mjs` — the Windows broker, its handshake, and the batch quoting both launch paths share.
- `scripts/supervisor-control.mjs` — `sendControlRequest` and the commands that change a live run: `add`, `enqueue`, `continue`, `steer`, `retry`, `cancel`, `set-concurrency`, `close`, plus the launch verification they report.
- `scripts/supervisor-views.mjs` — the read-only surfaces (`status` verbose/`--brief`/`--json`, `inspect`, `timeline`, `logs`, `view`) and the queue/progress formatting they quote.
- `scripts/supervisor-watch.mjs` — the durable `watch` loop with its cursor, the actionable-event enrichment every wake-up goes through, and `reconcileRun`, which turns a dead worker or a settled session into manifest state (`status` imports it too, so both surfaces repair the same way).
- `scripts/bootstrap.mjs` — discover and check delegate skills or implementer CLIs (`opencode`, `agy`, `sanad`).
- `scripts/watch-once.mjs` — race-safe event-driven wait for intervention (`needs_input`, `needs_permission`) or terminal transitions.

The pure policy modules `scripts/supervisor-events.mjs`, `scripts/supervisor-retry.mjs`, and `scripts/supervisor-follow.mjs` are imported by these owners as well; none of the scripts keeps a private copy of their rules.
