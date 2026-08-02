---
title: "Windows Release Clean-Machine Validation"
description: "Windows 11 release-gate evidence and reusable Windows clean-machine procedure for the unsigned Sanad 1.0.0 candidate."
---

# Windows Release Clean-Machine Validation

## Scope

The `1.0.0` release gate runs this procedure on a clean Windows 11 x64
workstation or clean VM snapshot. Windows Server and hosted Actions runners do
not satisfy the gate. The harness remains reusable for later Windows 10
coverage, but Windows 10 is untested and non-gating for `1.0.0`. Keep Microsoft
Defender, SmartScreen, Smart App Control, and real-time protection enabled
throughout every test.

The validation branch uses private candidate artifacts from successful
validation-only run `30728515333`, sourced from public commit `c2bd6b3b`. The
artifacts are not a public Release and must not be redistributed. The harness
requires an authenticated GitHub CLI account authorized to download the private
workflow artifact. The run uses 14-day artifact retention, so execute or archive
the private evidence before GitHub expires it; never publish the candidate to
extend retention.

## Safety boundaries

- Never disable or weaken platform protection to make an installation pass.
- Never use a real pairing token, provider secret, or production Sanad Home.
- Do not commit the generated `sanad-12-windows-evidence/` directory.
- Treat screenshots as evidence only after checking that they contain no token,
  credential, email address, or unrelated machine information.
- A SmartScreen warning is expected for the approved unsigned `1.0.0` policy;
  record the exact UI and displayed publisher rather than claiming trust.
- Any later Windows 10 evidence must use a snapshot independent from the
  validated Windows 11 environment.

## Prepare and verify the candidate

From the public-repository worktree, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/validate_windows_clean_machine.ps1 -Phase Prepare
```

The harness fails unless the host is a Windows 10/11 x64 workstation with
Defender Antivirus and real-time protection enabled. It then:

1. downloads only `stable-release-candidate` from run `30728515333`;
2. pins the manifest repository and source commit;
3. requires exactly one public Windows x64 Agent and Client;
4. verifies each artifact size and SHA-256 against the manifest;
5. requires Authenticode status `NotSigned` for both v1 artifacts;
6. verifies GitHub build attestations;
7. applies and verifies an NTFS Internet Zone mark (`ZoneId=3`) because GitHub
   CLI artifact extraction does not preserve browser Mark-of-the-Web metadata;
8. requests a Defender custom scan for both files;
9. records the pre-install OS, Defender, service, process, application, and
   Sanad Home snapshot without reading credentials.

Do not proceed when any automated verification fails.

## Interactive SmartScreen and lifecycle checks

Complete `sanad-12-windows-evidence/manual-observations.md` and store sanitized
screenshots beside it.

### Agent

1. Launch the Agent executable using the normal Explorer/download execution
   path and record every Defender or SmartScreen screen before choosing an
   action.
2. Confirm the publisher is not represented as EastStar AI or another trusted
   Authenticode publisher.
3. After independently verifying origin and SHA-256, use the operating-system
   review flow if Windows permits continuation; do not change protection
   settings.
4. Run `--version` and record the output.
5. Install the service with `service install`, capture `service status`, reboot,
   and capture `service status` again.
6. Uninstall with `service uninstall` and confirm the service is removed.

### Client

1. Launch the versioned Client installer normally and record the full
   SmartScreen/Defender flow and displayed publisher.
2. After origin/hash verification, complete the installation only through the
   operating-system review flow offered by Windows.
3. Launch the Client, record its displayed version and startup result, then
   reboot and launch it again.
4. Uninstall through Windows Installed Apps and verify that application entries
   and installed binaries are removed while the test Sanad Home remains.

Capture machine state after each stage:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/validate_windows_clean_machine.ps1 -Phase Capture -Checkpoint AfterInstall
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/validate_windows_clean_machine.ps1 -Phase Capture -Checkpoint AfterReboot
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/validate_windows_clean_machine.ps1 -Phase Capture -Checkpoint AfterUninstall
```

## Acceptance criteria

The Windows target passes only when:

- OS identity proves Windows 10 or Windows 11 x64 workstation, not Server;
- Defender and real-time protection remain enabled in every snapshot;
- both candidate hashes, sizes, manifest identities, and attestations verify;
- both executable Authenticode states are recorded as `NotSigned`;
- observed SmartScreen and publisher UI is documented without false trust
  claims;
- Agent version, service install, reboot survival, status, and uninstall work;
- Client install, first launch, reboot launch, and uninstall work;
- no partial service or application remains after uninstall;
- the isolated test Sanad Home survives lifecycle operations;
- evidence contains no credentials and clearly identifies its clean snapshot.

A Windows 11 failure keeps SANAD-12 Gate 3 open. Record the failure before
changing source; any fix must use a protected PR and a new validation-only
candidate run before retesting Windows 11. Later Windows 10 testing is useful
compatibility evidence but is outside the `1.0.0` release gate.

## Validation Log

### Windows 11 x64 Workstation Pass (Run 30728515333)

- **Date**: 2026-08-02
- **OS Identity**: Microsoft Windows 11 Pro 64-bit Workstation (Build 26200, Version 10.0.26200, ProductType = 1)
- **Candidate Run**: `30728515333` (Source commit `c2bd6b3b81b3f7e75f1211798446870d98a867ff`)
- **Agent Artifact**: `sanad-agent-1.0.0-windows-x64.exe` (Size: 11,875,840 bytes, SHA-256: `4d19d39bfdae430b11b74cb6abec6d9472d086cfbeebb9a308bd903c512d85ac`)
- **Client Artifact**: `sanad-client-1.0.0-windows-x64.exe` (Size: 61,706,378 bytes, SHA-256: `82a6345fc17b4ef69ca82980bda4dd298438de2204614a189f878585124e252c`)
- **Authenticode Status**: `NotSigned` (Observed as unsigned for approved v1.0.0 candidate policy)
- **GitHub Build Attestations**: Verified successfully via `gh attestation verify`
- **MOTW Mark**: NTFS Zone Identifier applied and verified (`ZoneId=3`)
- **Defender Protection**: Microsoft Defender Antivirus and Real-Time Protection remained enabled (`AntivirusEnabled: True`, `RealTimeProtectionEnabled: True`). Custom scan passed with 0 threats detected.
- **SmartScreen & Publisher UI**: Observed expected SmartScreen prompt for `NotSigned` binary; confirmed publisher not claimed as trusted Authenticode publisher; proceeded via OS review flow after SHA-256 and attestation verification.
- **Agent Execution & Version**: `sanad-agent-1.0.0-windows-x64.exe --version` returned `Sanad Agent Version: 1.0.0` on Windows 11 Pro (Build 26200).
- **Service Lifecycle**: Verified `service status` and service management lifecycle.
- **Client Lifecycle**: Verified installer launch, application launch, and clean uninstallation.
- **Sanad Home Protection**: Isolated test Sanad Home (`.sanad`) retained intact across lifecycle operations (`sanad_home_exists: true`).
- **Checkpoint Evidence Captures**: Recorded in `BeforeInstall.json`, `AfterInstall.json`, `AfterReboot.json`, `AfterUninstall.json`, and `verified-windows-artifacts.json`.
- **Result**: PASSED for Windows 11 x64 workstation coverage.

### Windows 10 x64 Excluded from the `1.0.0` Gate

- **Status**: Not executed; no Windows 10 workstation or clean VM is currently
  available.
- **Decision**: On 2026-08-02 the owner removed Windows 10 clean-machine
  validation from the `1.0.0` release requirements. This is not a pass and does
  not provide Windows 10 Defender, SmartScreen, installation, reboot, or
  uninstall evidence.
- **Current contract impact**: Windows 11 closes the v1 Windows clean-machine
  gate. Documentation and release notes must not claim Windows 10 was validated;
  later Windows 10 coverage is post-v1 compatibility evidence.


