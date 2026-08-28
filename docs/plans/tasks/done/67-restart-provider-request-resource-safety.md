---
title: "Restart Provider Request Resource Safety"
description: "Prevent controlled daemon restart from silently replaying an interrupted provider request and consuming duplicate tokens."
status: "ready_for_review"
progress: "95%"
scope: "agent engine and runtime interfaces"
related_to: "Task 34 partial stream recovery; Plan 50 run cancellation"
---

# Task 67: Restart Provider Request Resource Safety

## Goal

Prevent controlled daemon restart from replaying an interrupted provider request while preserving established rate-limit recovery, tool-origin restart checkpoints, queued input, and unsafe-tool behavior.

## Locked Decisions and Scope

- A live provider request blocks controlled restart while the caller-selected timeout remains.
- If the response becomes durable before timeout, restart proceeds normally.
- If timeout expires and every blocker is an active provider request, cancel only the exact still-owning streams, preserve blocked recovery, and restart.
- Startup never automatically replays a provider request whose outcome is unknown because of process interruption.
- A provider request that ends in a known runtime failure restores its previous safe checkpoint before normal waiting, failover, or blocked-recovery policy runs.
- Tool-origin restart retains its exact `after_tool_result` completion boundary.
- Unsafe executing tools retain the existing timeout and force policy.
- Queued input remains durable while restart drain owns admission.

## Gates

### G0 — Review and Regression Triage

- [x] Review the complete worktree diff and owning runtime contracts.
- [x] Run analyzer, focused tests, full fast tests, and daemon-backed recovery E2E.
- [x] Identify checkpoint-lifecycle, tool-origin restart, and stale-blocker race risks.

### G1 — Checkpoint Lifecycle Safety

- [x] Restore the previous safe checkpoint when a live provider request ends without a durable model response.
- [x] Settle persisted intermediate provider responses before tool execution or semantic continuation.
- [x] Preserve the terminal response marker until authoritative terminal commit.
- [x] Preserve `after_tool_result` for tool-origin restart completion.

### G2 — Exact-Owner Restart Interruption

- [x] Bind restart blockers to exact work-item, run, and generation ownership.
- [x] Revalidate active provider ownership synchronously before blocking or cancelling.
- [x] Emit blocked recovery only after the exact durable owner transitions successfully.

### G3 — Verification and Documentation

- [x] Add focused checkpoint and stale-owner regression coverage.
- [x] Pass analyzer and focused engine/interface tests.
- [x] Pass the full fast agent suite.
- [x] Pass daemon-backed durable restart E2E with sequential execution.
- [x] Update technical/runtime documentation and Graphify output.

## Acceptance Criteria

- [x] Given an active provider request, controlled restart waits while the request remains active.
- [x] Given completion before timeout, the response is persisted and no interruption or replay occurs.
- [x] Given provider-only timeout, only the exact active provider owners become blocked and restart may proceed.
- [x] Given a stale timeout snapshot after provider completion, the completed run is not cancelled or given a blocked notice.
- [x] Given a known provider error such as rate limit, restart recovery retains the established waiting/change-provider/stop behavior.
- [x] Given a tool-origin restart, the requester result reaches `after_tool_result` and restart can complete safely.
- [x] Given an interrupted provider request on startup, automatic replay does not occur and Retry, Change Provider, and Stop remain available.
- [x] Unsafe-tool timeout behavior and queued-input durability remain unchanged.

## Definition of Done

- [x] Analyzer, focused tests, full fast suite, and daemon-backed restart E2E pass.
- [x] Code, contracts, technical design, and this task status agree.
- [x] `graphify update .` completes after code changes.
- [x] Final diff contains no formatting errors, secrets, dependency drift, or unrelated files.
- [x] No commit or push is performed without explicit user authorization.

## Current Status

G0-G3 are complete. Automated review evidence is green; the remaining 5% is maintainer review and PR delivery after explicit commit/push authorization.
