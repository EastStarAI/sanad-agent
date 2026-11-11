# Task 170 — Promote the validated release candidate on tag

**Status:** active — item A of CI speed phase 2; one reviewed change on one branch
**Owner:** `.github/workflows/release.yml`, `.github/workflows/ci.yml` (`release-security`), `scripts/release/`
**Contract:** [docs/operations/release_and_signing.md](../../operations/release_and_signing.md), [docs/qa_maintenance/release_verification.md](../../qa_maintenance/release_verification.md)
**Design:** `runs/ci-speed-phase2-design-20261110/DESIGN.md` section A (owner approved decisions 1–3)
**Predecessor:** [167-ci-merge-release-speed-phase1.md](167-ci-merge-release-speed-phase1.md) (merged as PR #405)

## Goal

Publish, on a `v*` tag, the exact bytes a `workflow_dispatch` validation run on
`main` already built, signed, notarized, tested, manifested, SBOM-ed and
attested — instead of rebuilding all of them in the tag run. The published bytes
then equal the bytes that were proved, and the tag run stops spending about
11–12 minutes (about 20 when macOS runners are busy) and four macOS jobs on a
second build.

## Locked decisions and scope

1. **Publish candidate bytes.** The tag run re-uploads the verified candidate
   into its own run under the same artifact name, so `draft`, `client-download-aliases`
   and `deploy.yml` keep reading one artifact from `github.run_id`.
2. **Attestations keep naming the `main` dispatch run.** No new attestation is
   produced on tag; the public verification command is documented.
3. **Rollout is a repository variable**, `RELEASE_CANDIDATE_PROMOTION`:
   `enabled` promotes, `shadow` verifies and reports but always rebuilds, and
   unset or any other value skips selection entirely. Unsetting it is the
   instant rollback.
4. **Fail closed.** Selection and verification are one script; every check that
   cannot be proved ends in a non-zero exit and the ordinary rebuild path. No
   path publishes an unverified byte, and `shadow` can never change what is
   published.
5. **Nothing is lost.** `validate` (contract, tag == SHA, refuse an existing
   release, macOS full-suite gate), `draft` `--verify-tag`, the single
   `release-publication` approval, alias verification and every `deploy.yml`
   check still run. In promote mode only `agent`, `client-*` and `assemble` are
   skipped, because those bytes already exist and are bound to the same commit
   by attestation.
6. **Out of scope:** item B (merge queue → up-to-date merges), any change to
   `deploy.yml`, any live repository-variable change, and any live tag.

## Gates

### G0 — Discovery

- [x] Re-locate every `release.yml` and `ci.yml` anchor by job and step name;
      phase 1 moved all the line numbers the design quoted.
- [x] Confirm the real API job names from a tag run: `agent (…)` for the five
      matrix lanes, plain `validate`, `client-*`, `assemble`.
- [x] Confirm `gh attestation verify --format json` carries the producing run at
      `.verificationResult.statement.predicate.runDetails.metadata.invocationId`
      (the design's `runInvocationURI` name does not exist in gh 2.82.1).
- [x] Confirm a dual-attested file (candidate `refs/heads/main` plus tag) still
      passes `--source-ref refs/heads/main`, so promotion never wedges itself.
- [x] Confirm `assemble` merges the private iOS IPA into `dist`, so the
      "no unlisted file" rule must accept contract artifacts that are not public.

### G1 — Selector and verifier script

- [x] `scripts/release/promote_release_candidate.sh` with `select`, `verify` and
      the pure `verdict` decision, using only `gh`, `jq`, `sha256sum`, `fvm`.
- [x] Selection rules 1–4 (newest-first, at most 3; run identity; latest-attempt
      job conclusions; unexpired artifact with more than 1 h remaining).
- [x] Verification rules 1–4 (manifest identity; `verify-manifest`;
      `sha256sum -c --strict` plus a bounded file set; attestation per attested
      subject pinned to workflow, ref, commit, run and hosted runners).

### G2 — Workflow wiring

- [x] `release.yml`: `RELEASE_CANDIDATE_PROMOTION` env, the `candidate` job,
      promote-mode re-upload, and the `needs`/`if` edits on `agent`, the
      `client-*` jobs, `assemble`, `draft`, `publish`, `client-download-aliases`
      and `production-assets`, each with explicit `!cancelled()` and result
      checks so a skipped ancestor cannot silently skip publication.

### G3 — Fixture coverage

- [x] `scripts/release/test_promote_release_candidate.sh` and
      `scripts/release/fixtures/promote/` cover every case in design A.6 step 1
      with a fake `gh` on `PATH`.

### G4 — Contract guards and documentation

- [x] `ci.yml` `release-security`: the draft-condition grep, the new pinned-flag
      greps, and the new test script.
- [x] `docs/operations/release_and_signing.md`,
      `docs/qa_maintenance/release_verification.md` and
      `.agents/skills/sanad-pull-request-lifecycle/references/release-delivery.md`.

## Acceptance Criteria

- [x] Every A.6 case has a fixture case; the happy path prints `promote` and
      every other case prints the named rebuild reason.
- [x] `select` never returns a run whose latest attempt has a non-success job,
      whose `head_sha`/branch/event/repository/path/workflow differ, or whose
      candidate artifact is missing, duplicated, expired or under 1 h from
      expiry.
- [x] `verify` rejects a manifest with any of tag, channel, commit, version or
      build different from the tag run, a flipped byte, an extra file, a failed
      attestation and an attestation naming another run.
- [x] `verdict` maps `enabled` to `promote` only when selection **and**
      verification succeed, maps `shadow` to `would-promote` with mode
      `rebuild`, and maps unset/unknown to `skipped` with mode `rebuild`.
- [x] `actionlint` is clean, `ruby scripts/community/validate_governance.rb`
      passes under `LANG=en_US.UTF-8`, and the `release-security` grep block runs
      green locally.
- [x] `deploy.yml` is untouched.

## Definition of Done

- [x] Focused verification: the new fixture script, `actionlint` on both
      workflows, the governance validator, a local run of the `release-security`
      step body, and `shellcheck` on both new scripts.
- [x] Documentation updated in this change (release operations, release
      verification, release-delivery reference).
- [x] Pull request opened with `type/performance` and `comp/ci-release`; the
      protected labels `maintainer-reviewed` and `release-reviewed` stay with the
      coordinator.
- [x] Live rollout steps reported, not executed: `shadow`, then `enabled` on an
      RC, then Stable.

## Current status

Gates G0–G4 are implemented and locally verified. The pull request is open and
awaits CI plus independent security review of the selector. No tag, release,
repository variable or Environment was changed by this task.

## Rollout and rollback

1. Merge the pull request.
2. Set the repository variable `RELEASE_CANDIDATE_PROMOTION=shadow` and cut the
   next release. The `candidate` job must report `would-promote` in its step
   summary and the tag run must still publish its own build.
3. Set `RELEASE_CANDIDATE_PROMOTION=enabled` for the next RC tag. The tag run
   must show `agent` and every `client-*` job skipped, `candidate` and `assemble`
   as before, and one approval on `release-publication`.
4. Keep `enabled` for the following Stable tag.
5. Roll back by deleting the variable: no pull request, no workflow change. A
   failed promotion never needs a rollback because the tag run either rebuilds
   or fails before the Draft exists.
