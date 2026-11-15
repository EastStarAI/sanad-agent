# Task 172 — Up-to-date merges instead of the merge queue

**Status:** active — documentation, skills, and the post-merge proof guard; the two
repository settings stay with the owner and are flipped after this change merges
**Owner:** `docs/operations/continuous_integration.md`, `docs/operations/community_governance.md`,
`.agents/skills/sanad-repository-maintainer/`, `.agents/skills/sanad-pull-request-lifecycle/`,
`scripts/ci/`, `.github/workflows/ci.yml` (comments only)
**Contract:** [docs/operations/continuous_integration.md](../../operations/continuous_integration.md),
[docs/operations/community_governance.md](../../operations/community_governance.md)
**Predecessor:** [task 167](167-ci-merge-release-speed-phase1.md) (post-merge complement run, item G2)
**Study:** `runs/ci-speed-phase2-design-20261110` (design section B and the Handoff "Item B")

## Goal

Replace the repository merge queue with **"require branches to be up to date"**
(strict) merges, and move the one guarantee the queue provided — a protected-label
re-check at merge time — into the merge agent's procedure. No CI job, lane, or
aggregate check is removed.

## Locked decisions and scope

1. **Required checks are unchanged.** One context, `All required checks pass`.
   Strict mode adds no context and removes none.
2. **Tested tree stays the merged tree.** Strict mode requires the pull-request
   head to contain the `main` tip. PR CI tests `refs/pull/N/merge`, whose tree
   equals the head tree exactly when the head contains the base, and a squash merge
   lands that head tree. That is the same guarantee the queue gave; the label
   re-check moves from the queue run to the merge agent.
3. **The queue stays dormant, not deleted.** `ci.yml` keeps its `merge_group:`
   trigger and its merge-group code paths so a rollback needs no workflow change.
   Only comments change in the workflow.
4. **Settings are the owner's.** This task delivers the procedure, the docs, and
   the guard; it does not call the settings API. The coordinator flips the two
   settings, in order, after this change merges.
5. **Out of scope:** candidate promotion on tag (item A, task 171), Workflows
   permissions, pull-request template changes, and any lane selection change.

## Gates

### G0 — Confirm the post-merge proof selector matches the design

- [x] Source (a) accepts a successful `merge_group` run whose `head_sha` equals the
      push SHA (`prove_from_merge_queue`).
- [x] Source (b) accepts the merged pull request's own final successful
      `pull_request` run only when all of these hold: the push commit resolves to
      exactly one pull request merged into `main`; that pull request is the only one
      the API associates with its head SHA; `tree(push) == tree(pull-request head)`;
      `push^1` is an ancestor of the pull-request head; and a successful
      `pull_request` run exists for that head SHA and head branch.
- [x] Anything else — no run, a failed run, a different tree, a non-ancestor
      parent, several pull requests, an unreadable API — leaves every lane enabled.
- [x] A job that the proof run skipped proves nothing; only a job that executed and
      succeeded marks its lane proven.
- [x] Fixture coverage for both sources and every mismatch, executed by a guard
      test rather than by hand.

### G1 — Guard the selector mechanically

- [x] `scripts/ci/test_post_merge_proof.sh` extracts the real selector functions
      and the real `push` caller out of `ci.yml`, runs them against JSON fixtures
      with a fake `gh`, and fails when the workflow shape moves.
- [x] `scripts/ci/fixtures/post_merge_proof/*.json` cover source (a), source (b),
      the ordering between them, and every mismatch listed in G0.
- [x] `agent/test/tool/ci_post_merge_proof_test.dart` asserts the selector's
      invariants directly on `ci.yml` and runs the fixture harness where `bash`
      and `jq` exist, so the guard runs in the Agent test lane.

### G2 — Rewrite the merge documentation

- [x] `docs/operations/continuous_integration.md` presents "Up-to-date merges" as
      the live model, keeps the queue procedure as a rollback appendix, and states
      the real live queue settings instead of the documented 1/1 that the live
      ruleset contradicts.
- [x] `docs/operations/community_governance.md` no longer describes a queue as the
      live merge path; the merge agent updates, re-verifies protected labels, and
      merges.
- [x] `.github/GOVERNANCE.md` states the same merge path.
- [x] `docs/llms.txt` and `docs/operations/MOC.md` point at the renamed page.

### G3 — Move the pre-merge obligations into the skills

- [x] `.agents/skills/sanad-repository-maintainer/SKILL.md` step 5 carries the
      ordered merge sequence, including the protected-label re-check before merge.
- [x] `.agents/skills/sanad-pull-request-lifecycle/SKILL.md` carries the pre-merge
      label re-check and the bounded `BEHIND` recovery loop.

### G4 — Keep the rollback path working

- [x] The `merge_group:` trigger and every merge-group code path remain in
      `ci.yml`; the surrounding comments describe them as the rollback path.
- [x] The rollback calls below are recorded here and in the CI doc.

### G5 — Verification and delivery

- [x] `LANG=en_US.UTF-8 ruby scripts/community/validate_governance.rb`.
- [x] `ruby scripts/community/simulate_workflows.rb` and
      `scripts/community/test_sync_labels.sh`.
- [x] `actionlint` on `.github/workflows/ci.yml` (no new findings).
- [x] `bash scripts/ci/test_post_merge_proof.sh` and
      `fvm dart test test/tool/ci_post_merge_proof_test.dart` in `agent/`.
- [x] `fvm dart analyze` in `agent/`.
- [x] One commit; pull request opened with the mandatory non-protected labels.

## Owner settings (B.1, exact order)

The owner or an authorized administrator runs these two calls in this order and
only after this change has merged. Strict mode goes on first, so there is never a
window in which neither guard is active.

```bash
# 1. Require the pull-request head to contain the current `main` tip.
gh api --method PATCH \
  repos/EastStarAI/sanad-agent/branches/main/protection/required_status_checks \
  --input - <<<'{"strict": true}'

# 2. Only once the merge queue is empty: disable the queue ruleset (id 26634537).
#    Disable it; do not delete it, so rollback is one call.
gh api --method PUT \
  repos/EastStarAI/sanad-agent/rulesets/26634537 \
  --input - <<<'{"enforcement": "disabled"}'
```

Postconditions to read back, not assume:

```bash
gh api repos/EastStarAI/sanad-agent/branches/main/protection \
  --jq '{strict: .required_status_checks.strict, contexts: .required_status_checks.contexts}'
gh api repos/EastStarAI/sanad-agent/rulesets/26634537 --jq '{id, name, enforcement}'
```

Unchanged: `All required checks pass` stays the single context, **Allow
auto-merge** stays enabled, squash stays the only merge method, conversation
resolution, admin enforcement, force-push and deletion blocks all stay.

## Rollback (B.7, exact order)

Re-enable the queue first, then drop strict mode, so the two guards overlap
instead of leaving a gap. No workflow change is needed because the `merge_group:`
trigger was kept.

```bash
# 1. Re-enable the queue ruleset.
gh api --method PUT \
  repos/EastStarAI/sanad-agent/rulesets/26634537 \
  --input - <<<'{"enforcement": "active"}'

# 2. Drop strict mode; the queue rebuilds each entry against current `main`.
gh api --method PATCH \
  repos/EastStarAI/sanad-agent/branches/main/protection/required_status_checks \
  --input - <<<'{"strict": false}'
```

Then set the queue's build concurrency and maximum group size to 1 so a queued
build still carries exactly one pull request (see the CI doc's rollback appendix),
and revert this change's documentation.

## Acceptance Criteria

- [x] Given a `push` to `main` that resolves to one merged pull request whose head
      tree equals the pushed tree and whose head contains the pushed commit's
      parent, when the merged pull request has a final successful `pull_request`
      run, then only the lanes that run executed are skipped.
- [x] Given the same push with a different tree, a non-ancestor parent, several
      pull requests, no successful run, or an unreadable API, then every lane runs.
- [x] Given a successful `merge_group` run for the pushed SHA, then it is preferred
      over the pull-request proof.
- [x] Given a proof run in which a lane's job was skipped, then that lane is not
      treated as proven.
- [x] Given the documented merge procedure, then branch freshness, the protected
      label re-check, and the aggregate check are all required before merge.
- [x] Given `main` moved after the reviewed run, then the merge is retried through
      `gh pr update-branch`, a fresh CI run, and at most three attempts.

## Definition of Done

- [x] Ownership documentation updated in the same change as the procedure.
- [x] The workflow keeps the dormant `merge_group:` rollback path.
- [x] The guard test and its fixtures fail when a selector invariant is dropped.
- [x] Every verification command above passes on the delivered commit.
