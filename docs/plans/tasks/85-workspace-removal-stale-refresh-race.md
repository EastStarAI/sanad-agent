---
title: "Task 85 — Workspace Removal Stale Refresh Race"
description: "Prevent an older workspace-list response from restoring a workspace after a successful Settings mutation."
---

# Task 85 — Workspace Removal Stale Refresh Race

## Status

- **State:** Implementation, focused tests, analysis, documentation, and review are complete; Graphify maintenance is blocked because the executable is unavailable.
- **Branch:** `task/85-workspace-removal-stale-refresh-race`.
- **Delivery:** The owner authorized commit, push to the contributor fork, and a pull request to `EastStarAI/sanad-agent:main`.

## Goal

Keep successful workspace removal authoritative in the client cache even when a workspace-list refresh that started earlier completes afterward.

## Locked Decisions and Scope

- The daemon remains authoritative and the client updates its projection only after a successful mutation response.
- A successful create, rename, relocate, or remove mutation invalidates older in-flight workspace-list generations for the same device.
- Removal continues to delete only the workspace record; folders, files, and conversation rows remain unchanged.
- This task does not change the workspace protocol or perform visual/emulator verification.

## Gates

### G0 — Reproduce and locate ownership
- [x] Trace Settings confirmation through the repository, transport, daemon, and cache store.
- [x] Identify that removal does not invalidate an older in-flight workspace refresh.

### G1 — Implement cache ordering protection
- [x] Invalidate older workspace-list generations after successful update and removal mutations.
- [x] Preserve existing device-scoped cache cleanup and destination fallback behavior.

### G2 — Regression coverage and documentation
- [x] Add focused coverage for a refresh response arriving after successful removal.
- [x] Update workspace QA documentation with the race scenario and automated coverage.

### G3 — Verification
- [x] Run the focused Flutter test with bounded output.
- [x] Run Flutter analysis with bounded output.
- [x] Review production and test diffs.
- [ ] Run `graphify update .` (blocked: the `graphify` executable is unavailable on PATH).

## Acceptance Criteria

- [x] Given a workspace-list refresh is in flight, when removal succeeds and the older refresh then completes, the removed workspace stays absent.
- [x] Existing destination fallback and workspace projection cleanup still occur.
- [x] Rename and Change Path cannot be reverted by an older in-flight workspace-list response.
- [x] No daemon protocol or filesystem deletion behavior changes.

## Definition of Done

- [x] Focused regression test passes.
- [x] `fvm flutter analyze` passes.
- [x] QA documentation and this plan reflect the implemented behavior.
- [ ] Graphify is updated (blocked: executable unavailable).
