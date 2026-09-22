---
status: superseded
closure_reason: remaining-work-transferred-not-certified-complete
superseded_by: docs/plans/97-windows-first-agent-client-performance.md
current_gate: closed-transferred
priority: high
security_review: required
platforms: windows-primary, macos-regression, linux-regression
depends_on: sanad-dev-windows-command-latency
reference_grounding: official-platform-contracts
---

# sanad-dev Windows Secure Runtime-File Performance

## Closure and transfer to Plan 97

**Closed as superseded, not completed.** This file is a historical evidence record,
not an active execution queue. All previously unchecked items (12 entries)
are transferred to the successor owners below. Checked items retain their
historical meaning; no unverified acceptance or security result is marked passed.
The successor owns the complete original obligations, including negative cases,
security review, documentation and delivery reconciliation, not only a summary.
Archived under docs/plans/done with superseded status; references point to this record or its Plan 97 successor. No independent work remains here.

| Original outstanding scope | New execution owner |
|---|---|
| G0 — individual operations, subprocess counts, cold/warm median/p95 | [97c](docs/plans/tasks/97c-secure-runtime-verification.md) |
| G1/G3 — security authorization, races/interruption/replacement/immediate-delete, failure cleanup | [97c](docs/plans/tasks/97c-secure-runtime-verification.md) |
| G4 + acceptance — Windows analysis/tests and native/backend boundaries | [97c](docs/plans/tasks/97c-secure-runtime-verification.md) |
| G4 + acceptance — hosted three-OS suites, POSIX modes/rename, architecture/dependency regressions, final security/CI evidence | [97k](docs/plans/tasks/97k-regression-budgets-and-report.md) |
| Final managed-runtime smoke | [97l](docs/plans/tasks/97l-interactive-final-acceptance.md) |

## Historical plan and evidence (non-executable)

The following goals, gates and acceptance statements describe the original task.
`Transferred` entries are preserved requirements now owned by the table above;
they are not open checkboxes in this retired plan. Historical commands and merge
instructions do not authorize new execution or duplicate delivery.



## Goal

Reduce Windows secure runtime-file latency without weakening owner-only access,
path containment, link/reparse-point rejection, atomic publication, write
through, fail-closed behavior, or runtime ownership evidence. Preserve current
POSIX semantics and prove that macOS and Linux behavior does not regress.

## Motivation and Baseline

- On the measured Windows host, one `secureRuntimeAtomicWrite` takes about nine
  seconds because one logical publication starts several PowerShell processes.
- Startup attempt, launcher lease, journal, and control-manifest flows can issue
  several secure writes, causing production startup and focused tests to exceed
  their expected timing windows.
- The existing implementation is security-sensitive. Performance work must not
  replace atomic publication with delete-then-rename, trust inherited ACLs
  without validation, or cache an authorization decision beyond its safe
  lifetime.

### Current-host evidence

- From a human-owned Windows terminal, ten `git diff --check` samples averaged
  51 ms and five nested PowerShell starts averaged 131 ms. A fresh temporary
  Agent Home completed `doctor` bootstrap in 52.36 seconds.
- Through Agent `shell_execute`, equivalent nested PowerShell starts averaged
  about 2.01 seconds, and fresh isolated-Home startup exceeded 14 minutes before
  eventually reaching daemon health. The approximately 15x process-start ratio
  closely predicts the bootstrap ratio, while memory, disk capacity, and direct
  `icacls` timing were healthy.
- One secure atomic write currently starts PowerShell repeatedly for every
  hardened root/path segment, temporary file, final file, and `MoveFileExW`
  replacement. The dominant cost is subprocess multiplication under the Agent
  execution context, not Git, Dart computation, or raw ACL application.

### Reference-grounded design decision

Official Windows process, security, and Dart process contracts establish these
constraints:

- `GetProcessTimes` returns process creation time from a handle opened with
  `PROCESS_QUERY_LIMITED_INFORMATION`; process identity therefore needs no
  PowerShell subprocess.
- `SetNamedSecurityInfoW` can set a named file or directory DACL, and
  `PROTECTED_DACL_SECURITY_INFORMATION` prevents inherited ACEs from surviving.
  A current process-token SID can be obtained through `GetTokenInformation`.
- `MoveFileExW` with replace-existing and write-through flags remains the native
  atomic publication primitive already selected by the current implementation.
- Windows Job membership is inherited by children. Escaping requires both a job
  that permits breakaway and `CREATE_BREAKAWAY_FROM_JOB`; Dart detached mode does
  not document or expose that guarantee. Generic shell containment must not be
  weakened as a side effect of secure-file optimization.

Selected approach:

1. Adopt a focused in-process Win32 FFI backend for current-user SID lookup,
   protected owner-only DACL replacement, and write-through replacement.
2. Keep the public secure-runtime API and all path/reparse/atomicity checks
   unchanged; map native failures to the existing typed errors.
3. Cache only immutable process-level native bindings and, if proven equivalent,
   the current process-token SID. Never cache path validation, DACL success, or
   publication authorization.
4. Reject per-call and long-lived PowerShell helpers as the final design: one
   transaction would reduce subprocess count but retains the measured execution-
   context amplification and creates a second protocol/lifetime boundary.
5. Reject call-site batching as the primary fix because it couples independent
   atomic publications and can obscure which path was hardened or failed.
6. Defer process-tree breakaway/handoff to the runtime-lifecycle owner. This task
   neither enables `BREAKAWAY_OK` nor permits arbitrary descendants to escape a
   `shell_execute` Job Object.

Reference contracts:

- <https://learn.microsoft.com/windows/win32/procthread/job-objects>
- <https://learn.microsoft.com/windows/win32/procthread/nested-jobs>
- <https://learn.microsoft.com/windows/win32/procthread/process-creation-flags>
- <https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes>
- <https://learn.microsoft.com/windows/win32/api/aclapi/nf-aclapi-setnamedsecurityinfow>
- <https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw>
- <https://learn.microsoft.com/windows/win32/secauthz/security-information>
- <https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation>
- <https://api.dart.dev/dart-io/Process/start.html>

### Current implementation evidence

- A root-level secure atomic write previously started four PowerShell processes:
  root DACL, temporary-file DACL, `MoveFileExW`, and destination DACL. Each nested
  directory added another process. The in-process Windows backend reduces this
  count to zero while preserving the same public API and typed outcomes.
- On the same affected Agent execution context, the focused secure-file case fell
  from about nine seconds to less than one second. A fresh isolated-Home `doctor`
  fell from 52.36 seconds to 4.29 seconds, approximately a 12x improvement.
- A real Windows integration test seeds a foreign Users ACE, then proves that the
  Home, nested directory, and final file each contain only one current-user full-
  control ACE under a protected DACL. Replacement leaves no temporary artifact.
- New traversal and junction tests exposed and closed a pre-existing lexical
  prefix flaw: `home/../outside` is normalized before containment checks and can
  no longer harden or publish outside the selected Home.
- The focused stale-recovery/component-control/profile/secure-file set passes,
  including real ACL, locked-destination failure, and stale-lease recovery
  coverage. The complete package passes 149 tests with 18 platform skips on
  Windows.
- Live `run agent --background` reached daemon health, then the Agent tool's
  enclosing kill-on-close Job terminated the detached launcher after the command
  returned. The resulting exact stale lease was detected and removed by
  `doctor --fix` without signaling a process. Generic Job breakaway remains a
  separate lifecycle blocker and is not weakened by this task.

## Scope

- `scripts/sanad_dev/lib/src/infrastructure/secure_runtime_file.dart` and its
  focused tests.
- Windows owner SID and DACL application, directory preparation, temporary-file
  protection, and atomic replacement/write-through implementation.
- Call-site batching only where one security transaction can retain equivalent
  or stronger guarantees.
- Startup-attempt, launcher-record, control-manifest, switch-manifest, runtime
  metadata, and journal regression coverage.
- Documentation in the owning technical and QA pages.

## Out of Scope

- Bypassing FVM for Dart or Flutter operations.
- Weakening owner-only ACLs to inherited or best-effort permissions.
- Replacing atomic publication with a non-atomic compatibility fallback.
- Fixing unrelated Windows path fixtures or generic test-runner organization;
  those belong to the cross-platform test-baseline task.
- Changing runtime ownership, Home selection, source-switch semantics, generic
  `shell_execute` process identity, or Job Object breakaway policy. Those remain
  separately measured lifecycle/tooling concerns after secure-file subprocess
  amplification is removed.

## Locked Security Invariants

1. Every published runtime file is rooted beneath its validated Sanad Home or
   runtime directory.
2. Links, junctions, reparse points, unsafe file types, and path escapes fail
   closed before publication.
3. Directories and files expose access only to the current owner identity; an
   inherited or explicit foreign ACE cannot survive successful hardening.
4. Publication is atomic for readers and preserves equivalent write-through
   durability on Windows.
5. Temporary files are never observable through a less restrictive ACL than
   the final file.
6. Any SID, ACL, helper-process, or replacement failure produces a typed
   nonzero failure and leaves no permissive destination or temporary artifact.
7. macOS/Linux retain `0700` directories, `0600` files, atomic rename behavior,
   and immediate-consumer-delete safety.

## Gates

### G0 — Reproducible Profiling

- [x] Measure FVM/test-process startup separately from test-case execution.
- **Transferred to Plan 97:** Instrument one directory hardening, new-file publication, existing-file
      replacement, append-file acquisition, and secure read on Windows.
- **Transferred to Plan 97:** Record subprocess count, median, p95, and cold/warm timing over repeated
      runs on the same host.
- [x] Identify which cost belongs to PowerShell startup, ACL work, atomic move,
      antivirus/filesystem contention, and repeated call-site preparation.

### G1 — Threat Model and Design Decision

- [x] Enumerate threats: foreign explicit ACE, inherited ACE, SID ambiguity,
      link/junction substitution, destination replacement race, temporary-file
      disclosure, partial write, PID/process interruption, and helper failure.
- [x] Compare at least: a single bounded PowerShell transaction, direct Windows
      APIs through a focused helper, and safe call-site batching.
- [x] Reject any design that cannot prove exact DACL replacement and atomic
      write-through publication.
- [x] Document the selected design, rollback boundary, and why rejected options
      are unsafe or unnecessarily complex.
- **Transferred to Plan 97:** Obtain explicit `security-reviewed` authorization before merge because the
      owner-only runtime-file boundary is modified.

### G2 — Focused Windows Implementation

- [x] Implement the smallest reusable Windows backend behind the existing pure
      Dart API; keep callers platform-neutral.
- [x] Bound helper lifetime, input size, output, and error mapping.
- [x] Avoid shell interpolation of paths, identities, or contents.
- [x] Preserve typed `ownership_failed`, `atomic_replace_failed`,
      `atomic_write_failed`, and unsafe-path outcomes.
- [x] Leave POSIX code unchanged unless a proven shared refactor preserves exact
      behavior and reduces duplication.

### G3 — Security and Race Regression Coverage

- [x] Verify exact owner-only file and directory ACLs after success.
- [x] Seed inherited and explicit foreign ACEs and prove they are removed or the
      operation fails closed.
- [x] Cover unsafe symlink/junction/reparse-point and outside-root paths.
- **Transferred to Plan 97:** Cover existing destination replacement, concurrent readers/writers,
      process interruption, helper nonzero exit, and immediate consumer delete.
- **Transferred to Plan 97:** Assert no temporary artifacts or permissive destination remain after each
      failure.
- [x] Exercise startup attempts, launcher records, component controls, switch
      manifests, runtime metadata, and journals through the centralized API.

### G4 — Cross-Platform Regression

- **Transferred to Plan 97:** Run package analysis and focused secure-file/startup tests on Windows,
      macOS, and Linux through FVM.
- **Transferred to Plan 97:** Run the complete `scripts/sanad_dev` suite on all three hosted CI lanes.
- **Transferred to Plan 97:** Prove POSIX mode bits and atomic rename/immediate-delete tests remain
      unchanged.
- **Transferred to Plan 97:** Prove no platform wrapper, artifact, or dependency introduces an
      architecture-specific runtime requirement on macOS/Linux.

### G5 — Performance Acceptance and Documentation

- [x] Reduce median Windows secure atomic-write case execution by at least 50%
      or below two seconds on the same host, excluding FVM process startup.
- [x] Reduce startup secure-file subprocess count materially and document the
      exact before/after count.
- [x] Demonstrate no security-test regression and no timing-only assertion that
      hides a functional failure.
- [x] Update technical design, QA matrix, troubleshooting guidance, and this
      plan with bounded evidence.

## Acceptance Criteria

- [x] Security invariants are equal or stronger than the current implementation.
- [x] Windows startup and focused secure-file tests no longer exceed their case
      timeout under normal serial system load.
- **Transferred to Plan 97:** macOS and Linux package suites pass without behavior, mode-bit, bootstrap,
      or runtime-command regressions.
- [x] No direct global Dart/Flutter invocation, secret, absolute machine path,
      generated helper, or binary artifact is committed.
- **Transferred to Plan 97:** Required CI and explicit security review pass before squash merge.

## Verification Matrix

- Static: analyzer, format, diff/secret/generated-output scan.
- Unit: path validation, typed failures, backend argument construction.
- Integration: real Windows ACL and atomic replacement; real POSIX mode and
  rename semantics.
- Runtime smoke: background Agent startup, managed status, bounded journals,
  and safe stop from an isolated worktree.
- Hosted: Windows, macOS, and Linux `scripts/sanad_dev` lanes.

## Rollback

Keep the public secure-runtime API stable so the Windows backend can be reverted
without touching ownership callers or POSIX behavior. A rollback must restore
the previous exact ACL and atomic-replacement implementation, not a permissive
fallback.
