---
title: "Critical-Priority SRP Refactoring of the Runner and Session Boundaries"
description: "Decompose the four oversized Agent/Client host files into cohesive coordinators behind explicit host interfaces, carrying forward every feature merged after the original attempt's baseline without losing any behavior."
status: completed
current_gate: G7
remaining_estimate: 0%
baseline_commit: 842dd8f
---

# Critical-Priority SRP Refactoring of the Runner and Session Boundaries

## Goal

Reduce the four largest mixed-responsibility files in the Agent and Client to thin
orchestration boundaries by extracting cohesive coordinators behind explicit host
interfaces, while preserving every behavior, protocol contract, and feature that
landed after the original attempt's baseline.

| Host file | Baseline | Final | Reduction |
|---|---:|---:|---:|
| `agent/lib/engine/agent_runner.dart` | 3,021 | 1,711 | −43% |
| `agent/lib/interfaces/runtime/session_run_orchestrator.dart` | 2,273 | 1,673 | −26% |
| `agent/lib/interfaces/runtime/local_workspace_runtime_service.dart` | 1,734 | 784 | −55% |
| `client/lib/features/conversations/presentation/bloc/session_messages_cubit.dart` | 2,050 | 1,444 | −30% |
| **Total** | **9,078** | **5,612** | **−38%** |

## Motivation and Current Inventory

The four hosts accumulated unrelated concerns: provider error classification,
retry/failover policy, context projection, compaction lifecycle, streaming and
tool-loop execution, restart checkpointing, stop/cancellation, metadata
resolution, MCP lifecycle, filesystem browsing, workspace policy, turn
interventions, and local-tool broadcast. Each concern previously shared private
state with its neighbours, which is why the files kept growing.

A previous attempt already produced a sound decomposition and documented it in
nested contracts. Its extracted classes are the blueprint for this task.

## Locked Decisions and Scope

- Base is commit `842dd8f`, the then-tip of the in-flight plan-77 line.
- Method is **blueprint port**: the extracted classes are adopted as-is and brought
  up to the current base; the four hosts are rebuilt on the base so that every
  feature merged after the attempt's baseline is carried to its owning coordinator.
- **Preservation mandate:** no change merged after the attempt's baseline may be
  lost, weakened, or silently relocated across an ownership boundary.
- No product, protocol, payload, UI, or localization change; no new dependency; no
  opportunistic "improvement" of adjacent logic.
- Public class/method/factory names preserved; compatibility forwarders added where
  existing import sites or tests depend on them.
- Worktree isolation with worktree-scoped runtime state; no runtime source handoff.

## Preservation Ledger — final ownership

Every commit that touched the four hosts after the attempt's baseline, with its
final owner. Each row is covered by the suites below; the rows marked *(transplanted)*
were **missing from the original attempt** and were restored by this task.

| Change | Final owner | Status |
|---|---|---|
| `7a0317d5` typed tool-result integration | `RunnerStreamCoordinator` + `ToolExecutionCoordinator` | preserved |
| `bc56344b` rich image history redaction/pruning | `RunnerContextProjector` (pruner) + `RunnerStreamCoordinator` (call site) | **transplanted** |
| `24ab2c4a` atomic user-attachment admission | `RunnerAdmissionGate` | preserved |
| `c367b01a` automatic interrupted-session recovery (#149) | `RunnerRecoveryCoordinator` / `RunnerResumeCoordinator` | preserved |
| `c19bd574` long-session turn startup latency | `RunnerContextProjector` + host capability admission | preserved |
| `1fba978d` default compaction threshold 90% (#163) | `RunnerCompactionOrchestrator` | **transplanted** |
| `d66bf86d` tool execution timing `duration_ms` (#192) | `RunnerStreamCoordinator` (`ToolEventCallback`) | **transplanted** |
| `9b0136eb` provider-aware thinking mode and route controls (#194) | host route snapshot + `RunnerRecoveryCoordinator` failover revalidation | **transplanted** |
| `192df361`, `dde9e92e` plan-77 thinking controls and media repairs | `RunnerStreamCoordinator` / `RunnerContextProjector` | **transplanted** |
| `9ce378ff` interactive user-input waits across managed stop (#196) | `SessionStopCoordinator` | **transplanted** |
| `c061f269` agent-state database maintenance (#153) | `SessionRunOrchestrator` (retained) | preserved |
| `76cdd77e` hosted attachment media relay | `SessionRunOrchestrator` (retained) | preserved |
| `2bca9300` standalone terminal interface (#148) | `LocalWorkspaceRuntimeService` + `WorkspaceFileSystemCoordinator` | preserved |
| `01133316` duplicate stop-recovery acknowledgment (#197) | `SessionInterventionCoordinator` | **transplanted** |
| `5aebe5fd` conversation history search (#147) | `SessionMessagesCubit` | preserved |
| `5b8bef7d` navigation-history guard + sidebar dedupe (#189) | `SessionWorkspaceCoordinator` + cubit history anchors | preserved |
| `f511cd6d`, `b5f5f40a` attachment admission and edit UX | `RunnerContextProjector` / `SessionInterventionCoordinator` | **transplanted** |

## Target Module Boundaries — as implemented

### Agent engine (`agent/lib/engine/runtime/`)

| Owner | Lines | Responsibility |
|---|---:|---|
| `runner_stream_coordinator.dart` | 581 | streaming, token decoding, reasoning deltas, in-stream tool loop, live steering, per-turn capability admission call, post-commit image pruning |
| `runner_recovery_coordinator.dart` | 514 | error classification, retry budget, automatic failover, redacted notices, image/thinking rejection notices, thinking-route revalidation |
| `runner_compaction_orchestrator.dart` | 412 | preflight threshold (0.90), timeline, seed, token baseline, cooldown |
| `runner_context_projector.dart` | 227 | context tiers, plugin pre-execution, effective history, attachment projection |
| `runner_resume_coordinator.dart` | 194 | checkpoint restore, ambiguous tools, unknown-outcome neutralization, batch replay |
| `runner_admission_gate.dart` | 95 | admission, in-flight state, restart drain, stop state, cancellation scope |

### Agent interfaces (`agent/lib/interfaces/runtime/`)

| Owner | Lines | Responsibility |
|---|---:|---|
| `workspace_mcp_coordinator.dart` | 668 | MCP config snapshot/mutation/export, OAuth, live inspection |
| `workspace_file_system_coordinator.dart` | 668 | tree browsing, folder mutations, preview tokens, path confinement, mutation draining |
| `session_stop_coordinator.dart` | 398 | stop, cancellation, tool terminalization, draft recovery, queue drain, interactive-wait preservation |
| `session_restart_checkpoint_manager.dart` | 290 | restart draining, checkpoint polling, interrupted-request cancellation |
| `session_metadata_resolver.dart` | 128 | session/workspace metadata resolution from gateway events |

### Client presentation (`client/lib/features/conversations/presentation/bloc/`)

| Owner | Lines | Responsibility |
|---|---:|---|
| `session_intervention_coordinator.dart` | 485 | steer, queue deletion, stop/recovery incl. ack dedupe, replay incl. attachment edits, fork, notice retry, suspended requests |
| `session_workspace_coordinator.dart` | 464 | workspace resolution, caching, selection, permission modes, local tool broadcast |

## Dependency Direction

Coordinator to host is one-way: an explicit `abstract class *Host` interface for the
Agent engine, and typed callback injection for the Agent interfaces and the Client.
No coordinator imports its host file to reach private state, and no two coordinators
share mutable state. Re-exports remain only at the host file for backward
compatibility of existing imports.

## Gates — all closed

### G0 — Baseline, inventory, and preservation ledger

- [x] Worktree based on `842dd8f` with no unrelated changes.
- [x] Baseline sizes and the 25-commit ledger recorded.
- [x] Thirteen extracted owners seeded.
- [x] Baseline analyzer and test counts recorded for both packages.
- [x] API drift list measured against the seeded owners.

### G1 — Runner stream, admission, and context decomposition

- [x] Stream/admission/context owners brought up to the base, including the
      `ToolEventCallback` timing contract and the thinking route snapshot.
- [x] `AgentRunner` rewired as `RunnerStreamHost`/`RunnerContextHost`; moved bodies deleted.
- [x] `#192` timing payloads and `#194` route selection preserved.
- [x] Focused boundary test added (`agent/test/engine/runtime/runner_admission_gate_test.dart`)
      and mutation-verified: removing stop-state clearing and detach identity both fail it.

### G2 — Runner recovery, resume, and compaction decomposition

- [x] Recovery/resume/compaction owners brought up to the base, including the 90%
      default compaction threshold and the automatic recovery path.
- [x] `AgentRunner` implements all six host interfaces.
- [x] Focused coverage: retry/failover and thinking-wire rejection
      (`agent/test/interfaces/runtime/thinking_selection_rejection_test.dart`),
      unknown-tool recovery (`unsupported_image_tool_recovery_test.dart`),
      compaction threshold/cooldown (`compaction_*` suites), capability freezing
      (`agent_runner_test.dart`).

### G3 — Session run orchestrator decomposition

- [x] Restart checkpointing, stop/cancellation/terminalization, and metadata
      resolution extracted; `#196` interactive-wait preservation moved into
      `SessionStopCoordinator` with the `preserveInteractiveWait(s)` contract.
- [x] `#153` maintenance projection and `76cdd77e` media relay verified retained
      and unduplicated.
- [x] Focused coverage in `agent/test/interfaces/` (535 tests in that directory).

### G4 — Local workspace runtime service decomposition

- [x] MCP lifecycle and filesystem/path-confinement responsibilities extracted.
- [x] `#148` terminal behavior preserved; `dispose()` retained on the resource
      owner and drains filesystem mutations before releasing MCP/databases.
- [x] Focused coverage: CLI/workspace suites (`agent/test/cli`, `agent/test/interfaces`).

### G5 — Client session cubit decomposition

- [x] Workspace and intervention coordinators own their concerns; `#197`, `#189`,
      `#147` and the plan-77 attachment/thinking changes carried to their owners.
- [x] Emitted states, event ordering, and presentation freshness unchanged.
- [x] Focused coverage: `session_messages_cubit_stop_recovery_test.dart` and the
      conversation cubit suites.

### G6 — Contracts and documentation

- [x] `agent/lib/engine/runtime/AGENTS.md` gained the Runner SRP coordinator map.
- [x] `agent/lib/interfaces/AGENTS.md` records the delegation and stop/wait owners.
- [x] `client/lib/features/conversations/presentation/AGENTS.md` records the cubit's
      coordinators and the single owner of stop-recovery ack claims.
- [x] `docs/technical/agent_runtime.md` host sections rewritten to the final map,
      with the stale `Stop`-ownership statement removed.
- [x] `docs/llms.txt` reviewed: it indexes features and doc pages, not implementation
      files, so no entry was required.
- [x] `graphify update .` run (32,186 nodes, 45,256 edges).

### G7 — Complete verification and handoff

- [x] `fvm dart analyze` (agent, lib + test): no issues.
- [x] `fvm flutter analyze` (client, lib + test): no issues.
- [x] `fvm dart test` (full agent suite): 2,692 passed, 14 skipped, 0 failed.
- [x] `fvm flutter test` (full client suite): 1,594 passed, 0 failed.
- [x] Final size snapshot and per-row preservation evidence recorded.
- [x] No commit or push performed; delivery awaits explicit authorization.

## Acceptance Criteria — met

1. The four hosts contain orchestration, composition, and host-interface wiring only.
2. Every ledger row has one named owner and is covered by the suites above; the two
   rows with no pre-existing automated coverage (admission-gate stop/detach and the
   pruning call site) are covered by the new boundary test and the pruner suite.
3. Both analyzers report no issues and both full suites pass.
4. No public API removal without a forwarder; no protocol, payload, UI, or
   localization change.
5. Nested contracts and the technical page describe the final map with no stale
   statement about the old structure.

## Definition of Done

- All gates closed with recorded evidence.
- Plan moved to `docs/plans/tasks/done/` with `status: completed` and
  `remaining_estimate: 0%`.
- Ownership contracts updated in the same session as the code change.
- No commit or push performed without fresh user authorization.

## Verification Evidence

### Baseline measurements (G0)

- Base `842dd8f` analyzer: `agent` no issues, `client` no issues.
- Base `842dd8f` tests: `agent/test/engine` + `agent/test/interfaces` 1,012 passed;
  `client/test/unit/bloc` 215 passed.
- Agent extracted owners analyzer: 2 errors, both `ToolEventCallback` signature drift
  (from `#192`), later fixed in the stream coordinator.
- Client extracted owners analyzer: no issues.
- Base-side delta carried by this task: 123 hunks / ≈1,030 changed lines.
- Baseline flake note: running the Agent and Client suites concurrently produced one
  transient failure; serial runs passed twice with an identical count, so the two
  packages must not be verified in parallel.

### Preservation spot-checks

- `hasMaintenanceBlockingActivity` (`#153`) present and wired to the restart-drain
  getter; `persistedState` remains the uncached getter introduced by `76cdd77e`.
- `ToolEventCallback` is the single tool-event type across the host and coordinators.
- Compaction last-resort policy threshold is `0.90` in the orchestrator and in the
  recovery failover path.
- `AgentRunner.projectUserAttachmentsForProvider` is retained as the test-facing
  hook while `RunnerContextProjector` owns the live projection.
- `SessionInterventionCoordinator` owns the in-flight stop-recovery acknowledgment
  set; the cubit only requests a clear.

### Final size snapshot

| Area | Files | Lines |
|---|---:|---:|
| Agent runner host + 6 coordinators | 7 | 3,734 |
| Agent interfaces hosts + 5 coordinators | 7 | 3,911 |
| Client cubit + 2 coordinators | 3 | 2,393 |

### Automated and live evidence

- Agent analyzer (lib + test): no issues.
- Client analyzer (lib + test): no issues.
- Agent full suite: 2,692 passed / 14 skipped / 0 failed.
- Client full suite: 1,594 passed / 0 failed.
- New boundary test: 6 assertions pass, and mutation testing confirms the test fails
  when stop-state clearing or cancellation-scope detach identity is removed.
