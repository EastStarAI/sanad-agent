---
title: "Windows Agent No-Console Launcher"
description: "Keep the packaged Client bootstrap unchanged while running the installed Windows Agent without a visible terminal."
status: completed
current_gate: complete
remaining_estimate: "none; protected clean-snapshot validation remains a release-candidate gate"
---

# Windows Agent No-Console Launcher

## Goal

Run the release-installed Windows Agent as a durable per-user background process without a visible terminal, while preserving the existing Client flow that downloads one verified Agent executable and invokes Agent-owned service installation.

## Locked Decisions and Scope

- The Client download/bootstrap contract remains unchanged and receives no production-code changes.
- Windows release packaging embeds a native GUI-subsystem launcher inside the single Agent executable; `sanad service install` extracts and verifies it under the active Sanad Home.
- The Windows Scheduled Task runs the launcher directly. The launcher owns the console-free Agent process, redirected logs, and child exit code.
- macOS launchd, Linux service managers, source/FVM launches, and interactive CLI commands remain unchanged.
- The Windows Agent updater must reinstall the launcher/task definition from the newly verified Agent before starting the replaced daemon, with rollback to the previous Agent on failure.

## Gates

### G0 — Discovery and design
- [x] Confirm the visible console originates from the interactive Scheduled Task action and inherited stdio.
- [x] Confirm the repository already records the deferred deterministic no-console launcher.
- [x] Lock an Agent-owned, single-download design with no Client production changes.

### G1 — Launcher and service integration
- [x] Add the native Windows GUI launcher and deterministic release embedding tool.
- [x] Extract and verify the embedded launcher transactionally during Windows service installation.
- [x] Register the Scheduled Task against the launcher with redirected daemon logs and no PowerShell runtime host.
- [x] Preserve start, stop, restart, status, isolated service instances, and update rollback behavior.

### G2 — Verification and documentation
- [x] Add focused tests for bundle integrity, task registration, command exit propagation, safe uninstall, and replacement reinstall semantics.
- [x] Build and exercise the launcher/packaged Agent on Windows, including an assertion that no visible console is owned by the daemon tree.
- [x] Run Agent analysis and focused tests with bounded output.
- [x] Update technical and Windows QA documentation.
- [x] Confirm Graphify output is absent in this checkout, so no graph refresh is applicable.

## Acceptance Criteria

- [x] Given a verified Windows Agent executable downloaded by the existing Client path, when `service install` runs, then the Agent extracts its authenticated embedded launcher and registers a working per-user Scheduled Task.
- [x] Given immediate first installation or later start/restart, when the task starts, then no visible console window is created and authenticated Agent health becomes ready.
- [x] The installed task owns the Agent independently of the Client process.
- [x] Windows Agent replacement installs the new launcher/task definition before restart and restores the previous executable when that transition fails.
- [x] macOS, Linux, source-runtime, and interactive Agent CLI behavior are unchanged.

## Definition of Done

- [x] `fvm dart analyze` passes in `agent/`.
- [x] Focused setup/update tests pass.
- [x] Windows native build and no-console lifecycle evidence pass.
- [x] Relevant design and QA documentation match the implementation.
- [x] Graphify output is absent, so no graph update is applicable.
