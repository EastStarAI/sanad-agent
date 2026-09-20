status: planned
priority: high
security_review: required
platforms: windows-primary, macos-regression, linux-regression
depends_on: sanad-dev-windows-command-latency
---

# sanad-dev Windows Secure Runtime-File Performance

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
- Changing runtime ownership, Home selection, or source-switch semantics.

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

- [ ] Measure FVM/test-process startup separately from test-case execution.
- [ ] Instrument one directory hardening, new-file publication, existing-file
      replacement, append-file acquisition, and secure read on Windows.
- [ ] Record subprocess count, median, p95, and cold/warm timing over repeated
      runs on the same host.
- [ ] Identify which cost belongs to PowerShell startup, ACL work, atomic move,
      antivirus/filesystem contention, and repeated call-site preparation.

### G1 — Threat Model and Design Decision

- [ ] Enumerate threats: foreign explicit ACE, inherited ACE, SID ambiguity,
      link/junction substitution, destination replacement race, temporary-file
      disclosure, partial write, PID/process interruption, and helper failure.
- [ ] Compare at least: a single bounded PowerShell transaction, direct Windows
      APIs through a focused helper, and safe call-site batching.
- [ ] Reject any design that cannot prove exact DACL replacement and atomic
      write-through publication.
- [ ] Document the selected design, rollback boundary, and why rejected options
      are unsafe or unnecessarily complex.
- [ ] Obtain explicit `security-reviewed` authorization before merge because the
      owner-only runtime-file boundary is modified.

### G2 — Focused Windows Implementation

- [ ] Implement the smallest reusable Windows backend behind the existing pure
      Dart API; keep callers platform-neutral.
- [ ] Bound helper lifetime, input size, output, and error mapping.
- [ ] Avoid shell interpolation of paths, identities, or contents.
- [ ] Preserve typed `ownership_failed`, `atomic_replace_failed`,
      `atomic_write_failed`, and unsafe-path outcomes.
- [ ] Leave POSIX code unchanged unless a proven shared refactor preserves exact
      behavior and reduces duplication.

### G3 — Security and Race Regression Coverage

- [ ] Verify exact owner-only file and directory ACLs after success.
- [ ] Seed inherited and explicit foreign ACEs and prove they are removed or the
      operation fails closed.
- [ ] Cover unsafe symlink/junction/reparse-point and outside-root paths.
- [ ] Cover existing destination replacement, concurrent readers/writers,
      process interruption, helper nonzero exit, and immediate consumer delete.
- [ ] Assert no temporary artifacts or permissive destination remain after each
      failure.
- [ ] Exercise startup attempts, launcher records, component controls, switch
      manifests, runtime metadata, and journals through the centralized API.

### G4 — Cross-Platform Regression

- [ ] Run package analysis and focused secure-file/startup tests on Windows,
      macOS, and Linux through FVM.
- [ ] Run the complete `scripts/sanad_dev` suite on all three hosted CI lanes.
- [ ] Prove POSIX mode bits and atomic rename/immediate-delete tests remain
      unchanged.
- [ ] Prove no platform wrapper, artifact, or dependency introduces an
      architecture-specific runtime requirement on macOS/Linux.

### G5 — Performance Acceptance and Documentation

- [ ] Reduce median Windows secure atomic-write case execution by at least 50%
      or below two seconds on the same host, excluding FVM process startup.
- [ ] Reduce startup secure-file subprocess count materially and document the
      exact before/after count.
- [ ] Demonstrate no security-test regression and no timing-only assertion that
      hides a functional failure.
- [ ] Update technical design, QA matrix, troubleshooting guidance, and this
      plan with bounded evidence.

## Acceptance Criteria

- [ ] Security invariants are equal or stronger than the current implementation.
- [ ] Windows startup and focused secure-file tests no longer exceed their case
      timeout under normal serial system load.
- [ ] macOS and Linux package suites pass without behavior, mode-bit, bootstrap,
      or runtime-command regressions.
- [ ] No direct global Dart/Flutter invocation, secret, absolute machine path,
      generated helper, or binary artifact is committed.
- [ ] Required CI and explicit security review pass before squash merge.

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
