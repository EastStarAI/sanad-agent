---
title: "Single Final Release Publication Approval"
description: "Keep signing builds automatic on trusted release refs and require one final human approval only after the complete candidate has been assembled and verified."
status: "implementation"
priority: "critical"
design_contract: "docs/operations/release_and_signing.md"
qa_contract: "docs/qa_maintenance/release_verification.md"
---

# Single Final Release Publication Approval

## Problem

Stable release runs currently stop for manual review before signing jobs can
build, then stop again after the complete Draft candidate is ready. The first
stop does not review a complete candidate and duplicates the final publication
decision.

## Decision

The single human release approval belongs to `release-publication`, after all
platform builds, signing, notarization, tests, manifest generation, checksums,
SBOM, provenance attestations, and private Draft creation have succeeded.

The signing Environments remain separate secret boundaries with exact custom
release-ref policies, but do not require reviewers. Removing their reviewers
does not move secrets to repository scope, admit pull requests or forks, weaken
ref restrictions, publish a Release, or deploy Production assets.

After the final `release-publication` approval, Stable Client aliases and the
reusable Production asset workflow proceed automatically through the
non-interactive, tag-restricted `client-downloads-production` Environment.

## Activation sequence

1. Merge the reviewed repository change documenting and validating this policy.
2. Remove required reviewers only from `apple-signing`, `apple-testflight`,
   `windows-update-signing`, and `android-signing`.
3. Preserve every Environment, secret, custom deployment branch/tag policy, and
   `release-publication` required reviewer.
4. Query all affected Environments and prove the postcondition before creating a
   release tag.
5. Prepare version `1.0.3` through its own reviewed release-contract pull request.
6. After that pull request merges, create the immutable Stable tag and let the
   complete build reach the one final `release-publication` decision.

## Definition of Done

- [ ] Release architecture documents one final human publication approval.
- [ ] QA rejects reviewers on signing Environments and requires the reviewer on
      `release-publication`.
- [ ] Signing and Production secret/ref boundaries remain unchanged.
- [ ] The repository pull request passes CI with `maintainer-reviewed` and
      `release-reviewed` evidence.
- [ ] The pull request merges before live Environment activation.
- [ ] Live postcondition proves signing Environments have no required reviewers,
      `release-publication` retains the owner reviewer, and branch/tag policies
      are unchanged.
- [ ] Version `1.0.3` starts only after the approval-policy pull request merges.
