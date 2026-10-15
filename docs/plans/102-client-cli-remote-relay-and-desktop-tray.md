---
title: "Client CLI Remote Relay and Desktop Tray"
description: "Remote-only Sanad Client CLI relay, user-controlled access, multi-instance isolation, and Windows/macOS background tray operation."
status: active
current_gate: G4
remaining_estimate: 10%
---

# Plan 102 — Client CLI Remote Relay and Desktop Tray

## Goal

Allow a local Sanad Agent or human automation to invoke the existing Sanad CLI
surface on a selected remote Agent through the authenticated running Sanad
Client, while keeping the feature disabled by default and controlled by the
Client's existing permission UI. Keep the desktop Client available in the
background through a Windows/macOS system tray.

## Locked decisions

- `sanad-client` is remote-only. Local Agent execution continues to use `sanad`.
- The Client does not reimplement Sanad CLI commands. It forwards the complete
  CLI request to the selected remote Agent, which executes the existing Sanad
  command runner and returns its output/events through the same Client route.
- `--home`, `--url`, and `--standalone` remain accepted and are forwarded; the
  target Agent interprets them in its own environment.
- Local file-backed input such as `--brief-file` is transported as request
  content so the remote command does not attempt to read the caller's path.
- Client CLI is disabled by default. `default` permission mode uses the current
  Client approval UI and choices; `full_access` executes without that extra
  Client-side question.
- Every CLI request targets an explicit remote device. Workspace discovery is
  remote: list devices, list that device's workspaces, then pass its workspace
  id to the forwarded command.
- Multiple development/runtime copies are isolated by Sanad Home. At most one
  live Client process owns the CLI endpoint for one Home; `--home`, then
  `SANAD_HOME`, then the default Home resolves the owner.
- The first tray release supports macOS and Windows. Linux tray support is
  deferred.
- Closing the desktop window keeps the Client running in the background. The
  tray exposes the latest five conversations, Client CLI enabled state, local
  Agent availability, `Restart Agent` when available, and `Start Agent` when
  unavailable. Start/restart reuse existing Client lifecycle functions.
- No direct Agent-to-Agent connection and no new hosted persistence are added.
- No commit or push occurs without user permission.

## Architecture boundary

```text
sanad-client command
  -> matching running Client selected by Sanad Home
  -> current authenticated device routing
  -> hosted Gateway device command relay
  -> selected remote Agent existing Sanad CLI runner
  -> streamed events / terminal result back through Client
```

The relay accepts a structured CLI request, never an arbitrary shell command.
The Gateway remains a relay, the Client remains the account/device authority,
and the remote Agent remains command/runtime authority.

## Tasks

1. [Task 102a — Remote CLI relay contract and Agent execution](tasks/102a-remote-cli-relay.md)
2. [Task 102b — Client CLI host, settings, permissions, and delegation skill](tasks/102b-client-cli-host-and-permissions.md)
3. [Task 102c — Windows/macOS background lifecycle and system tray](tasks/102c-desktop-background-system-tray.md)

## Gates

### G0 — Contract and source audit
- [x] Freeze the forwarded request/event/result schemas and command lifecycle.
- [x] Map existing CLI command runner seams and Client device routing owners.
- [x] Confirm Sanad Home endpoint ownership and stale-owner recovery.

### G1 — Remote command execution
- [x] Add the canonical remote CLI relay command and streamed response contract.
- [x] Execute through the existing remote Sanad command runner without shell
      evaluation or copied command implementations.
- [x] Cover completion, failure, timeout, cancellation, stdin, brief input, and
      workspace discovery.

### G2 — Client CLI and authorization
- [x] Add the `sanad-client` executable/entry mode and Home-scoped discovery.
- [x] Add disabled-by-default enablement plus `default`/`full_access` modes.
- [x] Route default approvals through the existing Client permission surface.
- [x] Update `sanad-delegate` with device/workspace discovery and invocation.

### G3 — Desktop background and tray
- [x] Keep the desktop Client alive when its window closes on Windows, macOS, and
      Linux (closing hides the window; only `Quit` ends the process).
- [x] Add tray menu behavior, latest five conversations, CLI state, Agent state,
      Start Agent, Restart Agent, Show, and Quit.
- [x] Reuse existing Client navigation, cache, and daemon lifecycle owners.

### G4 — Integrated verification and documentation
- [x] Verify one CLI owner per Home and fail-closed Home isolation (live: a
      released/disabled endpoint rejects the caller; unrelated Homes return the
      no-owner failure instead of a foreign Client).
- [x] Verify a real remote command and workspace selection through the Client.
- [x] Linux tray execution verified live (icon registered on the session bus and
      the full 10-entry menu read back over D-Bus).
- [ ] macOS/Windows lifecycle contract execution on real hardware; the steps are
      owned by `docs/qa_maintenance/desktop_background_and_system_tray_qa.md`
      §Manual platform verification. These items stay open until the maintainer
      runs them on macOS/Windows.
- [x] Update product, technical, operations, QA, and skill outputs. (Graphify
      output refresh is deferred: the Graphify CLI is not installed in this
      environment.)

## Acceptance criteria

- [x] A disabled Client CLI rejects requests without contacting any device.
- [x] In `default`, the existing Client UI must approve the request before relay;
      denial produces one terminal rejected result.
- [x] In `full_access`, the same request relays without an extra Client prompt.
- [x] `sanad-client devices` and remote workspace listing provide the ids needed
      by a later forwarded `run` or other Sanad CLI command.
- [x] The remote Agent executes the existing Sanad CLI command behavior and the
      caller receives ordered output/events plus one terminal exit result.
- [x] `--home` is accepted and forwarded (explicit flag and `SANAD_HOME`
      resolution both verified); `--url`/`--standalone` pass through the same
      unchanged argv lane.
- [x] Two Clients using different Homes do not receive each other's requests;
      two Clients sharing one Home cannot both own its CLI endpoint.
- [x] Closing the window on Windows/macOS/Linux leaves the Client operational and
      the tray can reopen it or quit it explicitly (lifecycle logic owned by
      `desktop_lifecycle_manager_test.dart`; Linux verified live over D-Bus;
      macOS/Windows platform execution owned by the tray QA platform checklist).
- [x] The tray shows the latest five conversations and invokes existing Start or
      Restart Agent behavior according to current availability (owned by
      `tray_menu_builder_test.dart`; platform execution owned by the tray QA
      platform checklist).
- [x] No Agent talks directly to another Agent and no cloud credential is
      exposed through CLI output or local runtime records.

## Definition of Done

- [x] Agent and Client analyzers pass.
- [x] Focused unit/widget/process tests pass with bounded output.
- [x] Required daemon-backed remote relay verification passes.
- [x] Relevant design, user, and QA documentation is current.
- [x] `docs/llms.txt` remains complete.
- [x] `git diff --check` passes.
- [x] Graph refresh is not applicable to this change: this checkout contains no
      `graphify-out/` corpus (neither the primary checkout nor the task worktree)
      and the Graphify CLI is not installed, so there is no graph to update. The
      step stays part of the Graphify workflow only in checkouts that own a
      corpus.
- [x] No commit or push without explicit user approval.

## Verification evidence (2026-10-15, Linux host)

Environment: client and two agents on the same machine, one Sanad account.
Group A = Client + local Agent in Home A (`--client-instance 102-verify`);
Group B = second Agent in Home B cloned from Home A with a fresh `hardware_id`
(manual override, because `sanad-dev` refuses a second agent group in one
workspace). Devices were renamed `102-H1-Local` / `102-H2-Remote` to keep the
account inventory unambiguous.

| Check | Observed result |
|---|---|
| Client CLI disabled by default | no runtime record; `sanad-client` fails closed with exit 69 and no device contact |
| Enable from Settings | `runtime/client_cli.json` created with `0600`, dynamic loopback port, `client_version` 1.0.15 |
| Loopback authentication | `/health` and `/devices` without token → 401; with token → 200 |
| Local device exclusion | local Agent absent from `sanad-client devices` |
| Restart of the Client | endpoint ownership restored automatically at boot |
| Disable | record removed, port closed, caller fails closed |
| Secret hygiene | CLI token: 0 occurrences in Client and Agent logs |
| Remote discovery | `sanad-client devices` listed 6 account devices, remote target online |
| Remote execution | `ws list --json` and `session list` executed on the remote Agent with ordered output and exit 0 |
| Default approval | overlay presented device, argv and Allow once / Allow session / Deny choices |
| Denial | exit 1, `Command rejected by user in Sanad Client.`, remote execute counter unchanged (no device contact) |
| Full access | same request relayed with no approval overlay |
| Mode change | runtime record re-acquired with `permission_mode=full_access`, then back to `default` |
| Forwarded `--brief-file` run | `sanad-client -d 102-H2-Remote run --provider <OpenCode Go> --model deepseek-v4.1-flash --workspace … --brief-file … --json` was approved in the Client, executed on the remote Agent (`device.cli.execute` → `device.cli.result`), and returned one terminal JSON result: `text="RELAY-OK"`, `provider="opencode-go"`, `model="deepseek-v4.1-flash"`, `exit_code=0`, caller exit 0. An earlier attempt using the remote home's default provider stopped on that provider's `rateLimit` notice while the verifier session held the plan limit, which is why the run was repeated with an explicit provider/model. |
| Caller cancellation | `SIGINT` on the caller sent `device.cli.cancel`; the remote handler reported `exit_code=130` and cancelled the remote run session; the caller exited with `130` |
| Home isolation | `sanad-client --home <home without owner>` returned the no-owner failure with exit 69 instead of reaching the live Client of another Home |
| Environment resolution | `SANAD_HOME` resolved the same live Client without `--home` |
| Linux tray icon | Client log `System tray icon initialized`; the session bus lists `org.kde.StatusNotifierItem-<client pid>-1` and the icon appears in the Ubuntu panel |
| Linux tray menu | `com.canonical.dbusmenu.GetLayout` returned 10 entries: `Show`, five recent conversations, `Agent: Running`, `Restart Agent`, `Client CLI: Enabled`, `Quit` |
| Linux close-to-hide loop | Three close cycles logged `hiding window without disposing state or sockets`, each restored through the tray `Show` entry, with gateway/session traffic continuing while hidden |
| Linux explicit quit | `Explicit quit initiated: executing deterministic shutdown`, socket disconnect, CLI runtime-record release, tray item unregistration, and process exit; the three Agents stayed running |

Defects found by this verification and fixed on the branch:

1. Linux desktop build failed because the deferred tray dependency compiles with
   `G_APPLICATION_DEFAULT_FLAGS` (GLib ≥ 2.74) while supported Linux
   toolchains such as Ubuntu 22.04 ship GLib 2.72.
2. `IDeviceRepository` was registered as a factory, so the Client CLI host
   received an uninitialized inventory owner and `sanad-client devices` always
   returned an empty list in the real app (unit tests passed because they inject
   a fake repository).
3. A login/logout cycle released CLI endpoint ownership while the feature stayed
   enabled, and nothing re-acquired it afterwards.
4. The endpoint-restore change was re-entrant: an overlapping enable request and
   login-driven reconcile both passed the "not running" gate, bound two servers,
   and left the runtime record pointing at a bound-but-unserved port. Every later
   `sanad-client` call then timed out and reported "No active Sanad Client" until
   the Client restarted. Fixed by serializing lifecycle mutations behind one
   chain and publishing the server only after it is actually serving, with a
   deterministic regression test (verified to fail when the serialization is
   removed).

## Known limitations after G4

- macOS/Windows tray execution (icon in the system bar/taskbar, close-to-hide,
  explicit Quit) still requires real hardware; the steps stay open in
  `docs/qa_maintenance/desktop_background_and_system_tray_qa.md`.
- On Linux the panel owns tray clicks, so every action must exist as a menu entry
  and window restore relies on `Show`; GNOME additionally needs the AppIndicator
  extension.
- Overlapping enable/reconcile requests are now serialized, but a caller that
  probes the loopback endpoint during a very busy UI frame can still miss the
  1-second discovery health window; the CLI host shares the UI isolate.
- `login` is not relay-wired: forwarding it returns exit 0 with no output
  instead of an explicit unsupported result.
- `sanad-dev` reports "already running" when a second agent group is requested
  for one workspace; the second Agent therefore ran through the documented manual
  override.

## Status

Everything verifiable on this host is complete: the relay, the Client CLI host,
permissions, tray/background behavior on Linux (icon + full menu + close-to-hide),
documentation, and the focused verification suite. The plan stays open only for
the macOS/Windows tray execution the maintainer will run on real hardware.
