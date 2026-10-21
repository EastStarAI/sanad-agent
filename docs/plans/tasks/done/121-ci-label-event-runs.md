---
id: 121
title: One CI run per pull request — label events must not rerun the full Public CI
status: completed
created: 2026-10-21
delivery: own PR from fix/121-ci-label-event-runs
---

# Task 121 — One CI Run per Pull Request

## Problem

PR 229 showed 9 Public CI runs within 15 seconds. The cause was verified from `.github/workflows/ci.yml` and the run list:

- `pull_request` triggers on `opened, synchronize, reopened, labeled, unlabeled, ready_for_review`.
- GitHub sends one `labeled` event per label, even when `gh pr create --label a,b,c` applies all of them in one call. A new PR with 7 labels therefore starts 8 full runs: `opened` plus seven `labeled`.
- Concurrency is `ci-${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true`. Every label event cancels the in-progress full run and restarts it. A label added mid-run throws away the real CI work, and the run list looks stuck while cancellations propagate.

## Why label events exist

The `sensitive-review` job ("Verify protected review labels") checks the protected labels `maintainer-reviewed`, `security-reviewed` and `release-reviewed` against the changed paths. Adding a protected label must re-evaluate that check, and therefore the required aggregate `All required checks pass`.

## Goal

Adding or removing an ordinary label (`type/*`, `comp/*`, `platform/*`, `size/*`, etc.) does not cancel or rerun the full CI. Code changes (`opened`, `synchronize`, `reopened`, `ready_for_review`) behave exactly as today. Protected-label changes still re-verify protection correctly.

## Boundaries

- **Never weaken the required check.**
  - A run started only by a label event must never make `All required checks pass` succeed without the full checks for the current head SHA having passed.
  - GitHub treats a skipped required job as passing. Design against that explicitly; for example, do not let a label-only run publish a success for the required context unless the full result for that SHA is known to be green.
  - Prove this with reasoning and evidence in the PR.
- No secrets, no new permissions beyond what is needed (read `contents`/`actions`/`checks` only if necessary), and no `pull_request_target`.
- Keep the change minimal and inside `.github/workflows/`. If behaviour changes, update the owning CI documentation (e.g. `docs/operations/` or `.github` docs).
- `.github/` changes require the protected label `maintainer-reviewed` (from `ci.yml` `sensitive-review`). Its application is user-authorized only.

## Design Note

### GitHub behaviour relied on

- **Label payload.** A `pull_request` event with action `labeled` or `unlabeled` carries the changed `label` object and the full `pull_request` object ([webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads#pull_request)). One event is sent per label, so `github.event.label.name` identifies exactly the label that changed.
- **Skipped means green.** "A job that is skipped will report its status as Success. It will not prevent a pull request from merging, even if it is a required check" ([using conditions to control job execution](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/using-conditions-to-control-job-execution)). Required-check troubleshooting lists `success`, `skipped` and `neutral` as passing states and requires checks on the latest commit SHA.
- **Same-name check runs.** The live protection requires the context `All required checks pass` from app id 15368 (GitHub Actions). Any workflow in this repository can emit that name. GitHub does not document how several same-name check runs on one SHA combine, so this design assumes the worst case: the most recent same-name check run on the head SHA decides.
- **Concurrency.** A new run cancels a pending run in the same group; `cancel-in-progress: true` also cancels the running one. The group expression may use the `github` context ([workflow syntax](https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions#concurrency)).
- **Re-runs.** `POST /repos/{owner}/{repo}/actions/jobs/{job_id}/rerun` will "Re-run a job and its dependent jobs in a workflow run" ([workflow runs REST API](https://docs.github.com/en/rest/actions/workflow-runs)). A re-run reuses the original `GITHUB_SHA`, `GITHUB_REF` and event, and the original actor's privileges ([re-running workflows and jobs](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/re-running-workflows-and-jobs)). The jobs that are not re-run keep their prior results for `needs`.
- **Fork tokens.** For `pull_request` from forks, write permissions are reduced to read-only.

### Options considered

1. **Job-level `if` on `github.event.label.name` inside `ci.yml` (option a).** Rejected. Ordinary-label runs would still produce a `All required checks pass` check run for the head SHA. If it is skipped, it reports success and, as the newest same-name check, can mask a failing or unfinished code run. That breaks the safety property. If it runs and fails, it blocks merge. A separate concurrency group stops the cancellation, but either outcome still breaks something. A job cannot be removed from a run conditionally.
2. **Separate label concurrency group plus an aggregate that queries the code run's result via the API.** Rejected. It would duplicate the aggregate logic, need `checks`/`actions` read access, and depend on undocumented same-name ordering in both directions.
3. **Split label workflow that re-runs the protected-label job of the code run (option b). Chosen.**

### Chosen design

- `ci.yml` drops `labeled` and `unlabeled`. Its triggers are `opened`, `synchronize`, `reopened` and `ready_for_review` (plus `push` to `main` and `workflow_dispatch`, unchanged). Its concurrency group and every job are otherwise unchanged.
- `sensitive-review` reads the labels at run time with `gh api repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER`. It is granted job-scoped `contents: read` and `pull-requests: read`. A re-run would otherwise see the stale payload labels. An API failure fails the job closed.
- The new `.github/workflows/protected-labels.yml` (`Protected label review`) listens to `labeled` and `unlabeled`:
  - Its single job `Re-verify protected review labels` runs only for open PRs whose changed label is `maintainer-reviewed`, `security-reviewed` or `release-reviewed`. For ordinary labels it is skipped, no runner is used, and it reports success under its own, non-required name.
  - It resolves the PR's current head SHA, waits (bounded, 30 s poll, 80 min limit) for the newest `pull_request` Public CI run on that SHA to complete, and exits quietly if the head moved meanwhile. It then re-runs that run's `Verify protected review labels` job through the job re-run endpoint. GitHub re-runs the dependent `All required checks pass` job, which reuses every other job's result from the same run.
  - Permissions are `actions: write` (re-run) and `pull-requests: read` (head SHA). There is no checkout, no secret and no `contents` access.
  - Concurrency: protected-label events of one PR share a group with `cancel-in-progress`, so the newest one wins (it re-reads all labels anyway). Ordinary-label events get a unique group, so they cannot cancel anything.
- `scripts/community/validate_governance.rb` now asserts:
  - `ci.yml` has no label triggers and reads labels at run time;
  - the label workflow re-runs `Verify protected review labels`;
  - the label workflow never declares a job named `All required checks pass`;
  - the three protected labels are wired into both workflows.

### Safety argument

The only producer of the required context is the `all-required` job in `ci.yml`. Its logic is unchanged: it fails unless `classify`, `history` and `sensitive-review` succeeded and every lane succeeded or was skipped by the classifier.

1. **Ordinary label event.** `ci.yml` is not triggered at all. The label workflow job is skipped, but its name is not `All required checks pass`, so it cannot satisfy or overwrite the required context. The code run is neither cancelled nor restarted.
2. **Protected label event.** No new `ci.yml` run is created. The only effect is a re-run of `sensitive-review` and its dependent `all-required` inside the existing code run for the current head SHA. GitHub pins a re-run to that run's SHA. The re-run aggregate is green only if that same run's full lanes were green and the current labels satisfy the protected paths. A failed, cancelled or still-running code run cannot be turned green: the label workflow waits for completion, and a failed or cancelled prior job keeps its result in `needs`.
3. **Protected label removed after a green run.** This re-runs `sensitive-review` with the current labels, so the aggregate turns red. Merely deleting the label trigger from `ci.yml` without this workflow would have left a stale green.
4. **Push during the wait.** The new code run reads current labels itself. The label workflow sees the head moved and stops. Re-running an older SHA could not satisfy protection anyway, because required checks apply to the latest SHA.

### Residual risks

- **Fork PRs.** Their token is read-only, so the automatic re-run fails with a clear error. A maintainer must re-run `Verify protected review labels` (or `gh run rerun --failed`) after applying a protected label. This is safe: it fails closed, never open.
- **Untested `GITHUB_TOKEN` re-run.** A job re-run through `GITHUB_TOKEN` is not a new event, so the "no recursive runs" rule should not block it. This is only proven once the live verification passes.
- **Visible label runs.** Each label still creates one `Protected label review` run in the Actions list; ordinary ones are skipped immediately.
- **Pre-existing, unchanged:** `workflow_dispatch` on a PR branch skips the protected-label step and could produce a green aggregate for that SHA. This is out of scope here and should be tracked separately.

## Gates

- [x] Design note in this file: the options considered (job-level `if` on `github.event.label.name`, a separate concurrency group for label events, a split label workflow) and the chosen one, with the required-check safety argument.
- [x] Implementation, with workflow lint (`actionlint` if available) and any repo workflow-guard tests passing. `validate_governance.rb`, `test_sync_labels.sh` and the YAML parse pass; `actionlint` is not installed locally.
- [x] Coordinator review.
- [x] Live proof on PR 230 (head `991ea56`):
  - adding several ordinary labels starts no full rerun and does not cancel the code run: creation with three labels gave one Public CI run (`39561307075`) plus three skipped `Protected label review` runs, and `comp/docs` added mid-run gave only the skipped run `39561363243`, with `39561307075` completing at attempt 1;
  - adding a protected label re-verifies: `maintainer-reviewed` triggered `Protected label review` run `39561903632`, which re-ran `Verify protected review labels` and `All required checks pass` as attempt 2 of `39561307075` through `GITHUB_TOKEN`, both green, while every other job kept its attempt-1 result;
  - one push gives one full run: proven by the push of this completion commit (one `synchronize` Public CI run, no label-workflow run).
- [ ] Merge under the user's authorization, plus the `maintainer-reviewed` label authorization. `maintainer-reviewed` is applied; the merge is the squash of PR 230.

## Delivery

- Candidate committed on `fix/121-ci-label-event-runs` and merged with `origin/main` (`2286267a`). `ci.yml` keeps the new `Validate shipped model capability defaults` step from main together with this task's trigger, permission and run-time label changes.
- Local verification after the merge: `scripts/community/validate_governance.rb` passes, `scripts/community/test_sync_labels.sh` passes, and `ci.yml`, `protected-labels.yml` and `release.yml` parse as YAML. `actionlint` is not installed locally.
- The PR is created once with all its ordinary labels, and its own events serve as the live proof: one Public CI run for the head SHA, an ordinary label added mid-run starts or cancels nothing, and the authorized `maintainer-reviewed` label re-runs only `Verify protected review labels` and `All required checks pass` as a new attempt of the same run.
