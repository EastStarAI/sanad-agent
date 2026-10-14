---
title: "Task: Windows Installer Running-Client Guard and Safe DLL Replacement"
status: "completed"
current_gate: "complete"
---

# Task: Windows Installer Running-Client Guard and Safe DLL Replacement

## Goal
Prevent Bad Image / DLL-load failures during Windows Client upgrades by refusing
to replace files that remain in use and by restoring the prior complete payload
when replacement cannot finish safely.

## Locked Decisions and Scope

- The official Windows package remains the existing NSIS installer. Migrating to
  MSI or Inno Setup is outside this task.
- Preserve WinSparkle's graceful `before-quit-for-update` handoff. The bounded
  force-stop fallback may target only the exact installed executable path.
- Fail closed while any installed EXE or DLL remains exclusively locked; never
  kill an unrelated holder by process name.
- Extract a complete payload under the installation root before replacement.
  Use same-volume moves, SHA-256 verification of every staged file, backup, and
  rollback. Do not describe the multi-file transaction as one atomic filesystem
  operation.
- Keep the comparison-only Inno Setup script unchanged; `AppMutex` is invalid
  unless the application creates the matching named mutex.
- Extend isolated Windows verification and CI without touching a real installed
  Client or user Sanad Home. Real-installer lifecycle tests use dedicated
  compile-time display name, installation directory, registry keys, and disabled
  shortcuts so production defaults remain unchanged.
- Non-Windows packaging is excluded.

## Reference Evidence

- Microsoft documents that files must be closed before moving/replacing them and
  provides replacement with backup semantics:
  <https://learn.microsoft.com/windows/win32/fileio/moving-and-replacing-files>.
- Windows Installer's safety model preserves deleted files and automatically
  rolls back unsuccessful installation work:
  <https://learn.microsoft.com/windows/win32/msi/rollback-installation>.
- Restart Manager is the system facility for installers to identify and close
  applications holding updated files:
  <https://learn.microsoft.com/windows/win32/rstmgr/restart-manager-portal>.
- Inno Setup requires the application itself to create every mutex named by
  `AppMutex`: <https://jrsoftware.org/ishelp/topic_setup_appmutex.htm>.

## Gates

### G0 — Discovery and Design

- [x] Inspect the complete worktree diff, official installer path, release
  workflow, update architecture, and clean-machine QA contract.
- [x] Compare the implementation with official Windows, NSIS, and Inno Setup
  behavior.
- [x] Identify the incomplete verification, unsupported mutex, in-place partial
  write, and missing rollback risks in the original worktree implementation.

### G1 — Implementation

- [x] Make the exact-path shutdown helper wait for installed EXE/DLL handle
  release after graceful and forced shutdown paths.
- [x] Stage the complete NSIS payload before touching the installed payload.
- [x] Add same-volume replacement, full staged-file hash verification, backup,
  and rollback through `install_staged_client.ps1`.
- [x] Make `verify_installer.ps1` location-independent and add isolated tests for
  exact-process force stop, locked installed DLL rejection, failed replacement
  rollback, stale DLL removal, and successful retry.
- [x] Run the isolated guard in Windows CI and parse every involved PowerShell
  script.
- [x] Add compile-time test isolation for display name, installation directory,
  HKCU application/uninstall keys, execution level, and shortcuts without
  changing production defaults.
- [x] Update technical and clean-machine QA documentation.

### G2 — Verification

- [x] Parse all changed PowerShell scripts with Windows PowerShell.
- [x] Run `verify_installer.ps1 -UpgradeGuardOnly` successfully.
- [x] Compile `sanad_client_installer.nsi` with pinned NSIS 3.12 and an isolated
  synthetic payload.
- [x] Run `fvm flutter analyze` with zero issues.
- [x] Run `verified_agent_bootstrap_installer_test.dart` with all tests passing.
- [x] Build and launch the Windows Client in FVM Debug mode before producing a
  release installer candidate.
- [x] Build the real Windows release installer and run the full installer
  verifier against its release payload.
- [x] Run a real isolated two-version NSIS lifecycle on this workstation:
  running-client upgrade, locked-DLL rejection with exit code `2`, retry,
  uninstall, registry cleanup, and normal-client survival all passed.
- [x] Compile the NSIS script again with production-default defines after adding
  the test-isolation overrides.
- [x] Review the final diff and run `git diff --check`.
- [x] Graphify update waived by the owner because the CLI and an existing graph
  are unavailable in this worktree.

## Acceptance Criteria

- [x] Given the exact installed Client is running, the isolated verifier proves
  the fallback terminates that process and waits for handle release.
- [x] Given an installed DLL remains locked, the installer guard fails without
  changing the installed payload.
- [x] Given a staged DLL becomes locked during replacement, rollback restores
  the prior EXE, DLL, and data payload and removes the completed backup.
- [x] Given an unlocked complete staged payload, replacement removes stale DLLs,
  verifies every staged file hash, and leaves no staging or backup directory.
- [x] The official release payload and NSIS installer build and verify cleanly.
- [x] This task does not hold a future release open: clean-machine Defender,
  SmartScreen, reboot, and candidate checks remain release-time runbook work,
  while the running-client installer behavior required here passed locally.

## Definition of Done

- [x] Relevant analyzer, focused tests, PowerShell verification, and NSIS compile
  pass with bounded evidence.
- [x] Architecture, QA, and task documentation match the implementation.
- [x] Graphify maintenance was explicitly waived by the owner because the local
  CLI and graph are unavailable.
- [x] Worktree contains only intentional PR files and no generated artifacts.
- [x] No commit is created before user review.
