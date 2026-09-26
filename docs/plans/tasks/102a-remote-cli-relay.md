---
title: "Task 102a — Remote CLI Relay"
status: completed
current_gate: complete
remaining_estimate: 0%
---

# Task 102a — Remote CLI Relay

## Goal

Execute structured `sanad-client` requests on a selected remote Agent through
its existing Sanad CLI command runner and return ordered output/events plus one
terminal result, without shell evaluation or command reimplementation.

## Locked scope

- The Gateway receives one explicit device target and relays without persistence.
- The request carries argv, stdin/input material, correlation id, and bounded
  execution controls. File-backed caller input is materialized before relay.
- All current Sanad CLI commands, including options such as `--home`, `--url`,
  and `--standalone`, enter the existing command parser on the remote host.
- The relay is not a generic remote shell.
- Cancellation is scoped to the relay request/session and cannot stop unrelated
  remote work.

## Gates

### G0 — Contract
- [x] Inventory the complete `SanadCommandRunner` surface and identify the
      reusable remote execution seam.
- [x] Define versioned request, output/event, terminal result, and error schemas.
- [x] Define size, timeout, cancellation, and redaction boundaries.

### G1 — Agent execution
- [x] Add the canonical remote command handler to local/cloud protocol dispatch.
- [x] Adapt the existing CLI runner to injected argv/stdin/stdout/stderr/event
      sinks without changing ordinary local CLI behavior.
- [x] Stream correlated output and publish exactly one terminal result.

### G2 — Device and workspace flow
- [x] Relay device-scoped workspace listing through existing CLI behavior.
- [x] Prove a listed workspace id can be used by a later remote `run` request.
- [x] Materialize `--brief-file` content and preserve stdin semantics.

### G3 — Reliability
- [x] Add scoped timeout, cancellation, disconnect, duplicate request, and late
      event handling.
- [x] Add Agent protocol, runner, and daemon-backed tests.
- [x] Update technical protocol and CLI architecture documentation.

## Acceptance criteria

- [x] Given a selected online device, any supported Sanad CLI argv reaches that
      device's existing command parser and returns its actual exit code.
- [x] No request is interpreted by a system shell.
- [x] stdout, stderr, structured events, and terminal state remain correlated and
      ordered under concurrent requests.
- [x] Duplicate or cancelled requests cannot execute twice or affect another
      session.
- [x] Secrets and command payload content do not enter transport logs.

## Definition of Done

- [x] `fvm dart analyze` passes in `agent/`.
- [x] Focused CLI/interface tests and required daemon-backed E2E pass.
- [x] Technical docs and task status are current.
- [x] `git diff --check` passes.
- [x] No commit or push without explicit user approval.
