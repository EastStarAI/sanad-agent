---
title: "Client CLI and Remote Relay QA"
description: "Gate-linked pass/fail coverage for Client CLI host, permissions, sanad-client runner, and remote relay delegation."
---

# Client CLI and Remote Relay QA

Owning plan: `docs/plans/102-client-cli-remote-relay-and-desktop-tray.md`
Owning tasks: `docs/plans/tasks/102a-remote-cli-relay.md`, `docs/plans/tasks/102b-client-cli-host-and-permissions.md`, `docs/plans/tasks/102c-desktop-background-system-tray.md`
Technical specs: `docs/technical/remote_cli_relay_protocol.md`, `docs/technical/desktop_background_and_system_tray.md`
Companion QA: `docs/qa_maintenance/desktop_background_and_system_tray_qa.md`
Delegation guide: `.agents/skills/sanad-delegate/SKILL.md`

## Exit code semantics observed in the live product

| Code | Meaning | Reachability |
|---|---|---|
| 69 | No live Client owns that Sanad Home (Client not running, or the feature is disabled/released) | Normal fail-closed path; the disable path releases ownership, so a disabled feature reports 69 rather than 77 |
| 77 | A live owner record reports the feature as disabled | Defensive branch for a running host that reports `enabled=false`; not reachable through the settings toggle flow |
| 1 | Rejected by the user, ambiguous owner, or relay/command failure | Default-mode denial, conflicting owners, or remote command failure |
| 2 | Local input error (for example a missing `--brief-file`) | Local validation before any relay |
| 130 | Caller interrupted after forwarding a cancel request | SIGINT handling on non-Windows hosts |


---

## G0 — Local Ownership and Security Contract

| Area | Pass | Fail |
|---|---|---|
| Runtime file creation | Atomic write to `<SANAD_HOME>/runtime/client_cli.json` with `0600` permissions on macOS/Linux and `CurrentUser:FullControl` on Windows ACLs | World-readable runtime record or non-atomic write leading to partial reads |
| Live process check | If another live Client process owns the record, current Client fails closed with `already_running` | Second client overwrites active client's endpoint or crashes |
| Stale owner recovery | Dead PID or non-responsive endpoint is cleaned up and new owner writes fresh record | Dead PID prevents new Client from acquiring ownership |
| Authentication token | High-entropy ephemeral token required on all HTTP and WebSocket requests | Loopback requests accepted without token authentication |
| Home isolation | Client instance is strictly isolated by Sanad Home; explicit `--home`, `SANAD_HOME`, then default `~/.sanad` | CLI for Home A connects to Client for Home B |

Automated owner:
- `client/test/unit/client_cli/client_cli_ownership_test.dart`

---

## G1 — CLI Entry and Discovery (`sanad-client`)

| Area | Pass | Fail |
|---|---|---|
| Installed entry | `sanad-client` binary / script executable from shell; `sanad` remains strictly the local CLI | `sanad-client` invokes local agent or mutates local daemon |
| Device discovery | `sanad-client devices [--json]` lists remote connected devices; excludes local device | Local device included or remote inventory unreachable |
| Brief transport | `--brief-file <f>` content is read locally and relayed over WebSocket payload; argv is sanitized | Sensitive brief text exposed in process argv table |
| Standard I/O | Standard input, stdout, stderr, events, and exit codes stream transparently | Terminal exit codes lost or stdout buffered until process close |
| Signal forwarding | SIGINT (Ctrl+C) forwards `device.cli.cancel` message to host and exits with code 130 | SIGINT kills local CLI without notifying remote agent turn |

Automated owner:
- `client/test/unit/client_cli/sanad_client_runner_test.dart`

---

## G2 — Settings and Approval Presentation

| Area | Pass | Fail |
|---|---|---|
| Disabled by default | `Enable Client CLI` toggle in Settings > Client CLI is OFF on fresh install | Client CLI enabled without user consent |
| Disabled behavior | Any `sanad-client` invocation with no live owner for the Home returns the fail-closed no-owner result (exit 69) without contacting any device | Disabled host executes command or leaks remote data |
| Inventory ownership | The CLI host reads the same initialized device inventory as the conversation UI; a remote device listed by the UI is discoverable by `sanad-client devices` | CLI host resolves its own uninitialized inventory and always reports an empty device list |
| Lifecycle serialization | Overlapping enable/disable/reconcile requests run one at a time; exactly one server is bound and the runtime record always points at a serving port | Two overlapping requests bind two servers, one `listen` throws, and the record points at a bound-but-unserved port (every later call times out) |
| Concurrent cancellation | `SIGINT` on the caller forwards `device.cli.cancel`, the remote command ends, and the caller exits 130 | Caller hangs, remote command keeps running, or exit code is not 130 |
| Forwarded one-shot run | A `--brief-file run` with an explicit provider/model returns one terminal JSON result with the requested text and `exit_code: 0` | No terminal result, wrong provider/model echoed, or a non-zero exit for a successful turn |
| Permission modes | `Default` and `Full access` modes selectable via desktop UI | Mode switches unpersisted across restarts |
| Default approval | Commands display desktop approval dialog with device, command preview, and choices: Allow once, Allow session, Deny | Command executes without prompt in Default mode |
| Session caching | `Allow for this session` caches approval for that session ID; subsequent commands for that session execute without prompt | Re-prompting every command in an approved session |
| Denial handling | Deny click or Esc/key 3 rejects request with exit code 1; remote agent does not execute | Deny leaves command hanging or executes anyway |
| Hotkeys | Keys `1`, `2`, `3`, `Escape` resolve approval immediately | Keyboard navigation broken or requiring mouse focus |
| Ownership release | Disabling feature, logging out of account, or quitting app removes runtime file and closes loopback port | Lingering open ports or stale ownership files left behind |

Automated owners:
- `client/test/unit/client_cli/client_cli_host_test.dart`
- `client/test/unit/client_cli/client_cli_cubit_test.dart`
- `client/test/unit/client_cli/client_cli_version_test.dart`
- `client/test/unit/client_cli/client_cli_inventory_contract_test.dart`
- `client/test/widget/client_cli/client_cli_settings_card_test.dart`
- `client/test/widget/client_cli/client_cli_approval_overlay_test.dart`

---

## G3 — Delegation Integration and Documentation

| Area | Pass | Fail |
|---|---|---|
| Orchestrator guide | `.agents/skills/sanad-delegate/SKILL.md` documents device listing, workspace listing, remote run, observation, answer, and stop | External supervisor has no guidance for remote delegation |
| Technical protocol | `docs/technical/remote_cli_relay_protocol.md` documents HTTP endpoints, WebSocket envelope, and error codes | Protocol details missing or diverging from implementation |
| Verification loop | All unit and widget tests pass; Flutter analyzer is clean; bounded output preserved | Test failures, compiler warnings, or analyzer lints |

Automated owners:
- All unit and widget test suites in `client/test/unit/client_cli/` and `client/test/widget/client_cli/`
- Full test and analysis commands documented below.

---

## Verification Commands

Execute the following commands to verify implementation:

```bash
# 1. Analyze client codebase
cd client && fvm flutter analyze 2>&1 | tail -5

# 2. Run all Client CLI unit and widget tests
cd client && fvm flutter test test/unit/client_cli/ test/widget/client_cli/ 2>&1 | tail -5

# 3. Run Agent CLI relay tests (102a foundation)
cd agent && fvm dart test test/interfaces/platforms/sanad_gateway/handlers/remote_cli_command_handler_test.dart 2>&1 | tail -5
```
