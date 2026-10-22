---
title: "Sanad CLI Architecture"
description: "Attached and in-process transports, runtime ownership, automation output, cancellation, and test-isolation contracts."
---

# Sanad CLI Architecture & Gateway Runtime Contract

## 1. Overview

The Sanad Command Line Interface (CLI) provides a standalone, scriptable, and interactive terminal interface for the Sanad Agent without requiring the Flutter desktop UI.

The architecture enforces **one canonical agent runtime**:
- The engine, tools, SQLite owners, and provider adapters remain shared services under `agent/lib/`; standalone mode does not clone them.
- Attached CLI uses the **Sanad Local Gateway Protocol** through `LocalGatewayCliClient`.
- Standalone CLI uses `StandaloneCliTurnClient` as an in-process turn transport into `SessionRunOrchestrator`, while `SanadProtocolBridge` preserves the same canonical event model.

---

## 2. Layered Architecture

```
┌────────────────────────────────────────────────────────┐
│               Sanad CLI Interface Layer                │
│    (REPL / Interactive Chat, One-Shot, Unix Pipes)     │
└──────────────┬──────────────────────────┬──────────────┘
               │                          │
               ▼                          ▼
┌──────────────────────────────┐ ┌──────────────────────┐
│     LocalGatewayCliClient    │ │StandaloneCliTurnClient│
│  (Daemon WebSocket Client)   │ │(In-Process Transport) │
└──────────────┬───────────────┘ └──────────┬───────────┘
               │ ws://127.0.0.1:<port>/ws   │
               ▼                            │
┌──────────────────────────────┐            │
│  LocalDaemonServerPlatform   │            │
│    (SanadProtocolBridge)     │            │
└──────────────┬───────────────┘            │
               │                            │
               ▼                            ▼
┌────────────────────────────────────────────────────────┐
│            Sanad Agent Core Engine & Tools             │
└────────────────────────────────────────────────────────┘
```

---

## 3. Discovery & Credentials Contract

The CLI auto-discovers active runtime configuration from `SANAD_HOME`:

1. **`SANAD_HOME` Resolution:**
   - Explicit CLI flag: `--home <path>` or `--home=<path>` (a command's own option wins over the top-level option; the value is made absolute and normalized).
   - Environment variable: `SANAD_HOME`
   - Default user path: `~/.sanad` (or OS equivalent via `SanadHomeBootstrap.identity()`).
   - **Selection happens before any Home access (Task 126).** `agent/bin/sanad_agent.dart` resolves the selected Home with `SanadCommandRunner.selectedHome` — the same parser and precedence the commands use — and applies `selectSanadHome` before Home bootstrap, the vault open (which migrates and deletes legacy secret files), the bundled-skill sync, `.env` seeding, and the supervisor parent. Version and usage queries stay pure and touch no Home; a command line that does not parse only reports the usage error (exit `64`) and touches no Home either.
   - An explicit `--home` is a complete Home: identity, credentials, the vault, and runtime state (`state.db`) all resolve inside it, so an inherited `SANAD_HOME` or `SANAD_STATE_HOME` never leaks in. The supervised daemon child receives the same arguments and re-applies the selection.
   - E2E exception: in the deterministic E2E runtime (`SANAD_E2E_TEST_MODE=true`) an explicitly set `SANAD_STATE_HOME` keeps owning runtime state, because E2E isolation requires state separate from the identity Home. Before any Home access the CLI and `bin/daemon.dart` apply `requireSanadE2eTestIsolation`: E2E mode needs a non-empty `SANAD_STATE_HOME` distinct from the selected Home, and neither root may be the OS user's real default Home; a violation exits with configuration code `78`.

2. **Secret Credential Lookup:**
   - The CLI reads the local gateway token from `SANAD_HOME/.local_token`.
   - File permissions are validated to ensure owner-only access.
   - The token is never exposed in logs, CLI arguments, or printed output.

3. **Port Resolution & Probing:**
   - Explicit override: `--url <url>` or `--port <port>` or `LOCAL_GATEWAY_PORT`.
   - Default probe: `http://127.0.0.1:58085/health` with `x-sanad-local-token: <token>`.
   - Worktree range scan: If 58085 does not answer, the discovery service scans ports `58086`–`58185` with bounded timeout to find the instance matching the active workspace.

---

## 4. WebSocket Gateway Client (`LocalGatewayCliClient`)

### 4.1. Connection Handshake
- **Target Endpoint:** `ws://127.0.0.1:<port>/gateway` (with automatic `/ws` fallback support).
- **Authentication Headers:**
  - `x-sanad-gateway-token: <token>`
  - `x-sanad-local-token: <token>`
  - `authorization: Bearer <token>`
- **Welcome Event:** Upon connection, the daemon returns `register_success` with `platform_id` and `url`.

### 4.2. Outgoing Commands
All commands use the canonical `execute_command` envelope:

```json
{
  "type": "execute_command",
  "command": "think",
  "payload": {
    "session_id": "session-uuid",
    "message": "User instruction",
    "workspace_id": "ws-uuid",
    "model": "optional-model",
    "thinking_mode": "deep"
  },
  "request_id": "request-uuid",
  "device_id": "cli_client"
}
```

Supported commands:
- `think`: Starts or continues a conversation turn.
- `steer`: Steers an active execution mid-turn without discarding progress.
- `stop`: Halts the current agent turn.
- `tool_permission_response`: Submits user decisions for gated tools or interactive questions.
- `get_sessions`, `get_session_history`, `list_workspaces`, `get_capabilities`: Correlated query/response pairs.

### 4.3. Incoming Event Stream
Incoming WebSocket messages are dispatched into strongly-typed `CliEvent` instances:

| Event Type | Class | Description |
|---|---|---|
| `thought_stream` / `assistant` | `CliAssistantChunkEvent` | Streaming assistant text delta |
| `reasoning_stream` | `CliReasoningDeltaEvent` | Streaming thinking/reasoning delta |
| `tool_call` | `CliToolCallEvent` | Tool invocation notice with arguments |
| `tool_result` | `CliToolResultEvent` | Tool completion with output or error status |
| `tool_permission_request` | `CliPermissionRequestEvent` | Sensitive tool approval or clarifying questions |
| `final_answer` / `turn_complete` | `CliTurnCompleteEvent` | Turn completion with usage and model metadata |
| `session.runtime_notice` | `CliRuntimeNoticeEvent` | Advisory or rate-limit notices from orchestrator |
| `error` | `CliErrorEvent` | Operational or fatal errors |

---

## 5. Dual-Mode Attachment & Standalone Fallback

The CLI supports both attached daemon operation and standalone fallback:

1. **Attached Gateway Mode (Default):**
   - Connects to the background daemon via WebSocket.
   - Shares runtime state, active sessions, and workspace caches across CLI and desktop clients.
   - Automatically reconnects if the socket drops.

2. **Standalone Fallback Mode:**
   - Triggered when `--standalone` is passed or when no running daemon is detected.
   - `StandaloneCliTurnClient` initializes DI, auth, sessions, `SessionRunOrchestrator`, tools, permissions, provider routing, and canonical event translation inside the CLI process.
   - It binds both orchestrator responses and `RuntimeRecoveryService` notices into the canonical event path. `fatal` (or an unknown fail-closed status) and `blocked` end the current one-shot command. `blocked` awaits an intervention a non-interactive run cannot give, so `sanad run` exits `1` at once with one `Error: blocked: …` reason line (JSON `error`, artifact `status: failed`, `cause: blocked`) and sends no Stop: the blocked work stays daemon-owned for Retry, Change Provider or Stop (Task 125). `waiting`, `resuming`, and `cleared` remain non-terminal recovery lifecycle events while the daemon owns automatic progress. A typed refusal (`final_answer.error_code`, including `turn_failed`) also exits `1` at once.
   - It starts no Local Gateway, cloud transport, daemon supervisor, cron scheduler, or listening port.
   - The daemon and standalone process compete for the same owner-only state-root lock before SQLite opens. A conflict exits with configuration code `78` and advises attachment or another Home.
   - Teardown detaches the runtime bridge, closes orchestrator subscriptions, workspace/MCP/OAuth resources, provider model cache, the database owner, event streams, and finally the ownership lease.
   - This turn transport is independent from provider adapters: provider adapters still own OpenAI, Anthropic, Ollama, and compatible model-wire communication below `AgentRunner`.

3. **Automation and cancellation:**
   - `--timeout` defaults to 300 seconds and accepts 1–86400 seconds before or after `run`.
   - Timeout, SIGINT, and SIGTERM converge on one idempotent Stop request and then deterministic exit codes `124`, `130`, and `143`. A daemon block or refusal never reaches the timeout: it exits `1` immediately (Task 125).
   - `--json` emits one result envelope on stdout; `--quiet` emits only final assistant text. Bootstrap notices and diagnostics use stderr in both modes.
   - Gated tools are denied in non-interactive execution unless the caller supplies the invocation-scoped dangerous option `--allow-all-tools`; this option never mutates durable workspace policy.

---

## 6. Workspace Auto-Discovery & Management (`sanad ws`)

### 6.1. Workspace Locator & Ancestry Climbing
The CLI auto-detects the active workspace using `WorkspaceLocator`:
- Traverses upward from current working directory (`CWD`) towards filesystem root.
- Checks if `CWD` or any parent folder matches a registered workspace root.
- If multiple nested workspaces exist, the closest enclosing workspace is selected.
- If `CWD` is not registered, fast registration (`sanad ws add .`) is surfaced.

### 6.2. Active Workspace Resolution Priority
1. Explicit CLI argument (`-w` / `--workspace`).
2. `CWD` auto-discovery match.
3. Locally persisted active workspace (`SANAD_HOME/cli_state.json` via `sanad ws switch`).
4. Default fallback (null / prompt to register).

### 6.3. Workspace Subcommands
- `sanad ws list`: Formatted table with active marker `*`, name, policy, and path.
- `sanad ws current`: Full details of active workspace, status, discovery mode, and associated MCP servers.
- `sanad ws switch <name|id>`: Switches active workspace in local state file (`cli_state.json`).
- `sanad ws add [path] [--name <name>]`: Registers existing directory (defaults to `.`).
- `sanad ws create <name> [--path <dir>]`: Creates directory and registers workspace.
- `sanad ws tree [subpath]`: Renders formatted file/folder tree.
- `sanad ws policy [default|full_access]`: Views or updates security permission mode. The view also shows the Agent-owned execution mode and host discovery setting (read-only).

---

## 7. Interactive REPL Slash Commands & Control (`CliSlashCommandHandler`)

The REPL intercepts interactive slash commands locally or via gateway commands rather than forwarding them to the LLM as user messages.

### 7.1. Slash Commands Reference
| Command | Alias | Description |
|---|---|---|
| `/help` | | Show interactive REPL command reference and shortcuts |
| `/workspace` | `/ws` | View active workspace info, `/ws list`, or switch (`/ws switch <target>`) |
| `/model` | | View active model, list options (`/model list`), or switch (`/model <name>`) |
| `/session` | | Inspect session details, create new (`/session new`), list, or history |
| `/skills` | | List installed and bundled agent skills with status |
| `/mcp` | | List configured Model Context Protocol (MCP) servers and connection status |
| `/compact` | | Trigger session context compaction (`session.compact`, Plan 53). One correlated dispatch, never resent; a timeout renders a neutral still-running notice (Task 119) |
| `/steer <text>` | | Direct execution mid-flight; applies instructions at next step boundary |
| `/queue <text>` | | Enqueue prompt to execute after active turn completes (`delivery_intent: queue`) |
| `/stop` | | Cleanly interrupt active turn (also triggers on `Ctrl+C` during turns) |
| `/clear` | | Clear terminal screen display |
| `/history` | | List recent command history from `SANAD_HOME/cli_history` |
| `/thinking` | | Toggle deep reasoning stream visibility on/off |
| `/exit`, `/quit` | `exit`, `quit` | Exit interactive REPL session cleanly (`Ctrl+D` on empty prompt) |

### 7.2. Live Steering & Interruption Contract
1. **Live Steering (`/steer <text>`):**
   - When a turn is active, sends `steer` command to the gateway without killing or discarding in-flight tool results.
   - The orchestrator injects the steer instructions at the next safe execution boundary.
2. **Clean Interruption (`/stop` & SIGINT / `Ctrl+C`):**
   - Sends `stop` command to the gateway for the active session.
   - Aborts ongoing turn cleanly and prevents orphan background processes.
3. **Session Context Compaction (`/compact`):**
   - Sends one correlated `session.compact` query (`CliSlashCommandHandler._handleCompact` in `agent/lib/cli/repl/slash_command_handler.dart`, `resendOnTimeout: false`) to trigger the compaction coordinator (Plan 53).
   - The daemon replies after compaction finishes, so `accepted` renders as completed and busy, in-progress or failure outcomes render with their reason. A timeout (`SlashCommandContext.defaultCompactAcknowledgementTimeout`, 10 s) is not a failure: the REPL renders a neutral notice that compaction may still be running and never resends (Task 119).
   - Summarizes past turns and prunes obsolete tool results while preserving the current goal.

---

## 8. Automated Test State Isolation

E2E tests that initialize DI, open the on-disk SQLite owner, or launch an agent process use temporary roots for both `SANAD_HOME` and `SANAD_STATE_HOME`. Dart child processes receive both variables explicitly rather than inheriting the developer's environment. In-process tests set and clear both root overrides around each test.

`AgentStateDatabase` (default and `atPath`) and `SecretVaults.open`/`openDetached` additionally fail closed under the Dart test runner when no explicit state isolation is detectable, and whenever the selected root is the OS user's real default Home (`rejectUnisolatedTestHomeAccess` in `agent/lib/core/sanad_home/test_runtime_isolation.dart`). Suites that pass their own temporary paths declare isolation with `useIsolatedSanadStateRoot()`; worker isolates select their own root because overrides are per isolate. Under the Dart test runner and in `SANAD_E2E_TEST_MODE=true` processes, `createAgentSecretStore` returns the owner-only file store inside the selected Home (in E2E mode only after `requireSanadE2eTestIsolation`, the same rule DI enforces, so a real runtime started with the switch by mistake cannot hide OS-vault secrets behind a file), so tests and E2E subprocesses never reach the macOS Keychain, DPAPI, or Secret Service. `test/cli/cli_home_selection_isolation_test.dart` runs the real CLI entry with `HOME` and `--home` on different temporary roots and proves the default Home stays byte-for-byte untouched. `test/guards/e2e_state_isolation_contract_test.dart` scans E2E persistent-runtime entry points and Dart child-process tests so newly added coverage cannot silently fall back to the user's normal Sanad database.

### 8.1. Turn-Event Readiness in In-Process Runner Tests

In-process `sanad run` coverage (`test/cli/run_delegation_test.dart`) gates turn events on **dispatch readiness** (`await client.turnDispatched.future`), never on the initial `running` artifact. `OneshotRunner` records that artifact through `RunArtifactCoordinator.recordInitial()` before it resolves the client, subscribes to the client's event streams and dispatches the turn, while the test transport publishes on a broadcast stream: an event emitted in that window has no subscriber, is dropped, and the awaiting observer can never resolve. The shared mock's intervention emitters therefore fail fast when nothing is subscribed, so a premature gate becomes a deterministic, actionable failure instead of a scheduler-dependent timeout.

---

## 9. Session Observability & Safe Intervention (`sanad session`)

The CLI provides daemon-backed session inspection and safe intervention paths across both interactive chat and non-interactive script runs.

### 9.1. Subcommands Reference

| Subcommand | Invocations | Description |
|---|---|---|
| `list` | `sanad session list [--json]` | Lists active sessions discovered via the gateway. Appends `[Pending intervention]` when a session is suspended awaiting tool approval or user input. |
| `show` | `sanad session show <session-id> [--json] [--include-messages]` | Authoritative session inspection. Exposes status (`needs_input`, `needs_permission`, `running`, `idle`), owner identities, in-flight execution details, pending request payloads, the effective route, timestamps, and message/tool count summaries. By default the projection is **bounded** and excludes the full messages payload; pass `--include-messages` to opt in to the complete conversation/history. |
| `stop` | `sanad session stop <session-id> [--json]` | Halts execution strictly for the specified session, leaving other active sessions untouched. |
| `compact` | `sanad session compact <session-id> [--json] [--timeout <seconds>]` | Requests manual context compaction for the specified session through one correlated `session.compact` query (`LocalGatewayCliClient.compactSession` with `resendOnTimeout: false`, `agent/lib/cli/runner/commands/session_command.dart`). The daemon replies only after compaction finishes (`SessionRunOrchestrator.handleCompactCommand` awaits `runCompaction`), so the CLI waits for that terminal outcome (`accepted` = completed, `no_op`, or a failure/rejection). The wait is operation-scoped and bounded by the target Home's compaction pass timeout (`ModelAwareRuntimePolicy.compactionPassTimeoutForHome`, `config.yaml` `compaction.passTimeoutSeconds`, default 600 s); a valid `--timeout` overrides it and an invalid one falls back to it (Task 125). Dispatches exactly once. If the bound passes without a result the outcome is `unconfirmed` (exit `124`, JSON `poll: sanad session show <id>`), never failed: the daemon may still be compacting. `dispatched` occurs only on the resend-on-timeout path, which this subcommand disables. |
| `answer` | `sanad session answer <session-id> -r <req-id> --answer <text> [--file <path>] [--json]` | Explicit resolution path for pending `system_ask_user` questions. Accepts direct text or JSON/text file payload. |
| `permission` | `sanad session permission <session-id> -r <req-id> (--allow \| --deny) [--decision allow\|deny] [--scope once\|session\|workspace] [--comment <text>] [--file <path>] [--json]` | Explicit decision path for gated tool approvals. Accepts boolean flags or a structured JSON file payload. Aliases: `permit`, `decide`. |
| `new` | `sanad session new` | Generates and outputs a fresh UUID session identifier. |
| `delete` | `sanad session delete <session-id> [--json]` | Deletes a session and its cached turns from the daemon. |

### 9.2. Safe Intervention Protocol

1. **Strict Identity & Kind Validation:**
   - Every intervention binds to both `session_id` and `request_id`.
   - The daemon gateway enforces cross-session boundaries: attempting to answer a request under a different session returns `CROSS_SESSION_MISMATCH` without consuming the request.
   - Distinct failure codes prevent kind confusion: answers sent to ordinary tool permission requests return `INVALID_INTERVENTION_KIND`, while permission approvals sent to clarification questions return `INVALID_ANSWER` / `INVALID_INTERVENTION_KIND`.
   - Empty or whitespace-only clarification answers are rejected with `INVALID_ANSWER`.
   - Conflicting fields (e.g. `allowed: true, decision: deny`) are rejected with `CONTRADICTORY_DECISION`.

2. **Durable Checkpoints & First-Writer-Wins:**
   - Pending suspensions are backed by `suspended_checkpoints` rows in SQLite.
   - Multi-client or racing intervention attempts are reconciled using atomic DB claim semantics (`claimSuspendedCheckpointDecision`).
   - The winning writer claims the checkpoint and resumes execution; subsequent or duplicate responses receive `ALREADY_RESOLVED` and do not resume a second turn.

3. **One-Shot Non-Interactive Policy (`sanad run`):**
   - Headless execution (`sanad run "<prompt>"`) leaves gated tool permissions pending and emits a diagnostic notice to `stderr` specifying the exact intervention command syntax (`sanad session permission <session-id> -r <req-id> --allow / --deny`).
   - Permissions are never auto-denied, enabling external supervisors and developers to inspect via `session show` and resolve via `session permission`.
   - The `--allow-all-tools` option automatically approves ordinary tool execution only. Clarification questions (`system_ask_user`) always remain pending and require explicit user input.
   - Secret requests (`system_request_secret`) are never approved or answered by a terminal: `sanad run` records `needs_input` and prints a notice, the REPL prints the same notice and leaves the request pending for the Sanad Client, and the in-process terminal platform skips it. A manual `sanad session permission --allow` carries no values and is refused by the Agent.

### 9.3. Bounded Session Show Projection (Machine-Review Contract)

`session show <session-id> --json` returns a **bounded, reviewer-focused** envelope by default so that supervisors and orchestrators can inspect a session without pulling the entire conversation/history payload. The default envelope includes:

- **Owner identities** (`identities`): `session_id`, active `run_id`, `work_item_id`, `request_id`, `pending_request_id`, `history_revision`, and `route_revision` when present.
- **Execution status** (`status`): `idle`, `running`, `needs_input`, or `needs_permission`, derived from in-flight state and any pending suspended request.
- **Pending intervention** (`pending_permission_request`) and in-flight execution (`in_flight`, `execution_snapshot`).
- **Effective route**: `model`, `model_display`, `provider_instance_id`, `model_provider`, `route_revision`, `route_updated_at`, and `thinking_mode`.
- **Timestamps**: `created_at`, `updated_at`, `last_user_message_at`.
- **Counts** (`message_count` + `summary`): total rows plus bounded `user_messages`, `final_answers`, `tool_calls`, `tool_results`, `reasoning_rows`, and `thought_rows` counts derived from the message history without copying any content.
- **Latest compaction** (`compaction`, when history has a lifecycle row): `compaction_id`, `status` (`started`, `completed`, `failed`) and `trigger`, so a caller can poll a compaction that outlived `sanad session compact` (Task 125).

The complete conversation/history is **never** embedded by default. It is exposed only through the explicit `--include-messages` opt-in flag, which adds the full `messages` payload. The plain-text (non-`--json`) branch already renders a bounded human summary and, when history exists, reminds the operator that full history requires `--include-messages`.

---

## 10. Remote CLI Relay Architecture & Execution Seam (Plan 102)

The Sanad CLI architecture provides a remote execution seam so that `sanad-client` can target any online Agent without shell execution or command reimplementation.

### 10.1. Reusable Execution Seam
- Incoming `device.cli.execute` commands supply an argument vector `argv` and optional `stdin`.
- `RemoteCliCommandHandler` constructs `SanadCommandRunner` with injected `stdoutSink`, `stderrSink`, `stdinReader`, and `workspaceService`.
- Ordinary local CLI behavior remains unchanged: when invoked from a terminal shell, standard `stdout`, `stderr`, and `stdin` are used as defaults.
- Correlated stream events (`device.cli.stdout`, `device.cli.stderr`, `device.cli.event`) and a terminal `device.cli.result` envelope are published via the local or cloud gateway.
- Full protocol specification, schemas, and safety boundaries are documented in [Remote CLI Relay Protocol](remote_cli_relay_protocol.md).

### 10.2. Relay Boundaries per Command Family

- Read and control commands (`devices`, `ws list`, `session show|answer|stop`,
  `run`) execute through the remote runner and return ordered output plus one
  terminal result.
- `login` stays host-local by design: the remote runner has no interactive login
  handler, so a forwarded `login` returns exit code 0 with no relayed output.
  Hosts that need device authorization run `sanad login` locally in the target
  Sanad Home.
- File-backed caller input (`--brief-file`) is read by `sanad-client` and
  transported as request content; the remote process never opens the caller path
  and never evaluates a shell string.
- Interrupting the caller (`SIGINT`) forwards `device.cli.cancel`; the remote
  runner terminates the active command, the caller exits with code 130, and the
  remote session run is cancelled.

---

## 11. Schedule Inspection (`sanad schedule list`, Task 112)

`sanad schedule list` reads the `scheduled_tasks` rows of the selected Home directly from its
`state.db`, without the daemon. It is inspection only: schedule creation, update and cancellation stay
owned by the daemon's `CronScheduler` (single writer), so the CLI has no mutation subcommand.

- **Home selection:** `--home <path>` names the Home root that holds `state.db`; without it the
  process state root is used (`SANAD_STATE_HOME`, then `SANAD_HOME`, then the default Home).
- **Read-only connection:** `AgentStateDatabase.readOnlyAtPath` opens the file with SQLite
  `OpenMode.readOnly` and sets `PRAGMA query_only = ON`. It runs no Home bootstrap, schema creation,
  migration, WAL switch or permission repair, and it takes no state-root ownership lease, so it is safe
  while the daemon runs. A missing `state.db` is reported as empty and is never created. In WAL mode
  SQLite readers record read marks in the `state.db-shm` shared-memory index; `state.db` and
  `state.db-wal` content stay byte-identical. When no `state.db-wal` exists, some SQLite builds
  (for example on Linux) leave an empty one behind, because a read-only connection cannot checkpoint
  and delete it; an empty WAL holds no frames and changes no data.
- **Schema tolerance:** `ScheduledTaskRepository.inspectScheduledTasks` issues `PRAGMA`/`SELECT`
  only. A missing table is empty; a pre-Task-112 table (`run_at` only) is listed with the defaults
  `once`/`local`/enabled. The effective next run follows the migration precedence: a non-blank
  `run_at`, else `next_run_at`.
- **Text output:** columns `ID`, `SCHEDULE` (the schedule model's `humanRecurrenceSummary`, e.g.
  `daily at 14:52`, `every 10 minutes`, `weekly on mon, wed at 23:45`, `once at …`), `NEXT RUN` in the
  schedule zone, `ZONE`, `SESSION` (first 8 characters), `ENABLED`, and `LAST` (last status and last run
  in the schedule zone). An empty listing prints `No scheduled tasks`.
- **JSON output (`--json`), stable shape:** one object
  `{"source", "count", "tasks"}` where `source` is `current`, `legacy`, `missing_table` or
  `missing_database`, and each task has, in order, `id`, `task`, `kind`, `summary`, `zone`,
  `next_run_at` (in the zone), `next_run_at_utc`, `session_id` (full), `enabled`, `last_status`,
  `last_run_at` (in the zone) and `last_run_at_utc`.
- Coverage: `agent/test/cli/schedule_list_command_test.dart`.
