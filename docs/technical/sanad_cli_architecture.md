---
title: "Sanad CLI Architecture"
description: "Attached and in-process transports, startup vault order, prompt ownership and code-identity authorization failures, runtime ownership, automation output, non-interactive session steering and runtime recovery retry, cancellation, and test-isolation contracts."
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
   - File permissions are validated to ensure owner-only access: a token that is
     not `0600` is refused with code `token_permissions` (never auto-repaired,
     because a non-daemon caller must not write to the Home), and a missing,
     empty, or unreadable file keeps its own `token_not_found` / `token_empty` /
     `token_read_error` code. The desktop Client and `sanad-dev` apply the same
     `0600` rule.
   - The token is never exposed in logs, CLI arguments, or printed output.
   - Each Home owns a distinct token. `.local_token.home` binds `.local_token`
     to the SHA-256 identity of that Home root, so a Home cloned or restored
     from another Home (the Test-Home practice that once produced one shared
     `.local_token` across `~/.sanad-test-*`) is detected and rotated instead of
     inheriting the source credential.
   - **Only the daemon rotates.** `LocalGatewayCredentials.loadOrCreateForDaemonStart`
     is the single entry point that creates, migrates, or rotates the
     credential, and only `bin/daemon.dart` (after `SanadRuntimeOwnership.acquire`
     and before the listener serves) and the daemon's own platform fallback call
     it. It rotates when the binding is missing (a pre-binding Home) or names a
     different Home, and it writes the binding *before* the token so a concurrent
     reader never sees a rotated token beside a stale binding.
   - Every non-daemon caller is read-only: `sanad login`/logout notify through
     `LocalAuthenticationExchangeNotifier`, whose default loader reads with
     `LocalGatewayCredentials.readExisting()` and never creates or rotates.
     Rotating from there would invalidate the credential a running daemon (and
     every desktop Client re-reading `.local_token`) already holds, which is the
     upgrade regression this contract rules out. `tryRead` treats a token bound
     to another Home as absent, so a clone never lends its credential to the
     Home it was copied into.
   - A `.local_token` whose binding names another Home is refused by discovery
     with `token_bound_to_other_home`; start the Agent for that Home to issue
     its own credential.

3. **Port Resolution & Probing:**
   - Explicit override: `--gateway-url <url>` or `--port <port>`.
   - **Selected Home:** when `--home` or `SANAD_HOME` selects a Home, the CLI
     resolves the endpoint from that Home's own runtime record
     (`.local_gateway_endpoint.json`, written by the daemon after it binds and
     removed on every exit path that ends the runtime) and probes only that
     endpoint. Three paths end the runtime and all of them run one bounded
     pre-exit cleanup: a termination signal (`SIGTERM`/`SIGINT`), the managed
     pause or stop a coordinator performs after `/shutdown` or `/restart`
     flushed its response (exit `123`, which is what `sanad-dev stop` produces),
     and a controlled refresh (exit `0`) whose successor republishes the record
     when it binds. Every path removes the record only while it still names its
     own pid, and a cleanup that fails or never completes still lets the daemon
     exit — a runtime that refuses to stop is worse than a record the next call
     fails closed on. A record is
     usable only when it is owner-only (`0600`), names a loopback host, carries
     a process id that is still alive, and its `home_id` matches the selected
     Home's identity; the answer is then accepted only when `/health` reports
     the same `home_id`. Removal is ownership-checked and atomic: the record is
     claimed with a rename before the identity is re-verified, so a draining
     daemon can never delete a successor runtime's republished record. An
     unclean death (`SIGKILL`) leaves the record to fail closed as
     `home_runtime_stale`, which is the signal that the previous runtime did not
     stop cleanly. A signal-driven exit keeps the signal's own status
     (`128 + signal`: `143` for `SIGTERM`, `130` for `SIGINT`) instead of
     exiting `0`, so a shell, `sanad-dev`, and a real supervisor still see a
     signal termination rather than a requested clean stop.
   - **Inherited values never override a selection.** `SANAD_GATEWAY_URL`,
     `LOCAL_GATEWAY_URL`, and `LOCAL_GATEWAY_PORT` come from a parent process
     (a launcher, a test harness, another runtime) and are ignored entirely when
     a Home is selected, so a Home X token is never sent to an endpoint that was
     not chosen for that Home. They are still honoured when no Home is selected.
   - **Every healthy answer must prove the Home.** An explicit
     `--gateway-url`/`--port` target, an inherited URL/port, the default port
     probe, and every scanned port are all accepted only when `/health` reports
     the resolved Home identity — token acceptance alone is not evidence.
   - **A refusal is an answer, not silence.** With a selected Home, an explicit
     `--gateway-url`/`--port` target that answers `401`/`403` has provably
     refused *this Home's* credential, so it is not that Home's daemon: the call
     fails closed with `home_identity_mismatch` and exit `78`, and no WebSocket
     connect is attempted. A target that does not answer at all remains "not
     running", which keeps `--standalone` and the oneshot standalone fallback
     working. A recorded endpoint (`step 3`) that refuses the credential is
     treated the same way; without a selected Home the historical behaviour is
     kept, so the legacy default-Home flow is unchanged.
   - **Backward compatibility (default Home only):** a daemon released before
     `home_id` existed reports none. A *missing* `home_id` is tolerated only on
     the default Home's port `58085`; a named Home, a scanned port, or a
     *mismatching* `home_id` always fails closed.
   - A selected Home with no live record, a stale record (its publisher process
     is gone), an unreachable recorded endpoint, or a daemon that serves another
     Home fails closed with exit code `78` and an actionable message. A
     Home-selected call never probes `58085` and never scans the range, so an
     unpinned mutating command can no longer attach to another Home's runtime.
   - Default Home only: probe `http://127.0.0.1:58085/health`, then scan
     `58086`–`58185` with a bounded timeout. Every candidate must prove the
     resolved Home identity over `/health`.

   **Endpoint-resolution failures (`session …` and any other attached command):**
   - Exit code `78` (configuration), not `1`. Exit code `1` continues to mean the
     command ran and failed; `78` means the environment could not name an
     endpoint this Home owns, and the message names the fix.
   - `--json` emits the same result envelope the CLI uses elsewhere
     (`session_id`, `text`, `tool_executions`, `exit_code`, `error`), not the
     removed `{"exit_code": 1, "error": …}` shape, and the message is duplicated
     on `stderr` so a text consumer sees it too. The envelope also carries
     `error_code`, the discovery code below, so a consumer branches on the code
     instead of parsing English; it is absent when the failure has no code.
     Commands that deliberately fall back instead of failing (`sanad run`,
     workspace, doctor) keep their own contract and report no code because no
     endpoint failure terminates them.
   - Error codes: `home_runtime_missing`, `home_runtime_foreign`,
     `home_runtime_stale`, `home_runtime_unhealthy`, `home_identity_mismatch`,
     plus the token codes above. Token-read and permission problems stay
     distinguishable (`token_permissions` vs `token_read_error` vs
     `token_not_found`).

### 3.1. Startup Order and the Agent Vault

Startup order is a contract, because every step before dispatch touches the Home:

```
--version/help (pure, no Home)  →  --home selection  →  E2E isolation check
  →  Home bootstrap  →  Agent vault (only when the command can touch a secret)
  →  bundled-skill sync  →  `.env` seeding  →  command dispatch
```

- **The vault opens only for a command that can read or write a secret.** `SanadCommandRunner.requiresSecretVault` classifies the command line with the same parser the commands use, per subcommand: `session`, `workspace`/`ws`, `memory`, the pure queries, `schedule list`, and `skills list` never open it; every other command and subcommand — including an unrecognized or unparseable line, and a bare family name such as `schedule` — keeps opening it, so a new command can never silently lose its credentials. The in-process standalone runtime still opens the vault itself (`StandaloneCliTurnClient.start`) and the daemon opens it in `bin/daemon.dart`.
- **A process that never opened the vault cannot write a secret to a file.** `SecretVaultPolicy.vaultSkipped` records the classification, and `SecureFileSecretStore` (the plaintext provider-secret store, including the `di.dart` fallback) refuses `write`, `remove`, and `pruneOrphans` in such a process with `plaintext_fallback_blocked`. A vault-free command that suddenly reaches a provider-secret write therefore fails loudly instead of leaving plaintext on disk.
- **Why the vault is not free.** The vault is the OS credential vault (macOS Keychain, Windows DPAPI, Linux Secret Service). Opening it reads each namespace owner index, and macOS answers a read of a generic-password item whose ACL does not accept the calling binary with an interactive authorization dialog instead of data. In a desktop session that dialog *is* shown for a CLI binary, and the reading thread then blocks *inside* the security framework, before the event loop can serve anything: the process prints nothing (not even the bundled-skill line), opens no socket, spawns no child, and never exits. `sample(1)` shows the blocked thread in `SecItemCopyMatching → SecKeychainItemCopyContent → SecurityServer::ClientSession::decrypt → mach_msg` while the Dart main isolate idles in `Dart_RunLoop`, and `securityd` logs `displaying keychain prompt for <binary>; ACL: … <CodeSignatureAclSubject … identifier dartvm …>`. The reported defect was therefore not "the dialog never appears": it was a dialog nobody was looking at while an automation caller, the Client, or a scheduler waited for output that could never come. A gateway command that opens the vault for no reason turns any unattended caller into that wait.
- **Why it presents as "AOT only".** The ACL is a *code-identity* check, not an interpreter check. A vault populated by `fvm dart run …` records the FVM `dartvm` signature, so the same command under JIT is already authorized while a `dart compile exe` build — a different ad-hoc signature with no matching requirement — is asked to authorize. Any other identity differs the same way: a newer release binary whose signature no longer matches an older item, or the packaged app versus a separately installed CLI.
- **Who may start the dialog.** `SecretVaultPolicy` decides it from explicit evidence, once per process, before the vault opens:

  | Evidence | Detected by | Interaction |
  | --- | --- | --- |
  | Daemon entry point (`daemon`, alias `start`, direct `bin/daemon.dart`) | `SanadCommandRunner.dispatchesToDaemon`, `bin/daemon.dart` | allowed |
  | Interactive CLI (`run --standalone`, `models`, `providers`, `setup`, `login`, `doctor`) | stdin **and** stdout are terminals, no machine-output flag | allowed |
  | `--json`, `--quiet`, `-q` | command line | forbidden (`machine_output`) |
  | `--child-process` | command line | forbidden (`supervised_child`) |
  | Client, scheduler, delegate relay, script, pipe | stdin or stdout is not a terminal | forbidden (`no_terminal`) |
  | Spawner declaration | `SANAD_SECRET_VAULT_INTERACTION=forbid`/`allow` | honour the declaration |

  There is no inference from a parent process name: a caller that allocates a terminal on purpose sets the environment variable, and everything else is decided by the command line and the stdio shape.
- **The daemon keeps the prompt.** It is the process that migrates legacy secret files, an operator starts it from the desktop app or a launchd service, and its one-time authorization dialog is the intended way to grant access. It never inherits the CLI's stdio-shaped detection.
- **Only a process with nobody present suppresses the dialog.** `MacOsKeychainAgentSecretStore` then attaches an `LAContext` with `interactionNotAllowed` through the non-deprecated `kSecUseAuthenticationContext` and switches the legacy file keychain with `SecKeychainSetUserInteractionAllowed(0)` (the file keychain ignores the per-query context; the switch is safe there precisely because the process already established that no human can answer anything). An authorization-demanding item returns `errSecInteractionNotAllowed` (`-25308`) or `errSecInteractionRequired` (`-25315`), `errSecAuthFailed` (`-25293`) means the item's access control rejected this binary, and `errSecUserCanceled` (`-128`) means somebody dismissed the dialog. Each maps to its own `AgentSecretStoreUnavailableReason` (`interaction_forbidden`, `interaction_required`, `authorization_denied`, `authorization_canceled`) and its own message, so a dismissed dialog never reads as a rejected binary.
- **An interactive run announces the wait.** Before its first Keychain query the store prints one stderr line, `Waiting for macOS Keychain approval for ai.eaststar.sanad.agent…`, and never a secret. A process that forbids interaction never prints it, because it never starts the dialog.
- **A closed vault is reported, not buried.** `SecretVaults` records the reason code, `sanad doctor` prints `[✗] Agent Vault: unavailable (<reason>)` with the recovery steps, the daemon logs an actionable warning naming what is unreadable and how to recover, and the local gateway `/health` payload carries `secret_vault: available|unavailable` plus `secret_vault_reason`. All three are non-secret.
- **Recovery for an affected Home.** Authorization is per code identity, so the recovery is to give the item an identity that trusts the binary you run: Keychain Access → the `ai.eaststar.sanad.agent` item → Access Control → add the Agent binary you invoke. Nothing in Sanad rewrites, re-creates, or re-ACLs vault items, and a binary that cannot read the owner index cannot migrate them either, so a Home whose items belong to a foreign identity is recovered out of band or by running the build that created them. A release whose signature keeps a stable designation-based requirement does not re-ask on upgrade; a development AOT build changes identity on every compile and therefore always differs from a vault populated by `fvm dart run …`.
- **Regression guard.** `agent/tool/cli_aot_smoke.dart` (the `cli-automation` CI job, all three OSes) compiles the CLI with `dart compile exe`, starts `agent/tool/fake_local_gateway.dart` on an ephemeral loopback port, and runs `session list`, `session show`, and `session stop` against a throwaway Home and token with a hard per-command deadline. It asserts that every gateway command succeeds *and* that the throwaway Home holds no `secret_vault*` artifact, and then that `models list` — which does read provider credentials — opens the vault, finishes, and prints no approval notice in a process with no terminal. `test/cli/cli_vault_open_policy_test.dart` pins the classifier, and `test/core/auth/secret_vault_interaction_policy_test.dart` pins the status mapping, the detection matrix, the plaintext guard, and the `LAContext` path.


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
   - A mid-turn gateway drop is a restart, not a failure. The run spends at most `--reconnect-timeout` (default 60 s) per drop re-discovering the same Home's endpoint, then compares the durable `execution_snapshot.request_id` with the turn it dispatched and keeps following that turn. `waiting`, `resuming`, `running`, `queued`, and `stopping` are followed; `blocked` keeps the immediate exit `1`; an expired window exits `1` with `reconnect_window_expired`; a different lineage or an idle turn with no recorded result exits `1` with `turn_lost`; a foreign Home fails closed with `78` and `home_identity_mismatch`. A re-dispatch onto a session whose turn still owns it is refused with exit `3` and `turn_in_flight`. The owning machine contract is [Sanad Delegate CLI Relay § 4.4](../agent_engine/sanad_delegate_relay.md).
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
| `steer` | `sanad session steer <session-id> (--message <text> \| --message-file <path>) [--timeout <seconds>] [--json]` | Non-interactive live steering for an orchestrator that supervises a running turn. Dispatches one `steer` command with `steer_only: true` and reports the daemon's own delivery classification for that message id; see §9.5 for the exit codes and what "sent" proves. |
| `retry` | `sanad session retry <session-id> [--provider <instance-id>] [--model <model-id>] [--timeout <seconds>] [--json]` | Non-interactive recovery retry. Refuses before dispatch unless the session is `blocked`/`waiting`, then sends the same `session.runtime_retry` command the Sanad Client's Retry action sends and reports the daemon's own `resuming` transition; see §9.6 for the exit codes, the route override, and the automatic-retry rule. |
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
   session subcommand honours. Exactly one of the two message sources is required: a
   shape that carries both options is refused even when one of them is blank. An
   empty or whitespace-only message is refused, a `--message-file` is read as plain
   text and trimmed, and the file path itself is used verbatim — never trimmed or
   rewritten — so a path with surrounding spaces names exactly what the caller
   passed. A directory, a missing path, and an unreadable or empty file are distinct
   usage errors. No CLI-side length cap exists for user input in this command, so a
   message is bounded only by the transport itself. `--timeout` bounds the
   acknowledgement wait (default: the client request timeout, 15 s) and reuses the
   shared option's documented range of whole seconds `1..86400`; any other value is a
   usage error, never a silent fall-back to the default.
2. **What "sent" proves.** Success means the message was dispatched **and acknowledged
   by the gateway as a pending steer for the run that owns the session** — not that it
   was applied. The daemon delivers a pending steer at the next execution boundary, so
   an orchestrator must read the session history or event stream to confirm application.
   The plain success line is `Steer sent to session <id> (request <reqId>).`; `--json`
   emits `{"session_id":..., "request_id":..., "status":"steer_sent"}`. The request id
   is allocated by the command before the dispatch, so every outcome — including a
   timeout — names it in both plain (`... (request <reqId>)`) and JSON form; a late
   acknowledgement can therefore always be correlated.
3. **`steer_only` (opt-in, daemon-enforced).** Every CLI dispatch carries
   `steer_only: true` (protocol: [Communication Protocols](communication_protocols.md)
   §4.1). Without a live owner the daemon answers with a correlated typed rejection
   (`error` frame, `code: no_active_turn`) instead of admitting the text as a new turn
   or queuing it, so a race between the CLI and the turn's completion can no longer
   create a turn. Clients that omit the flag — Sanad Client and the REPL `/steer` —
   keep the legacy behaviour exactly.
4. **Ownership pre-check (fast path only).** The command still reads the session
   projection first and refuses to dispatch when no run owns the session. That read is
   a fast path: it answers without a round trip and names the reason precisely, while
   `steer_only` remains the authoritative guard. It uses the durable execution snapshot
   (`running`/`resuming`), so a stale in-memory `in_flight` projection left behind by a
   stopped or blocked run is not read as an active turn (Task 134); a `stop_requested`
   snapshot, the durable `stopping` state (written before the run is cancelled), or an
   active `runtime_notice` whose status is not `resuming` are all reported as
   not steerable. A controlled-restart drain is **not** projected through the session
   query, so the daemon decides it and the CLI learns it from the rejection. A session
   id that does not exist is indistinguishable from an idle session in that projection
   and is reported the same way. A read that fails is its own condition
   (`session_state_unreadable`, exit `8`) because no steer was sent; a transport failure
   during that read stays exit `1`. The projection carries no in-memory stop flag: an
   in-flight stop is visible only as the durable `stopping` state (written before the run
   is cancelled) and, immediately after, as the daemon's own rejection.
5. **Acknowledgement mapping.** The acknowledgement is the daemon's own classification
   of the dispatched message id: `session.pending_steer_changed` or
   `session.message_classified` with `classification: steer` proves the pending steer was
   registered (a `pending_steer_changed` record counts only in state
   `pending`/`delivering`/`delivered` — a `cancelled` or `recovered` record never became
   a steer); `queue` means the gateway queued the text as a later turn instead;
   `think` means it was admitted as a new turn. A typed gateway `error` frame with a
   matching request id is reported with the gateway's own `error_code`.
6. **Gateway behaviour with no active turn.** The daemon's `SessionRunOrchestrator`
   steers only when a live owner exists (`canSteer`: not draining, `auto` delivery intent,
   an owned and not-stopping run, durable work `running`/`resuming`, and no recovery
   notice outside `resuming`). With `steer_only` the message is rejected with
   `no_active_turn` and nothing is created, queued, or applied. Without the flag it falls
   through to the ordinary admission path: an idle session starts a **new turn** from the
   steer text, and a busy session **queues** it. `sanad session steer` always sends the
   flag, so it can neither start nor queue a turn.
7. **Exit codes.** Every non-zero code carries a distinct JSON `error_code` in `--json`
   mode (`{"session_id":..., "request_id":..., "status":"error", "error_code":..., "error":..., "exit_code":...}`).

| Exit | `error_code` | Meaning |
|---|---|---|
| `0` | — | Acknowledged as a pending steer for the active turn (not applied yet). |
| `1` | transport code (`connection_failed`, `disposed`, `not_connected`, `disconnected`, `send_error`, `query_timeout`, `steer_failed`) | The steer could not be dispatched, or the session projection could not be read over a transport that failed. |
| `2` | `invalid_arguments` | Invalid invocation: missing session id, neither or both message sources, an empty message, an unusable `--timeout`, or a missing/directory/unreadable/empty message file. |
| `3` | `no_active_turn` | No run owns the session (idle, unknown, stopped, waiting, blocked, or draining). Reported either by the local pre-check or by the daemon's own `steer_only` rejection; nothing was started or queued. |
| `4` | `steer_not_applied`, or the gateway's own code | The gateway answered without registering the text as a steer (for example a cancelled pending-steer record), or rejected it with a typed error. |
| `5` | `steer_unacknowledged` | Dispatched, but no acknowledgement arrived within the bound; the steer may still be applied. Confirm with `sanad session show <id>`. The request id is printed so the caller can correlate a late acknowledgement. |
| `6` | `admitted_as_turn` | The daemon admitted the text as a **new turn** (`classification: think`) — an older daemon that does not honour `steer_only`. The message states that a turn is now running. |
| `7` | `queued_as_turn` | The daemon queued the text as a **later turn** (`classification: queue`) — an older daemon that does not honour `steer_only`. The message states that a turn is now queued. |
| `8` | `session_state_unreadable` | The session projection could not be read, so no steer was sent. Distinct from a steer rejection because nothing was dispatched. |

   **Why these codes differ from sibling commands.** Usage errors exit `2` rather than
   the `1` that `session answer|stop|permission` return, and transport failures exit `1`,
   so a caller can separate "you invoked this wrongly" from "the daemon is unreachable";
   `session steer`'s own failure taxonomy is the point of the command, and collapsing
   both into `1` would destroy it. `steer_unacknowledged` stays `5` rather than the `124`
   that `session compact` uses for an unconfirmed operation: `124` there means a
   still-running query the caller should poll, while `5` means the text was dispatched and
   its delivery classification never arrived — a different recovery action (`session show`
   to correlate the printed request id). Codes `6`/`7` exist so a caller can never read
   "a turn is now running/queued" as a successful steer.

8. **Known edge: a steer that outlives the turn.** A steer delivered at the last tool
   boundary of a turn, which the run never reaches an execution boundary to drain, is not
   applied. `sanad session steer` has already exited `0` at that point, because its claim
   is only that the text was acknowledged as a pending steer for the owning run — not that
   it was applied. At the next daemon restart that unresolved pending record becomes a
   durable **recovered draft** (never a new generation's steer), visible as recovered text
   in the session history. A caller that must know whether the text took effect reads the
   session history (`sanad session show <id>`, or the `session.pending_steer_changed`
   lifecycle record) instead of treating the exit code as application.

9. **Logging.** The steer body never enters stdout, stderr, or logs; failures report only
   identities, codes, and lifecycle metadata.

---

### 9.6. Runtime Recovery Retry (`sanad session retry`)

The daemon already owns recovery: a blocked session waits for the Sanad Client's Retry
action (`session.runtime_retry`) or for an automatic retry budget. A non-interactive
`sanad run` worker has no client attached, so nothing presses Retry, and the session stays
blocked until a person or supervisor intervenes. `sanad session retry` is the
non-interactive equivalent of that action.

1. **Argument contract.** `sanad session retry <session-id> [--provider <instance-id>]
   [--model <model-id>]`, plus the shared `--home`/`--gateway-url` pins every session
   subcommand honours. `--provider` is a provider **instance id** (the value
   `sanad providers` and `sanad models` report), not a template name; a blank value is
   treated as absent so an empty shell variable never becomes a provider id. `--model`
   is a model id for that provider. `--timeout` bounds the acknowledgement wait exactly
   like `session steer` (default: the client request timeout, 15 s; range `1..86400`).
2. **Retry, not "change provider".** The payload maps `--provider`/`--model` onto the
   retry command's own `provider_instance_id`/`model_id` fields and resumes the suspended
   request the session already owns with recovery reason `manual_retry`. The dedicated
   Change Provider action is a **different** command — `session.runtime_continue_with_provider`
   — which requires a provider instance id, resolves that provider's default model and
   refuses with `model_not_found` when it has none, rewrites the route with reason
   `provider_changed`, and broadcasts the canonical route confirmation. `session retry`
   changes the route only as an override of the same suspended request: it also rewrites
   every non-terminal queued work item's route, but it never confirms a route change as a
   configuration decision.
3. **Pre-check (nothing is sent when it cannot help).** The command reads the session
   projection first and refuses with `not_blocked` (exit `3`) unless the session is in a
   retryable recovery state: the daemon's `runtime_notice` status is `blocked` or
   `waiting`, or the durable execution snapshot state is `blocked`/`waiting` (restored
   blocked work can be projected before its notice is rehydrated). A `waiting` session is
   retryable because a manual retry shortens the remaining cooldown. Idle, queued,
   running, resuming, and stopping sessions are not retried, so the command never turns a
   healthy session into a second turn.
4. **What the acknowledgement proves.** Accepted means the daemon's recovery projection
   moved the session to `resuming` after the dispatch; it never proves the resumed provider
   request succeeded. The daemon resumes under the **turn's** request id, so a `resuming`
   notice for the session is accepted without strict correlation while typed rejections
   require it: a correlated `error` frame, or a correlated `runtime_notice` whose status is
   `blocked`/`fatal` (for example an unsafe checkpoint or a provider with no default
   model), is reported as a rejection with the gateway's own code. A scattered rejection
   the daemon cannot answer — a retry that arrives while the session is busy with another
   resume — produces no event at all, which is reported as unacknowledged with the request
   id rather than as accepted.
5. **Output.** Plain success is `Retry accepted for session <id> (request <reqId>): the
   daemon is resuming the last request.`; `--json` emits
   `{"session_id":..., "request_id":..., "status":"retrying", "notice_request_id":...}`.
   The request id is allocated before the dispatch and printed in every outcome, including
   a timeout, so a late acknowledgement can always be correlated.
6. **Exit codes.** Every non-zero code carries a distinct JSON `error_code` in `--json`
   mode (`{"session_id":..., "request_id":..., "status":"error", "error_code":..., "error":..., "exit_code":...}`).

| Exit | `error_code` | Meaning |
|---|---|---|
| `0` | — | Accepted: the daemon is resuming the suspended request. |
| `1` | transport code (`connection_failed`, `disposed`, `not_connected`, `disconnected`, `send_error`, `query_timeout`, `retry_failed`) | The retry could not be dispatched, or the projection could not be read over a transport that failed. |
| `2` | `invalid_arguments` | Invalid invocation: missing session id, or an unusable `--timeout`. |
| `3` | `not_blocked` | The session is not blocked or waiting, so nothing was sent. |
| `4` | `retry_rejected`, or the gateway's own code | A correlated typed rejection from the daemon. |
| `5` | `retry_unacknowledged` | Dispatched, but not acknowledged within the bound; it may still resume. Confirm with `sanad session show <id>`. |
| `8` | `session_state_unreadable` | The projection could not be read, so nothing was sent — distinct from a rejection because no retry was dispatched. |

7. **Automatic retry rule (why a blocked worker can wait forever).** Before any manual
   intervention the runner already retries some provider failures on its own
   (`RunnerRecoveryCoordinator.automaticRetryBudget`): `timeout` and the local tool/runtime
   errors get **one** automatic attempt, `networkError` two, and
   `rateLimit`/`upstreamRateLimit`/`overloaded` three, with a `2 s` base delay
   (`fallbackRetryDelay`) doubled per attempt and clamped to `60 s` — and only when no
   output has started streaming. A `timeout` after the first automatic attempt therefore
   becomes a `blocked` notice with Retry/Change Provider actions and **no** further timer:
   a headless worker stays blocked indefinitely. The blocked notice states what the
   automatic retry already did ("gave up after N attempts", or that streaming output
   prevented one), so the state is never mistaken for a first failure that is still
   retrying. `sanad session retry` is the missing manual step.
8. **Logging.** The command reports identities, codes, and lifecycle metadata only; it
   never prints provider bodies or session content.

### 9.7. Session Projection as a Following Channel (B16)

The bounded projection is also the contract a supervisor uses to observe a delegated turn whose `sanad run` worker has exited. The delegate supervisor keeps such a task non-terminal (`following`) and polls `sanad session show <session-id> --json`, so these fields are a machine contract, not decoration:

- `status` (`needs_input`, `needs_permission`, `running`, `idle`) decides whether a request awaits a human. The pending payload supplies `request_id`, `tool_name`, and `questions` for `needs_input`; answers are never read back.
- `execution_snapshot.state` (`running`, `queued`, `waiting`, `blocked`, `resuming`, `stopping`, `idle`) decides whether the turn is still owned by the daemon, is blocked, is resuming, is stopping, or has ended. A published block outranks the top-level `status`, because `status` reports `idle` once nothing is publishing.
- `updated_at` and the snapshot's `updated_at` date the observation; `identities.pending_request_id` and `identities.request_id` correlate it.

When a build also projects the durable cause (a `runtime_notice.cause` or a snapshot-level `cause`), the supervisor forwards it with a `blocked` transition and can auto-retry a transient cause. Without one it records the block with an unknown cause and never invents a recovery decision. Answers and permissions continue to travel through §9.2, so the projection stays read-only.

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

- Read and control commands (`devices`, `ws list`, `session show|steer|retry|answer|stop`,
  `run`) execute through the remote runner and return ordered output plus one
  terminal result. The relay forwards the argument vector to the target Agent's own
  `SanadCommandRunner`, so a new session subcommand is relayable without a separate
  allow-list entry; `sanad-client -d <device-id> session steer ...` and
  `sanad-client -d <device-id> session retry ...` therefore work as soon as the Agent
  exposes them. Default-mode approval is keyed on the session the forwarded argv will act
  on, resolved with the Agent's own `args` grammar (attached short values, `--name=value`,
  the `--` terminator, and every value option consuming its value). An argv that names two
  different sessions — a positional id plus a disagreeing `--session`, a repeated
  `--session`, or `-s<id>` beside a different positional — is refused before approval with
  `ambiguous_session_target` and is never relayed.
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
  Models:` header. Under each model row the block adds one `thinking:` segment describing the
  levels that exact route resolved (see below); when the cached entry carries no descriptor the
  segment is absent and the row is byte-identical to the pre-Task-137 output.
- **Thinking levels (Task 137):** the cached row already stores the capability the daemon
  resolved for that exact route through the five-layer authority
  ([provider_protocol.md](provider_protocol.md) §2.3). The command reports that stored record and
  never re-derives it, refreshes it, or re-orders a layer. A `supported` route prints
  `thinking: supported (<kind>) — <id> [off, default], …`, marking the genuine Off option and the
  known native default. An `unsupported` route prints `thinking: unsupported`, and an `unknown`
  route prints `thinking: unknown — no declared levels for this route`; neither invents a level.
  A single-model inspection (`--model <id>`) additionally prints the authority provenance —
  `thinking source:`, `thinking default: <id> (from <source>)`, and `capability revision:` — while
  a full listing omits it to stay readable.
- **JSON output (`--json`), stable shape:** one object
  `{"schema": "sanad.models.v1", "providers": [...]}` where each provider carries `id`,
  `template_id`, `display_name`, `default_model`, `is_default`, `status`, `catalog_source`,
  `catalog_fetched_at`, and `models` (each with `value`, `label`, `supports_reasoning`,
  `is_default`, plus an optional `thinking_control` described next). The cached catalog is
  reported as stored; this command never refreshes it, so a provider that advertises a model it
  later rejects still appears here until the cache is refetched.
- **`thinking_control` (additive, Task 137):** present only when the cached entry carries a
  descriptor, and otherwise omitted so the documented four-key model entry is unchanged. Its shape
  is exactly `ThinkingControlDescriptor.toMap()` — the same record the Client snapshot consumes:
  `status` (`supported`/`unsupported`/`unknown`), optional `kind`, `options[]` (each `id`, `label`,
  `is_off`, `is_provider_default`, and `budget_tokens` only for a genuine positive budget),
  optional `default_option_id` and `default_source`, `capability_revision`, `source`, and
  `observed_at`. Because it is the stored record, its `source` names the authority layer that
  actually won for that route (`config_override`, `endpoint_declared`, `provider_reported`,
  `shipped_default`, `models_dev`, `models_dev_canonical`), which is the one fact the CLI could not
  report before this task.
- **Why filtering is mandatory:** model ids are advertised per provider and overlap in name shape
  (for example several providers ship `glm-*`). Reporting the whole catalog for a filtered request
  made a single provider's catalog indistinguishable from another provider's, which is how a
  `tail`n unfiltered report was mistaken for an OpenCode Go inventory.
- Coverage: `agent/test/cli/models_command_test.dart`.
- **Reading a route's thinking levels without the database (Task 137):** before this change the
  resolved capability was observable only through the Client snapshot or by reading
  `provider_model_cache.models_json` in `state.db` by hand. `sanad models --provider <id> --model
  <id>` now answers the same question from the CLI, including which authority layer won.

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
- **Endpoint failures fall back to standalone, deliberately.** `StandaloneFallbackStrategy.resolveMode`
  catches every discovery failure, so the `home_runtime_*` codes (`home_runtime_missing`,
  `home_runtime_foreign`, `home_runtime_stale`, `home_runtime_unhealthy`, `home_identity_mismatch`)
  resolve to `CliRuntimeMode.standalone` for `sanad run` instead of exiting `78`. That is correct
  for a one-shot command: no daemon proves it owns the Home, so the command runs in-process rather
  than attaching to a runtime that may belong to another Home. The state-root ownership lease is the
  backstop — if a runtime really does own that Home, the standalone start fails closed with exit `78`
  and an explicit message instead of competing for SQLite. `session …` commands have no standalone
  path, so they surface the same discovery failures directly with exit `78` (see §3).
- Coverage: `agent/test/cli/run_command_test.dart`.
