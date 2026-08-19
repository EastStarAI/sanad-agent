---
title: "Serialize Concurrent Permission Prompts"
status: complete
current_gate: done
remaining_estimate: "0%"
---

# Serialize Concurrent Permission Prompts

## Goal
Prevent a session from becoming trapped when a parallel tool batch contains multiple calls that require user approval by allowing at most one unresolved permission prompt per session.

## Locked Decisions and Scope
- Serialize only permission authorization for the same session; preserve concurrency across sessions.
- Preserve parallel execution for tools that do not require approval and for post-authorization tool work.
- Keep the existing single pending-permission client and session-hydration contract.
- Re-evaluate policy when each queued authorization reaches the front so prior session or workspace grants take effect.
- Do not change runtime source or stop any active runtime during implementation.

## Gates

### G0 — Discovery
- [x] Confirm parallel tool execution can enter multiple external-path permission checks concurrently.
- [x] Confirm the client and history hydration project only one pending permission per session.
- [x] Select daemon-side per-session FIFO serialization as the smallest safe ownership fix.

### G1 — Implementation
- [x] Add per-session permission authorization serialization in `PermissionManager`.
- [x] Ensure queue cleanup occurs after success, denial, or exception.
- [x] Add focused concurrent regression coverage.

### G2 — Documentation and Verification
- [x] Document the one-unresolved-permission-per-session invariant.
- [x] Extend external workspace access QA with the parallel batch scenario.
- [x] Format and analyze the agent changes.
- [x] Run focused permission-manager and relevant engine tests.
- [x] Update Graphify and review the final diff.

### G3 — Daemon-backed multi-request verification
- [x] Extend the deterministic E2E adapter with a parallel external-file-read scenario.
- [x] Verify over the authenticated local socket that only one permission request is emitted before each response.
- [x] Resolve every request and verify all tool results reach a terminal final answer.
- [x] Run the focused E2E sequentially, re-run analysis, and update Graphify.

## Acceptance Criteria
- [x] Given five concurrent approval-requiring calls in one session, only one permission request is active at a time.
- [x] Resolving one request exposes the next request without leaving hidden waiters.
- [x] A denial or exception releases the queue for later requests.
- [x] Approval requests from different sessions are not serialized against each other.
- [x] Non-sensitive tools remain outside the permission queue.

## Definition of Done
- [x] Focused automated tests pass.
- [x] `fvm dart analyze` passes with bounded output.
- [x] Runtime and QA documentation match behavior.
- [x] `graphify update .` completes.
- [x] No commit, push, runtime switch, stop, or restart occurs without separate user authorization.
