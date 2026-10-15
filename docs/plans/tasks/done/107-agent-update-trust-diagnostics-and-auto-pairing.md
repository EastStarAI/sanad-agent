---
id: 107
title: Agent Update Trust Diagnostics and Client Auto-Pairing
status: in_progress
gate: G5-R
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

6. **Agent Compatibility Validation Before Service Registration (G5):**
   - Ensure compatibility of the agent version and CLI capabilities with the desktop client's requirements before attempting to register or run the background service.
   - For stopped daemons (`health == null`), inspect the on-disk binary at `getExecutablePath()`. If it is older than `targetVersion`, has an unparseable version, or lacks required service CLI options (e.g. `--user-scope`), automatically update it to `targetVersion` using the verified bootstrap installer before registering or starting the service.
   - Validate dynamic service options compatibility (e.g. checking command help) rather than relying on hardcoded static version strings.
   - Reject downgrades safely if the installed executable is newer than `targetVersion`.
   - Ensure zero manual terminal commands and zero sudo are required on Ubuntu when an older agent (e.g. v1.0.15) is present and the user selects "Run Sanad Locally".

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

### G5 — Agent Compatibility Validation Before Service Registration (`client/`)
- [x] Implement `getInstalledExecutableVersion()` and `validateServiceInstallCompatibility()` on `StandaloneDaemonController`.
- [x] Update `StandaloneDaemonController.updateDaemon()` to validate on-disk executable compatibility when stopped, upgrading via verified bootstrap before registering or starting service.
- [x] Guard `registerService()` with pre-flight capability validation.
- [x] Update `DeviceConnectionCoordinator.checkAndStartLocalDaemon()` to handle stopped daemons safely via `updateDaemon`.
- [x] Add regression tests covering all 8 scenarios:
  - [x] Old agent not supporting CLI arguments with unregistered service.
  - [x] Old agent stopped with registered service.
  - [x] Old agent already running.
  - [x] Compatible agent with unregistered service.
  - [x] Clean fresh install (no agent present).
  - [x] Update/verification failure handling with rollback safety.
  - [x] Newer installed agent rejecting accidental downgrade.
  - [x] Retry after prior failure.
- [x] Verify Ubuntu acceptance scenario: agent v1.0.15 + unregistered service auto-updates, registers service, and starts on "Run Sanad Locally".

### G5-R — Reopened Hardening: Running-Daemon Scenarios & Real Linux Verification

Reopened after PR #211 review to close four verification gaps. All items below
must be backed by executable evidence, not manual reasoning.

- [ ] **R1 — Fix Scenario 3 test (running old agent, real update execution):**
  The current Scenario 3 only exercises a running daemon that already matches the
  target version. Replace/extend it so a daemon that is **actually running v1.0.15**
  faces a **newer Target Version** (v1.0.17), and the test asserts the update is
  **actually executed** (a gateway `POST /update` carrying `target_version=1.0.17`
  is observed) and the lifecycle ends `ready` after the daemon reports 1.0.17.
  Requires injecting the gateway HTTP client into `StandaloneDaemonController`
  (same pattern as the existing `processRunner`/`healthProvider` seams).
- [ ] **R2 — Fix unregistered-service `upToDate` short-circuit:**
  When the daemon is running and its version already equals `targetVersion`,
  `updateDaemon()` returns `upToDate` immediately **without checking service
  registration**. If the binary is at the required version but the background
  service is not registered (e.g. daemon started manually from a terminal), the
  client must register the service instead of reporting `upToDate`, so auto-start
  survives reboot. Registration failure must surface `serviceRegistrationFailed`.
- [ ] **R3 — Regression coverage for PR #198 service-registration boundaries:**
  Executable proof that the fixes from PR #198 (Task 105) cannot regress:
  - [ ] Linux service registration arguments remain exactly `service install
    --user-scope` (user-scoped systemd unit); no code path passes system-scope
    arguments.
  - [ ] No registration path spawns `sudo`, `loginctl enable-linger`, `systemctl`
    (system), or falls back to a system/OpenRC service; sanitized diagnostics must
    not leak privilege-escalation instructions.
  - [ ] The existing agent-side user-scope suite keeps passing unchanged.
- [ ] **R4 — Real Linux verification (not unit tests only):**
  On the available Ubuntu host, with the real published `sanad-agent-1.0.15-linux-x64`
  binary and the real release manifest download path:
  - [ ] Stopped v1.0.15 + unregistered service → auto-update to the current target
    version, real service registration, real daemon start, zero manual terminal
    commands.
  - [ ] Running v1.0.15 daemon + newer target → the update is actually executed
    and health reports the target version afterwards.
  - [ ] Running daemon at target version + unregistered service → service is
    registered (R2) without restarting the healthy daemon.
  - [ ] Every scenario asserts no `sudo`, no `linger` modification, no system
    service (PR #198 boundaries hold on a real host).
  - [ ] Ubuntu 26 note: if an Ubuntu 26 host is required for any part and is not
    available, that part is explicitly declared **not covered** and the gate is
    not considered fully verified.

## Acceptance Criteria

### Original criteria (G0–G5)

- [x] Given a macOS artifact with invalid code signature or wrong publisher, when `verifyReleaseArtifactTrustDetailed` runs, it returns a failed `PlatformTrustResult` containing the failed stage and sanitized output without user paths.
- [x] Given `sanad update` hitting a platform trust failure, the CLI output includes sanitized diagnostic stage information and official installer recovery guidance.
- [x] Given a desktop client launching with an older local agent running in the background, the client detects the version mismatch and automatically initiates daemon update to the client version.
- [x] Given a stopped agent on disk that is older than `targetVersion` or lacks required service CLI options (e.g. `--user-scope`), `updateDaemon` automatically updates the agent via verified bootstrap before registering or starting the service.
- [x] Given an agent on disk that is newer than `targetVersion`, `updateDaemon` refuses to downgrade the agent and returns `downgradeRejected`.
- [x] Given a clean machine without an agent installed, `updateDaemon` downloads, verifies, installs, registers service, and starts the daemon cleanly.
- [x] Given an update failure (network or verification), the previous agent is preserved and retry is fully supported.
- [x] All code passes `fvm dart analyze` and `fvm flutter analyze` with zero errors.

### G5-R criteria (verifiable, each with a precise assessment method)

- [ ] **AC-R1 (Scenario 3 fix):** Given a daemon whose health endpoint reports
  v1.0.15 while running, when `updateDaemon(targetVersion: '1.0.17')` executes,
  then exactly one gateway `POST /update` with `target_version=1.0.17` is observed
  and the result is `ready` once health reports 1.0.17.
  *Assessment:* unit test with an injected recording gateway client passes;
  asserting both the recorded request and the final lifecycle status.
- [ ] **AC-R2 (unregistered service at target version):** Given a running daemon
  already at `targetVersion` with no registered background service, when
  `updateDaemon()` executes, then `service install --user-scope` is invoked
  (recorded by the fake process runner), the healthy daemon is not restarted, and
  the result stays successful (`upToDate`). Given registration failure, the result
  is `serviceRegistrationFailed`.
  *Assessment:* two unit tests — success path and registration-failure path.
- [ ] **AC-R3 (PR #198 regression):** Given any client registration flow on Linux,
  the spawned arguments are exactly `['service', 'install', '--user-scope']`;
  given registration stderr containing `sudo`/`loginctl`/`systemctl` hints, the
  diagnostic is sanitized to the safe generic message; the agent-side user-scope
  suite passes unchanged.
  *Assessment:* client unit tests asserting exact argument lists, sanitizer
  outputs, and absence of privilege-escalation strings; `fvm dart test` on the
  agent service suite exits 0.
- [ ] **AC-R4 (real Linux verification):** On the available Ubuntu host, using the
  real published v1.0.15 linux binary and the real manifest download path, the
  three real scenarios (AC-R1, AC-R2, and stopped-daemon auto-update) each end
  with: on-disk binary reporting the target version via real `--version`, a real
  systemd user unit file created under `~/.config/systemd/user/`, the daemon
  healthy on its gateway with the target version, and zero `sudo`/`linger`/system
  service usage (verified from host state before/after).
  *Assessment:* recorded command transcripts + before/after host state attached
  to the PR as evidence. **Ubuntu 26 is not available on this host (Ubuntu 22.04;
  CI provides ubuntu-24.04) — any Ubuntu-26-specific behavior is declared not
  covered and AC-R4 is not claimed fully verified on that dimension.**

## Definition of Done

- [x] Implementation of G5 completed in `client/`.
- [x] Unit and regression tests passing for all 8 scenarios.
- [x] Technical documentation updated in `docs/technical/update_architecture.md` and `docs/technical/client_local_daemon_control.md`.
- [x] Codebase knowledge graph updated via `graphify update .`.
- [x] PR #211 updated and CI checks verified.

## Current Status
- Gate: G5-R (Reopened — R1–R4 in progress)
- Target PR: #211
- Note: G0–G5 remain complete; G5-R hardens running-daemon scenarios and adds
  real Linux verification. Ubuntu 26 is unavailable on the development host
  (Ubuntu 22.04; CI ubuntu-24.04), so Ubuntu-26-specific coverage is explicitly
  declared not covered until a matching host is available.
