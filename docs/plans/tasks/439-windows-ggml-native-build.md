---
title: "Task 439 — Windows GGML Native Build Correctness"
issue: "https://github.com/EastStarAI/sanad-agent/issues/439"
status: planned
---

## Goal

Make the Windows x64 whisper builder and release proof enforce the documented `GGML_NATIVE=OFF` / AVX2 baseline, and determine whether the v1.0.23 runtime is a plausible owner of the reported production crash.

## Locked Scope

- Fix and prove PowerShell/CMake argument construction and cache validation.
- Inspect official v1.0.23 Agent/runtime assets only after manifest/SHA verification.
- Treat the production crash relationship as unproven until isolated A/B evidence exists.
- Do not lower the accepted Windows x64 AVX2 floor or add GPU acceleration.

## Gates

### G0 — Artifact and Build Audit
- [ ] Reproduce the literal `GGML_NATIVE:BOOL=$ggmlNative` cache value.
- [ ] Verify v1.0.23 asset hashes, layout, load behavior, and available ISA evidence.
- [ ] Record whether the artifact audit can prove or only bound crash risk.

### G1 — Build Fix
- [ ] Pass `OFF` unambiguously on Windows x64.
- [ ] Fail closed when the generated cache is missing, literal, or not exactly `OFF`.
- [ ] Add focused regression coverage at the builder/release boundary.

### G2 — Verification
- [ ] Rebuild and prove the cache value and native runtime load.
- [ ] Run owning analyzer/tests with elapsed/bounded output.
- [ ] Update native-runtime documentation and Graphify.

## Acceptance Criteria

- [ ] Every Windows x64 build records `GGML_NATIVE:BOOL=OFF`.
- [ ] A literal or wrong value fails before staging/publication.
- [ ] Release verification records evidence consistent with the declared AVX2 baseline.
- [ ] The report distinguishes confirmed build defects from unproven crash causality.

## Definition of Done

- [ ] Implementation, tests, and docs are complete in the isolated worktree.
- [ ] Focused verification passes on Windows.
- [ ] A separate reviewer session accepts the candidate; fixes return to the original implementer session and re-review returns to the original reviewer session.
- [ ] Stop before Ready/merge without separate authorization.
