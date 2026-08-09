---
title: "Code Signing Policy"
description: "Public artifact trust, protected signing, role separation, verification, and revocation policy for Sanad releases."
---

# Code Signing Policy

## Current Release Policy

Sanad Agent publishes release artifacts only from a tagged GitHub Actions build. Every release must include a release manifest and SHA-256 checksums generated from the immutable artifacts. Users should verify the official release origin and checksum before installation or update.

Windows installers remain **Unsigned Windows builds** until the documented Authenticode transition is completed. Release notes, download surfaces, and installation guidance must disclose that status. Documentation must not tell users to disable Microsoft Defender or Smart App Control. Any SmartScreen bypass guidance is limited to a user who has independently verified the official origin and SHA-256 hash.

macOS and Android signing follow the protected release workflow and platform-specific credentials. Private keys and signing credentials must never enter Git, pull-request jobs, fork jobs, logs, or general build artifacts.

## Trusted Build Boundary

- The tagged source revision is the build origin.
- Protected GitHub Environments own signing and publication secrets.
- Fork pull requests receive no signing, deployment, or release credentials.
- Build, signing, checksum, manifest, and publication steps remain auditable in CI.
- A release artifact is immutable after publication; correction requires a new version.
- Compromise or suspected compromise pauses publication and triggers credential rotation and incident review.

## Roles

- **Committer:** authors or lands source changes but cannot approve their own sensitive release change merely by authorship.
- **Reviewer:** reviews source, workflow, dependency, and provenance changes.
- **Approver:** authorizes use of protected signing or publication environments.

The initial project owner may hold multiple roles while Sanad has one maintainer, but protected review labels and recorded evidence remain mandatory. Roles should be separated when another independent maintainer joins. All maintainers and signing approvers must use two-factor authentication.

## SignPath Foundation Readiness

A post-v1 task will evaluate an application to SignPath Foundation after the project is public, documented, and active. MIT licensing alone does not guarantee acceptance. The application must demonstrate trusted source origin, reproducible or otherwise auditable builds, role separation, protected credentials, and a maintained signing policy.

If accepted, the Windows publisher shown to users may be **SignPath Foundation**, not EastStar AI. Signing also does not guarantee immediate SmartScreen reputation; reputation is a separate Microsoft trust signal.

## Verification and Revocation

Release documentation must provide checksum verification for every platform and signature verification where a platform signature exists. A compromised certificate or key is revoked or rotated promptly, affected releases are identified publicly when safe, and replacement artifacts use a new version rather than silently mutating an existing release.
