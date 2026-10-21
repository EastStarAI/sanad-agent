---
id: 107
title: Agent Update Trust Diagnostics and Client Auto-Pairing
status: in_review
gate: G6
created: 2026-10-13
updated: 2026-10-21
branch: fix/107-port
supersedes_branch: fix/107-agent-update-trust-diagnostics-and-auto-pairing (PR #211, not merged)
---

# Task 107 — Agent Update Trust Diagnostics and Client Auto-Pairing

## Goal

Resolve Issue #203: replace opaque platform trust rejection with typed, bounded,
sanitized, fail-closed diagnostics shared by the Agent updater and the Client
bootstrap installer, and give `sanad update` actionable recovery guidance. On
Desktop, keep the local Agent paired to the exact Client version: update an
older running Agent at bootstrap, and validate, replace, register, and start a
stopped Agent without manual commands or elevation.

## Locked Decisions & Scope

1. **Fail-closed trust.** The exact Apple-anchored NanoSoft requirement is
   unchanged. Every untrusted result, including a verifier that cannot run, is
   rejected.
2. **Typed, sanitized diagnostics.** `PlatformTrustStage` names the stage
   (`metadata_validation`, `codesign_verification`, `publisher_requirement`,
   `authenticode_signature`, `verifier_unavailable`, `platform_verifier`).
   `codesign` exit 3 is the publisher-requirement stage. Details lose local
   artifact, home, temp, and per-user paths and are one line of at most 500
   characters.
3. **Backward-compatible contract.** `verifyReleaseArtifactTrust` and
   `verifyPlatformCodeSignature` keep their boolean API over the detailed forms.
4. **Recovery guidance.** After `trust_failed`, `sanad update` prints the
   platform-appropriate official installer command from
   `OfficialAgentInstaller` (POSIX or PowerShell) and the service-restart
   warning. No other host is named. The legacy boundary is v1.0.0–v1.0.5
   (`=notarized`); #105 shipped in v1.0.6.
5. **Bootstrap auto-pairing.** The gateway bootstrap checks the local Agent
   before treating a running daemon as usable; a failed pairing still connects.
6. **Stopped-agent compatibility (G5).** Read the version from the `Version:`
   line only, keep prereleases, and probe capabilities with the read-only
   `sanad help service install`. Never use `service install --help`, because
   v1.0.0–v1.0.4 really install. Probes are bounded and Home-pinned. Replace an
   absent, older, unparseable, or incompatible executable before registration.
   Never replace a newer executable; start it when compatible. Restore the
   previous executable when registration, start, or health fails after a
   replacement.
7. **Ownership.** Only `StandaloneDaemonController` owns the stopped lifecycle
   (`ownsStoppedAgentLifecycle`). Source runtimes keep start-then-update on an
   explicit Run Locally. `checkAndStartLocalDaemon` is single-flight.
8. **Home isolation.** Every agent child process receives the managed
   `SANAD_HOME` and `SANAD_SERVICE_INSTANCE`.
9. **Out of scope.** Installer scripts (unchanged), making the Agent's own
   `--version`/`help` side-effect free, and consolidating the Client
   `DeviceInstallGuide` installer literals into `OfficialAgentInstaller`.

## Port Mapping (PR #211 → `fix/107-port`)

Main since the PR's base (`2114da35`) changed none of the 17 touched files, so
the Task 110 SRP ownership map moves nothing; every change lands in the same
owner. The port is a transplant with review fixes, not a merge.

| Old change | New location |
|---|---|
| `PlatformTrustResult`, sanitizer, detailed verifiers in `release/contract/lib/release_contract.dart` | Model, stage enum, sanitizer, `OfficialAgentInstaller` in `release/contract/lib/src/platform_trust.dart` (exported); verifiers stay in `release_contract.dart` |
| `agent_update_service.dart`, `update_command.dart` | same files; guidance is `trustFailureRecoveryGuidance` |
| Trust tests in `agent/test/core/update/release_manifest_test.dart` | `agent/test/core/update/platform_trust_diagnostics_test.dart` (the contract has no test package; CI runs Agent and Client suites on contract changes) |
| `verified_agent_bootstrap_installer.dart` | same file |
| `LocalDaemonController` probe methods (+ source no-ops) | removed from the interface; replaced by `ownsStoppedAgentLifecycle`; probes are `StandaloneDaemonController` members |
| `standalone_daemon_controller.dart` stopped path | `_updateStoppedAgent`, `_registerAndStartService`, `_restoreRollback(restart:)`, `_probeExecutable`, `_runAgent` |
| `device_connection_coordinator.dart` | same file, single-flight plus capability routing |
| `gateway_connection_cubit.dart` | same change |
| `agent_compatibility_validation_test.dart` | rewritten against `client/test/helpers/fake_agent_cli.dart` |

## Defects Found in PR #211 and Fixed

| # | Location | Defect | Fix | Regression |
|---|---|---|---|---|
| D1 | `standalone_daemon_controller.dart` `validateServiceInstallCompatibility` | Probed `sanad service install --help`; v1.0.0–v1.0.4 ignore `--help` and perform a real (on Linux, possibly system-scope) service install | Probe `sanad help service install`, read-only on every release | `legacy v1.0.0-v1.0.6 binaries are never probed…`, `registerService probes with read-only help…` |
| D2 | `getInstalledExecutableVersion` | Fallback regex took the first semver anywhere, such as the Linux kernel in `Platform:`, giving a false `downgradeRejected` | Accept only the `Version:` line | `a missing Version line is unparseable…`, `parseAgentVersionOutput…` |
| D3 | same | Returned `marketingVersion`, dropping the prerelease, so `1.0.18-rc.1` compared equal to `1.0.18` | Return the full `ReleaseVersion` | `a prerelease agent is upgraded…` |
| D4 | probes | `Process.run` without timeout or stdin EOF; a hung binary blocked pairing forever | `Process.start`, stdin closed, timeout and kill | `a hung executable probe is bounded…` |
| D5 | `updateDaemon` stopped path | After replacing an existing executable, failed registration, start, or health left the new candidate; `.rollback` was never restored (`health == null`) | Stop the candidate, restore, leave stopped, `rollbackCompleted` with the cause | `a failed start after replacing…`, `a fresh install that fails…` |
| D6 | `updateDaemon` stopped path | A newer stopped Agent returned `downgradeRejected` without starting, leaving the local runtime unusable (a newer *running* Agent stays usable) | Start it when compatible; still never replace it | `a newer compatible stopped agent is started…` |
| D7 | trailing block in `updateDaemon` | Re-registered after success: duplicate Windows registration, and `service install` next to a manually started daemon | Removed; registration happens once before start | `macOS and Windows register once…` |
| D8 | `device_connection_coordinator.dart` | Always called `updateDaemon` for a stopped Agent; `SourceDaemonController.updateDaemon` never starts, so Run Locally in a source run reported success and started nothing | `ownsStoppedAgentLifecycle`; source keeps start-then-update | `a source-managed agent is still started…` |
| D9 | same | No single-flight; cubit bootstrap and `ensureLocalConnection` could run two concurrent bootstrap installs on one executable | Shared in-flight attempt; forced caller retries once | `concurrent callers share…`, `a forced caller retries…` |
| D10 | `standalone_daemon_controller.dart` (pre-existing, widened by 107) | Agent processes inherited the Client environment; a Client built for an isolated `SANAD_HOME`/instance could register or restart the default service | `managedAgentEnvironment` on every agent child process | `agent child processes are pinned…` |
| D11 | `option` matching | `helpText.contains(option)` matched prefixes | Exact-flag regex | `option detection requires the exact flag` |
| D12 | `release_contract.dart` | Stages were free-form strings that did not match the task (`manifest_metadata`, `codesign_publisher_requirement`); a throwing verifier escaped as an exception | `PlatformTrustStage`; exit-code mapping; throw → `verifier_unavailable` | `verifyPlatformCodeSignatureDetailed`, `verifyReleaseArtifactTrustDetailed` groups |
| D13 | `sanitizePlatformVerifierOutput` | Missed resolved `/private` artifact paths, a `HOME` outside `/Users` or `/home`, temp roots, `/var/folders`, and non-`C:` drives; kept newlines and ANSI; truncation could split a surrogate pair | Environment-aware roots, `/var/folders`, any drive, control collapse, rune-safe bound | `sanitizePlatformVerifierOutput` group |
| D14 | `update_command.dart` | Hard-coded bash command printed on Windows; blamed "legacy v1.0.0–v1.0.4", which the printing (current) Agent never is; wrong range | Platform-aware `OfficialAgentInstaller`; accurate wording; docs give v1.0.0–v1.0.5 | `sanad update recovery guidance` group |
| D15 | logging | Probe logs included full executable paths | Path-free messages | review |
| D16 | old tests | Fakes answered `--help` before `install` (hiding D1); "old agent already running" tested an up-to-date one; tests read the developer's real `HOME`; trust-failure scenario did not assert the previous binary; controller tests had no guard against falling through to the real installer and the live release manifest | Version-faithful `FakeAgentCli`, isolated `HOME`, `noBootstrapExpected` guard, explicit preservation asserts | whole suites |

## Gates

### G0 — Discovery and alignment
- [x] Issue #203 and PR #105 root cause; legacy range verified from tags (`=notarized` through v1.0.5, #105 first in v1.0.6).
- [x] Legacy CLI behavior verified from tags v1.0.0–v1.0.16 (`--version`, `help`, `service install --help`, `--user-scope` from v1.0.16).
- [x] Worktree `.agent/worktrees/107-port` on `fix/107-port` from `origin/main` `695d356b`.

### G1 — Shared release contract diagnostics
- [x] `PlatformTrustStage`, `PlatformTrustResult`, sanitizer, `OfficialAgentInstaller`.
- [x] Detailed verifiers; boolean wrappers kept.
- [x] Tests (in the Agent suite; see mapping).

### G2 — Agent update service and CLI guidance
- [x] `AgentUpdateService` carries the typed summary.
- [x] Platform-aware recovery guidance.

### G3 — Client bootstrap auto-pairing
- [x] Gateway bootstrap pairs before treating a running daemon as usable.
- [x] Cubit regression (fails on `origin/main`, passes here).

### G4 — Documentation
- [x] `docs/technical/update_architecture.md`, `docs/technical/client_local_daemon_control.md`, `docs/operations/user_guide.md`, `docs/operations/release_and_signing.md`, `client/lib/features/devices/AGENTS.md`, `docs/qa_maintenance/agent_update_trust_and_auto_pairing_qa.md`, MOC, `docs/llms.txt`.

### G5 — Stopped-agent compatibility validation
- [x] Review defects D1–D11 fixed with regressions.
- [x] All eight original scenarios plus Ubuntu acceptance ported against a version-faithful fake CLI.

### G6 — Live acceptance (open)
- [ ] L1–L7 in `docs/qa_maintenance/agent_update_trust_and_auto_pairing_qa.md` on an isolated Test Home and service instance.

## Acceptance Criteria

- [x] A macOS candidate with an invalid signature or wrong publisher yields an untrusted `PlatformTrustResult` with its stage and sanitized detail, and a verifier launch failure is rejected.
- [x] `sanad update` on `trust_failed` prints the stage and the platform-appropriate official installer guidance.
- [x] A running older local Agent is updated to the Client version during bootstrap; a failed update still connects.
- [x] A stopped older, unparseable, or `--user-scope`-less Agent is replaced via the verified installer before registration and start; legacy binaries are never invoked with a mutating probe.
- [x] A newer installed Agent is never downgraded; when stopped it is started.
- [x] A clean machine installs, registers, and starts the Agent.
- [x] A network or verification failure keeps the previous Agent; a post-replacement start/health failure restores it; retry works.
- [x] Agent child processes are pinned to the managed Home and service instance.
- [x] Analyzers report zero issues.
- [ ] Live L1–L7 pass on an isolated Test Home.

## Definition of Done

- [x] `fvm dart analyze` (agent, release contract) and `fvm flutter analyze` (client) clean.
- [x] Focused and full Agent and Client suites pass (evidence below).
- [x] Documentation and owning `AGENTS.md` updated.
- [ ] Live acceptance G6.
- [ ] Draft PR and independent review (not part of this port: no push, no PR).

## Evidence

Logs live under `temp/107/` in the worktree (gitignored).

- Agent full: `fvm dart test` → `+3065 ~14`, all passed (`temp/107/agent-full.log`).
- Client focused (6 files) → `+79`, all passed (`temp/107/client-focused.log`).
- Client full: see `temp/107/client-full.log`.
- `shellcheck`: not installed; installer scripts are unchanged by this task, and neither supports a dry run.

## Open Questions

1. Should the Agent print `--version` and `help` before `SanadHomeBootstrap.prepareAll()` and bundled-skill reconciliation, so Client probes never write to the Home? It currently initializes the managed Home only.
2. A newer stopped Agent is started (D6) to match newer-running behavior. Confirm that this is the intended policy rather than refusing to start it.
3. Should `DeviceInstallGuide` reuse `OfficialAgentInstaller` for its installer URLs? It belongs to the Client devices feature and is outside 107.
4. When the bootstrap installer replaces a stopped Agent with a registered service, the existing service definition is reused. Should a version change force re-registration so the unit/plist/task matches the new Agent?
