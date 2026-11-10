# Task 167 — CI merge and release speed, phase 1

**Status:** active — phase 1 scope locked; items 1–6 land as one commit each in a single branch
**Owner:** `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/actions/apt-install/`, `scripts/ci/lane_inputs.txt`
**Contract:** [docs/operations/continuous_integration.md](../../operations/continuous_integration.md), [docs/operations/release_and_signing.md](../../operations/release_and_signing.md)
**Predecessor:** task 146-era study `runs/ci-merge-release-speed-study-20261110` (study + independent review)

## Goal

Cut the two measured wastes in the merge → release path without removing a single
test that runs before `main` or before a release: the unbounded package install
that can eat a whole job budget, the post-merge re-run of lanes the merge queue
already proved on the same commit, unenforced macOS coverage at the release
boundary, over-broad lane triggers, and cancellable protected release runs.

## Locked decisions and scope

1. **Guardrail first.** No test that runs today before `main` or before a release
   may stop running. The only relaxation approved is per-pull-request lane
   selection (item 4): the skipped lanes still run on the merged commit through
   the complement run (item 2) and before a release through the release gate
   (item 3).
2. **Anomaly-free numbers only.** Expected savings are quoted from the reviewed
   study with the explicit infrastructure-anomaly rule applied; the 19m49s apt
   stall and the 15m01s runner-loss attempts are excluded from medians.
3. **Evidence before claims.** Every item states why it cannot lose coverage, in
   the commit message body as well as here.
4. **In scope:** bounded package installs, the post-merge complement run, the
   release gate on the macOS full suite, narrow change-based lane gating plus the
   classifier holes, two dictation tests added to the per-OS native lane, and
   protected-run concurrency in `release.yml`.
5. **Out of scope:** candidate promotion on tag, dropping the merge queue,
   FVM activation, paid macOS runners, and the Xcode/Flutter build cache. Those
   remain study items with open decisions.
6. **Timing constraint.** No push and no pull request while the v1.0.23 release
   gate is open: a pushed workflow branch with an open pull request starts macOS
   jobs and competes with the release for the account-wide macOS runner cap.

## Gates

### G0 — Discovery

- [x] Read the reviewed study and the anomaly-cleaned numbers.
- [x] Confirm every `apt-get` call site in `ci.yml` and `release.yml`.
- [x] Confirm the merge-group → push identity claim (same commit, 46/46).
- [x] Confirm task number 167 is free on `main` and in open pull requests.
- [x] Confirm the two dictation test files pass with `SANAD_STT_REQUIRE_NATIVE=1`.

### G1 — Bounded package installs

- [x] Add `.github/actions/apt-install` with bounded acquire timeouts, a bounded
      retry/backoff, and a `skip-if-command` fast path.
- [x] Replace all five `apt-get` call sites (three in `ci.yml`, two in
      `release.yml`) with the action and a per-step `timeout-minutes`.
- [x] Keep the disassembler no-op behaviour and the package sets unchanged.
- [x] Document the policy in the CI doc.

### G2 — Post-merge complement run

- [x] Classify per lane instead of per component on `push` to `main`.
- [x] Find the successful `merge_group` run for the identical commit and skip
      exactly the lanes it proved; run everything when no such run exists.
- [x] Keep the post-merge-only work (branch history, credential scan, protected
      labels) always running.
- [x] Document the rule in the workflow comments and the CI doc.

### G3 — Release gate on the macOS full suite

- [x] Query `macOS full suite` by `head_sha` in `release.yml` `validate`.
- [x] Fail closed for tagged and publishing runs when the suite is missing,
      failed, cancelled, or still running.
- [x] Report without failing for `validation_only` runs.
- [x] Document the gate in the release doc and the CI doc.

### G4 — Narrow change-based gating and classifier holes

- [x] Declare one input set per gated lane in `scripts/ci/lane_inputs.txt`.
- [x] Gate `Native dictation` and `sanad-dev bootstrap` by their declared inputs.
- [x] Close the listed classifier holes (workflow edits, `shared/**`,
      `scripts/sanad_dev/**`, `shared/public_service_endpoints/**`).
- [x] Keep every always-run trigger (workflows, actions, `scripts/ci`, `.fvmrc`,
      pubspecs, `agent/native/**`, `shared/**`, release) and the fail-closed
      fallback.
- [x] Add the guard test that fails when the Dart closure outgrows a lane's
      declared inputs.
- [x] Do not gate `CLI automation`.

### G5 — Dictation tests on the native lane

- [x] Add `test/stt/stt_digest_test.dart` and
      `test/stt/stt_download_pipeline_test.dart` to `Native dictation`.
- [x] Run them sequentially so the in-process timing ratio is not measured under
      CPU contention.
- [x] Record the measured cost locally and estimate it per OS.

### G6 — Protected release concurrency

- [x] Cancel only superseded `workflow_dispatch` + `validation_only` runs.
- [x] Separate the concurrency group so a validation run can never cancel a
      tagged or publishing run.
- [x] Document the policy in the release doc.

### G7 — Verification and delivery

- [x] `actionlint` clean for every changed workflow (no new findings against the
      baseline).
- [x] Repository governance and workflow-contract scripts pass.
- [x] Agent analyzer passes; the new guard test passes.
- [x] Docs updated in the same change as the behaviour.
- [x] One commit per item with its guardrail statement; no push until the
      coordinator releases the timing hold.

## Acceptance Criteria

- [x] Given a stalled Ubuntu mirror, when the dependency install runs, then the
      lane fails within its step timeout instead of consuming the job budget, and
      a transient failure recovers inside the same step.
- [x] Given a merge that fast-forwarded `main` to a commit the merge queue already
      proved, when the `push` run classifies, then only the lanes that run did not
      prove execute, and every post-merge-only job still executes.
- [x] Given a tagged run without a green `macOS full suite` on that commit, when
      `validate` finishes, then no Draft or publication step can run.
- [x] Given a documentation-only change, when classification finishes, then
      `Native dictation` and `sanad-dev bootstrap` do not run; given a change to
      their declared inputs, then they do.
- [x] Given a `.github/workflows/*` change, when classification finishes, then
      every lane runs.
- [x] Given two concurrent `validation_only` dispatches, when the second starts,
      then the first is cancelled; given a tagged run, when any dispatch starts,
      then the tagged run is never cancelled.

## Definition of Done

- [x] `actionlint` on every changed workflow.
- [x] `LANG=en_US.UTF-8 ruby scripts/community/validate_governance.rb` and
      `ruby scripts/community/simulate_workflows.rb`.
- [x] `fvm dart analyze` in `agent/` and the new guard test.
- [x] CI doc, release doc, and the QA measurement record updated.
- [x] Six commits with their guardrail statements; worktree removed after the
      branch is delivered.

## Current status

G0–G6 complete. G7 (verification and delivery) is open; delivery stays on hold until the timing
constraint is lifted.
