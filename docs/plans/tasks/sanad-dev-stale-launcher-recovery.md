---
status: in_progress
priority: critical
security_review: required
platforms: windows-primary, macos-regression, linux-regression
depends_on: sanad-dev-windows-command-latency
current_gate: G3-G4 verification
remaining: full-suite baseline triage, human-terminal Agent restart cycle, security review, CI, merge
---

# sanad-dev Stale Launcher Recovery

## Goal

Restore a safe, actionable recovery path when a sanad-dev launcher lease becomes
stale while an Agent or Client remains live, and verify the complete managed
lifecycle from an isolated Windows worktree without weakening ownership checks
or changing the primary runtime.

## Locked Decisions and Scope

- Preserve strict fail-closed ownership: a stale launcher PID alone never grants
  authority to stop an Agent, Client, or delete a lease.
- `run` must not perform implicit destructive orphan cleanup. It either remains
  idempotent for a proven managed group or fails with one accurate recovery
  action.
- `cleanup-target-orphans` remains target-only and may not stop a live Agent,
  source/requester runtime, IDE-owned Client, ambiguous Client, or any process
  lacking exact stale-record launcher id, runtime nonce, Home, source, PID, and
  endpoint evidence.
- Any recovery that drains a live Agent must use the authenticated daemon safety
  boundary, verify a successful response, wait for endpoint/process exit, and
  delete the launcher record only after every owned live surface is absent.
- Do not accept root-relative POSIX paths as absolute Windows Home selectors and
  do not change production path semantics merely to support host-invalid test
  fixtures.
- Do not use manual process kills, global Dart/Flutter commands, runtime source
  switching, or the primary runtime for implementation verification.
- Keep the untrusted repair diff available in this worktree for forensic review;
  retain only changes independently justified by the contracts and evidence.
- The unrelated lost sidebar working-tree edit is outside this task and must not
  be reconstructed speculatively.

## Gates

### G0 — Reproduce and Classify

- [x] Record the clean `a925c8c` behavior for `status`, `doctor`, `run`, and
      explicit cleanup when a launcher record is stale and no/live components
      remain.
- [x] Reproduce the reported stale-launcher state with injected deterministic
      fixtures and, when safe, an isolated runtime; do not manufacture the state
      in the primary Home.
- [x] Determine whether the root defect is launcher lifetime, ownership
      classification, inaccurate doctor guidance, or a missing explicit recovery
      transaction.
- [x] Classify every line of the transferred untrusted diff as retain, replace,
      or reject with contract evidence.

### G0 Evidence

- Clean `a925c8c` classifies a dead-launcher/live-Agent group as orphaned, but
  `doctor` recommends `cleanup-target-orphans`, which contractually refuses a
  live Agent. `run` correctly refuses rather than mutating that group.
- Two isolated Agent startup attempts did not reach health within their bounded
  windows on the loaded Windows host. The second left a dead-launcher record
  with no live component and was safely removed by the existing no-process
  `doctor --fix` path. Logs ended at Agent process spawn, so this evidence does
  not establish the reported restart failure's launcher-lifetime root cause.
- The proven defects are inaccurate doctor guidance and a missing explicit
  recovery transaction for an exact Agent-only orphan. Live lifecycle evidence
  remains required before attributing or closing any launcher-lifetime defect.
- The transferred repair diff is rejected in full as implementation input. Its
  live-Agent and path-matched-Client kills, swallowed failures, pre-exit lease
  deletion, implicit `run` cleanup, and Windows path-semantic changes violate
  the locked safety contract. The forensic copy remains ignored under
  `.dart_tool/` with SHA-256
  `68c441b39dbe1cb05f665e22510b23e59a75872bce4b7cc38a45309b390de6ae`.

### G1 — Recovery Design

- [x] Select one explicit recovery owner and document its admission, mutation,
      wait, rollback/failure, and lease-deletion boundaries.
- [x] Require exact agreement among stale record, Agent health identity, Home,
      source/workspace, launcher id/nonce, and complete recorded Client
      inventory before any live mutation.
- [x] Preserve the existing no-live-Agent contract of target orphan cleanup
      unless a separately reviewed design proves why a new command boundary is
      safer and necessary.
- [x] Ensure every rejected, timed-out, ambiguous, cross-owned, or partial case
      preserves the lease and reports a concrete nonzero result.

### G2 — Focused Implementation

- [x] Implement the smallest cohesive correction behind injected seams; do not
      duplicate discovery, authentication, or secure runtime-file logic.
- [x] Make `doctor` recommend only an action that can actually handle the
      observed classification and evidence.
- [x] Keep `run`, `stop`, restart, reload, and cleanup semantics consistent with
      the runtime ownership contract.
- [x] Remove all unsafe or fixture-only portions of the transferred diff.

### G3 — Automated Regression Coverage

- [ ] Cover stale launcher with no endpoints, exact live Agent-only, exact live
      Client-only, and exact live Agent+Client states.
- [ ] Cover PID reuse, launcher identity/nonce mismatch, foreign Home/source,
      requester/source port, IDE-owned Client, incomplete profile, multiple
      matching Agents, failed daemon response, timeout, and partial exit.
- [x] Assert no process signal or lease deletion occurs before full admission.
- [x] Assert a failed recovery leaves the lease and every unproven process
      untouched.
- [ ] Run format, analyzer, focused lifecycle/ownership tests, and the complete
      standalone package suite through FVM with bounded output.

### G4 — Isolated Live Lifecycle Verification

- [ ] From this worktree, prepare and launch a local-only managed Agent with
      `sanad-dev run agent --background --no-cloud` using its automatically
      isolated Home and port.
- [ ] Verify `status` reports one managed launcher, the expected Agent, no
      Client, and zero cross-owned/unverifiable Clients.
- [ ] Run and verify `sanad-dev restart agent --timeout 60`, including exact
      Agent-only stale recovery if the launcher failure reproduces.
- [ ] Run and verify `sanad-dev stop`; confirm the isolated Agent, lease, startup
      locator, and port are no longer active.
- [ ] Cover Client restart and reload through automated tests and hosted CI. A
      second local Client is optional because this Windows host may not have
      sufficient resources; lack of a second local Client is not grounds to
      skip automated or Windows/macOS/Linux CI coverage.
- [x] Confirm the primary runtime remains managed and unchanged before and after
      isolated verification.

### G5 — Documentation and Delivery

- [x] Update the runtime ownership technical design, developer guidance, and QA
      matrix with the exact stale-launcher recovery contract.
- [x] Update the closest `AGENTS.md` only if the durable ownership law changes.
- [x] Run `graphify update .` if a graph exists at implementation time (no
      `graphify-out/graph.json` exists in this worktree).
- [ ] Review diff, generated output, secrets, machine paths, and protected-label
      requirements.
- [ ] Rebase on current `origin/main`, obtain required security review, pass the
      Windows/macOS/Linux hosted checks, create a focused PR, and squash merge
      only after `All required checks pass` is green.

## Acceptance Criteria

- [ ] The originally reported state produces one accurate and executable
      recovery instruction rather than a cleanup command that necessarily
      refuses or silently fails.
- [ ] No normal `run` invocation kills or drains an orphaned live component.
- [ ] No stale record is deleted while its launcher, Agent endpoint, recorded
      Client, or exact exit evidence remains live.
- [ ] Mismatched, ambiguous, cross-owned, source-attached, or unverifiable
      processes are never signaled.
- [ ] A fully admitted recovery either completes and permits a subsequent
      managed `run`, or fails nonzero while preserving recoverable evidence.
- [ ] The isolated live Agent sequence `run agent → restart agent → stop`
      succeeds with managed ownership throughout; Client restart/reload pass in
      automated coverage and hosted CI.
- [ ] The primary runtime is not switched, stopped, or used as the test target.
- [ ] Windows, macOS, and Linux CI pass without weakening POSIX behavior.

## Definition of Done

- [ ] Root cause and rejected unsafe diff portions are documented in this plan.
- [ ] Production code, tests, and owning documentation agree.
- [ ] FVM analyzer and automated tests pass with bounded output.
- [ ] Isolated lifecycle evidence satisfies G4 and leaves no runtime residue.
- [ ] Security review and all required GitHub checks pass.
- [ ] PR is squash-merged and the primary checkout is updated without losing
      unrelated local work.
