---
title: "Execution Trust and Permission Authority"
description: "Transport-derived command authority, daemon-private workspace policy, child-process environment policy, Direct/Protected backends, host discovery, project .env redaction, the Agent secret vault, and user secrets."
---

# Execution Trust and Permission Authority

Owner: Plan 83 (§10: Plan 84). This page describes who may decide workspace security policy, where that policy is stored, what a model-requested child process inherits, where commands run, and which values never reach a model-visible result.

## 1. Authority comes from the transport

Every command and turn carries a daemon-derived `CommandAuthority`. User decision (2026-10-21): the authenticated cloud client is as trusted as the local client.

| Transport | Authority |
|---|---|
| Authenticated loopback Local Gateway (owner-only token in Sanad Home) | `owner` |
| Authenticated Cloud Gateway relay (socket registered with the key-bound Device Credential) | `owner` |
| In-process CLI (standalone runtime, terminal `CliPlatform`) | `owner` |
| Remote CLI relay (`device.cli.execute`) | the relay command's own authority |
| Any other or unauthenticated transport (mixin default) | `unverified` |

- Ingress (`SanadGatewayBehavior.handleIncomingCommand` and `handleIncomingProtocolEvent`) overwrites the reserved `command_authority` payload field. An owner transport honours a sender's request for `unverified`; no sender can raise it. Any other spelling reads as `unverified`.
- Turn translation applies the same stamp to turn metadata and removes `allow_all_tools` and `permission_mode` from non-owner turns. The orchestrator records each turn's own authority so a merged session can never carry an older stamp.
- Repository content is never authority, whichever client is connected.

## 2. Policy is daemon-private

`workspace_security_policies` in the Agent state database is the only source of workspace security policy. `WorkspaceSecurityPolicyRepository` owns it; `WorkspacePolicyStore` is the facade.

| Column | Meaning |
|---|---|
| `workspace_id` | Registered workspace UUID, or `exec_root:<validated root>` for an isolated execution root |
| `canonical_path` | Root the row was recorded for |
| `permission_mode` | `default` or `full_access` |
| `execution_mode` | `direct` or `protected` |
| `host_discovery_policy` | `owner_only` or `disabled` |
| `permissions_json` | Durable workspace-scope allow/deny decisions |
| `revision` | Monotonic compare-and-swap revision, `0` means no stored row |

- Removing a workspace deletes its policy row (modes and grants) in the same transaction as the workspace record; re-adding the folder registers a new id and starts from clean defaults. Registration never reuses a removed id. `exec_root:` rows belong to their root and are kept.
- Policy stays with the workspace id across relocation, so restrictions are never silently reset; `canonical_path` is refreshed on the next write. Revisions stay monotonic.
- The governing policy is derived only from the validated tool root (`execution_root` when set, else the registered workspace path), never from workspace display metadata. The innermost registered workspace containing the root owns writes (durable grants), else the root's `exec_root:` key. Every containing registered workspace, plus the root's own `exec_root:` row when one exists, combines most restrictively: Full Access only when all grant it, Protected or disabled discovery when any requires it, denies from all scopes, allows only from the owning scope. Records of the same folder under different stored spellings (the daemon can register a session's raw path again at start-up) count as one scope: they share grants, the owning key is the lowest id, and only records with a stored policy combine, so an automatically created duplicate cannot cancel the owner's choice.
- Clean defaults: `default` permission, `direct` execution, `owner_only` discovery, no grants.
- Unknown stored values resolve to the restrictive posture (`protected`, `disabled`, `default`); a corrupt grant list grants nothing.
- `<workspace>/.sanad/settings.json` is never read, seeded from, or written as policy. Legacy permission fields there are ignored and left untouched. There is no permission migration.
- The table is additive. An older Agent on the same Sanad Home ignores it; no column is renamed or dropped.

### Mutation rules

- `workspace.set_permission_mode` is the only mutation command. It accepts any of `permission_mode`, `execution_mode`, `host_discovery_policy` and an optional `expected_revision`.
- Widening any axis (`default -> full_access`, `protected -> direct`, `disabled -> owner_only`) requires `owner`, which every authenticated client transport has, local or cloud. Narrowing is always accepted.
- Unknown values, a malformed revision, or an empty mutation fail with `invalid_request` and write nothing.
- Typed error codes: `invalid_request`, `permission_denied`, `stale_revision` (with `current_revision`), `workspace_not_found`, `workspace_unavailable`, `policy_update_failed`. Error messages never echo exception text.
- A successful change broadcasts `workspace.policy_changed` with the policy projection; responses to the caller also include `workspaceId` and `canWiden`. The projection includes the durable command allow and deny lists (for example `shell_execute::<command>`). With every authenticated client trusted as the owner this is accepted: the lists reach only the owner's Sanad clients and never contain secret values.
- `PermissionManager` writes a workspace-scope approval only after the winning decision. When the workspace is not registered, the decision falls back to session scope.

### Approval bypass

- Workspace `full_access` skips prompts; explicit workspace `deny` entries still win.
- Turn-level `allow_all_tools` is honoured only on an `owner` turn. Only the CLI sends it (`sanad run --yes`, locally or through the remote CLI relay); no Sanad Client, local or cloud, has an `allow_all_tools` control. Session metadata `permission_mode` never grants anything.

## 3. Child-process environment

`ProcessEnvironmentPolicy` is the single owner of the environment handed to model-requested commands.

- Direct Developer starts from the inherited operator environment so `PATH`, SDK roots, caches, SSH agent, Docker and cloud selectors, proxies and CA roots keep working.
- It removes credentials Sanad reads for itself: every provider registry `envApiKeyName` plus `LLM_API_KEY` and `SERPER_API_KEY`. Matching is case-insensitive.
- Everything else in the operator environment is inherited unchanged, including credentials the operator holds for other tools (for example another agent's token): only names Sanad itself reads are removed. A Direct shell therefore sees the same environment as the operator's terminal minus Sanad's own credentials.
- It keeps `SANAD_HOME` and the `SANAD_DEV_*` runtime markers: they are routing identity, not credentials, and `sanad-dev restart agent` from a shell needs them.
- Request overrides can never set `PATH`, `PATHEXT`, `COMSPEC`, identity and temp variables, interpreter start-up hooks, Git transport hooks, trust roots, proxies, or anything prefixed `LD_`, `DYLD_` or `SANAD_`, and can never reintroduce a Sanad credential. A rejection is logged by key and reason only.
- User secrets (§10) are added only when the call names them in `secrets`; the default is none. They follow the same protected-key rule as request overrides.
- Children are spawned with `includeParentEnvironment: false`; the policy-built map is the whole environment. Without it Dart merges the daemon environment, and every credential, back in.
- Backend-generated values (`GIT_TERMINAL_PROMPT`, `GCM_INTERACTIVE`, `SSH_ASKPASS_REQUIRE`, `SANAD_REQUESTER_SESSION_ID`, `SANAD_REQUESTER_TOOL_CALL_ID`) are added after the policy.
- Other spawns keep their own owners: MCP stdio starts through `StrictStdioClientTransport` with exactly its allowlist (`PATH`, `HOME`, user, locale, `TMPDIR`, proxies, CA roots, and the Windows system variables) plus server-owned values; supervisor restart and update installers relaunch Sanad itself; automation helpers run fixed system binaries without model input.

## 4. Where commands run

`ShellExecuteTool` owns the schema, the workspace boundary and the permission check, then hands a `ShellCommandRequest` to the backend that `ExecutionBackendResolver` selects from the policy at that execution.

- `DirectExecutionBackend` keeps the host-native command semantics, process-group ownership, bounded output, timeout and cancellation behaviour. On Windows, it generates a pure-ASCII start-gate wrapper (`command.cmd`) that switches the console code page to 65001 (`%SystemRoot%\System32\chcp.com 65001>nul 2>&1`) and calls the command from a separate UTF-8 payload file (`payload.cmd`), ensuring non-ASCII (e.g. Arabic) arguments reach child processes without code-page corruption. The wrapper invokes its helpers (`chcp.com`, `ping.exe`) by absolute path from `%SystemRoot%\System32\` so it does not depend on the child `PATH`, and resets `%errorlevel%` to 0 via `(call )` immediately before calling the payload so wrapper operations never leak into the reported command exit status. On natural process exit, the result payload additively exposes the numeric `exit_code` alongside `duration_ms` and `output`.
- The backend is resolved before approval. A backend that will not run the command (`runsCommands: false`) answers without a permission prompt and without recording a durable grant.
- An unreadable policy yields a typed `policy_unavailable` refusal (`executionFailed`); it never falls back to Direct and never echoes the error.
- `ProtectedExecutionBackend` always fails closed in this release (user decision 2026-10-21: accepted until a real isolated backend exists): no isolated backend ships, the command is not run, and the host is never used as a fallback. The result is typed `permissionDenied` with `terminal_reason: protected_backend_unavailable`.
- A policy change applies to the next command of the same session. A command already running keeps its backend. Nothing is replayed.
- The working directory must be the canonical root or inside it; a sibling root that merely shares a name prefix is rejected.

## 5. Host capability discovery

`host_capability_discovery` reports whether named executables exist on the inherited `PATH`. It never runs a binary, never starts a shell, never lists directories, and never returns `PATH` or any other environment value. Names must be bare (`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`); Windows lookups follow `PATHEXT`.

The catalog adds it only when all hold:

1. the turn has a workspace policy scope;
2. the turn carries stamped `owner` authority;
3. policy is `owner_only`;
4. no tool in the turn already reaches the host `PATH` (a Direct shell does).

So it normally appears only in a Protected owner session. There is no prompt text or stub about it, and Full Access does not override `disabled`.

## 6. Project `.env` files

`file_read` and `search_grep` redact values of project environment files (`.env`, `.envrc`, `.env.*`, `*.env`) while keeping names, comments and line structure. Only exact template names (`.env.example`, `.env.sample`, `.env.template`, `.env.dist`, `.env.defaults`) stay readable; `.env.example.local` and similar hold real values. A quoted value spanning lines is redacted on every line, including PEM and base64 lines; other shell lines in `.envrc` are redacted whole. `search_grep` matches against the redacted text, so it cannot confirm a secret value exists. Processes started in the workspace still open the file directly.

## 7. Client

- Full Access shows `FullAccessConfirmationDialog` once on `default -> full_access`; turning it off never prompts and no banner persists. All copy is localized (en, ar).
- The conversation Full Access toggle sends `workspace.set_permission_mode` through `WorkspaceSecurityClient` (`DeviceCommandClient`, explicit device) with the policy revision last read or broadcast; a rejection keeps the Agent's state and shows its reason.
- Every stored policy change, including a recorded workspace grant, is announced once by `WorkspacePolicyStore` through `WorkspacePolicyAnnouncer` (`workspace.policy_changed` with the new revision), so clients never keep a stale revision. If a toggle still hits `stale_revision`, the client re-reads the policy and retries once; a remaining failure shows a localized message. Device command rejections log their typed code, never content.
- Every authenticated client (local or cloud) receives `canWiden: true`, so owner-only widening is available everywhere.
- Workspace Settings > Overview shows `WorkspaceSecurityCard` through `WorkspaceSecurityClient` (`DeviceCommandClient`, explicit device). It sends only the changed axis with the revision on screen, disables choices the Agent reports it would reject (`canWiden: false`), and reloads Agent truth after any rejection.
- A call that never ran shows in the timeline as "Not run" (localized) with the muted block icon, never as "Ran": a user or policy denial of any tool (the Agent raises `ToolPermissionDeniedException`, recorded with the typed `permission_denied` code, which the live `tool_result` and the `get_session_history` `tool_result` row both carry as `errorCode`; the durable resume path records it too), and a shell call refused before running (`protected_backend_unavailable`, `policy_unavailable`).
- The Client never stores policy as authority.

## 8. Known limits

- Direct Developer shares the operating-system account. A shell command can still read files that account can read, including project `.env` files; Full Access copy states this. Shell output is not redacted.
- Protected execution has no backend yet, so selecting it disables shell commands for that workspace.
- `file_edit` on a `.env` file can still act as a value oracle.
- An older Agent on the same Sanad Home ignores the policy table and still honours a repository's `.sanad/settings.json` `full_access`, and after the vault migration it no longer finds provider or MCP secrets.
- A remote-chosen `execution_root` such as `$HOME` or `~/.sanad` is a valid tool root. In Full Access it gives approval-free file access there, which is accepted (user decision 2026-10-21: roots are not restricted in Full Access). Follow-up proposal, no code: outside Full Access, require approval for a root that is not inside a registered workspace.
- The vault cache sees another process's write within the daemon's two-second generation poll. A CLI that switches Home after start-up without reopening the vault uses the legacy file store for that Home.
- Client secure credential storage (Task 83d) is not implemented.

## 9. Agent secret vault

Provider credentials and MCP secrets live in `AgentSecretStore` (macOS Keychain, Windows DPAPI, Linux Secret Service, or the Linux headless owner-only fallback, which is not encryption), owned by `SecretVaults`.

- Namespaces: `providers:<instance id>` (JSON `SecretRecord`), `mcp:<mcp-secret:// reference>` and `custom:<NAME>` (user secrets, Plan 84, see §10), each with a `<prefix>index` list. `AgentSecretNamespaces` also reserves `agent:auth:`. `custom:` has no legacy file and is never migrated from one.
- Reads come from a cache loaded when the vault opens. Writes are verified by read-back, then committed to the index under a cross-process file lock, and a generation marker in Sanad Home tells other processes to reload (the daemon polls it every two seconds).
- The daemon opens the vault at start-up, and the CLI opens it only for a command that can read or write a secret (`SanadCommandRunner.requiresSecretVault`, per subcommand), always for the selected Home: the CLI entry applies `--home` before it opens the vault (Task 126), so a command aimed at another Home never migrates the default Home. A gateway command such as `session list` never opens it, because opening reads the owner indexes and the OS may answer with an interactive authorization dialog instead of data (see [Sanad CLI Architecture](sanad_cli_architecture.md) §3.1). A process that skips the vault can never write a provider secret: the plaintext `SecureFileSecretStore` refuses mutations with `plaintext_fallback_blocked`. Opening migrates `provider_secrets.json` and `mcp_secrets.json`: entries not yet in the vault are written and verified, the index is committed, and only then is the file deleted. A failed migration keeps the file and its values readable (writes still go to the vault) and retries on the next open. A value already in the vault always wins over a legacy value.
- macOS ACL authorization is a code-identity check on the calling binary, not on the interpreter: items created by one Agent build (or by the FVM `dartvm` a source checkout ran) demand an interactive dialog from a different build. Who may start that dialog is decided once per process by `SecretVaultPolicy` from explicit evidence: the daemon (every entry point) and an interactive CLI keep it, while `--json`/`--quiet`, `--child-process`, a non-terminal stdin or stdout, or a spawner declaration forbid it. Only a process that forbids interaction attaches an `LAContext` with `interactionNotAllowed` (through `kSecUseAuthenticationContext`, the supported replacement for the deprecated `kSecUseAuthenticationUI`) and switches the legacy file keychain off; `errSecInteractionNotAllowed`, `errSecInteractionRequired`, `errSecAuthFailed`, and `errSecUserCanceled` then close the vault with distinct reason codes (`interaction_forbidden`/`interaction_required`, `authorization_denied`, `authorization_canceled`) instead of blocking the process. The interactive path prints one `Waiting for macOS Keychain approval for …` line before its first read and never prints a value.
- A closed vault is reported, never buried: `sanad doctor` prints the reason code and the recovery steps, the daemon logs an actionable warning naming what is unreadable, and the local gateway `/health` payload carries `secret_vault: available|unavailable` with `secret_vault_reason`. All of it is non-secret, and no path deletes a secret because the vault was closed.

- User decision 2026-10-21: deleting the legacy files is approved; downgrade compatibility is not required. An older Agent on the same Home loses those secrets.
- Test isolation: under the Dart test runner the vault refuses to open without explicit state isolation or for the real default Home, and the test runner and `SANAD_E2E_TEST_MODE=true` processes use the owner-only file store instead of the OS credential vault. E2E mode selects that store only for temporary roots: it refuses the real default Home and a state root that is not separate from the identity Home.
- An unavailable vault keeps legacy values readable and rejects writes with `AgentSecretStoreUnavailable`; it never writes plaintext.
- Vault lifecycle events (migration counts, a failed verification, an unavailable vault) are appended to the owner-only `secret_vault_events.jsonl` in Sanad Home, because the CLI has no agent log and the vault may open before a process logs. The daemon opens the vault after logging starts and replays and clears the file, so every migration that deletes files reaches the agent log. Events carry namespaces and counts only.

## 10. User secrets (Plan 84)

User secrets are credentials the user enters for the Agent to use in commands (for example a database password). They live only in the vault's `custom:` namespace, owned by `UserSecretVault`, keyed by their environment variable name.

### Names

A name matches `^[A-Za-z_][A-Za-z0-9_]{0,63}$` and must not be a protected operator variable or a Sanad credential (`ChildProcessSecurityContract.isDangerousRequestOverride`), so `PATH`, `LD_*`, `SANAD_*` or `OPENAI_API_KEY` can never be stored or injected.

### Injection into a command

- `shell_execute` accepts an optional `secrets` list of at most 16 names. Exactly those names are injected into that one child process. A call without `secrets` gets no user secret: there is no default, wildcard, workspace-wide or session-wide injection.
- Injection requires a turn with stamped `owner` authority; otherwise the call is refused as `permission_denied` (`terminal_reason: secret_authority_required`) and the command does not run.
- An unknown name fails as `not_found` (`terminal_reason: secret_not_found`) before approval, and the command does not run. A malformed or reserved name is invalid input.
- The approval key of a call with secrets is `shell_execute::<command>::secrets=<sorted names>`, so a grant for a command without secrets never covers the same command with secrets, and the permission prompt shows the names (never values).
- Every output the Direct backend reports (progress checkpoints, final, partial, timeout and error output) has each injected value replaced by `[REDACTED:<NAME>]` before it becomes a tool result, history row, request dump or client timeline entry. Only verbatim echoes are caught.

### Acquisition

- `system_request_secret` takes a `reason` (at most 500 characters) and 1 to 10 `fields` (`name`, `label`, optional `description`, `masked` default true, `required` default true). Names are validated as above and must be unique. It is offered, and runs, only on an `owner` turn, and fails without prompting when the vault is unavailable.
- The call suspends like `system_ask_user`: a durable checkpoint (tool name, fields, reason, and `replaces` for names already stored, never values) is written first, then `tool.permission_request` reaches the Client.
- The Client answers with `tool_permission_response` carrying `secret_values` (`{NAME: value}`) to save, or `allowed: false` to skip. `PlatformRuntimeBridge` accepts it only when the ingress stamped `owner` authority (`PERMISSION_DENIED` otherwise), refuses `answer`, unrequested names, non-text or oversized values and missing required values (`INVALID_SECRET_VALUES`), and in every refusal keeps the request pending and logs the code only.
- `SecretAcquisition` writes accepted values to the vault and replaces the decision with `{allowed, secret_outcome: stored|skipped|failed, secret_names}`. Only that value-free decision is retained in memory, handed to the waiting tool, claimed into `suspended_checkpoints.resolved_decision`, or resumed after a restart, where `SuspendedResumeService` returns the same result instead of re-running the tool.
- The tool result is `{"status":"stored","secrets":[names]}`, `{"status":"skipped"}` or `{"status":"failed"}` (vault refused the write). It never contains a value. Re-entering a stored name replaces its value.
- Terminal clients do not collect secrets: `sanad run` never auto-approves a secret request and records `needs_input`, the REPL leaves it pending for the Sanad Client, and the in-process terminal platform skips it.

### Client

- `SecretRequestCard` (composer, en/ar) shows the model's reason, one input per field (masked fields hide the value, disable suggestions and autocorrect, and offer a show/hide toggle), a "Replaces the saved value" note for names in `replaces`, and Save to vault / Skip.
- Save requires every required field and sends `secret_values` exactly as typed through `ConversationInputCubit.submitSecretRequest`; Skip sends a plain denial. The controllers are cleared immediately and the values never enter Client state, caches, the timeline, or logs. Driver keys are listed in [Flutter VM Driver CLI QA](../qa_maintenance/flutter_vm_driver_cli_qa.md).
- The timeline shows the tool call (reason, field names and labels) and the value-free result.

### Listing, deletion and revocation

- `system_list_secrets` returns the sorted names in `custom:` only; it never lists `providers:` or `mcp:` entries.
- `system_delete_secret` takes 1 to 16 names. It is sensitive (`permission_class: secret_management`) and asks the user every time, then reports `deleted` and `not_found`. Deletion removes the vault entry and its index id, so later calls naming it fail as `secret_not_found`. A command already running keeps the environment it started with.
- Task 140 adds a **device-owner** list, add/replace, and delete authority beside the model's tools. Both surfaces act on the same `custom:` namespace; the model's tools are unchanged by it.

### Device-owner listing and rotation (Task 140)

- The owner lists stored secrets with non-secret metadata: name, a user-authored description (at most 256 characters), the arrival source (`agent_request` through an acquisition card, `user` through this path), and the created/updated instants. The metadata lives in `user_secret_metadata`, never in the vault; see [the agent database schema](agent_database_schema.md) §3.6.
- Add and replace are one command. Replacing never shows the old value: the form starts empty and the write is a single verified vault write. There is **no reveal**, for the user, the model, or support.
- A submitted value that is empty, longer than `UserSecretVault.maxValueLength`, or a redaction sentinel (`[REDACTED:<NAME>]`) is refused as `invalid_secret_value`, on both the Client and the Agent. The sentinel rule exists because a mask shown in a log, a tool result, or the timeline must never be written back as the secret itself.
- Deletion requires an explicit confirmation and removes the vault entry and its metadata row together. A later command naming the deleted secret fails as `secret_not_found`.
- A verified vault write is never reported as a failure because metadata could not be recorded; the metadata row is repaired by the next list read, with `source = agent_request`, so a repair never claims the owner typed a value in.
- The list projection is structurally value-free: it has no value field, add and replace return metadata, delete returns an outcome, and no command, response, event, or error carries a stored value in either direction. The handler and the catalog log the name and the outcome only.
- The protocol commands (`secrets.list`, `secret.set`, `secret.delete`) require stamped `owner` authority (`command_authority: owner`); any unverified or model caller is refused as `permission_denied` and mutates nothing. Successful mutations broadcast `secrets.changed` (`{name, change: 'set'|'deleted'}`) to every connected client on every platform. See [User Secret Management Protocol](secret_management_protocol.md).

### Limits

- Redaction catches verbatim echoes only. A command that encodes, splits or transforms a value, or a value cut at an output truncation boundary, is not detected. Injection therefore stays behind the shell approval (or Full Access) and the owner check.
- In Full Access, a command naming secrets runs without a prompt, as any other command does.
- Secret values travel from the Client to the Agent inside `tool_permission_response`; for a cloud client that path is the TLS Cloud Gateway relay. Neither side logs payloads.
- If the daemon stops after a decision is claimed and before the vault write completes, the recovered decision still reports `stored`; the next use then fails as `secret_not_found` and the user can enter it again.

