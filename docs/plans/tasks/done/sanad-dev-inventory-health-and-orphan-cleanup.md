---
title: "sanad-dev inventory Health Columns and Confirmed Orphan Cleanup"
description: "Layer 1 of 2: per-worktree disk, commit age, upstream, optional gh PR state, and a removal verdict in the read-only inventory projection, plus an explicit dry-run-first cleanup-orphans command for the sanad-dev dev area."
---

# sanad-dev inventory Health Columns and Confirmed Orphan Cleanup

## Goal

Give an operator (and a machine consumer through `inventory --json`) enough
evidence per worktree to decide whether that worktree can be removed, and add one
explicit, dry-run-first command that prunes the orphaned records the projection
reports — without ever touching a live runtime, the primary Home's own data, a
Test Home, or anything outside the sanad-dev dev area.

## Locked decisions and scope

- This layer is generic: it knows nothing about any parent/private repository, a
  superproject, or a private path or name. A private consumer reads `--json`.
- `inventory` stays read-only by default. The optional `gh` PR lookup is opt-in
  (`--pr`), cached in the gitignored `.sanad-dev/inventory/pr-cache.json`, and
  never required: missing `gh`, no network, and a hung child each produce a
  reported marker instead of a failure.
- Verification of a worktree removal is advisory only. `inventory` prints
  `removal=safe|keep` with a reason and never removes a worktree.
- Pruning stays a separate command: `cleanup-orphans` is dry-run by default,
  deletes only with `--confirm`, only inside `<primary home>/dev`, and refuses a
  live runtime, the primary Home, a Test Home, a symbolic link, and any target
  outside that area.
- `cleanup-target-orphans` remains the target-Client cleanup operation and is
  unchanged; the new command reuses the existing Home, lease, and liveness
  helpers instead of duplicating discovery.
- No process is started, stopped, or signaled by either command.

## Gates

### G0 — Discovery

- [x] Read the repository, `sanad-dev`, and runtime-domain contracts plus the
      runtime-ownership and inventory documentation.
- [x] Confirm the existing inventory model, collector seams, JSON schema, orphan
      classification, and size guard (700 lines per file, 250 for `cli.dart`).

### G1 — Health columns

- [x] Add bounded disk sizing with a marker when the budget or entry limit ends
      the walk early.
- [x] Add last-commit timestamp/age and upstream state (none/tracking/gone with
      ahead/behind).
- [x] Add the opt-in `gh` PR lookup with a bounded child, a global budget, a
      cache with TTL, negative caching, and offline fail-soft behavior.
- [x] Add the `safe`/`keep` removal verdict with a reason, computed from clean +
      pushed/merged and live-runtime/Test-Home/lock/detached evidence.
- [x] Bump the JSON schema to `2` additively and expose the new columns in the
      table, `--all`, and `--json`.

### G2 — Confirmed orphan cleanup

- [x] Add `sanad-dev cleanup-orphans [--confirm] [--json]`, dry-run by default.
- [x] Build the plan from the read-only inventory projection and re-verify with a
      fresh projection before deleting.
- [x] Refuse every target outside the dev area, the primary Home, a Test Home, a
      symbolic link, the dev-area group roots, and any live runtime/lease.
- [x] Print exactly what would be (or was) deleted and return nonzero on any
      deletion failure.

### G3 — Verification and documentation

- [x] Cover verdicts, upstream states, disk markers, PR offline/cache behavior,
      JSON schema, cleanup dry-run/confirm/idempotence, and each refusal.
- [x] Update the runtime-ownership technical doc, the QA matrix, the CLI help,
      the package README, the developer guide, and the owning contracts.

## Acceptance Criteria

- [x] Given a clean worktree merged into `origin/main` with no live runtime and no
      Test Home, `inventory` reports `removal=safe` with
      `clean and merged into origin/main`.
- [x] Given a dirty, unpushed, locked, detached, live, Test-Home, primary, or
      missing worktree, `inventory` reports `removal=keep` and names that reason
      first.
- [x] Given no `gh` binary, an unauthenticated `gh`, or a `gh` child that never
      answers, `inventory --pr --json` still completes and reports
      `pull_request_lookup` as `unavailable` or `timeout`.
- [x] Given a warm PR cache for the same branch head, a second `--pr` run answers
      from the cache without invoking `gh`.
- [x] Given a cold cache and a slow repository, the disk pass ends inside one
      global budget and every unmeasured row reports `disk_scan=skipped`.
- [x] Given `cleanup-orphans` with no `--confirm`, no file or directory is
      deleted and the plan lists every target with its action.
- [x] Given `cleanup-orphans --confirm`, only in-area, non-live orphan targets are
      deleted, and a second run reports nothing to clean.
- [x] Given a Test Home endpoint record, a primary Home record, an out-of-area
      path, a symbolic link, or a live runtime, the plan refuses that exact target
      with a named reason.
- [x] `inventory --json` keeps every existing key and adds only the documented
      schema-2 keys.
- [x] `fvm dart analyze` and `fvm dart test` pass in `scripts/sanad_dev/`.

## Definition of Done

- [x] Analyzer clean and the focused plus full fast suite green in
      `scripts/sanad_dev/`.
- [x] Owning documents updated in the same change: the technical ownership doc,
      the QA matrix, `scripts/sanad_dev/AGENTS.md`, the package README, the
      developer guide, and the documentation index descriptions.
- [x] Graph refreshed with `graphify update .`.
- [x] No process, Test Home, supervisor, runtime, or Home fixture on the
      development machine is started, stopped, or pruned; every test uses
      throwaway directories.
- [x] Delivered as a focused pull request with the mandatory labels.
