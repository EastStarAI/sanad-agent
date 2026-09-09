---
title: "Remote Device Control QA"
description: "Gate-linked pass/fail coverage for remote Agent update, restart, managed workspaces, and redacted MCP management."
---

# Remote Device Control QA

Owning task: `docs/plans/tasks/82-secure-remote-device-control-workspaces-and-mcp.md`.
Threat model: `docs/technical/remote_device_control_threat_model.md`.

Until G4, the cloud adapter still rejected remote MCP management. G4 admits
cloud MCP commands except `replace_mcp_config`. Workspace commands are admitted
as managed-remote. Update and restart use the shared admission owner and
execute on every Online device.

## G0 — hosted freeze record

| Area | Pass | Fail |
|---|---|---|
| Cloud workspace admission | Nine workspace commands dispatch as `managed_remote` without session registration; wrong-device still fails closed | A cloud create uses a client absolute path as the workspace root; empty browse lists `/` or Home |
| Cloud MCP admission | List/inspect/import/export/OAuth dispatch without session; save/delete require confirmation; `replace_mcp_config` stays `remote_mcp_management_disabled` | A cloud replace mutates configuration; a save runs without a ticket; secrets appear in preview/logs |
| Allowed query | `list_workspaces` still succeeds on cloud | Listing existing workspaces is blocked |
| Local continuity | Existing local workspace and MCP handler tests still pass | Local picker or local MCP management regresses |

Automated owner:
`agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`.

## G1 — contracts and admission

| Area | Pass | Fail |
|---|---|---|
| Typed models | Commands/errors use canonical names; apply rejects client URL/checksum | UI-label parsing or client artifact authority |
| No capability keys | Agent capabilities omit `supports_remote_*`; Client does not parse them | New remote-control flags in the capabilities envelope |
| Wrong device | Cloud `device_id` ≠ registered id returns `wrong_device` with no session/runtime mutation | Command executes on the registered device |
| Duplicate / stale | Admission rejects duplicate `request_id` and consumed/expired confirmation tickets | Second request mutates |
| Offline | Client `DeviceCommandClient` fails without emitting a command | Command sent to a disconnected socket |

Automated owners:

- `agent/test/interfaces/runtime/device_command_admission_test.dart`
- `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`
- `client/test/unit/services/device_command_client_test.dart`

## G2 — update and restart

| Area | Pass | Fail |
|---|---|---|
| Check | Read-only; returns current/latest and `source_managed` without download | Check mutates files or follows a client URL |
| Apply | User confirmation ticket + exact target through `AgentUpdateService`; rollback statuses typed | Downgrade, candidate URL, or unattended apply |
| Restart | `accepted` before drain via `DaemonRestartCoordinator`; safe is default; explicit confirmed force remains supervised; invalid force/unbounded timeout is rejected | Disconnect treated as success; implicit fallback to force; parallel kill/start path |
| Client | Check/Update/Restart on every Online device through `DeviceCommandClient` | `LocalDaemonController` used for a cloud or Overview restart |

Automated owners:

- `agent/test/interfaces/platforms/sanad_gateway/handlers/device_control_command_handler_test.dart`
- `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`
- `client/test/unit/services/device_control_client_test.dart`

## G3 — managed workspaces

| Area | Pass | Fail |
|---|---|---|
| Managed root | Identity prepare creates `SANAD_HOME/workspaces` and rejects a symlink | Managed root is a link or missing |
| Name-based create | Remote create uses name/description only under the managed root | Client absolute path becomes the cloud workspace root |
| Browse | Empty managed browse lists allowed roots only; internals and `/` are hidden | Empty browse lists `/` or Home |
| Folder ops | create/rename/delete stay inside allowed roots after canonical checks | Traversal, symlink, or root deletion mutates |
| Confirmation | Delete/relocate require a one-time preview token; stale tokens fail closed | Consumed token deletes again |
| Record removal | Remove deletes only the workspace row and preserves the directory, files, sessions, and messages | Removal reaches filesystem deletion or cascades conversation data |
| Client | Remote create is a name dialog; Workspace Overview hides Browse folders and confirms record-only removal | Remote create opens an OS picker or removal has ambiguous destructive copy |

Automated owners:

- `agent/test/interfaces/local_workspace_runtime_service_test.dart`
- `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart`
- `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`
- `client/test/unit/services/device_conversation_commands_test.dart`
- `client/test/widget/conversation_input_panel_rebuild_test.dart`

## G4 — remote MCP management

| Area | Pass | Fail |
|---|---|---|
| Read vs mutate | List/inspect/import/export/OAuth status dispatch without session; save/delete/Advanced save/STDIO inspect/OAuth complete require confirmation | A cloud save mutates on the first request; inspect of a STDIO draft starts a process without a ticket |
| Replace freeze | Cloud `replace_mcp_config` still returns `remote_mcp_management_disabled` | Root-document replacement succeeds on cloud |
| Redaction | Nested `secrets` are redacted in daemon logs and Client diagnostics; snapshots use configured markers | A secret value appears in preview, event, log, or export |
| Stale ticket | Intervening mutation invalidates the confirmation fingerprint | Confirm applies after another save |
| Catalog | Effective MCP specs refresh from the new fingerprint without restart | Tools stay stale until daemon restart; permissions are bypassed |
| `/api/mcp` | Client still has no hosted MCP REST caller | A new `/api/mcp` Client path is added |

Automated owners:

- `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`
- `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart`
- `agent/test/core/secrets_redactor_test.dart`
- `agent/test/capabilities/mcp_configuration_test.dart`
- `agent/test/capabilities/mcp_runtime_manager_test.dart`
- `client/test/unit/services/mcp_runtime_client_test.dart`
- `client/test/unit/services/sanad_socket_service_test.dart`

## G5 — Client UX

| Area | Pass | Fail |
|---|---|---|
| Selected device | Overview Check/Update/Restart use `DeviceControlClient` for the inspected device | Settings call `LocalDaemonController` or the local daemon for a cloud device |
| Remote workspace | Name-based create and constrained browse; Change Path stays local-only | Remote create sends a host path; browse lists `/` or Home |
| MCP settings | Offline devices show a reconnect message and disable Add/Test/Edit/Remove; delete reloads snapshot on failure | Mutations fire while offline; a timed-out delete retries automatically |
| English copy | All new labels and dialogs are English | Arabic UI strings |

Automated owners:

- `client/test/features/mcp/mcp_server_management_screen_test.dart`
- `client/test/features/mcp/mcp_server_form_test.dart`
- `client/test/unit/services/device_control_client_test.dart`
- `client/test/unit/services/device_conversation_commands_test.dart`

## G6 — local security verification

| Area | Pass | Fail |
|---|---|---|
| Analyzers | Agent and Client analyzers are clean | Analyzer errors in changed owners |
| Focused tests | Admission, restart, workspace, MCP, canary, and fail-injection tests pass | A negative case mutates or leaks |
| Fast suites | Full Agent `test/` and Client `test/` suites pass | Shared-surface regressions |
| Daemon E2E | `device.runtime.restart` reconnects; managed workspace and MCP survive | Disconnect treated as success; mutations lost |
| Secret canaries | Unique canaries are absent from logs, errors, snapshots, and export | Any canary string in those surfaces |
| Symlink / race / fail-injection | TOCTOU symlink delete, stale fingerprint, and update rollback fail closed | Outside target deleted; rollback restarts |

Automated owners:

- `agent/test/interfaces/remote_device_control_g6_security_test.dart`
- `agent/test/interfaces/runtime/device_command_admission_test.dart`
- `agent/test/interfaces/platforms/sanad_gateway/handlers/device_control_command_handler_test.dart`
- `agent/test/interfaces/local_workspace_runtime_service_test.dart`
- `agent/test/core/secrets_redactor_test.dart`
- `agent/e2e_test/remote_device_control_e2e_test.dart`
- `client/test/unit/services/sanad_socket_service_test.dart`

## G7 — Live Remote Device Control Verification (Task 81 Remote VPS)

| Verification Step | Target / Method | Result | Evidence / Log Status |
|---|---|---|---|
| Read-only state check | Account-owned remote test device | PASS | Registered online, capabilities received; device identity omitted from tracked evidence |
| `device.update.check` | Flutter Client `device_check_updates_button` | PASS | Returned version `1.0.6`, read-only without file mutation |
| `device.runtime.restart` | Flutter Client `device_restart_agent_button` | PASS | Daemon acknowledged, safely drained, restarted under systemd, re-registered online |
| Explicit force restart | Flutter Client red `dialog_force_restart_button` | PASS | Sent explicit `force=true`; the supervisor restarted the same remote Agent and it re-registered online |
| Managed Remote Workspace Creation | Flutter Client `sidebar_create_workspace_btn` | PASS | Created `test-task-82-live` under `~/.sanad/workspaces/test-task-82-live` with `0700` permissions |
| Workspace record removal | Flutter Client confirmation | PASS | Removed the disposable database record while the existing directory remained on disk |
| Remote Workspace sandboxing | Path escape rejection | PASS | Root escaping rejected with `path_not_allowed` |
| Local STDIO MCP Parity | Local Daemon + Flutter Client | PASS | Tested, inspected `test_tool`, saved to `~/.sanad/mcp_config.json` and workspace config cleanly |
| Remote STDIO MCP Management | Remote test device + Flutter Client | PASS | A disposable fixture exposed one test tool and was removed after verification; host paths are omitted |
| Remote HTTP/SSE MCP Management | Remote test device + Flutter Client | PASS | A loopback-only disposable fixture exposed one test tool; endpoint details are omitted |
| Remote MCP confirmed delete | Flutter Client keyed card controls | PASS | Preview and one-time confirmation preceded `mcp_server_deleted`; the card disappeared and the fixture listener was removed |
| Scope & Precedence Isolation | Global vs Workspace vs Effective | PASS | Workspace MCPs isolated to `<workspace_path>/.sanad/mcp_config.json`, Global in `~/.sanad/mcp_config.json` |
| Security admission & redaction | Cloud admission tickets | PASS | Mutation preview and confirmation tokens enforced, secrets redacted |

## G8 — Documentation and Hand-off Review

All contracts, threat models, QA guides, and task specifications are updated in place with zero drift. All unit, widget, and integration test suites pass with 0 analyzer warnings across both agent and client.
