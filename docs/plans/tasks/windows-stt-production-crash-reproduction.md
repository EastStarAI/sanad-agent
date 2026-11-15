---
title: "Windows Production Dictation Crash Reproduction"
status: planned
---

## Goal

Determine whether the reported Windows production Agent crash follows the official v1.0.23 native runtime, the Agent version, or packaging, without exposing the running primary daemon to native crash risk.

## Locked Scope

- Delegation remains attached to the running primary daemon and `C:\Users\aatia\.sanad`.
- Native crash probes run only in disposable child processes; do not start another daemon, Client, managed runtime, or Sanad Home.
- Verify every downloaded release artifact against the manifest and SHA-256 before execution.
- Use the same installed model/fixture read-only where possible; never mutate primary sessions, databases, or configuration.
- Treat Issue #439's AVX-512 evidence as a hypothesis until a child-process load/decode proves the behavior.
- Do not modify product code in this task; create a minimal temporary or test-owned reproduction harness only when existing smoke coverage cannot decode.

## Gates

### G0 — Inputs
- [ ] Record host CPU features and official v1.0.23 Agent/runtime identity, size, and digest.
- [ ] Locate a safe fixed audio fixture and the model used by the successful local session.
- [ ] Define exit-code/crash evidence collection before executing native code.

### G1 — Runtime A/B
- [ ] Decode the same fixture in a disposable process with the locally built runtime.
- [ ] Decode the same fixture in a disposable process with the verified v1.0.23 runtime.
- [ ] Capture stdout/stderr, PID, exit code, duration, Windows event/dump evidence, and whether the primary daemon remained unchanged.

### G2 — Ownership Bound
- [ ] If the release runtime crashes and local does not, attribute the runtime boundary and connect the evidence to Issue #439 without overstating the exact instruction fault.
- [ ] If both pass, prepare the minimum exact packaged-Agent subprocess test and stop for approval before starting any second daemon/runtime.
- [ ] Record the next smallest experiment needed to distinguish Agent code from packaging.

## Acceptance Criteria

- [ ] The local and release runtimes are compared with the same model/audio/process contract.
- [ ] A native process failure has durable exit/crash evidence and cannot restart or kill the primary daemon.
- [ ] The report states confirmed owner, excluded owners, and remaining uncertainty.
- [ ] No alternate delegation daemon, Client, Home, or database is created.

## Definition of Done

- [ ] Evidence and exact commands are recorded here.
- [ ] Primary `sanad-dev status` before/after proves the same launcher, Agent endpoint, and Home remained active.
- [ ] A separate reviewer session accepts or rejects the evidence; corrections return to the original investigator session and re-review returns to the original reviewer session.
