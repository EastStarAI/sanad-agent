---
status: superseded
closure_reason: remaining-work-transferred-not-certified-complete
superseded_by: docs/plans/97-windows-first-agent-client-performance.md
current_gate: closed-transferred
priority: critical
security_review: required
platforms: windows-primary, macos-regression, linux-regression
depends_on: sanad-dev-windows-secure-runtime-file-performance
---

# sanad-dev Stale Launcher Recovery

## Closure and transfer to Plan 97

**Closed as superseded, not completed.** This file is a historical evidence record,
not an active execution queue. All previously unchecked items (20 entries)
are transferred to the successor owners below. Checked items retain their
historical meaning; no unverified acceptance or security result is marked passed.
The successor owns the complete original obligations, including negative cases,
security review, documentation and delivery reconciliation, not only a summary.
Archived under docs/plans/done with superseded status; references point to this record or its Plan 97 successor. No independent work remains here.

| Original outstanding scope | New execution owner |
|---|---|
| G3 — outstanding state/admission/failure coverage | [97e](docs/plans/tasks/97e-launcher-lifecycle-verification.md) |
| G4 — remaining hosted Client restart/reload coverage | [97k](docs/plans/tasks/97k-regression-budgets-and-report.md) |
| G5 + acceptance + DoD — reconcile merged delivery, protected review/security/CI and outstanding correctness checks | [97e](docs/plans/tasks/97e-launcher-lifecycle-verification.md) |
| Cross-platform checks and final evidence review | [97k](docs/plans/tasks/97k-regression-budgets-and-report.md) |
| Any remaining live lifecycle/residue evidence | [97l](docs/plans/tasks/97l-interactive-final-acceptance.md) |

## Historical plan and evidence (non-executable)

The following goals, gates and acceptance statements describe the original task.
`Transferred` entries are preserved requirements now owned by the table above;
they are not open checkboxes in this retired plan. Historical commands and merge
instructions do not authorize new execution or duplicate delivery.



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

- **Transferred to Plan 97:** Cover stale launcher with no endpoints, exact live Agent-only, exact live
      Client-only, and exact live Agent+Client states.
- **Transferred to Plan 97:** Cover PID reuse, launcher identity/nonce mismatch, foreign Home/source,
      requester/source port, IDE-owned Client, incomplete profile, multiple
      matching Agents, failed daemon response, timeout, and partial exit.
- [x] Assert no process signal or lease deletion occurs before full admission.
- [x] Assert a failed recovery leaves the lease and every unproven process
      untouched.
- [x] Run format, analyzer, focused lifecycle/ownership tests, and the complete
      standalone package suite through FVM with bounded output.

### G4 — Isolated Live Lifecycle Verification

- [x] From a human-owned terminal in this worktree, prepare and launch a
      local-only managed Agent and Client with
      `sanad-dev run all --background --driver --no-cloud` using an isolated
      Home and ports. Agent-origin launch remains blocked by the enclosing
      kill-on-close Job; no general breakaway policy may be enabled as a
      workaround.
- [x] Verify `status` reports one managed launcher, the expected Agent and
      Client, and zero cross-owned/unverifiable Clients.
- [x] Run and verify `sanad-dev restart agent --timeout 60`, including exact
      Agent-only stale recovery if the launcher failure reproduces.
- [x] Run and verify Client reload and restart against the exact managed VM
      endpoint, followed by managed status.
- [x] Run and verify `sanad-dev stop`; confirm the isolated Agent, Client, lease,
      startup locator, and ports are no longer active.
- [x] Retain Client restart/reload automated coverage in addition to the local
      Agent+Client cycle.
- **Transferred to Plan 97:** Pass Client restart/reload coverage in hosted CI.
- [x] Confirm the primary runtime remains managed and unchanged before and after
      isolated verification.

### G5 — Documentation and Delivery

- [x] Update the runtime ownership technical design, developer guidance, and QA
      matrix with the exact stale-launcher recovery contract.
- [x] Update the closest `AGENTS.md` only if the durable ownership law changes.
- [x] Run `graphify update .` if a graph exists at implementation time (no
      `graphify-out/graph.json` exists in this worktree).
- **Transferred to Plan 97:** Review diff, generated output, secrets, machine paths, and protected-label
      requirements.
- **Transferred to Plan 97:** Rebase on current `origin/main`, obtain required security review, pass the
      Windows/macOS/Linux hosted checks, create a focused PR, and squash merge
      only after `All required checks pass` is green.

## Acceptance Criteria

- **Transferred to Plan 97:** The originally reported state produces one accurate and executable
      recovery instruction rather than a cleanup command that necessarily
      refuses or silently fails.
- **Transferred to Plan 97:** No normal `run` invocation kills or drains an orphaned live component.
- **Transferred to Plan 97:** No stale record is deleted while its launcher, Agent endpoint, recorded
      Client, or exact exit evidence remains live.
- **Transferred to Plan 97:** Mismatched, ambiguous, cross-owned, source-attached, or unverifiable
      processes are never signaled.
- **Transferred to Plan 97:** A fully admitted recovery either completes and permits a subsequent
      managed `run`, or fails nonzero while preserving recoverable evidence.
- [x] The isolated live sequence succeeds with managed ownership throughout:
      `run all → restart agent → reload client → restart client → stop`, with
      Client control also covered by the local automated suite.
- [x] The primary runtime is not switched, stopped, or used as the test target.
- **Transferred to Plan 97:** Windows, macOS, and Linux CI pass without weakening POSIX behavior.

## Definition of Done

- **Transferred to Plan 97:** Root cause and rejected unsafe diff portions are documented in this plan.
- **Transferred to Plan 97:** Production code, tests, and owning documentation agree.
- **Transferred to Plan 97:** FVM analyzer and automated tests pass with bounded output.
- **Transferred to Plan 97:** Isolated lifecycle evidence satisfies G4 and leaves no runtime residue.
- **Transferred to Plan 97:** Security review and all required GitHub checks pass.
- **Transferred to Plan 97:** PR is squash-merged and the primary checkout is updated without losing
      unrelated local work.
