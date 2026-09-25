---
title: "Task 102b — Client CLI Host and Permissions"
status: pending
current_gate: G0
remaining_estimate: 100%
---

# Task 102b — Client CLI Host, Permissions, and Delegation

## Goal

Expose the running desktop Client as the disabled-by-default `sanad-client`
remote command tool, isolate concurrent Clients by Sanad Home, and authorize
requests through `default` or `full_access` mode.

## Locked scope

- `sanad-client` targets remote devices only; `sanad` remains the local CLI.
- Resolution order is explicit `--home`, `SANAD_HOME`, then default Home.
- One live Client owns the endpoint for one Home; stale ownership is recoverable.
- `default` uses the existing permission UI and choices. `full_access` skips
  only this extra Client CLI approval.
- The Client reuses device inventory and `DeviceConnectionCoordinator`; it does
  not duplicate cloud authentication or routing.

## Gates

### G0 — Local ownership contract
- [ ] Define owner-only endpoint, runtime record, authentication, and stale-owner
      cleanup for macOS and Windows.
- [ ] Define deterministic no-owner, disabled, ambiguous, and version-mismatch
      errors.

### G1 — CLI entry and discovery
- [ ] Add the installed `sanad-client` command/entry mode.
- [ ] Add device discovery/selection and transparent forwarding of remaining
      Sanad CLI argv/stdin.
- [ ] Preserve JSON, quiet, event-stream, signal, and exit-code behavior.

### G2 — Settings and approval
- [ ] Add `Enable Client CLI`, disabled by default.
- [ ] Add `Default` and `Full access` permission modes.
- [ ] Route Default requests through the current Client approval presentation;
      reuse its allow/deny choices and authoritative resolution.
- [ ] Release endpoint ownership on disable, logout, or Client exit.

### G3 — Delegation integration
- [ ] Extend `sanad-delegate` with device listing, workspace listing, remote
      invocation, observation, cancellation, and intervention examples.
- [ ] Add unit/widget/process tests for settings, ownership, routing, and output.
- [ ] Update product, technical, user, and QA documentation.

## Acceptance criteria

- [ ] Disabled CLI fails locally before any remote command is sent.
- [ ] Different Homes route only to their matching Client; one Home never has
      two active CLI owners.
- [ ] Default mode executes only after the user allows it in the current Client
      permission UI; Full access executes without that prompt.
- [ ] The caller can list devices, list a selected device's workspaces, and then
      forward the unchanged Sanad command using the returned workspace id.
- [ ] Client/Gateway credentials never appear in argv, output, runtime records,
      or logs.

## Definition of Done

- [ ] `fvm flutter analyze` passes in `client/`.
- [ ] Focused widget/unit/process tests and required Client/Agent E2E pass.
- [ ] `sanad-delegate` and relevant docs are current.
- [ ] `git diff --check` passes.
- [ ] No commit or push without explicit user approval.
