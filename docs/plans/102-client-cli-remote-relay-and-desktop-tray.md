---
title: "Client CLI Remote Relay and Desktop Tray"
description: "Remote-only Sanad Client CLI relay, user-controlled access, multi-instance isolation, and Windows/macOS background tray operation."
status: active
current_gate: G0
remaining_estimate: 100%
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
- [ ] Freeze the forwarded request/event/result schemas and command lifecycle.
- [ ] Map existing CLI command runner seams and Client device routing owners.
- [ ] Confirm Sanad Home endpoint ownership and stale-owner recovery.

### G1 — Remote command execution
- [ ] Add the canonical remote CLI relay command and streamed response contract.
- [ ] Execute through the existing remote Sanad command runner without shell
      evaluation or copied command implementations.
- [ ] Cover completion, failure, timeout, cancellation, stdin, brief input, and
      workspace discovery.

### G2 — Client CLI and authorization
- [ ] Add the `sanad-client` executable/entry mode and Home-scoped discovery.
- [ ] Add disabled-by-default enablement plus `default`/`full_access` modes.
- [ ] Route default approvals through the existing Client permission surface.
- [ ] Update `sanad-delegate` with device/workspace discovery and invocation.

### G3 — Desktop background and tray
- [x] Keep Windows/macOS Client alive when its window closes.
- [x] Add tray menu behavior, latest five conversations, CLI state, Agent state,
      Start Agent, Restart Agent, Show, and Quit.
- [x] Reuse existing Client navigation, cache, and daemon lifecycle owners.

### G4 — Integrated verification and documentation
- [ ] Verify isolated multi-Home Clients and one CLI owner per Home.
- [ ] Verify a real remote command and workspace selection through the Client.
- [ ] Verify macOS and Windows lifecycle contracts; record Linux deferral.
- [ ] Update product, technical, operations, QA, skill, and Graphify outputs.

## Acceptance criteria

- [ ] A disabled Client CLI rejects requests without contacting any device.
- [ ] In `default`, the existing Client UI must approve the request before relay;
      denial produces one terminal rejected result.
- [ ] In `full_access`, the same request relays without an extra Client prompt.
- [ ] `sanad-client devices` and remote workspace listing provide the ids needed
      by a later forwarded `run` or other Sanad CLI command.
- [ ] The remote Agent executes the existing Sanad CLI command behavior and the
      caller receives ordered output/events plus one terminal exit result.
- [ ] `--home`, `--url`, and `--standalone` are accepted and forwarded.
- [ ] Two Clients using different Homes do not receive each other's requests;
      two Clients sharing one Home cannot both own its CLI endpoint.
- [ ] Closing the window on Windows/macOS leaves the Client operational and the
      tray can reopen it or quit it explicitly.
- [ ] The tray shows the latest five conversations and invokes existing Start or
      Restart Agent behavior according to current availability.
- [ ] No Agent talks directly to another Agent and no cloud credential is
      exposed through CLI output or local runtime records.

## Definition of Done

- [ ] Agent and Client analyzers pass.
- [ ] Focused unit/widget/process tests pass with bounded output.
- [ ] Required daemon-backed remote relay and restart verification passes.
- [ ] Relevant design, user, and QA documentation is current.
- [ ] `docs/llms.txt` remains complete.
- [ ] `git diff --check` and `graphify update .` pass.
- [ ] No commit or push without explicit user approval.
