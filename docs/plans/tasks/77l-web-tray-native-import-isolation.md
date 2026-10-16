---
title: "77L — Isolate native tray imports from Web compilation"
status: "in_progress"
current_gate: "Scoped delegated platform boundary repair"
---

# Goal

Restore Web compilation of the consolidated Client without changing native desktop tray behavior or the verified 77K thinking controls.

## Evidence and locked scope

The existing Web hot restart fails compiling `cnativeapi`/`ffi` with `Only JS interop members may be external`. The only direct tray-package import in Client source is `client/lib/infrastructure/platform/tray_manager_service.dart`; the already-merged tray dependency reaches a native FFI library even when runtime platform guards would skip its calls. A runtime `kIsWeb` check alone cannot exclude an imported native library from Web compilation.

Use a minimal compile-time platform import/adapter boundary, preserving the existing injectable adapter API, desktop listener/menu behavior and no-op unsupported-platform semantics. Do not change dependency versions, the thinking implementation, endpoints/configuration, runtime scripts or any Agent source. No package downgrades, vendoring, new feature, research or broad refactor. Native CocoaPods lock synchronization is already preserved by the principal's native rebuild.

## Gates and acceptance

- [ ] Read the nearest owning contracts, tray adapter/service and its existing focused tests. Delegate owns all implementation/tests/implementation docs. Reuse the assigned clean worktree; no further worktrees or delegation.
- [ ] Exclude the native tray/FFI library from Web's transitive compile graph; preserve desktop behavior and existing fake-adapter tests. Add a focused regression for the unsupported/Web adapter or compile boundary, without a diagnostic utility.
- [ ] Run focused tray/background adapter tests and `fvm flutter analyze`. Prove real Web compilation with `fvm flutter build web --debug --target lib/driver_main.dart` (or the smallest equivalent complete Client Web build), keeping logs outside the repository with exit status/duration. Do not run another full test suite.
- [ ] Update the owning public platform contract/technical/QA documentation where the compilation boundary changes; no private file/host references. Return exact changed/new paths, commands, outcomes and uncertainty in the external report.
- [ ] Principal independently reviews/verifies and preserves the result, removes the completed worker worktree, then refreshes the owned existing Web Client. No worker live/runtime/browser/Home/config operations, source handoff, commit/push/PR/deploy.

## Definition of Done

Real Client Web compilation succeeds without importing native FFI; focused desktop tray behavior remains green; analyzer and relevant docs pass; no unrelated product change. Live thinking acceptance remains separate in 77K.
