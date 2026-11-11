---
title: "Public CI Pipeline and Up-to-date Merges"
description: "Job layout, cross-component path classification, test sharding, toolchain caching, required-check aggregate, slow-test evidence, and the protected up-to-date merge runbook for Public CI."
---

# Public CI Pipeline and Up-to-date Merges

Public CI (`.github/workflows/ci.yml`) is the only producer of the required
branch-protection check `All required checks pass`. This page owns its job
layout, the reasons behind the shard and cache design, and the merge runbook the
repository owner and merge agent follow.

## Pipeline Model

Classification (`classify`) reads the changed paths and enables only the lanes
that the change touches. It publishes **one output per lane**, not one per
component, because a component and a lane are not the same set: the client
component feeds four lanes and the post-merge complement run has to be able to
skip exactly the lanes a proof run already proved.

A classification failure, a `workflow_dispatch` run, a changed path that matches
no class at all, or a changed path that matches one of the always-run triggers in
[`scripts/ci/lane_inputs.txt`](../../scripts/ci/lane_inputs.txt) enables every
lane, so a broken classifier can never silently skip validation. A `push` to
`main` also enables every lane — and then reduces that set to the complement
described in the next section, which is the only reduction a `push` ever applies.

Every lane is an independent job. The client and agent test lanes are matrices
with one job per shard, so the critical path is the setup cost plus the
slowest single shard instead of the whole suite.

| Lane | Job names | Runs when |
| --- | --- | --- |
| History | `Verify branch history` | always |
| Client analysis | `Analyze client` | `client_analyze` |
| Client tests | `Test client (1/4)`, `Test client (2/4)`, `Test client (3/4)`, `Test client (4/4)` | `client_tests` |
| Client Web guard | `Web startup composition` | `client_web` |
| Agent checks | `Agent contract checks and analyze` | `agent_checks` |
| Agent tests | `Test agent (1/4)`, `Test agent (2/4)`, `Test agent (3/4)`, `Test agent (4/4)` | `agent_tests` |
| Supervisor skill tests | `Supervisor skill tests` | `supervisor_skill` |
| CLI automation | `CLI automation (ubuntu-24.04)`, `CLI automation (ubuntu-24.04-arm)`, `CLI automation (macos-26)`, `CLI automation (windows-2025)` | `cli_automation` |
| Native dictation | `Native dictation (ubuntu-24.04)`, `Native dictation (ubuntu-24.04-arm)`, `Native dictation (macos-26)`, `Native dictation (macos-15-intel)`, `Native dictation (windows-2025)` | `native_stt` |
| `sanad-dev` bootstrap | `sanad-dev bootstrap (<os>)` | `sanad_dev` |
| Docs and governance | `Validate docs and governance` | `docs_governance` |
| Release and security | `Validate release and security boundaries` | `release_security` |
| Protected review | `Verify protected review labels` | always |
| Aggregate | `All required checks pass` | always |

Each lane output is its component's classification, except `native_stt` and
`sanad_dev`, which are decided by their declared input sets (see
[Lane Input Sets](#lane-input-sets)), and `release_security`, which is never
reduced by the post-merge complement run because its credential scan covers the
pushed range.


`All required checks pass` depends on every lane and on every shard of a
matrix, and it fails unless each dependency succeeded or was skipped by
classification. It reads the classifier's per-lane outputs alongside the results:
a lane the classifier marked `true` must end `success`, so a required lane that
ends `skipped` (or a missing output) fails the aggregate instead of passing. A new
lane that is not added to its `needs`, its result list, and the matching `REQUIRED`
position is a coverage hole, so all three edits belong to the same change.

### Supervisor Skill Tests

`.agents/skills/delegate-task-supervisor/` is Node code, so no Dart lane can
execute it. `Supervisor skill tests` runs
`node --test test/*_test.mjs` in that directory on the runner's preinstalled
Node, and it is classified by the same `agent` output as the Agent lanes
(`.agents/skills/*` is an `agent` path). It exists because the alternative was
what actually happened: every supervisor fix was verified by hand once, so a
regression could not fail a pull request, and a live run could execute
code that was already several fixes behind.

`test/incident_regression_test.mjs` holds one named scenario per past supervisor
incident — outage alerting, daemon-restart follow survival, an expired restart
window, `follow_lost` actionability, gone-vs-unreachable classification, the
scheduled-retry stall rule, the `continue --new-session` pin, the stale-code
guard, and the lingering watcher — so a change that reintroduces one of them
fails here instead of in a coordinator round. The rest of `test/` is the
mechanism suite; both run in the same command.

Those files run concurrently, so a teardown may only sweep the fixture families
its own file creates (`sweepOrphanedFixtures({ prefixes })`): a broad prefix can
signal a live fixture that another running file still owns. A scenario that reads
a multi-write composition also awaits the exact record it asserts rather than the
transition before it, so a preempted worker cannot be mistaken for a wrong cause.

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

`Native dictation` also runs `test/stt/stt_digest_test.dart` and
`test/stt/stt_download_pipeline_test.dart` on every operating system, because the
SHA-256 the download verifies is a per-OS native binding and the write pipeline
opens a second file handle for writeback; both fall back silently where the
binding is missing, so a single Linux lane would prove neither. The two files run
with `--concurrency 1` because the pipeline suite asserts a cost ratio against an
in-process sink, and
[Test Suite Performance and Ownership QA](../qa_maintenance/test_suite_performance_qa.md#native-dictation-lane-additions)
owns the measured cost.

Both arm64 lanes first copy `agent/tool/pubspec_overrides.no_sherpa.yaml` to
`agent/pubspec_overrides.yaml`: `sherpa_onnx` requires the Flutter SDK, which
those lanes do not install, so the Agent links the whisper-only engine stand-in.
The lane then analyzes the engine package it selected, because
`agent/analysis_options.yaml` excludes `packages/**` (only one variant can
resolve). A lane that forgets the overlay fails at `pub get` instead of shipping
a half-configured build.

`Native dictation` also runs the write pipeline's cost gate
(`agent/test/stt/stt_pipeline_cost_test.dart`) on every OS lane. The gate owns a
file so it owns a process: it measures the isolate hop against the same sink
in-process, warms both arms, runs five alternating paired trials, and judges the
median ratio against `0.5`, printing every trial so a lane log carries the
evidence rather than only a verdict. The shape is the contract — a ratio measured
beside another suite, or always in the same order, charges one arm for the other's
contention, which is how `windows-2025` charged the isolate 2.78x on a run where
the pipeline had not regressed.

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

## Post-Merge Complement Run

A merge through the queue fast-forwarded `main` to the exact commit the queue had\njust built. Between 2026-11-08 and 2026-11-10 — while the queue was the live merge\npath — that was true for **46 of 46** pushes to `main`, so the `push` run of\nPublic CI was re-proving a tree that had already passed every lane the classifier\nselected for it. What the `push` run added was the lanes the proof run *skipped*,
plus roughly 60 runner-minutes per merge of repeated work — four macOS jobs among
them, against an account cap of five concurrent macOS jobs. That repeat is what
turned a normal merge into a 33-minute post-merge run: with `macOS full suite` and
a release candidate starting minutes later, the four duplicate jobs waited 28–30
minutes for a runner.

On `push` to `main`, classification therefore runs the **complement** of a proof:

**Proof A — the merge queue (dormant).** Ask the Actions API for the runs of this
workflow with `event=merge_group` and `head_sha` equal to this commit, and keep the
most recent one whose conclusion is `success`. No such run exists while merges are
up-to-date merges, so this source is the rollback path.

**Proof B — the merged pull request's own run.** Accept only when *all* of these
hold: the commit resolves to exactly one pull request **merged into `main`**; that
pull request is the only one the API associates with its head SHA (a second pull
request with the same head, for example one targeting another base branch, would
own a run that tested a different merge, and a run is keyed by head SHA only); that
pull request's head tree is byte-identical to this commit's tree; the head contains
this commit's parent, so the run was made against the same `main` as well as the
same content; and there is a successful run with event `pull_request`, that head
SHA, and that head branch. Zero or several candidate pull requests mean no proof.
The commit-to-pull-request endpoint lists open and merged pull requests for a
commit outside the default branch; a closed, unmerged duplicate is the residual
case it may omit.

Proof B is the source the live merge model relies on. The merge path is a
repository setting rather than a property of this workflow: with **require
branches to be up to date** enforced, a pull-request head always contains the
`main` tip it will land on, the pull request's own run tested exactly that
content, and a squash merge lands the head's tree. Identical trees plus a
contained base is therefore the same guarantee the queue provided, and it is what
[Up-to-date Merges](#up-to-date-merges) depends on. A and B are tried in that
order, so a `merge_group` run still wins if the queue is re-enabled; the first
source that yields proof is used.

Then:

1. Read that run's jobs. A lane counts as **proven** only when a job for it
   actually executed and succeeded; a job the run skipped proves nothing.
2. Set a proven lane to `false` and leave every other lane as classified.

The reduction is fail-closed by construction. No matching run, a run that is not
successful, a tree that differs, a commit that maps to several pull requests, or
an unreadable API all leave the full lane set in place, so the worst case of this
step is today's behaviour. A `workflow_dispatch` run and any event other than
`push` never reduce anything.

These jobs never participate in the reduction, because their work is genuinely
post-merge:

- `Verify branch history` — the pushed range is the merge itself.
- `Verify protected review labels` — the label check belongs to the merge
  decision; on `push` the job still runs, but its label step is limited to
  `pull_request` and `merge_group`, so it is a no-op there rather than a re-check.
- `Validate release and security boundaries` — its credential scan is bounded to
  `BEFORE..AFTER` on a push and to `BASE...HEAD` on a pull request, so it is the
  one lane that scans the merged commit as pushed.

The complement run is also what keeps per-pull-request lane selection honest: a
lane a pull request skipped still executes on the merged commit, and the release
workflow additionally refuses to publish without a green `macOS full suite` run on
the release commit (see
[Release, Signing, and Deployment Architecture](release_and_signing.md#release-gate-on-the-macos-full-suite)).

The selector itself is guarded, because a weakened selector silently drops
coverage from `main`. `scripts/ci/test_post_merge_proof.sh` extracts the two
proof functions and the `push` caller out of `ci.yml`, runs them against the
fixtures in `scripts/ci/fixtures/post_merge_proof/cases.json` with a fake `gh`,
and covers both sources, the ordering between them, and every mismatch listed
above. `agent/test/tool/ci_post_merge_proof_test.dart` asserts the same
invariants directly on the workflow text and runs that harness wherever `bash`
and `jq` exist. Moving either function fails the harness's own extraction check
instead of quietly narrowing the guard.

## Lane Input Sets

Two lanes do not follow a component. `Native dictation` builds, verifies, loads,
and stages the whisper and sherpa runtimes on five runners, and it consumes a
small slice of the Agent rather than the Agent. `sanad-dev bootstrap` exercises
the `sanad_dev` package and the Windows installer scripts, and it consumes a
developer tool that no component class names. Both used to be gated by a
component — `agent/**` and `client` or `docs` respectively — which cost real
money: across the 48 merged pull requests of the reviewed population, Native
dictation ran on 38 and `sanad-dev bootstrap` on 47, while their actual inputs
changed far less often.

`scripts/ci/lane_inputs.txt` is the single declaration of what each of them
consumes. The `classify` job reads the `glob` lines with bash `case` semantics;
the guard suite reads the `entry` lines. Nothing else may restate them.

| Lane | Real inputs |
| --- | --- |
| `native-stt` | `agent/lib/infrastructure/stt/`, `agent/packages/stt_sherpa/`, `agent/packages/stt_sherpa_stub/`, `agent/test/stt/`, `agent/tool/ensure_native_stt.dart`, `agent/tool/stt_native_archive.dart`, `agent/tool/stt_native_runtime.dart`, `agent/tool/pubspec_overrides.no_sherpa.yaml` |
| `sanad-dev` | `scripts/sanad_dev/`, `scripts/sanad-dev`, `scripts/sanad-dev.ps1`, `client/config/`, `scripts/install.ps1`, `client/release/windows/` |

Everything else keeps its component gate. `CLI automation` is deliberately **not**
gated by an input set: the import closure of `bin/sanad_agent.dart` plus
`tool/cli_aot_smoke.dart` is 575 of 585 `agent/lib` files, so a narrower trigger
would save nothing while adding a way to miss a change. The Linux agent and
client suites are not gated either — they are the coverage everything else
assumes.

### Always-run triggers

A path that can change the meaning of a lane it does not touch enables every
lane. Declared in the `all` section of the same file:

| Trigger | Why every lane |
| --- | --- |
| `.github/workflows/*`, `.github/actions/*` | the workflow graph and the composite actions every lane runs |
| `scripts/ci/*` | the shard listing, the event counters, the SDK pin, the proof-selector fixtures, and this declaration itself |
| `.fvmrc`, any `pubspec.yaml`, any `pubspec.lock` | toolchain and dependency resolution |
| `agent/native/*` | the shipped native sources and their checksums |
| `shared/*` | the runtime packages the Agent, the Client, and `sanad_dev` all consume |

The previous classifier named only `.github/workflows/*`, and only as a
`release` path, so a pull request that edited a lane in `ci.yml` did not run that
lane before merge. `shared/windows_path/`, `shared/public_service_endpoints/`,
and `scripts/sanad_dev/` matched no class at all, so alone they fell back to
running everything while mixed with an Agent change they skipped the `sanad-dev`
lane. Both holes are closed by the declaration above.

### Why this cannot lose coverage

1. **The guard fails the build, not the reviewer.** `agent/test/tool/ci_lane_inputs_test.dart`
   resolves the Dart import closure of every declared `native-stt` entrypoint
   through the package configuration and fails when any file in it matches none of
   that lane's globs. A new `lib/` file a smoke test imports therefore fails in the
   ordinary Agent shard, on the pull request that introduced it. The suite also
   reads the `Native dictation` job in `ci.yml` and fails when a Dart file the job
   runs is not declared as an `entry`, so a suite added to the lane cannot run
   outside the closure check. For `sanad-dev` it resolves every `'../…'`
   path literal in the package's tests (the bootstrap wrappers they copy and run,
   the Client configs they parse) and fails when an existing repository file read
   that way matches no `sanad-dev` or `all` glob.
2. **The same suite asserts the always-run triggers**, so narrowing a lane cannot
   quietly drop one.
3. **The complement run covers the merged commit.** A lane a pull request skipped
   still runs on `push` to `main` unless a proof run executed and passed it on the
   same tree.
4. **The release gate covers the release commit.** `release.yml` refuses to build
   or publish without a green `macOS full suite` on that exact commit, and the
   macOS suite's definition comes from `list_test_shard.sh`, not from this
   classifier.

What this relaxation does **not** protect against is a dependency no import graph
shows: a suite that reads a fixture by path, an FFI library loaded by name, or a
runner-image change with no repository diff. Those are caught after merge by the
complement run and before release by the gate — not before merge. That is the
accepted trade: two lanes stop running on pull requests that cannot affect them.

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

`--platform-macos` prints the third selection: the suites whose behavior
depends on the macOS host (real Keychain and file credential stores, launchd
service management, POSIX permissions and atomic rollback, file locks and Home
ownership, native dictation, build-tool paths) plus the process and filesystem
owners that use POSIX-only primitives. `release.yml` runs it on both macOS
agent lanes, and it excludes the `--isolated` suites for the same reason a
shard does; the lane runs those alone. The listing is the single source of truth
for what a macOS lane proves, so the release gate and the post-merge workflow
cannot drift into two different definitions of "macOS coverage".

Shard count is chosen from the measured critical path, not from the number of
test files: setup cost dominates when shards are too small, and the slowest
shard dominates when they are too large. Four shards keep the slowest client
shard well under the per-shard setup cost while leaving every lane on a stock
`ubuntu-24.04` runner.

## Full macOS Suite After Merge

The whole agent suite is 381 files. Running all of it unsharded on four lanes
was the largest single term of a release run: the `macos-15-intel` lane spent
10–15 minutes in `dart test` alone, executed the same work 2.4–3.0× slower per
unit than the arm64 lane, and set the critical path of the workflow because
`assemble` waits for it. Two structural facts made that spend redundant:

- `ci.yml` already runs every one of those files on four Ubuntu shards for every
  pull request and every push to `main`.
- Every test that runs only on macOS — the two Keychain cases in
  `test/core/agent_secret_store_test.dart:500,527`, the launchd cases in
  `test/core/setup/service_manager_test.dart`, and the vault interaction policy —
  sits inside the `--platform-macos` subset.

So the coverage is split instead of duplicated:

| Where | What it proves |
| --- | --- |
| Public CI (`ci.yml`, every pull request and merge) | The complete agent suite on four Ubuntu shards, the CWD-sensitive suites alone, and the Intel-native runtime build/verify/load on `macos-15-intel` |
| Release (`release.yml`) | The complete agent suite on Linux x64 and arm64, and the `--platform-macos` subset plus the isolated suites on macOS arm64 and x64 — the platform-sensitive behavior a Linux lane cannot prove, on the same runners that build the shipped artifacts |
| `macos-full-suite.yml` (every push to `main`) | The complete agent suite on `macos-26` and `macos-15-intel`, four file shards each, plus the CWD-sensitive suites alone on both |

`macos-full-suite.yml` is deliberately **not** a required check. It reports on
the merge commit within minutes of a merge and is fixed forward; wiring a
post-merge signal into branch protection would block every unrelated pull
request. A `concurrency` group per ref cancels a superseded `main` run, so a
second merge never doubles the macOS queue draw.

The split is safe in one direction only: a macOS-only regression now reaches
`main` before it reaches a release lane, so a red `macOS full suite` run is a
blocking defect for the next release even though it is not a required check.
Do not treat "the release is green" as proof that the macOS suite is green.

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

### Bounded package installs

Every `apt-get` in `ci.yml` and `release.yml` goes through
`.github/actions/apt-install`, which owns the retry and timeout policy for
package installation, and every calling step declares its own
`timeout-minutes`.

`apt-get` has no timeout of its own: a mirror that accepts the connection and
then stops answering holds the step until the *job* timeout kills it. That is
not hypothetical here. On 2026-11-10 the `apt-get update` half of the client
shard dependency install in `Test client (3/4)` hung for 19m49s, was killed by
the 20-minute job timeout, and the clean re-run finished the same install in
17 seconds. The same step was slow or stalled 11 times in 2.5 days, across the
client shards, the Web guard, and the post-merge run.

The action therefore:

- bounds the acquire phase per command (`Acquire::Retries=3`,
  `Acquire::http::Timeout=20`, `Acquire::https::Timeout=20`, plus
  `Acquire::ForceIPv4=true` so an unroutable IPv6 path fails instead of
  blackholing);
- retries the whole `update` + `install` pair at most three times with a 10s
  then 20s backoff, so one late or truncated index costs seconds instead of the
  lane;
- fails with a single actionable error after the last attempt, and
- skips the install entirely when its `skip-if-command` input already resolves,
  which is how the instruction-set disassembler stays a no-op on runners that
  ship `objdump`.

A caller's `timeout-minutes` (8 minutes for the dependency installs and the
disassembler, 10 for the release Linux build dependencies) is the last bound: a
stall that survives three bounded attempts fails fast instead of consuming a
20–45 minute job budget. Nothing about which packages are installed, or on
which lane, changed — only how a stalled mirror is handled.

## Required Checks and Protected Labels

`All required checks pass` is the single branch-protection context. Job names
are display-only for this model; only the aggregate name must stay stable, and
the protected-label workflow re-runs the job names `Verify protected review
labels` and `All required checks pass`, so those two names are fixed.

## Up-to-date Merges

`main` requires every pull-request head to contain the current `main` tip
(**Require branches to be up to date before merging**, strict mode) and gates the
merge on one check, `All required checks pass`. The merge queue is not deleted, it
is disabled and left dormant: the ruleset stays in place, the `merge_group:`
trigger stays in the workflow, and the post-merge complement run accepts either
proof, so [the two settings calls below](#owner-settings) are the only switch
between the two merge paths.

Strict mode keeps the tested tree and the merged tree identical. PR CI runs on
`refs/pull/N/merge`, whose tree equals the head tree exactly when the head
contains the base, and a squash merge lands that head tree. The
[post-merge complement run](#post-merge-complement-run) relies on that identity
and therefore starts from the pull request's own run (proof B).

**Cost when `main` moves.** In the reviewed population, `main` moved after the
last PR CI for 28% of merges. Each of those needs `gh pr update-branch`, a full PR
CI (median 6m55s, p90 11m00s), and then the merge — the same minutes the queue
spent on the rebuild, but driven by the merge agent. The other 72% skip the
second run entirely, which puts expected merge latency near 2.5 minutes against
the queue's 7m54s median enqueue→merged. Back-to-back merges now serialize
instead of speculating in parallel, about 7 minutes each; the queue becomes worth
revisiting above roughly 25% back-to-back merges.

### Protected labels just before merge

A queued run re-read protected labels on the merge commit. Strict mode has no
queued run, so the merge agent performs that re-check itself, seconds before the
merge instead of minutes:

1. Read the latest Public CI run for the head SHA and the `completed_at` of its
   `Verify protected review labels` job.
2. Read `GET /issues/N/events` for `labeled` and `unlabeled` events on
   `maintainer-reviewed`, `security-reviewed`, or `release-reviewed` after that
   time.
3. If any exist — or the data is ambiguous — dispatch
   `gh workflow run protected-labels.yml -f pr_number=N`, wait for it, and
   require a green `All required checks pass` on the same head.
4. Merge with `gh pr merge N --squash --match-head-commit <sha>`.

The residual race is a label removed between step 2 and step 4, which is seconds
wide; the queue's window was the minutes between enqueue and merge.

### Owner settings

Both settings are repository-settings changes and stay with the repository owner.
Apply them in this order, and only after the change that documents them is on
`main`:

1. Settings → General → Pull Requests: keep **Allow auto-merge** enabled, keep
   **Allow squash merging** as the only merge method, and keep
   **Automatically delete head branches** on.
2. Settings → Rules → `main` ruleset (or branch protection): keep the single
   required check `All required checks pass` and enable **Require branches to be
   up to date before merging**. `.github/branch-protection.yml` already declares
   `strict: true`, so this clears the recorded drift instead of adding one.
3. Once the merge queue is empty, **disable** — do not delete — the
   `main-merge-queue` ruleset. Disabling it first would leave a window with
   neither guard.
4. Leave **Require merge queue** off.
5. Verify with a throwaway pull request: an up-to-date one merges directly, and a
   second one whose `main` moved is blocked until it is updated.

Unchanged: the single context `All required checks pass`, the protected-review
label model, conversation resolution, admin enforcement, and the force-push and
deletion blocks.

### Merge agent flow

The merge agent owns branch freshness, conflicts, and the label re-check; the
coordinator only reviews and dispatches. For each authorized merge:

1. Update the branch from current `main` with `gh pr update-branch <number>`, and
   resolve conflicts with the repository's fail-closed merge procedure.
2. Verify the head commit, the complete diff, resolved conversations, and the
   mandatory non-protected label set.
3. Re-check the protected labels against the current head as described above.
4. Merge:

   ```bash
   gh pr merge <number> --squash --match-head-commit <sha>
   ```

   `--match-head-commit` refuses the merge if the head moved after review. When
   GitHub rejects the merge because the branch is behind, update it, wait for the
   new PR CI run on the new head, and retry — at most three times before stopping
   and reporting the blocker.
5. Confirm the resulting `push` run of Public CI, the merge commit, and the branch
   deletion.

### Rollback appendix: the merge queue

The `merge_group:` trigger and the merge-group code paths are kept in `ci.yml`, so
a rollback changes no workflow. Apply these two calls in this order, so the guards
overlap instead of leaving a gap:

```bash
# 1. Re-enable the queue ruleset (disable, never delete, is what makes this one call).
gh api --method PUT repos/EastStarAI/sanad-agent/rulesets/26634537 \
  --input - <<<'{"enforcement": "active"}'

# 2. Drop strict mode: the queue rebuilds each entry against current `main`.
gh api --method PATCH \
  repos/EastStarAI/sanad-agent/branches/main/protection/required_status_checks \
  --input - <<<'{"strict": false}'
```

Then restore the queue settings — with one correction. The live ruleset has been
observed at **build concurrency 5 and maximum group size 5** with a 2-minute wait,
which contradicts this page's earlier 1/1 recommendation and the label invariant:
a merge group carries no pull-request payload, so a group that cannot be
attributed to exactly one pull request fails `Verify protected review labels`
closed. Set **Build concurrency** and **Maximum group size** to 1 when the queue
is re-enabled, and keep **Merge method** squash, **Wait time** 5 minutes,
**Check timeout** 60 minutes, and **Only merge non-failing pull requests**
enabled. Verify the rollback with a throwaway pull request: enqueue it, confirm a
`merge_group` Public CI run starts, confirm its `All required checks pass` is
green, and confirm the merge lands and deletes the branch.
