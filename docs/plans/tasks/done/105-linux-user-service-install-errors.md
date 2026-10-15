---
title: "Task 105 — Linux user-service installation and actionable errors"
status: completed
current_gate: complete
remaining_estimate: 0%
---

# Task 105 — Linux user-service installation and actionable errors

## Goal

Make packaged Linux Client bootstrap register a usable systemd user service without privilege escalation, and show the concise real registration failure when installation cannot complete.

## Locked decisions and scope

- Linux Client-initiated installation must explicitly request a user-scoped service path and must not invoke `sudo`, `pkexec`, `loginctl enable-linger`, or silently fall back to a system service.
- An active user bus plus a successful `systemctl --user show-environment` probe is sufficient for Client-initiated user-service installation even when `Linger=no`.
- Client installation must not change linger state. The service may consequently require an interactive user login to start after logout/reboot; document this limitation clearly.
- Preserve the existing default Agent CLI/headless installation policy: normal `sanad service install` may continue selecting durable user scope or system/OpenRC fallback as currently documented. Introduce the smallest explicit typed CLI option needed for the Client-only no-elevation path rather than weakening the durable default globally.
- Preserve macOS and Windows behavior.
- When service registration exits unsuccessfully, propagate a bounded, sanitized, concise project-owned diagnostic into `AgentLifecycleResult.message`; use the existing generic text only when no safe diagnostic exists.
- Do not expose secrets, full command payloads, unbounded process output, stack traces, or control/ANSI sequences in UI errors or logs.
- Do not add graphical elevation in this task.
- No unrelated refactors. Do not commit, push, or open a pull request.

## Gates

### G0 — Discovery and contract alignment

- [x] Confirm the Client bootstrap call path, Agent service CLI parsing, Linux backend selection, and current test seams.
- [x] Record the minimal explicit user-scope contract and all affected docs/tests.

### G1 — Agent user-scope service contract

- [x] Add an explicit Client-safe user-service install option with no privileged fallback.
- [x] Allow that explicit path to use a healthy active user manager when linger is disabled, without changing linger.
- [x] Return a concise typed failure when the user manager is unavailable.
- [x] Preserve default durable CLI behavior and non-Linux behavior.

### G2 — Client diagnostic propagation

- [x] Invoke the explicit no-elevation Linux install path from the packaged Client.
- [x] Propagate bounded sanitized stderr/status detail to the user-visible lifecycle result.
- [x] Preserve the generic fallback when output is empty or unsafe.

### G3 — Regression coverage and documentation

- [x] Add focused Agent tests for explicit user scope, `Linger=no`, unavailable manager, and unchanged default fallback behavior.
- [x] Add focused Client tests for Linux arguments and safe actionable error propagation.
- [x] Update `docs/technical/linux_service_lifecycle.md`, `docs/technical/client_local_daemon_control.md`, `docs/operations/user_guide.md`, and `docs/qa_maintenance/linux_service_lifecycle_qa.md` as needed.

### G4 — Verification and review readiness

- [x] Run formatters for touched Dart files.
- [x] Run Agent analysis and focused service tests with bounded output.
- [x] Run Client analysis and focused controller tests with bounded output.
- [x] Run `graphify update .` after code changes.
- [x] Review the complete diff for scope, safety, stale docs, and generated artifacts.

### G5 — Ubuntu real-host acceptance

- [x] On the Ubuntu device, create a fresh worktree from `origin/fix/105-linux-user-service-install-errors`; do not switch or modify the source of any existing runtime.
- [x] Run the Agent and Client analyzers plus the focused service/controller tests from that worktree with bounded output.
- [x] Confirm the test account has an active systemd user bus and record `Linger` before testing; never change a pre-existing `Linger=yes` account merely to force the scenario.
- [x] Using only a worktree-scoped Sanad Home and isolated service instance, exercise real `--user-scope` install/status/stop/start/restart/uninstall against the Ubuntu user manager.
- [x] Prove the user unit is enabled and running under the user unit directory, no new system unit is created, no `sudo`/`pkexec` path is invoked, and `Linger` is unchanged.
- [x] Exercise the matched branch Client bootstrap path on Linux when the isolated runtime permits it, and verify successful local readiness; also preserve automated evidence for the sanitized detailed failure and generic fallback paths.
- [x] Clean only the isolated test service/Home, confirm the pre-existing Sanad runtime remains healthy, and return concise command/evidence results in the conversation. Do not commit or push from the Ubuntu device unless explicitly requested.

## Acceptance Criteria

- [x] Given Linux Client bootstrap under an active systemd user session with `Linger=no`, when service installation runs, then it creates/enables/starts the user unit without invoking any privilege command or modifying linger.
- [x] Given the Client-safe user scope is requested but the user manager is unavailable, when installation runs, then it fails without system/OpenRC fallback and returns a concise actionable diagnostic.
- [x] Given Agent service registration exits nonzero with safe stderr/status text, when the Client reports failure, then the visible message includes a bounded sanitized version of that diagnostic.
- [x] Given registration output is empty or unsuitable, when the Client reports failure, then it uses the existing generic service-registration message.
- [x] Existing default `sanad service install` durable selection, macOS behavior, and Windows behavior remain covered and unchanged.
- [x] No failure message exposes credentials, full command payloads, ANSI/control characters, or unbounded output.
- [x] On the real Ubuntu host, the isolated user-scoped service completes its lifecycle without elevation, system-unit creation, linger mutation, or impact on the pre-existing runtime.
- [x] The Ubuntu run provides bounded analyzer/test output and Client-bootstrap evidence, or records a precise environmental blocker without weakening the earlier automated coverage.

## Definition of Done

- [x] Relevant source, tests, and design/user/QA documentation are updated together.
- [x] Focused tests and analyzers pass under FVM with bounded reported output.
- [x] The task status, closed gates, and remaining estimate reflect actual verification evidence.
- [x] Graphify is updated.
- [x] Local changes passed orchestrator review.
- [x] G5 Ubuntu real-host evidence is reviewed and the task status/remaining estimate is closed accurately.
