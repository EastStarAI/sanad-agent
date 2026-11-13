---
plan: 168
issue: 428
branch: fix/168-switch-fresh-worktree-admission
status: in-progress
gate: G2
remaining: second defect found during live acceptance
---

# 168 — `switch` accepts a handoff from a fresh worktree

## Goal

Make `sanad-dev switch --runtime current` usable from a worktree that has no runtime of its own, by letting an explicit `--home` reach discovery and by naming both remedies when discovery still finds nothing.

## Locked decisions and scope

- **Defect (Issue #428):** `handleRuntimeSwitch` called `discoverAgentInstances()` with no Home context. Candidate Homes are derived from the caller's own runtime record, so a fresh worktree had no credential-bearing Home, authenticated no agent, and aborted with `no source agent matches current` even when `--port` identified a healthy pair.
- The resolved `--home` was parsed for every command but deliberately kept out of the switch call, so the one operator remedy could not reach discovery.
- **Fix:** plumb the resolved Home into `handleRuntimeSwitch` and pass it as `sanadHomeOverride`; extend the empty-discovery message to name `--home` and `--port`; document both on the switch help.
- **Out of scope:** the switch transaction's target-start path, and the discovery range itself. A second defect found during live acceptance is recorded below and left for a follow-up.
- The mechanism is already covered by `explicit Home restricts gateway credential discovery` (`scripts/sanad_dev/test/discovery/sanad_dev_home_discovery_test.dart`), which asserts the override collapses the candidate set to that single Home.

## Gates

### G0 — Root cause and reproduction
- [x] Fresh worktree + `--port` → `no source agent matches current` (no mutation).
- [x] Same worktree once it owns a runtime → discovery finds both live agents → `ambiguous; pass --port`.
- [x] With `--home` + `--port` → resolves, then reports `Runtime already uses …`.
- [x] Confirmed `cli.dart` never passed the resolved Home to `handleRuntimeSwitch`.

### G1 — Admission fix
- [x] `handleRuntimeSwitch` accepts `sanadHomePath` and uses it as `sanadHomeOverride`.
- [x] Empty-discovery message names `--home` and `--port`.
- [x] Switch help documents `--home` and `--port`.
- [x] `scripts/sanad_dev` analyzer clean: `No issues found!`.
- [x] `test/runtime/switch` + `test/discovery`: 40 tests pass.

### G2 — Live acceptance
- [x] Live run 1 (cold target): admission succeeded — the switch was accepted and wrote `/home/ubuntu/.sanad-test/dev/runtime-switch-58150.json`. This is the behaviour the fix owns; before it, no manifest was ever written.
- [x] Live run 2 (warm target, pre-run then stopped): admission succeeded again.
- [ ] End-to-end handoff completes. **Failed in both runs** — see the second defect below.

## Second defect found during acceptance (out of scope here)

Both live runs ended `recovery_failed | Target startup and rollback both failed.`

Evidence from `agent.*.journal` under the source Home:

- Each agent generation reaches `Sanad Agent Hot Restart Manager` about 21 s after process start, prints `Spawning Process`, and is terminated with `SIGTERM` roughly 9 s later.
- The spawned child never reports readiness and never logs a failure of its own.
- The rollback generation fails identically, so the pair is left **stopped** after a failed handoff — the source runtime does not come back.
- Reproduced once with a cold target worktree and once with a target that had already run and been stopped, so cold JIT cost is not the trigger.

The start path through the switch transaction therefore fails where `sanad-dev run` succeeds on the same Home. This needs its own investigation; it is not an admission problem and this PR does not change it.

## Acceptance Criteria

- [x] Given a fresh worktree with `--home <source-home>`, when `switch --runtime current` runs, then discovery finds the source agent and the handoff is accepted (manifest written).
- [ ] Given the same invocation, when the handoff completes, then the target worktree serves the pair and `sanad-dev status` reports the target source. Blocked by the second defect.
- [x] Given a fresh worktree with no selector, then the abort names both remedies.

## Definition of Done

- [x] `fvm dart analyze` clean in `scripts/sanad_dev/`.
- [x] Focused switch and discovery suites green.
- [x] Help text and task file updated in the same change.
- [ ] Draft pull request opened with the acceptance result stated honestly.
- [ ] Follow-up investigation for the target-start and rollback failure.
