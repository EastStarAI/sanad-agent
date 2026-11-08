---
title: "Public CI Pipeline and Merge Queue"
description: "Job layout, cross-component path classification, test sharding, toolchain caching, required-check aggregate, slow-test evidence, and the protected merge-queue runbook for Public CI."
---

# Public CI Pipeline and Merge Queue

Public CI (`.github/workflows/ci.yml`) is the only producer of the required
branch-protection check `All required checks pass`. This page owns its job
layout, the reasons behind the shard and cache design, and the merge-queue
runbook the repository owner and merge agent follow.

## Pipeline Model

Classification (`classify`) reads the changed paths and enables only the lanes
that the change touches. A classification failure, a `push` to `main`, or a
`workflow_dispatch` run enables every lane, so a broken classifier can never
silently skip validation.

Every lane is an independent job. The client and agent test lanes are matrices
with one job per shard, so the critical path is the setup cost plus the
slowest single shard instead of the whole suite.

| Lane | Job names | Runs when |
| --- | --- | --- |
| History | `Verify branch history` | always |
| Client analysis | `Analyze client` | `client` paths |
| Client tests | `Test client (1/4)`, `Test client (2/4)`, `Test client (3/4)`, `Test client (4/4)` | `client` paths |
| Client Web guard | `Web startup composition` | `client` paths |
| Agent checks | `Agent contract checks and analyze` | `agent` paths |
| Agent tests | `Test agent (1/4)`, `Test agent (2/4)`, `Test agent (3/4)`, `Test agent (4/4)` | `agent` paths |
| CLI automation | `CLI automation (ubuntu-24.04)`, `CLI automation (ubuntu-24.04-arm)`, `CLI automation (macos-26)`, `CLI automation (windows-2025)` | `agent` paths |
| Native dictation | `Native dictation (ubuntu-24.04)`, `Native dictation (ubuntu-24.04-arm)`, `Native dictation (macos-26)`, `Native dictation (macos-15-intel)`, `Native dictation (windows-2025)` | `agent` paths |
| `sanad-dev` bootstrap | `sanad-dev bootstrap (<os>)` | `client` or `docs` paths |
| Docs and governance | `Validate docs and governance` | `docs` paths |
| Release and security | `Validate release and security boundaries` | `release` or `security` paths |
| Protected review | `Verify protected review labels` | always |
| Aggregate | `All required checks pass` | always |

`All required checks pass` depends on every lane and on every shard of a
matrix, and it fails unless each dependency succeeded or was skipped by
classification. A new lane that is not added to its `needs` and to its result
check is a coverage hole, so both edits belong to the same change.

`CLI automation (ubuntu-24.04-arm)` runs the Agent AOT smoke on GitHub's arm64
runner, so a native arm64 executable is proved at pull-request time on the same
runner family the release matrix uses for the official Linux arm64 Agent
artifact. The pinned Flutter SDK publishes no Linux arm64 archive, so that lane
installs the standalone Dart SDK through `.github/actions/setup-dart` at the
version declared by `scripts/ci/dart_sdk_version.txt`; every other lane keeps the
FVM-managed Flutter SDK, `DART` selects the executable per lane, and
`agent/test/guards/dart_sdk_pin_test.dart` fails on the ordinary lanes when the
pin and the Flutter-bundled Dart version diverge.

`Native dictation (ubuntu-24.04-arm)` builds, verifies, loads, and stages the
whisper runtime on arm64 Linux for the same reason: the release matrix publishes
`linux-arm64` from that runner, so the slice is proven here rather than trusted
from an x64 host. It uses the same per-lane `DART` selector and a whisper build
cache keyed by the runner label.

### Cross-Component Contract Fixtures

A path is classified by the component that *consumes* it, not only by the
directory that owns it. `agent/test/fixtures/cli_relay_grammar.json` belongs to
the Agent, but the Client reads it as the source of truth for the relay grammar,
so the `client` classifier case lists that fixture explicitly and a change to it
runs the Client analyze and test lanes.

Every Agent-to-Client contract artifact must be listed in the `client` case for
the same reason: a contract change that runs only the Agent lane leaves the
Client consumer unverified, which is how a stale relay table reached `main`.
Client-to-Agent contracts follow the inverse rule and belong in the `agent`
case. A new consumer also needs a test in the consuming component, because
classification only decides which lanes run, never whether the consumer agrees.

## Test Sharding

Client and agent tests are split by test **file**, not with `--total-shards`.
`flutter test --total-shards` and `dart test --total-shards` slice the tests
inside every suite, so every shard still loads and compiles all test files. On
the client suite that made one shard of four *slower* than the unsharded run.

`scripts/ci/list_test_shard.sh` prints the files of one deterministic shard by
round-robin over the sorted test-file list. Shards never overlap and never drop
a file. Each shard job prints the number of files it runs and the number of
tests it executed, so the sum over shards can be compared with the unsharded
total in the same run.

A suite that assigns the process working directory cannot share a runner: all
suites in a `dart test` process share that directory, so a child process
started by another suite fails while the directory is held or deleted. The
listing keeps those suites out of every shard, `--isolated` prints them, and
the agent lane runs them alone with `--concurrency 1`. They still run exactly
once per CI run.

Shard count is chosen from the measured critical path, not from the number of
test files: setup cost dominates when shards are too small, and the slowest
shard dominates when they are too large. Four shards keep the slowest client
shard well under the per-shard setup cost while leaving every lane on a stock
`ubuntu-24.04` runner.

## Toolchain Caching

`.github/actions/setup-fvm` installs the Flutter SDK pinned by `.fvmrc` once,
with `subosito/flutter-action`, and points FVM at that same SDK through
`FVM_CACHE_PATH`. `fvm install` therefore registers the pinned version instead
of downloading a second copy, and the job still fails if FVM resolves a version
that `.fvmrc` does not declare.

`PUB_CACHE` keeps its platform default and is restored with `actions/cache`,
keyed on the OS, `.fvmrc`, and every `pubspec.lock` in the repository: the
runner images already put the cache's bin directory on PATH, so no path is
overridden. Lockfile changes produce a new key, so a stale cache can never
resolve different dependency versions.

The client test shards and the Web guard install `libgtk-3-dev` and
`libasound2-dev` because the `nativeapi` build hook compiles against GTK 3, X11,
and Xi with `pkg-config`, and the image only ships those runtime libraries. The
analysis and agent lanes do not build native assets and install nothing.

## Required Checks and Protected Labels

`All required checks pass` is the single branch-protection context. Job names
are display-only for this model; only the aggregate name must stay stable, and
the protected-label workflow re-runs the job names `Verify protected review
labels` and `All required checks pass`, so those two names are fixed.

## Merge Queue

The workflow also triggers on `merge_group`. When a queued entry is built,
classification and every lane run against the merge-group diff, and the same
aggregate check reports the result that gates the queue.

A merge group has no pull-request payload. `Verify protected review labels`
reads the queued pull request number from the queue head ref
(`gh-readonly-queue/<base>/pr-<number>-<sha>`) and re-checks that pull
request's labels against the merge-group diff. A group that cannot be
attributed to exactly one pull request fails closed instead of passing
vacuously, so keep the queue at one pull request per build (build concurrency 1,
no batching).

### Owner settings

Enabling the queue is a repository-settings change and stays with the
repository owner. Apply it only after this pipeline is merged to `main`, in this
order:

1. Merge the pull request that introduces the `merge_group` trigger.
2. Settings → General → Pull Requests: enable **Allow auto-merge** and keep
   **Allow squash merging** as the only merge method.
3. Settings → Rules → `main` ruleset (or branch protection): keep the required
   check `All required checks pass`, then enable **Require merge queue**.
4. Merge queue settings: **Merge method** squash, **Build concurrency** 1,
   **Minimum group size** 1, **Maximum group size** 1, **Wait time** 5 minutes,
   **Check timeout** 60 minutes, and keep **Only merge non-failing pull
   requests** enabled.
5. After the queue is required, turn off **Require branches to be up to date
   before merging**: the queue already rebuilds each entry on the current
   `main`, and keeping both makes every merge wait for a second full CI run.
6. Verify with a throwaway pull request: enqueue it, confirm a `merge_group`
   Public CI run starts, confirm its `All required checks pass` is green, and
   confirm the merge lands and deletes the branch.

### Merge agent flow

The merge agent owns branch freshness and conflicts; the coordinator only
reviews and dispatches. For each authorized merge:

1. Update the branch from current `main` and resolve conflicts with the
   repository's fail-closed merge procedure.
2. Verify the head commit, the complete diff, resolved conversations, and the
   mandatory non-protected label set.
3. Enqueue instead of merging directly:

   ```bash
   gh pr merge <number> --squash --match-head-commit <sha>
   ```

   `--match-head-commit` refuses the enqueue if the head moved after review.
4. Confirm the `merge_group` run of Public CI and the resulting merge commit.
