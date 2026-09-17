---
title: "Automated Release Preparation and Single Final Publication Approval"
description: "Reduce each future release to one skill invocation that prepares and merges a deterministic metadata PR, starts the immutable release build, and requests one final publication approval only after the complete candidate succeeds."
status: "implementation"
priority: "critical"
current_gate: "G5"
remaining_estimate: "5% (post-merge live activation)"
design_contract: "docs/operations/release_and_signing.md"
qa_contract: "docs/qa_maintenance/release_verification.md"
---

# Automated Release Preparation and Single Final Publication Approval

## Goal

A maintainer can request a new Sanad release through the existing repository
`Sanad Pull Request Lifecycle` skill. Its release reference derives and reviews
the release content, runs one deterministic command to
update every mechanical version surface, opens and merges a narrowly validated
metadata-only pull request, creates the immutable tag, waits for the complete
signed candidate, and then asks the maintainer for exactly one final publication
approval. Stable Production assets deploy automatically after that approval.

## Locked decisions and scope

- `release-publication` remains the only human approval that publishes artifacts
  or deploys Stable Production assets.
- Signing Environments remain separate secret/ref boundaries without reviewers.
- The preparation command owns every mechanical version/build edit currently
  repeated across package metadata, lockfiles, native Windows metadata, the
  release contract, artifact filenames, and the current-release documentation
  sentence.
- Release highlights and changelog wording remain authored from reviewed Git
  history by the PR Lifecycle release reference; deterministic validation rejects
  stale identity or unfinished placeholders.
- Release orchestration extends the existing `Sanad Pull Request Lifecycle`
  skill through an on-demand reference rather than adding another top-level
  skill. Ordinary PR work therefore loads only the short routing paragraph.
- A release-preparation PR may omit `release-reviewed` only when a fail-closed
  diff validator proves it is metadata-only and every mechanical release surface
  matches the generated contract. Workflow, signing, installer logic, scripts,
  or any unrelated path continue to require protected human review.
- Invoking the PR Lifecycle release route with an explicit target version or an
  unambiguous request for the next Stable release authorizes its bounded branch,
  commit,
  push, PR, squash-merge, and immutable tag operations. The latter increments
  patch and build by one. It does not authorize publication; the skill must
  request that final decision after all prerequisite jobs succeed.
- No Environment, secret, branch/tag restriction, signing policy, or Production
  deployment boundary is weakened.

## Gates

### G0 — Discovery and release-surface inventory

- [x] Create an isolated worktree from current `origin/main`.
- [x] Compare the two latest release-preparation commits and inventory all 11
      repeatedly changed files.
- [x] Identify the protected `release-reviewed` label as the current extra human
      decision that conflicts with the requested one-approval flow.

**Evidence:** releases `1.0.5` and `1.0.6` changed the same package, lockfile,
native Windows, contract, notes, changelog, and architecture-document surfaces.

### G1 — Deterministic release preparation

- [x] Add one FVM-managed Dart command that validates monotonic version/build
      input and updates all mechanical release identity surfaces atomically.
- [x] Add a check mode that rejects stale package/native/contract/docs/notes
      identity and unfinished changelog or release-note placeholders.
- [x] Add focused tests for a successful bump, invalid/non-increasing input,
      stale surfaces, and no partial mutation on validation failure.

### G2 — Safe metadata-only PR path

- [x] Add a fail-closed diff validator with an exact path and changed-line
      allowlist for generated release-preparation PRs.
- [x] Let protected-review CI waive `release-reviewed` only when that validator
      passes; retain normal review for every broader release change.
- [x] Replace version-specific workflow input help text with a durable format.

### G3 — Release orchestration skill

- [x] Add a release-delivery reference to the existing PR Lifecycle skill that
      discovers the prior Stable tag, derives release notes from merged history,
      invokes the preparation command, and performs bounded local/CI verification.
- [x] Define the authorized PR/merge/tag flow, bounded polling, failure stop
      conditions, and the single final `release-publication` approval request.
- [x] Require post-publication verification of Release state, manifest/tag/source
      identity, and automatic Stable asset deployment.

### G4 — Documentation and final verification

- [x] Update release architecture and QA contracts with the command, metadata-only
      exception, skill handoff, and single-approval evidence.
- [x] Run formatting, analyzers, focused tests, shell/YAML checks, and secret/path
      review with bounded output.
- [x] Run `graphify update .`, review the complete diff, and record evidence.

**Evidence:** Agent and Client analyzers passed; four focused Dart tests passed;
the shell validator fixture and historical `1.0.6` metadata-only diff passed;
forbidden-line and unrelated-path cases failed closed; governance validation,
workflow YAML parsing, `check-preparation`, CLI fixture preparation, bundled
skills validation, diff checks, and Graphify update passed.

### G5 — One-time post-merge Environment activation

- [ ] Merge this reviewed implementation before changing live Environment rules.
- [ ] With separate explicit administrative authorization, remove required
      reviewers only from the four signing Environments.
- [ ] Re-query all six Environments and prove signing plus
      `client-downloads-production` have zero reviewers, `release-publication`
      retains the owner reviewer, and custom ref policies are unchanged.
- [ ] Create no release tag until that postcondition passes.

**Current live evidence (read-only, 2026-09-02):** all four signing Environments
still report one required reviewer; `release-publication` reports one and
`client-downloads-production` reports zero. All six currently expose the custom
policies `main` and `v*`; those are the post-activation comparison baseline. The
PR Lifecycle release route therefore fails closed until this one-time activation
is completed after merge.

## Acceptance criteria

- [x] Given a clean checkout at version `X` and build `N`, when preparation runs
      for version `Y` and build `N+1`, then every mechanical identity file equals
      `Y`/`N+1` and a second check run reports no drift.
- [x] Given invalid, equal, or lower version/build input, preparation fails before
      changing any file.
- [x] Given a PR containing only the generated identity changes plus release notes
      and changelog, protected-review CI accepts the metadata-only exception.
- [x] Given any changed workflow/script/signing logic, unrelated path, or
      non-version line in a native/contract file, the exception fails and
      `release-reviewed` remains required.
- [ ] Given successful merged preparation and complete candidate builds, the
      release remains private until the maintainer approves `release-publication`
      once; Stable downstream publication then needs no second approval.
- [x] Given any failed build, Draft assembly failure, stale tag, or ambiguous
      GitHub state, the skill does not request or submit publication approval.

## Definition of Done

- [x] Deterministic command and diff validator have focused automated coverage.
- [x] Relevant Agent and Client analyzers plus focused tests pass through FVM.
- [x] Release architecture, QA matrix, task status, and skill stay consistent.
- [x] Graphify is incrementally updated after code changes.
- [x] No commit, push, PR, merge, tag, Environment mutation, or publication is
      performed for this implementation task without the user's separate current
      authorization.
