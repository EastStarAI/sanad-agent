---
title: "macOS Agent Runtime Trust Verification"
status: ready_for_pr
current_gate: complete
remaining_estimate: 0%
---

# macOS Agent Runtime Trust Verification

## Goal
Allow a verified raw macOS Agent executable to install without relying on the nondeterministic local notarization-ticket lookup, while retaining an exact Apple-anchored publisher boundary.

## Locked Scope
- Release CI remains responsible for mandatory notarization and exact ticket/`cdhash` matching.
- Runtime installation requires canonical metadata, size, SHA-256, a valid signature, Apple trust anchor, exact Team ID `UC2824B99G`, and exact publisher certificate name.
- Runtime installation does not use `spctl --type execute` or `codesign '=notarized'` for the raw CLI.

## Gates

### G0 — Evidence
- [x] Reproduce the raw-CLI `spctl` rejection and verify the official 1.0.5 signature, publisher, checksum, and release notarization gate.

### G1 — Implementation
- [x] Apply the exact Apple-anchored requirement in the shared Dart contract and POSIX installer.
- [x] Add focused regression coverage and update release documentation.

### G2 — Verification
- [x] Pass analyzers, focused tests, shell validation, diff review, and Graphify update.

## Acceptance Criteria
- [x] Correct Apple-anchored NanoSoft artifacts pass without a runtime notarization-ticket lookup.
- [x] Invalid signatures, non-Apple chains, wrong Team IDs, and wrong publisher names fail closed.
- [x] The Client bootstrap and canonical POSIX installer enforce the same publisher identity.

## Definition of Done
- [x] Code, tests, and owning documentation are consistent.
- [x] No commit, push, release, or runtime switch is performed.
