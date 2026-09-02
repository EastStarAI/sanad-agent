# Release Delivery Extension

Load this reference only when a user asks to prepare, cut, create, or publish a
Sanad RC or Stable release. The owning design and acceptance contracts are
`docs/operations/release_and_signing.md` and
`docs/qa_maintenance/release_verification.md`; do not duplicate them here.

## Authorization

A direct request for an exact release or the unambiguous next Stable release
authorizes its isolated branch/worktree, generated commit, push, PR, eligible
squash merge, and immutable tag. For “next Stable”, increment patch and build by
one. It does not authorize Environment/settings changes, protection bypasses,
publication, Production recovery, or force-push/tag replacement. Publication
always needs the final decision below.

## Preflight

1. Verify `EastStarAI/sanad-agent`, authenticated role, clean isolated worktree,
   current `origin/main`, latest published Stable tag, and absence of the target
   tag or Release.
2. For the next and later releases, require PR #129 merge commit
   `872a5b75aec8303bf59ea39e25826d017d0ad714` to be an ancestor of both
   `origin/main` and the eventual release commit.
3. Inspect Environment metadata without reading secrets. Require zero reviewers
   on the four signing Environments and `client-downloads-production`, exactly
   the owner reviewer on `release-publication`, and the documented `main`/`v*`
   custom policies. Stop before preparation when this one-time activation has
   not been completed; never mutate it from this release flow.
4. Derive release notes and the Agent-only changelog entry from merged commits
   and PRs in `<latest-stable-tag>..origin/main`. Describe resulting behavior,
   not reverted features; PR #129 means milestone-key streaming must not be
   claimed.

## Prepare the metadata PR

From `agent/`, run:

```bash
fvm dart run tool/release_tool.dart prepare-release \
  --repo-root .. --version <X.Y.Z> --build-number <N>
```

Replace the generated changelog placeholder and complete
`release/release-notes.md`, preserving the Windows unsigned-build disclosure and
exact iOS build note. Then run:

```bash
fvm dart run tool/release_tool.dart check-preparation --repo-root ..
fvm dart run tool/release_tool.dart validate-contract --repo-root ..
fvm dart test test/tool/release_preparation_test.dart
fvm dart analyze
(cd ../client && fvm flutter analyze)
```

Review the complete diff, then require the branch to match the exact 11-file
metadata surface accepted by:

```bash
scripts/release/verify_metadata_release_diff.sh <base-sha> <head-sha>
```

Any workflow, script, signing, deployment, installer-logic, task-plan,
unrelated path, unexpected line, stale identity, placeholder, secret, or private
path exits this exception and follows the normal protected-review process.

Commit of ordinary release prose is allowed only in release notes and the Agent
changelog. Use `chore(release): prepare vX.Y.Z` (or the RC identity) for the PR.
The exact metadata-only PR does not self-apply a protected label; CI proves the
narrow exception.

## Merge and tag

1. Poll checks at bounded intervals with a fixed deadline; never use watch/follow
   or an unbounded loop. Stop on the first terminal failure.
2. Before merge, fetch `origin/main`; require mergeability, resolved discussions,
   current base, and successful `All required checks pass`. Update and reverify
   if `main` moved.
3. Squash merge, fetch `origin/main`, and verify the resulting commit plus all
   package/contract identities.
4. Recheck PR #129 ancestry and target nonexistence. Create the canonical
   annotated `vX.Y.Z` or `vX.Y.Z-rc.N` tag on that exact public `main` commit and
   push only that tag. Never move an existing tag.
5. Identify the release workflow by tag and source SHA, not newest-run order.

## Complete candidate and one final decision

Poll with a fixed deadline until a prerequisite fails or all Agent/Client builds,
signing, notarization, tests, manifest, checksums, Appcast, SBOM, attestations,
and private Draft creation succeed. Before asking the user, require exactly one
Draft for the tag, matching source/channel/assets, exactly one pending deployment
named `release-publication`, and no started Production deployment.

Any failure, cancellation, missing or duplicate Draft, stale source, ambiguous
pending deployment, or timeout blocks approval. Present a compact summary of
version/build, tag, source and PR commits, PR #129 ancestry, workflow run,
platform matrix, Draft URL, artifact count, and channel behavior. Ask one final
question with three outcomes:

1. Approve `release-publication` for the discovered run and Environment id.
2. Keep the Draft private without mutation.
3. Abort publication and investigate.

Preparation/tag authorization is never the publication answer. On approval,
submit only that pending deployment through the GitHub API and immediately
re-query its run/environment identity.

## Verify publication

Use bounded polling to verify the exact GitHub Release is public. Stable releases
must then complete Client aliases followed by the reusable Production asset
workflow and pass the public manifest, Appcast, installer hash, Web version, and
source checks from the QA contract. RC releases must not enter Stable Production
paths. Report Release publication separately from downstream deployment; never
silently retry a failed Production mutation or request a routine second
approval. Recovery needs a new explicit instruction.
