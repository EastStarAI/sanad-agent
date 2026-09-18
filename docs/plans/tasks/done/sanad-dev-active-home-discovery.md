---
title: "sanad-dev Active Home Discovery"
description: "Infer the active workspace runtime Home after an explicit launch so lifecycle commands do not require repeated --home selectors."
status: done
current_gate: complete
remaining_estimate: 0%
---

# sanad-dev Active Home Discovery

## Goal

Allow a runtime launched with `sanad-dev run --home <absolute-path>` to be discovered and safely managed by subsequent workspace-scoped commands without repeating `--home`, while preserving explicit overrides, worktree isolation, and fail-closed ownership checks.

## Locked Decisions and Scope

- `run` remains the command that explicitly selects a non-default Home.
- `status`, logs, restart, reload, stop, UI/driver, inspect, doctor, and other workspace-scoped runtime actions may infer the active Home after launch.
- A workspace-scoped locator is discovery evidence only; it never grants mutation authority without the existing launcher lease, Agent health identity, Client profile, and nonce checks.
- An explicit `--home` remains authoritative when supplied.
- `run` without `--home` continues to resolve the normal checkout/worktree default and does not silently reuse a previous custom Home.
- Ambiguous or contradictory live runtime identity remains fail-closed.
- Runtime source handoff behavior is out of scope and will not be invoked during implementation or verification.

## Gates

### G0 — Discovery and alignment

- [x] Read the repository and `scripts/sanad_dev/` contracts.
- [x] Trace Home parsing, runtime discovery, Agent authentication, ownership assessment, and startup-attempt locators.
- [x] Identify the bootstrap cycle: Agent discovery requires the custom Home credential before the live Agent can reveal that Home.

### G1 — Focused implementation

- [x] Add one centralized, owner-only workspace locator lookup to candidate-Home discovery.
- [x] Preserve explicit Home precedence and default `run` behavior.
- [x] Add deterministic unit coverage for custom-Home inference, stale/invalid locators, and explicit overrides.

### G2 — Documentation and contract alignment

- [x] Update the closest runtime contract to permit inferred active Home for post-launch commands.
- [x] Update technical architecture and QA matrices with the discovery-versus-authority boundary.
- [x] Update developer-facing guidance that currently requires repeating `--home`.

### G3 — Verification

- [x] Format and analyze the standalone Pure-Dart package.
- [x] Run focused tests covering Home discovery and command selection.
- [x] Run the complete `scripts/sanad_dev/` test suite with bounded output.
- [x] Run a worktree-local wrapper smoke without mutating the active runtime.
- [x] Update Graphify and review the final diff.

## Acceptance Criteria

- [x] Given a managed runtime launched from a workspace with an absolute custom Home, when a later command from that same workspace omits `--home`, then discovery includes the recorded Home and can authenticate the matching Agent.
- [x] Given an explicit `--home`, inferred locator state cannot override it.
- [x] Given a malformed, stale, foreign-workspace, missing, or unreadable locator, discovery grants no ownership and safely falls back to existing candidates.
- [x] Given no explicit Home on a new `run`, the checkout/worktree default remains unchanged.
- [x] Mutation still requires the complete existing managed-runtime ownership assessment.
- [x] Analyzer, focused tests, complete package tests, wrapper smoke, documentation, and Graphify update all pass.

## Definition of Done

- [x] Production code and regression tests are complete.
- [x] Contracts, technical documentation, QA documentation, and developer guidance agree.
- [x] Verification evidence is recorded by checked gates and final command results.
- [x] No commit, push, runtime switch, or active-runtime mutation occurs without separate user authorization.

## Verification Evidence

- `fvm dart analyze`: no issues.
- Focused discovery/startup/component tests: 38 passed.
- Complete `scripts/sanad_dev/` suite: 146 passed, 1 pre-existing skip.
- Worktree wrapper help smoke: passed without runtime mutation.
- Live isolated full-runtime cycle: launched Agent plus driver-enabled macOS Client with an absolute custom Home, then `status`, Agent/Client bounded logs, `ui snapshot`, Client reload/restart, safe Agent restart, Client stop/relaunch, `doctor`, complete stop, post-stop status, and retained Agent/Client journal logs all succeeded without `--home` on every non-`run` command.
- `run agent --dry-run --no-cloud` after the custom-Home cycle still resolved the normal worktree Home, proving `run` does not silently reuse the locator.
- `graphify update .` completed with no topology changes; `git diff --check` passed.
