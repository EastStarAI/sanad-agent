---
id: 107
title: Agent Update Trust Diagnostics and Client Auto-Pairing
status: completed
gate: G4
created: 2026-10-13
branch: fix/107-agent-update-trust-diagnostics-and-auto-pairing
---

# Task 107 — Agent Update Trust Diagnostics and Client Auto-Pairing

## Goal

Resolve Issue #203 by replacing opaque platform trust rejection with typed, bounded, and sanitized diagnostics in the shared release contract (`release/contract/`) and agent update service (`agent/`). Document the legacy upgrade boundary (v1.0.0–v1.0.4) and actionable official-installer recovery path.

Additionally, address the client-agent version pairing gap on desktop: fix the bootstrap short-circuit in `GatewayConnectionCubit` so that whenever the desktop client connects to an older local agent daemon, it automatically initiates the verified background update to the exact client version without requiring manual intervention from the settings UI.

## Locked Decisions & Scope

1. **Security & Platform Trust Boundary (Fail-Closed):**
   - Retain the exact Apple-anchored Developer ID requirement (`Developer ID Application: NanoSoft LY LLC (UC2824B99G)`).
   - Under no circumstances weaken platform code-signing checks or remove strict signature verification.
   - Preserve fail-closed behavior for untrusted binaries, invalid signatures, or mismatched hashes.

2. **Sanitized & Bounded Diagnostics:**
   - Platform verifier failures must identify the precise failure stage (`metadata_validation`, `codesign_verification`, `publisher_requirement`, etc.).
   - Error messages must be sanitized to strip local user directories (`$HOME`, temp paths) to prevent leaking private paths or environment information.
   - Diagnostics must be bounded in length (e.g. truncated stderr).

3. **Backward Compatible Shared Contract:**
   - Preserve `Future<bool> verifyReleaseArtifactTrust(...)` for existing callers.
   - Introduce `Future<PlatformTrustResult> verifyReleaseArtifactTrustDetailed(...)` returning structured failure stage, exit code, and sanitized details.

4. **Actionable CLI Guidance:**
   - When `sanad update` fails with `trustFailed`, print clear recovery guidance with the official installer command (`curl -fsSL https://sanad.eaststarai.com/install.sh -o install.sh && bash install.sh --no-login`) and warn about service restart.

5. **Desktop Client Local Agent Auto-Pairing:**
   - In `GatewayConnectionCubit`, ensure that checking the local daemon does not short-circuit past version comparison.
   - When a running local daemon is older than the client (`daemonVersion < clientVersion`), automatically trigger `_serviceManager.updateDaemon(targetVersion: clientVersion)`.

## Gates

### G0 — Discovery & Task Alignment
- [x] Analyze Issue #203 and PR #105 root cause.
- [x] Trace client-agent bootstrap and update flow in `gateway_connection_cubit.dart` and `device_connection_coordinator.dart`.
- [x] Create isolated Git worktree `.agent/worktrees/107-agent-update-trust-diagnostics-and-auto-pairing` and task plan.

### G1 — Shared Release Contract Diagnostics (`release/contract/`)
- [x] Define `PlatformTrustResult` in `release/contract/lib/release_contract.dart` with stage, exit code, and sanitized detail.
- [x] Implement `verifyReleaseArtifactTrustDetailed` and path-sanitizing helper.
- [x] Keep `verifyReleaseArtifactTrust` delegating cleanly to the detailed verifier.
- [x] Add unit tests in `release/contract/` covering sanitized failure details and fail-closed checks.

### G2 — Agent Update Service & CLI Recovery Guidance (`agent/`)
- [x] Update `AgentUpdateService` in `agent/lib/core/update/agent_update_service.dart` to consume detailed trust diagnostics in `AgentUpdateResult.message`.
- [x] Enhance `UpdateCommand` in `agent/lib/cli/runner/commands/update_command.dart` with actionable recovery instructions upon trust failure.
- [x] Add tests in `agent/test/core/update/release_manifest_test.dart` for typed trust diagnostic messages.

### G3 — Client Local Daemon Auto-Pairing (`client/`)
- [x] Fix bootstrap short-circuit in `client/lib/features/devices/presentation/bloc/gateway_connection_cubit.dart`.
- [x] Ensure `checkAndStartLocalDaemon` verifies version and triggers `updateDaemon` when `daemonVersion < clientVersion`.
- [x] Add unit/cubit tests in `client/test/` validating auto-update triggering on outdated local daemon.

### G4 — Documentation & Regression Verification
- [x] Update `docs/technical/update_architecture.md` with legacy upgrade notes, recovery path, and sanitized trust reporting.
- [x] Run bounded analyzers: `fvm dart analyze` and `fvm flutter analyze`.
- [x] Run focused unit test suites.
- [x] Run `graphify update .`.

## Acceptance Criteria

- [x] Given a macOS artifact with invalid code signature or wrong publisher, when `verifyReleaseArtifactTrustDetailed` runs, it returns a failed `PlatformTrustResult` containing the failed stage and sanitized output without user paths.
- [x] Given `sanad update` hitting a platform trust failure, the CLI output includes sanitized diagnostic stage information and official installer recovery guidance.
- [x] Given a desktop client launching with an older local agent running in the background, the client detects the version mismatch and automatically initiates daemon update to the client version.
- [x] All code passes `fvm dart analyze` and `fvm flutter analyze` with zero errors.

## Definition of Done

- [x] Implementation completed across `release/contract/`, `agent/`, and `client/`.
- [x] Unit and regression tests passing.
- [x] Technical documentation updated in `docs/technical/update_architecture.md`.
- [x] Codebase knowledge graph updated via `graphify update .`.

## Current Status
- Gate: G4 (Completed)
- Verified: All unit, widget, and cross-platform CI checks passing across Linux, macOS, and Windows
- PR: #211
