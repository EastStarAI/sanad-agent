# Task 81: macOS Impeller Crash Mitigation

## Goal

Prevent the Flutter 3.47 macOS Client from using Impeller while upstream issue
`flutter/flutter#185394` remains unresolved, restoring the prior Skia rendering
path for installed macOS users.

## Gates

- [x] **G1 — Configuration:** Set `FLTEnableImpeller` to `false` in the macOS Client `Info.plist` without changing other platforms.
- [x] **G2 — Regression Contract:** Add a focused source-level test that fails if the deployment opt-out is removed accidentally.
- [x] **G3 — Documentation:** Record the temporary macOS release invariant and the condition for re-enabling Impeller.
- [x] **G4 — Local Verification:** Pass the focused test and Flutter static analysis.
- [ ] **G5 — Delivery:** Open a focused pull request, require hosted checks to pass, and merge it through the protected repository workflow.
- [ ] **G6 — Post-Merge Soak and Release:** Before preparing a patch release, run the macOS Client for approximately one day across resize, compact/restore, background/foreground, and sleep/wake transitions without recurrence.

## Acceptance Criteria

- The built macOS application resolves `FLTEnableImpeller` to `false`.
- Windows, Linux, Android, iOS, and Web rendering configuration is unchanged.
- A focused automated test protects the source configuration.
- Impeller is not re-enabled until an upstream stable Flutter engine fix is available and passes macOS soak verification.
