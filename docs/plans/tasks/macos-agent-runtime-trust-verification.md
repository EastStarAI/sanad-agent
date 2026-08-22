---
title: "macOS Agent Runtime Trust Verification"
status: in_review
current_gate: G3
remaining_estimate: 10%
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

### G3 — Pull Request Review
- [x] Commit, push, and open the focused pull request.
- [ ] Pass hosted checks and receive the required protected reviews before merge.

## Acceptance Criteria
- [x] Correct Apple-anchored NanoSoft artifacts pass without a runtime notarization-ticket lookup.
- [x] Invalid signatures, non-Apple chains, wrong Team IDs, and wrong publisher names fail closed.
- [x] The Client bootstrap and canonical POSIX installer enforce the same publisher identity.

## Definition of Done
- [x] Code, tests, and owning documentation are consistent.
- [x] The focused change is committed, pushed, and opened for review.
- [ ] Hosted checks and protected reviews pass before merge.
- [x] No release or runtime switch is performed.
