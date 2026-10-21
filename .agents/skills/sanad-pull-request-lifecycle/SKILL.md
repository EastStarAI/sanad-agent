---
name: Sanad Pull Request Lifecycle
description: Prepare and deliver a focused Sanad pull request through an isolated worktree, bounded verification, CI repair, protected review, and squash merge. Use this skill for ordinary PR delivery and whenever the user asks to prepare, cut, create, publish, or ship a Sanad RC or Stable release.
---

# Sanad Pull Request Lifecycle

Use this skill after work is accepted and scoped. It may prepare local changes and a review handoff, but it must not push, merge, close an Issue, delete a branch, or mutate repository settings without explicit authorization.

## Delegated Gate Flow

In the delegated three-role workflow, open a **Draft PR after the first accepted gate** so CI runs on every push. Draft-to-Ready conversion, merge, and protected labels remain authorization boundaries unless the brief granted them up front. Mandatory `type/*` and `comp/*` labels are never deferred to review or to merge time.

## Label Gate

An unlabeled pull request is an incomplete deliverable, not a cosmetic gap: without `type/*` and `comp/*` the change cannot be triaged, routed, or reviewed by category, and the protected-label CI job proves nothing about them.

1. Read `.github/labels.yml` before classifying, and never apply a label that is absent from the manifest.
2. Derive the labels from the complete changed-path list (`gh pr diff --name-only`), not from the pull-request summary or from the Issue it closes.
3. Apply the mandatory minimum: exactly one `type/*` and at least one `comp/*`. Add `platform/*` only for platform-specific behavior and a `size/*` entry when the size is material.
4. Apply non-protected labels with `gh pr edit <number> --add-label "<label>,<label>"`, then verify the applied set with `gh pr view <number> --json labels`. Re-verify before handoff whenever later commits change the diff, and repair the set in the same session.
5. `All required checks pass` is never label evidence: the `Verify protected review labels` job checks protected labels only, so a green run can coexist with a pull request that carries no `type/*` or `comp/*` label.

## Prepare

1. Confirm the owning Issue or plan, acceptance criteria, dependencies, and required protected-review labels.
2. Search for an existing branch or pull request before creating another.
3. Use an isolated worktree for parallel, broad, risky, or review-bound work. Follow the repository's worktree runtime and FVM contracts.
4. Read the closest `AGENTS.md` before editing and update owning documentation in the same change.

## Implement and Verify

1. Keep the diff focused and reusable; do not mix unrelated cleanup.
2. Add focused tests and run the affected analyzer. Keep verification output bounded while preserving exit status.
3. Review the full diff and scan for secrets, personal paths, private infrastructure, generated output, and dependency changes.
4. Update the owning task checklist and evidence only after verification. When a task or plan is completed as part of the PR, move its file via `git mv` (task plan from `docs/plans/tasks/<name>.md` to `docs/plans/tasks/done/<name>.md`, or roadmap/major plan from `docs/plans/<name>.md` to `docs/plans/done/<name>.md`) and include the file relocation in the PR commit.
5. Use a Conventional Commits pull-request title. The human PR will be squash merged, so the title must describe the final commit.
6. Write the pull request with Problem/Goal, linked `Closes #...`, Changes, Verification, risk, cross-platform impact, documentation, and rollback.
7. Apply the mandatory labels before creating the pull request, following the Label Gate above: exactly one `type/*` and at least one `comp/*`, plus `platform/*` only when the scope is platform-specific and `size/*` when the size is material. For any required protected positive-review label (`maintainer-reviewed`, `security-reviewed`, or `release-reviewed`), report why it is required and ask the responsible maintainer for explicit authorization after presenting the review evidence; never add a protected label merely to make CI pass. If authorization is withheld or unavailable, leave the label absent and report the merge blocker.

## Release Delivery Route

When the request is for an RC or Stable release, read and follow
[references/release-delivery.md](references/release-delivery.md). A direct
request for an exact release or the unambiguous next Stable release supplies the
bounded commit/push/PR/merge/tag authorization defined there; it never supplies
the final publication approval. Keep ordinary PR invocations on this main file
so they do not load release-only procedure tokens.

## CI Repair Loop

1. Inspect the first failing affected job and its bounded evidence.
2. Fix the root cause; never hide a failure by weakening a check or marking an affected lane skipped.
3. Repeat focused local verification before updating the review branch.
4. Stop after a bounded repair loop and report the unresolved blocker rather than churning.
5. Fork-origin jobs must work without signing, deployment, or repository secrets.

When waiting for GitHub CI checks, never perform manual periodic polling loops in the conversation. Instead, run a single terminal command that watches the checks until completion and wait for its result. Use `gh pr checks` with `--watch`, `--interval 5`, and `--fail-fast` (specifying `timeout_ms: 420000` in `shell_execute` for a cross-platform 7-minute timeout guard):

```bash
gh pr checks <pr-number> --watch --interval 5 --fail-fast
```

Alternatively, use the repository's bounded monitor:

```bash
fvm dart run scripts/workflow_guards/bin/pr_checks_watch.dart <pr-number>
```

`pr_checks_watch.dart` polls `gh pr checks --json` every 5 seconds, stops on the first failed check (fail-fast), enforces a 7-minute maximum, prints bounded per-poll summaries, and preserves its exit status (0 success, 1 first failure, 124 timeout). It is Windows-safe (no `for /f` parsing) and cross-platform; see `scripts/workflow_guards/README.md` for flags and exit codes.

## Merge, Rebase, and Conflict Safety

Resolving a conflict must be fail-closed, especially on Windows where transient `cmd` quoting/expansion can corrupt a resolved file:

1. Prefer an explicit three-way reconstruction when the merge driver is ambiguous. With both trees staged, extract the stages and rebuild the file deterministically:
   - base: `git show :1:<path>`
   - ours (HEAD / target): `git show :2:<path>`
   - theirs (incoming / feature): `git show :3:<path>`
   Then resolve into the working tree using explicit argument arrays or tracked tooling; never pipe a resolved file through hand-built `for /f` or quoted `cmd` one-liners.
2. Before staging a resolved file, run the reusable validation gate:

   ```bash
   fvm dart run scripts/workflow_guards/bin/merge_validate.dart <resolved-file>...
   ```

   It rejects leftover conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) and corrupt JSON/JSONL syntax, and exits nonzero (3 markers, 4 syntax, 2 usage/missing) so `git add` refuses a corrupt file.
3. Re-run the focused syntax check or affected tests for the resolved file before staging: analyzer for Dart, `flutter test`/`dart test` for behavior, strict JSON parse for data files.
4. Never `git add` (or force-commit) a file with markers or syntax corruption; reconstruct and re-validate instead.

No broad merge framework is introduced here: these are the smallest fail-closed guards with regression coverage.

## Pre-Merge Handoff

Before merge, update the branch from current `main`, inspect the complete resulting diff, rerun affected checks, resolve review conversations, and confirm the mandatory non-protected label set (exactly one `type/*`, at least one `comp/*`, plus any `platform/*` or `size/*` that reflects the change) together with the protected labels and `All required checks pass`. Preserve human attribution through Git authorship, appropriate `Co-authored-by` trailers, and release notes.

Squash merge only after the required human decision. Then verify the final commit and linked Issue state, and delete the branch only when authorized. No lifecycle step that merges, closes work, or changes protection may run without explicit authorization.
