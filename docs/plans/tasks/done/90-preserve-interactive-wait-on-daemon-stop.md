# 90 — Preserve Interactive User-Input Waits Across Managed Daemon Stop

## Goal

A conversation parked on `system_ask_user` or a tool-permission prompt must survive a managed daemon stop (`sanad-dev stop` / `DaemonRestartCoordinator.stop()`) exactly as it survives a power cut: no synthetic tool result is recorded, and startup recovery restores the session as `waiting` for the user's decision.

## Locked Decisions and Scope

- Only **managed shutdown** (`DaemonRestartCoordinator.stop()` → `SessionRunOrchestrator.requestStopAll`) preserves interactive waits. An **explicit user Stop** (gateway `stop` event / `session.runtime_stop`) keeps the current cancelling behavior and may still report `cancelled_by_user`.
- Preservation condition mirrors `SessionRecoveryRestorer`'s `isInteractiveWait`: the active work item is `running` or `waiting`, `currently_executing_tools` is non-empty, and every id is owned by a suspended checkpoint for the same session whose status is not `executing_tool` (i.e. `awaiting_permission` or `decision_ready`).
- A checkpoint in `executing_tool` status (decision approved, side effect possibly started) is **not** preserved; existing interrupted-tool recovery (unknown outcome) remains correct there.
- The preserved run is **not** cancelled in memory: the awaiting tool owns the durable checkpoint and its cancellation path may delete it (`system_ask_user` `finally` block). The exiting process abandons the in-memory wait; durable state stays truthful (`running` → `waiting`).
- Preserved sessions skip: `markSessionStopping`, tool terminalization, durable clear (`clearAllForSession`/`cancelWorkItems`), queued-event removal, and the synthetic `Execution stopped.` emission.
- Mixed work (any executing tool not owned by an unresolved checkpoint) falls back to the existing terminalizing stop.

## Gates

### G0 — Discovery
- [x] Trace managed-stop path: `DaemonRestartCoordinator.stop()` → `requestStopAll()` → `_requestStop` → `ToolTerminalizationService.terminalizeExecutingTools` records synthetic tool results for parked interactive tools.
- [x] Confirm crash-recovery counterpart (`SessionRecoveryRestorer` interactive-wait detection) already restores power-cut sessions as `waiting`.

### G1 — Implementation
- [x] Add `preserveInteractiveWait` flag to `requestStop`/`_requestStop`; short-circuit before any mutation when the interactive-wait condition holds.
- [x] Transition the preserved work item `running` → `waiting`; drop in-memory run/busy projections only.
- [x] Add `preserveInteractiveWaits` parameter to `requestStopAll`; pass `true` from `DaemonRestartCoordinator.stop()`.

### G2 — Regression Coverage
- [x] Managed stop preserves an ask_user/permission-parked session: work item stays active as `waiting`, no terminal tool records, suspended checkpoint intact, no history pollution.
- [x] Explicit user stop on the same setup still terminalizes (unchanged behavior).
- [x] `executing_tool`-status checkpoint is not preserved.
- [x] Existing `requestStopAll` test (no interactive checkpoints) still passes unchanged.

### G3 — Documentation
- [x] Update the owning `agent/` contract for the managed-stop preservation law.
- [x] Update the durable stop/recovery design page in `docs/`.

## Acceptance Criteria

- [x] Given a session awaiting `system_ask_user` or a permission decision, when the daemon stops via `DaemonRestartCoordinator.stop()`, then no tool-result message is appended to history, the suspended checkpoint row survives, and the work item is durable `waiting`.
- [x] Given the same session after the next daemon startup, when recovery runs, then the session is restored as `waiting` and the user can still answer the original prompt.
- [x] Given an explicit user Stop on a parked session, when `requestStop` runs without the preserve flag, then behavior is byte-identical to today (terminal records + `Execution stopped.`).
- [x] Automated coverage proves all of the above; `fvm dart analyze` and focused tests pass.

## Definition of Done

- [x] `set -o pipefail; fvm dart analyze 2>&1 | tail -5` clean in `agent/`.
- [x] Focused orchestrator/stop tests pass.
- [x] Owning `AGENTS.md` and `docs/` page updated in the same session.
- [x] `graphify update .` run after code changes.
- [x] No commit/push before user review.

## Current Status

- Gate: Complete
- Remaining: 0%
