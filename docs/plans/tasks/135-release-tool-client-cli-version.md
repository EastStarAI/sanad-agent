---
title: "Task 135: Release Tool Ownership of the sanad-client CLI Version"
description: "Make release preparation advance the sanad-client CLI version constant, reject a stale value in check-preparation, and admit the file as the twelfth metadata path with a single-line version rule."
status: "in_review"
current_gate: "Writer round 1"
priority: "high"
depends_on: "Plan 130 (sanad-client relay), v1.0.18 release preparation"
file_budget: 12
---

# Task 135: Release Tool Ownership of the `sanad-client` CLI Version

## 1. Problem

`client/lib/features/client_cli/domain/models/client_cli_version.dart` declares
the single `sanadClientCliVersion` literal that the standalone `sanad-client`
relay CLI reports for `--version`. It landed with PR #188, after v1.0.17 had
already been prepared, so the release tooling never learned about it:

- `agent/tool/release_tool.dart prepare-release` left it at `1.0.17` while
  advancing `client/pubspec.yaml` to the next identity;
- `check-preparation` did not look at it, so the stale value passed the release
  gate;
- `scripts/release/verify_metadata_release_diff.sh` allowed exactly 11 metadata
  paths, so any manual correction failed the exact-surface exception.

The v1.0.18 preparation PR (#257) was therefore red on the Client CI job
(`client_cli_version_test.dart` requires the constant to mirror
`client/pubspec.yaml`) while a hand fix broke the diff gate. The two gates had
no shared owner.

## 2. Design

### 2.1. The version literal is release-managed identity

`client_cli_version.dart` stays the one place that holds the CLI version, but the
literal is now written only by release preparation:

| Surface | Owner |
| --- | --- |
| Advance the literal | `prepare-release` (`agent/tool/release_preparation.dart`) |
| Reject a stale literal | `check-preparation` |
| Accept the literal-only diff | `scripts/release/verify_metadata_release_diff.sh` |
| Enforce Client parity | `client/test/unit/client_cli/client_cli_version_test.dart` (unchanged) |

`agent/tool/release_preparation.dart` exposes one owner constant,
`clientCliVersionPath`, and both commands use it, so the path cannot drift
between writer and checker.

### 2.2. Version-only substitution

`prepare-release` performs `_replaceExactly` of

```text
const String sanadClientCliVersion = '<current contract version>';
```

with the same line carrying the target version. Exactly-one-occurrence matching
means a stale, missing, or duplicated literal aborts the whole prepare run
before any file (`_writeUpdates` keeps the transactional write), so release
preparation can never "fix up" an unexpected file. `check-preparation` requires
the exact `'<contract version>'` form, so a partially edited constant fails.

### 2.3. Twelfth metadata path with a line rule

`verify_metadata_release_diff.sh` now lists
`client/lib/features/client_cli/domain/models/client_cli_version.dart` in the
fixed set (12 paths) and validates every changed line of that file against:

```text
^const\ String\ sanadClientCliVersion\ =\ '[0-9]+\.[0-9]+\.[0-9]+';$
```

The rule is intentionally literal: no indentation, no trailing comment, no
prerelease suffix, and no other line in the file may change. Any other edit is a
source change and returns to normal protected review, exactly like the existing
native-metadata rules.

### 2.4. Tests

- `agent/test/tool/release_preparation_test.dart` copies the release surface into
  a temporary fixture (now 12 paths) and derives the next patch/build from the
  fixture contract, so no release identity is pinned. It asserts the literal
  advances on prepare, that a stale literal fails `check-preparation`, and that
  prepare rejects a stale literal without writing any file.
- `scripts/release/test_verify_metadata_release_diff.sh` (existing fixture test)
  now seeds the version file, proves the 12-path release diff passes, and proves
  rejection for both a trailing-comment edit on the literal line and an extra
  line appended to the file.

## 3. Files

| Path | Change |
| --- | --- |
| `agent/tool/release_preparation.dart` | prepare substitution and check requirement for the CLI version literal |
| `agent/test/tool/release_preparation_test.dart` | 12-path fixture, advance/check/prevalidation coverage |
| `scripts/release/verify_metadata_release_diff.sh` | twelfth path and single-line version rule |
| `scripts/release/test_verify_metadata_release_diff.sh` | fixture seed plus two forbidden-edit cases |
| `client/lib/features/client_cli/domain/models/client_cli_version.dart` | doc comment naming the owning release command; version literal unchanged |
| `docs/operations/release_and_signing.md`, `docs/qa_maintenance/release_verification.md`, `.agents/skills/sanad-pull-request-lifecycle/references/release-delivery.md` | 11-file statements replaced by 12 and the new path |
| `agent/AGENTS.md`, `client/AGENTS.md` | durable ownership of the release-managed literal |
| `docs/llms.txt` | this task indexed |

The release identity itself is untouched: `main` stays at marketing version
`1.0.17` and build number `18`. Advancing it is the separate release-preparation
PR.

## 4. Verification

| Gate | Command | Result |
| --- | --- | --- |
| Agent analysis | `cd agent && fvm dart analyze` | passed |
| Agent release tooling tests | `cd agent && fvm dart test test/tool/` | passed |
| Client CLI version parity | `cd client && fvm flutter test test/unit/client_cli/client_cli_version_test.dart` | passed |
| Metadata diff fixture suite | `bash scripts/release/test_verify_metadata_release_diff.sh` | passed |
| Synthetic prepare | `prepare-release --version 1.0.18 --build-number 19` in a scratch worktree, then `check-preparation` and `verify_metadata_release_diff.sh <base> <head>` | passed; the scratch worktree was removed |

## 5. Definition of Done

- [x] `prepare-release` advances the `sanadClientCliVersion` literal.
- [x] `check-preparation` rejects a stale literal.
- [x] The verify script accepts the file as the twelfth metadata path under a
      version-only line rule.
- [x] Red-first coverage in the Agent release-preparation test and in the
      metadata-diff fixture test.
- [x] Every "11 files" statement now reads 12 and names the new path.
- [x] Recorded here and indexed in `docs/llms.txt`.
