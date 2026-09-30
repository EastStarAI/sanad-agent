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
   - Explicit CLI flag: `--home <path>`
   - Environment variable: `SANAD_HOME`
   - Default user path: `~/.sanad` (or OS equivalent via `SanadHomeBootstrap.identity()`).

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
   - It binds both orchestrator responses and `RuntimeRecoveryService` notices into the canonical event path. Only `fatal` (or an unknown fail-closed status) terminates the current one-shot command. `waiting`, `blocked`, `resuming`, and `cleared` are non-terminal recovery lifecycle events: an attached `sanad run` remains connected while blocked for intervention and through a later resume, until the turn completes or its own timeout/stop boundary fires.
   - It starts no Local Gateway, cloud transport, daemon supervisor, cron scheduler, or listening port.
   - The daemon and standalone process compete for the same owner-only state-root lock before SQLite opens. A conflict exits with configuration code `78` and advises attachment or another Home.
   - Teardown detaches the runtime bridge, closes orchestrator subscriptions, workspace/MCP/OAuth resources, provider model cache, the database owner, event streams, and finally the ownership lease.
   - This turn transport is independent from provider adapters: provider adapters still own OpenAI, Anthropic, Ollama, and compatible model-wire communication below `AgentRunner`.

3. **Automation and cancellation:**
   - `--timeout` defaults to 300 seconds and accepts 1–86400 seconds before or after `run`.
   - Timeout, SIGINT, and SIGTERM converge on one idempotent Stop request and then deterministic exit codes `124`, `130`, and `143`.
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
- `sanad ws policy [default|full_access]`: Views or updates security permission mode.

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
| `/compact` | | Trigger session context compaction (`session.compact`, Plan 53) |
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
   - Sends `session.compact` command to trigger the compaction coordinator (Plan 53).
   - Summarizes past turns and prunes obsolete tool results while preserving the current goal.

---

## 8. Automated Test State Isolation

E2E tests that initialize DI, open the on-disk SQLite owner, or launch an agent process use temporary roots for both `SANAD_HOME` and `SANAD_STATE_HOME`. Dart child processes receive both variables explicitly rather than inheriting the developer's environment. In-process tests set and clear both root overrides around each test.

`AgentStateDatabase` additionally fails closed under the Dart test runner when no explicit state isolation is detectable. `test/guards/e2e_state_isolation_contract_test.dart` scans E2E persistent-runtime entry points and Dart child-process tests so newly added coverage cannot silently fall back to the user's normal Sanad database.

---

## 9. Session Observability & Safe Intervention (`sanad session`)

The CLI provides daemon-backed session inspection and safe intervention paths across both interactive chat and non-interactive script runs.

### 9.1. Subcommands Reference

| Subcommand | Invocations | Description |
|---|---|---|
| `list` | `sanad session list [--json]` | Lists active sessions discovered via the gateway. Appends `[Pending intervention]` when a session is suspended awaiting tool approval or user input. |
| `show` | `sanad session show <session-id> [--json] [--include-messages]` | Authoritative session inspection. Exposes status (`needs_input`, `needs_permission`, `running`, `idle`), owner identities, in-flight execution details, pending request payloads, the effective route, timestamps, and message/tool count summaries. By default the projection is **bounded** and excludes the full messages payload; pass `--include-messages` to opt in to the complete conversation/history. |
| `stop` | `sanad session stop <session-id> [--json]` | Halts execution strictly for the specified session, leaving other active sessions untouched. |
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

### 9.3. Bounded Session Show Projection (Machine-Review Contract)

`session show <session-id> --json` returns a **bounded, reviewer-focused** envelope by default so that supervisors and orchestrators can inspect a session without pulling the entire conversation/history payload. The default envelope includes:

- **Owner identities** (`identities`): `session_id`, active `run_id`, `work_item_id`, `request_id`, `pending_request_id`, `history_revision`, and `route_revision` when present.
- **Execution status** (`status`): `idle`, `running`, `needs_input`, or `needs_permission`, derived from in-flight state and any pending suspended request.
- **Pending intervention** (`pending_permission_request`) and in-flight execution (`in_flight`, `execution_snapshot`).
- **Effective route**: `model`, `model_display`, `provider_instance_id`, `model_provider`, `route_revision`, `route_updated_at`, and `thinking_mode`.
- **Timestamps**: `created_at`, `updated_at`, `last_user_message_at`.
- **Counts** (`message_count` + `summary`): total rows plus bounded `user_messages`, `final_answers`, `tool_calls`, `tool_results`, `reasoning_rows`, and `thought_rows` counts derived from the message history without copying any content.

The complete conversation/history is **never** embedded by default. It is exposed only through the explicit `--include-messages` opt-in flag, which adds the full `messages` payload. The plain-text (non-`--json`) branch already renders a bounded human summary and, when history exists, reminds the operator that full history requires `--include-messages`.
