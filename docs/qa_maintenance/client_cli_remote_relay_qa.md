---
title: "Client CLI and Remote Relay QA"
description: "Gate-linked pass/fail coverage for Client CLI host, permissions, sanad-client runner, and remote relay delegation."
---

# Client CLI and Remote Relay QA

Owning plan: `docs/plans/102-client-cli-remote-relay-and-desktop-tray.md`
Owning tasks: `docs/plans/tasks/102a-remote-cli-relay.md`, `docs/plans/tasks/102b-client-cli-host-and-permissions.md`, `docs/plans/tasks/102c-desktop-background-system-tray.md`, `docs/plans/tasks/130-client-cli-relay-reliability.md`
Technical specs: `docs/technical/remote_cli_relay_protocol.md`, `docs/technical/desktop_background_and_system_tray.md`
Companion QA: `docs/qa_maintenance/desktop_background_and_system_tray_qa.md`
Delegation guide: `.agents/skills/sanad-delegate/SKILL.md`

## Exit code semantics observed in the live product

| Code | Meaning | Reachability |
|---|---|---|
| 69 | No live Client owns that Sanad Home (Client not running, or the feature is disabled/released) | Normal fail-closed path; the disable path releases ownership, so a disabled feature reports 69 rather than 77 |
| 77 | A live owner record reports the feature as disabled | Defensive branch for a running host that reports `enabled=false`; not reachable through the settings toggle flow |
| 1 | Rejected by the user, ambiguous owner, or relay/command failure | Default-mode denial, conflicting owners, remote command failure, or a relay that ended without a terminal result |
| 2 | Local input error (for example a missing `--brief-file`) | Local validation before any relay |
| 130 | Caller interrupted after forwarding a cancel request | SIGINT handling on non-Windows hosts |
| 64 | The target CLI rejected the forwarded argv | Relayed usage error; the CLI's own code is preserved |
| 124 | The effective relay window expired | The relayed run was still active when its derived window (command `--timeout` + grace, otherwise 300 s) closed |

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
| Relay window | `timeout_seconds` is the forwarded command's own `--timeout` plus a 30 s grace, clamped to 1..86400, and 300 s without one (`run --timeout 5400` relays for 5430 s) | A long run is killed by the relay at the 300 s default with exit `124` while still inside its own timeout |
| Stdin gating | Piped stdin is read only for a `run`/`chat` command with no `--brief-file`, `--prompt`, or positional prompt; `--stdin` forces it and is never relayed | A background job whose stdin never reaches EOF blocks before the request is sent, so even `providers list` produces no output |
| Approval wait notice | In `default` mode the caller prints one `Waiting for approval in Sanad Client...` line on stderr before the overlay is answered; stdout stays clean under `--json` | The caller is silent while the approval is pending, so an orchestrator sees an unexplained stall |
| Terminal result | Every request receives exactly one terminal frame; a stream that ends first yields exit `1` with a diagnostic, and a caller that loses its relay exits non-zero | Caller exits `0`, or waits forever, after a run that produced no result |
| Rejected argv | A usage-rejected argv returns the CLI's own exit code (`64`) with usage text on stderr | An unknown or extra argument hangs the caller instead of returning quickly |

Automated owners:
- `client/test/unit/client_cli/sanad_client_runner_test.dart`
- `client/test/unit/client_cli/sanad_client_relay_caller_test.dart`
- `client/test/unit/client_cli/client_cli_relay_policy_test.dart`

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
| Pending approval status | The host emits one `status` frame with `code: approval_pending` before it prompts, and none for an already-approved session | The approval frame is missing, or the notice arrives after the terminal result |
| Relay liveness | A device event stream that ends or fails before the terminal result still produces exactly one terminal `result` with a non-zero exit code and an explanatory error | The caller is left waiting after the device transport goes away |
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
| Caller contracts | `client/lib/features/client_cli/domain/models/client_cli_relay_policy.dart` is the single owner of the relay window and stdin-forwarding policy; the caller and host read the same approval-pending code | Either side re-derives the relay window or the approval notice code separately |

Automated owners:
- All unit and widget test suites in `client/test/unit/client_cli/` and `client/test/widget/client_cli/`
- `agent/test/interfaces/platforms/sanad_gateway/handlers/remote_cli_command_handler_test.dart` (terminal-result contract for a rejected argv)
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
