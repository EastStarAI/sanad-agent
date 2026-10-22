---
title: "Sanad CLI Architecture"
description: "Attached and in-process transports, runtime ownership, automation output, non-interactive session steering, cancellation, and test-isolation contracts."
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
   - A forced `--standalone` run refuses a Home whose daemon is healthy: the ownership pre-check probes the same explicitly targeted endpoint as the attach path through one run-scoped discovery, so it keeps the targeted deadline (2 s) for `--gateway-url` and a supplied gateway URL/port, while its speculative probes stay on the cheap bound (300 ms). Narrowing the pre-check to the speculative bound is a defect: a healthy but busy daemon would be mistaken for an absent one and the run would fall through to the standalone factory.
   - The daemon and standalone process compete for the same owner-only state-root lock before SQLite opens. A conflict exits with configuration code `78` and advises attachment or another Home.
   - Teardown detaches the runtime bridge, closes orchestrator subscriptions, workspace/MCP/OAuth resources, provider model cache, the database owner, event streams, and finally the ownership lease.
   - This turn transport is independent from provider adapters: provider adapters still own OpenAI, Anthropic, Ollama, and compatible model-wire communication below `AgentRunner`.

3. **Automation and cancellation:**
   - `--timeout` defaults to 300 seconds and accepts 1–86400 seconds before or after `run`.
   - Timeout, SIGINT, and SIGTERM converge on one idempotent Stop request and then deterministic exit codes `124`, `130`, and `143`. A daemon block or refusal never reaches the timeout: it exits `1` immediately (Task 125).
   - `--json` emits one result envelope on stdout; `--quiet` emits only final assistant text. Bootstrap notices and diagnostics use stderr in both modes. Every terminal reason is one line: the CLI owns the single leading `Error:` prefix and the sentence punctuation, so a refusal reads `Error: turn_failed: <cause>.` and a block reads `Error: blocked: <reason>. Intervene with sanad session stop <id> or retry from a client.` even when the daemon's own text already carries an `Error:` prefix or a trailing period (Task 125 round 2).
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
| `stop` | `sanad session stop <session-id> [--json]` | Halts execution strictly for the specified session, leaving other active sessions untouched. Dispatches one session-scoped `stop` immediately (naming the in-flight `run_id` resolved from the session projection), then confirms **authoritative idle** state through ordered state reads before reporting success. A matching `stopped` event only shortens the wait to the next read; it never proves the stop on its own. |
| `compact` | `sanad session compact <session-id> [--json] [--timeout <seconds>]` | Requests manual context compaction for the specified session through one correlated `session.compact` query (`LocalGatewayCliClient.compactSession` with `resendOnTimeout: false`, `agent/lib/cli/runner/commands/session_command.dart`). The daemon replies only after compaction finishes (`SessionRunOrchestrator.handleCompactCommand` awaits `runCompaction`), so the CLI waits for that terminal outcome (`accepted` = completed, `no_op`, or a failure/rejection). The wait is operation-scoped and bounded by the target Home's compaction pass timeout (`ModelAwareRuntimePolicy.compactionPassTimeoutForHome`, `config.yaml` `compaction.passTimeoutSeconds`, default 600 s); a valid `--timeout` overrides it and an invalid one falls back to it (Task 125). Dispatches exactly once. If the bound passes without a result the outcome is `unconfirmed` (exit `124`, JSON `poll: sanad session show <id>`), never failed: the daemon may still be compacting. `dispatched` occurs only on the resend-on-timeout path, which this subcommand disables. |
| `answer` | `sanad session answer <session-id> -r <req-id> --answer <text> [--file <path>] [--json]` | Explicit resolution path for pending `system_ask_user` questions. Accepts direct text or JSON/text file payload. |
| `permission` | `sanad session permission <session-id> -r <req-id> (--allow \| --deny) [--decision allow\|deny] [--scope once\|session\|workspace] [--comment <text>] [--file <path>] [--json]` | Explicit decision path for gated tool approvals. Accepts boolean flags or a structured JSON file payload. Aliases: `permit`, `decide`. |
| `steer` | `sanad session steer <session-id> (--message <text> \| --message-file <path>) [--timeout <seconds>] [--json]` | Non-interactive live steering for an orchestrator that supervises a running turn. Dispatches one `steer` command and reports the daemon's own delivery classification for that message id; see §9.5 for the exit codes and what "sent" proves. |
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

### 9.3. Stop Confirmation Contract (`sanad session stop`, Task 134)

The CLI stop is the same session-scoped interruption the Sanad Client UI sends, and it
confirms the same authoritative outcome:

1. **Run identity.** `SessionStopCommand` reads the session projection first and passes the
   in-flight `run_id` to `LocalGatewayCliClient.stop()` when one exists, so the daemon
   acknowledges the execution the operator observed. That read is best-effort: if it fails,
   the stop is still dispatched (the daemon's stop is session-scoped and never gated on the run).
2. **Immediate dispatch.** The `stop` command carries `session_id`, the optional `run_id`, and
   one correlation `request_id`; it is sent before any confirmation read so an interruption is
   never delayed behind an inspection round trip.
3. **Authoritative confirmation.** Success requires a post-dispatch read that reports no
   `in_flight` and no `pending_permission_request`. Reads repeat (bounded by the client request
   timeout, default 15 s) until that state is observed; a matching `stopped` canonical event
   only wakes the wait early so the state is re-read. A run that never becomes idle raises
   `CliClientException(stop_timeout)` and the command exits 1 without claiming success.
4. **Daemon side.** `SessionStopCoordinator` releases the stopped owner's in-memory
   `in_flight` projection and its durable interactive-wait checkpoints alongside durable work,
   recovery, and queued state, so `session show` reports `idle` after the stop instead of a
   frozen `running` snapshot (with its frozen `updated_at`) or a stale `needs_permission`.
   `SessionTurnExecutor` releases the same projection when a run enters a blocked/waiting
   recovery, because that run no longer publishes.
5. **REPL parity.** `/stop` and `Ctrl+C` use the same client path; an unconfirmed stop renders a
   neutral “dispatched, not yet confirmed idle” notice instead of a send failure.

### 9.4. Bounded Session Show Projection (Machine-Review Contract)

`session show <session-id> --json` returns a **bounded, reviewer-focused** envelope by default so that supervisors and orchestrators can inspect a session without pulling the entire conversation/history payload. The default envelope includes:

- **Owner identities** (`identities`): `session_id`, active `run_id`, `work_item_id`, `request_id`, `pending_request_id`, `history_revision`, and `route_revision` when present.
- **Execution status** (`status`): `idle`, `running`, `needs_input`, or `needs_permission`, derived from in-flight state, the durable execution snapshot, and any pending suspended request. An in-flight partial-stream snapshot whose durable execution projection is unowned (`idle`/`queued`) is stale and is not reported as `running` (Task 134).
- **Pending intervention** (`pending_permission_request`) and in-flight execution (`in_flight`, `execution_snapshot`).
- **Effective route**: `model`, `model_display`, `provider_instance_id`, `model_provider`, `route_revision`, `route_updated_at`, and `thinking_mode`.
- **Timestamps**: `created_at`, `updated_at`, `last_user_message_at`.
- **Counts** (`message_count` + `summary`): total rows plus bounded `user_messages`, `final_answers`, `tool_calls`, `tool_results`, `reasoning_rows`, and `thought_rows` counts derived from the message history without copying any content.
- **Latest compaction** (`compaction`, when history has a lifecycle row): `compaction_id`, `status` (`started`, `completed`, `failed`) and `trigger`, so a caller can poll a compaction that outlived `sanad session compact` (Task 125).

The complete conversation/history is **never** embedded by default. It is exposed only through the explicit `--include-messages` opt-in flag, which adds the full `messages` payload. The plain-text (non-`--json`) branch already renders a bounded human summary and, when history exists, reminds the operator that full history requires `--include-messages`.

### 9.5 Non-Interactive Steering Contract (`sanad session steer`)

`/steer` is the interactive REPL form; `sanad session steer` is the non-interactive
equivalent an orchestrator uses to add scope or corrections to a turn that is already
running, without waiting for it to finish and re-dispatching.

1. **Argument contract.** `sanad session steer <session-id> (--message <text> |
   --message-file <path>)`, plus the shared `--home` and `--gateway-url` pins every
   session subcommand honours. Exactly one of the two message sources is required; an
   empty or whitespace-only message is refused, and a `--message-file` is read as plain
   text and trimmed. No CLI-side length cap exists for user input in this command, so a
   message is bounded only by the transport itself. `--timeout` bounds the
   acknowledgement wait (default: the client request timeout, 15 s).
2. **What "sent" proves.** Success means the message was dispatched **and acknowledged
   by the gateway as a pending steer for the run that owns the session** — not that it
   was applied. The daemon delivers a pending steer at the next execution boundary, so
   an orchestrator must read the session history or event stream to confirm application.
   The plain success line is `Steer sent to session <id> (request <reqId>).`; `--json`
   emits `{"session_id":..., "request_id":..., "status":"steer_sent"}`.
3. **Ownership pre-check.** The command reads the session projection first and refuses to
   dispatch when no run owns the session, because the daemon does not reject such a
   steer: it admits it through the ordinary turn path (see 5). The pre-check uses the
   durable execution snapshot (`running`/`resuming`), so a stale in-memory `in_flight`
   projection left behind by a stopped or blocked run is not read as an active turn
   (Task 134). A session id that does not exist is indistinguishable from an idle
   session in that projection and is reported the same way.
4. **Acknowledgement mapping.** The acknowledgement is the daemon's own classification
   of the dispatched message id: `session.pending_steer_changed` or
   `session.message_classified` with `classification: steer` proves the pending steer was
   registered; `queue` means the gateway queued the text as a later turn instead;
   `think` means it was admitted as a new turn. A typed gateway `error` frame with a
   matching request id is reported with the gateway's own `error_code`.
5. **Gateway behaviour with no active turn.** The daemon's `SessionRunOrchestrator`
   steers only when a live owner exists (`canSteer`: not draining, `auto` delivery intent,
   an owned and not-stopping run, durable work `running`/`resuming`, and no recovery
   notice outside `resuming`). With no such owner the message falls through to the
   ordinary admission path: an idle session starts a **new turn** from the steer text, and
   a busy session **queues** it. Nothing is rejected and nothing is applied to the
   previous turn. `sanad session steer` never changes that daemon behaviour; it refuses
   before dispatch instead of silently starting a turn.
6. **Exit codes.** Every non-zero code carries a distinct JSON `error_code` in `--json`
   mode (`{"session_id":..., "status":"error", "error_code":..., "error":..., "exit_code":...}`).

| Exit | `error_code` | Meaning |
|---|---|---|
| `0` | — | Acknowledged as a pending steer for the active turn (not applied yet). |
| `1` | transport code (`not_connected`, `disconnected`, `send_error`, `query_timeout`, `steer_failed`) | The steer could not be dispatched or the session projection could not be read. |
| `2` | `invalid_arguments` | Invalid invocation: missing session id, neither or both message sources, an empty message, or an unreadable/empty message file. |
| `3` | `no_active_turn` | No run owns the session (idle, unknown, stopped, or blocked), or the gateway admitted the text as a new turn instead of a steer. |
| `4` | `steer_not_applied`, or the gateway's own code | The gateway acknowledged the message without registering it as a steer (for example queued as a later turn), or rejected it with a typed error. |
| `5` | `steer_unacknowledged` | Dispatched, but no acknowledgement arrived within the bound; the steer may still be applied. Confirm with `sanad session show <id>`. |

7. **Logging.** The steer body never enters stdout, stderr, or logs; failures report only
   identities, codes, and lifecycle metadata.

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

- Read and control commands (`devices`, `ws list`, `session show|steer|answer|stop`,
  `run`) execute through the remote runner and return ordered output plus one
  terminal result. The relay forwards the argument vector to the target Agent's own
  `SanadCommandRunner`, so a new session subcommand is relayable without a separate
  allow-list entry; `sanad-client -d <device-id> session steer ...` therefore works as
  soon as the Agent exposes it.
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

---

## 12. Model Catalog Filtering (`sanad models`, Task 136)

`sanad models` answers "which provider and which models can this Home actually route to". It reads
the cached catalog rows (`provider_model_cache`, keys `models`/`all`/`default`) from the selected
Home's `state.db` without contacting any provider.

- **Selection contract:** an unfiltered call reports every configured instance in
  `ProviderInstanceRepository.findAll()` order (`created_at DESC`). `--provider <selector>` narrows
  the report to exactly one instance using `ProviderSelector.resolve`, which matches at the first
  tier that produces a hit: instance UUID, then template id (`opencode-go`), then display name
  compared case-insensitively with internal whitespace collapsed. `--model <id>` then narrows to one
  cached model inside that selection (exact id, case-insensitive).
- **Fail-closed rules:** an unknown selector, an ambiguous selector (several instances matching at
  the same tier), or a `--model` that is absent from the selected catalog exits `2`, writes nothing
  to `stdout`, and prints one actionable `stderr` line naming the accepted selectors. The command
  never falls back to "all providers" for a selector it did not understand.
- **Text output:** the human block format is unchanged — `• Provider: <display> (<template>)`
  with `[DEFAULT]`, `Default Model:`, and one `- <value> (<label>) [reasoning] (active default)`
  row per cached model. `--quiet` suppresses only the leading `Configured Providers & Available
  Models:` header.
- **JSON output (`--json`), stable shape:** one object
  `{"schema": "sanad.models.v1", "providers": [...]}` where each provider carries `id`,
  `template_id`, `display_name`, `default_model`, `is_default`, `status`, `catalog_source`,
  `catalog_fetched_at`, and `models` (each with `value`, `label`, `supports_reasoning`,
  `is_default`). The cached catalog is reported as stored; this command never refreshes it, so a
  provider that advertises a model it later rejects still appears here until the cache is refetched.
- **Why filtering is mandatory:** model ids are advertised per provider and overlap in name shape
  (for example several providers ship `glm-*`). Reporting the whole catalog for a filtered request
  made a single provider's catalog indistinguishable from another provider's, which is how a
  `tail`n unfiltered report was mistaken for an OpenCode Go inventory.
- Coverage: `agent/test/cli/models_command_test.dart`.

---

## 13. One-Shot Stdin Contract (`sanad run`, Task 136)

`sanad run` resolves its prompt from the argument or `--brief-file`, and additionally from piped
stdin whenever stdin is not a terminal. Both sources are kept: an inline prompt followed by piped
content is joined as `"<prompt>\n\n<piped>"`, and piped content alone becomes the prompt.

- **Default splice:** this preserves the documented `cat file | sanad run "analyze"` workflow,
  including when the prompt arrives as a positional argument.
- **`--no-stdin` (additive, default off):** skips the stdin read entirely, so the caller's stdin
  stream is left untouched. Any driver loop of the form
  `while read -r item; do sanad run --no-stdin ... "$PROMPT"; done < list.txt` must pass this flag;
  without it the first `sanad run` consumes the rest of the loop's input and the loop ends after one
  iteration.
- The flag does not change dispatch, session, artifact, or exit-code behavior: it only removes the
  stdin splice.
- Coverage: `agent/test/cli/run_command_test.dart`.
