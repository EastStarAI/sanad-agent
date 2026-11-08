# Public Fixture Names Safe for the Private Deploy Archive

## Goal
Stop a committed test fixture from blocking the private Production deploy: no tracked file in the public repository ends in a final path component the host artifact check rejects, and a guard proves it stays that way.

## Scope and locked decisions
- The private Production deploy packs the pinned public submodule into an archive, and a root-owned artifact check on that host rejects any member whose final path component ends in `pem`, `key`, `p12`, `pfx`, `dump`, or `sql`. Only `client/release/shared/dsa_pub.pem` is allowlisted because both clients embed it.
- The three legacy agent-state fixtures were the only offenders. Fix them by renaming, not by rewriting content, deleting coverage, or asking the host to widen its check.
- Convention: keep the real format as a trailing double extension (`legacy_pre_112_schedules.sql.txt`). It reads as SQL, ends in a safe suffix, and stays consistent with the sibling `*.schema.txt` snapshots.
- No content change: the rename is byte-identical and `git mv` preserves history.
- The rule is enforced from the Agent package because that is where the fixtures live, but it covers the whole public repository through the Git index; client or tooling fixtures are caught by the same guard.
- Out of scope: the host-side artifact check, private deploy workflows and pinning, release metadata, and any runtime or deployment action.

## Gates

### G0 — Discovery
- [x] Confirm the three `.sql` fixtures are the only tracked paths with a rejected suffix (`git ls-files`).
- [x] Trace every reference: the snapshot test's fixture path builder and the fixture paragraph in `docs/technical/agent_database_schema.md`.
- [x] Confirm CI shards pick up a new `test/guards/*_test.dart` file automatically (`scripts/ci/list_test_shard.sh`) and that the changed paths require no protected review label.

### G1 — Rename and references
- [x] `git mv` the three fixtures to `*.sql.txt`.
- [x] Point the fixture path builder at `*.sql.txt` and state the naming reason next to it.
- [x] Update the fixture documentation to name the new suffix and the deploy rule.

### G2 — Guard
- [x] Add `agent/test/guards/deploy_artifact_suffix_guard_test.dart`: it reads the Git index, fails on any blocked suffix except the allowlisted key, and its message explains the private deploy artifact rule and the rename convention.
- [x] Keep the allowlist honest with a stale-entry check and prove non-vacuity: a classifier test for each blocked suffix, mixed-case detection, safe double extensions, and the exact-path allowlist.
- [x] Prove the guard fails on a real violation by staging a probe `.sql` file, observing the failure, and removing the probe.

### G3 — Verification
- [x] `fvm dart analyze` in `agent/`: `No issues found!`.
- [x] `fvm dart test test/evolution/agent_state_schema_snapshot_test.dart test/guards/deploy_artifact_suffix_guard_test.dart`: 14 passed.
- [x] `fvm dart run scripts/lint_wiki.dart` from the repository root: no documentation errors.
- [x] Record the naming rule in `agent/AGENTS.md` and the fixture doc.

## Acceptance criteria
- [x] No tracked file in the public repository ends in `.pem`, `.key`, `.p12`, `.pfx`, `.dump`, or `.sql` except `client/release/shared/dsa_pub.pem`.
- [x] The three legacy agent-state fixtures still load, migrate, and match their pinned schema snapshots byte for byte.
- [x] A newly committed `.sql` (or other blocked suffix) file fails an Agent guard test with a message that explains the deploy consequence and the rename convention.
- [x] The guard cannot pass vacuously: it asserts the index listing is non-empty and repository-relative, and its suffix matcher is exercised directly.

## Definition of Done
- [x] Analyzer clean, focused fixture and guard tests green, documentation lint clean.
- [x] Owning contract (`agent/AGENTS.md`) and fixture documentation updated in the same change.
- [x] Renames carry no content change and preserve file history.
- [ ] Pull request opened against `main` with the mandatory `type/*` and `comp/*` labels and pushed for review; merge remains an owner decision.

## Implementation record

### Renamed fixtures
`agent/test/evolution/fixtures/agent_state/legacy_pre_workspace_uuid.sql`, `legacy_pre_attachments_v2.sql`, and `legacy_pre_112_schedules.sql` became the same names plus `.txt`. Only `agent/test/evolution/agent_state_schema_snapshot_test.dart` resolves those paths, so it is the single code reference; `docs/technical/agent_database_schema.md` carried the only documentation reference.

### Guard boundary
The guard reads `git ls-files -z --cached` from the checkout root found by walking up for `.git` (a directory in a normal checkout, a file in a worktree or submodule), so an untracked local artifact never fails it and a committed offender never escapes it. A missing Git or a checkout without an index fails closed with an actionable message rather than silently reporting a clean tree, because the deploy archives tracked content only.
