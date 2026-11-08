---
title: "Linux arm64 Agent Release Build"
description: "Task 145: publish the official Sanad Agent for Linux arm64 in every release, keep the contract and validators in step, and make the installer report a missing architecture clearly."
---

# Task 145 — Linux arm64 Agent Release Build

## Goal

Every Sanad release publishes `sanad-agent-<version>-linux-arm64`, so the official
installer completes on an Ubuntu arm64 server instead of stopping at a manifest
that has no asset for that machine.

## Locked decisions and scope

- The new target is a GitHub-hosted `ubuntu-24.04-arm` runner in the existing
  Agent release matrix. It uses the same steps, the same `release-build`
  Environment, and the same trust policy as Linux x64: a Linux Agent carries
  SHA-256 plus GitHub attestation and has no platform code signature.
- The manifest, `SHA256SUMS`, SBOM, and attestations are generated from the
  contract, so the artifact enters those outputs through
  `release/release-contract.json` rather than through new per-file branches.
- The official Agent build matrix becomes a validated contract property: a
  contract that omits one of the official targets fails `validate-contract` and
  `check-preparation`, so a future edit cannot silently drop a supported target.
- Out of scope: a Linux arm64 **Client** build. The Client keeps Linux x64
  `.deb` and portable `tar.gz`. This plan records it as a follow-up, not as
  partial work.
- The installer already maps `aarch64|arm64` to `arm64`. Its missing-asset
  behavior changes from an anonymous error to a named, actionable failure that
  states the requested target and the targets the manifest publishes.

## Gates

### G0 — Discovery

- [x] Confirm the release matrix has no Linux arm64 Agent target.
- [x] Confirm `scripts/install.sh` already resolves `aarch64|arm64` and selects
      the Agent artifact by `platform` plus `architecture`.
- [x] Confirm manifest generation, `SHA256SUMS`, SPDX, and attestation already
      enumerate contract artifacts generically.
- [x] Confirm the Agent updater and the Client bootstrap installer derive
      `arm64` from the running platform and need no per-release change.

### G1 — Release contract and validators

- [x] Add the `linux`/`arm64` Agent artifact to `release/release-contract.json`.
- [x] Publish the official Agent targets as a validated contract property in
      `release/contract/lib/release_contract.dart`.
- [x] Call that validator from `release_tool.dart validate-contract` and from
      `release_preparation.dart check`.
- [x] Add tests for the validator, the checked-in contract, and `check`
      rejecting a contract that drops Linux arm64.

### G2 — Release and pull-request workflows

- [x] Add the `ubuntu-24.04-arm` Agent matrix entry to `.github/workflows/release.yml`.
- [x] Add `ubuntu-24.04-arm` to the pull-request `CLI automation` matrix so an
      arm64 AOT smoke runs before merge.
- [x] Add a pull-request rejection case that fails `validate-contract` when the
      contract drops the Linux arm64 Agent artifact.
- [x] Guard the release matrix itself in the release-security lane, so the
      matrix and the official target list cannot drift apart.

### G3 — Installer diagnostics

- [x] Report the requested `platform/architecture`, the release version, and the
      published Agent targets when no asset matches.
- [x] Preserve the existing manifest-trust and exit-code behavior.
- [x] Cover artifact selection and the missing-architecture message with
      behavioral installer tests and the static installer guard.

### G4 — Documentation and delivery

- [x] Update `docs/operations/release_and_signing.md`, `release/README.md`,
      `agent/release/README.md`, the installer and manual-download sections of
      `docs/operations/user_guide.md`, the CI job table, and the release
      verification matrix.
- [x] Leave `docs/llms.txt` untouched: the generator excludes `docs/plans/`, and
      regenerating it would rewrite unrelated entries that this task does not own.
- [ ] Commit, push, and open a pull request that requests `maintainer-reviewed`
      and `release-reviewed`.

## Acceptance Criteria

- [x] Given an Ubuntu arm64 host and a release manifest that publishes
      `linux`/`arm64`, the installer downloads, verifies, and installs that
      artifact exactly as it does Linux x64 — proved by
      `agent/test/core/setup/installer_transaction_test.dart`.
- [x] Given an Ubuntu arm64 host and a manifest without that target, the
      installer exits non-zero, installs nothing, and prints one actionable
      message naming `linux/arm64`, the release version, and the published
      Agent targets — proved by the same suite.
- [x] Given a release contract that omits the Linux arm64 Agent artifact,
      `validate-contract` and `check-preparation` fail with a message naming the
      missing target.
- [x] The checked-in contract publishes every official Agent target.
- [x] The release workflow declares exactly one Agent job per official target,
      and Linux arm64 uses the same runner family, Environment, and trust policy
      as Linux x64.
- [x] `fvm dart analyze` passes in `agent/`, `release/contract/`, and for
      `agent/tool/release_tool.dart`; the release contract tests, the installer
      tests, and `validate-contract` pass.

## Definition of Done

- [ ] Analyzer and focused tests recorded with bounded output.
- [ ] Documentation updated in the same change; no stale platform list remains.
- [ ] `graphify update .` run after the code change.
- [ ] Pull request opened with the required protected-review request; no label
      applied by the implementing agent.

## Follow-ups (not this task)

- A Linux arm64 **Client** build (`.deb` and portable `tar.gz`) needs an arm64
  Linux runner, an arm64 `flutter build linux` gate, and the corresponding
  Appcast/alias handling. Tracked here so it is not mistaken for coverage this
  task provides.
- If the Linux Agent runtime archive work (`sanad-agent-runtime-<version>-linux-x64`)
  merges first, the archive target set needs its own Linux arm64 decision; this
  task neither adds nor assumes runtime archives.

## Current status

| Gate | State | Remaining |
| --- | --- | --- |
| G0 — Discovery | complete | 0% |
| G1 — Release contract and validators | complete | 0% |
| G2 — Release and pull-request workflows | complete | 0% |
| G3 — Installer diagnostics | complete | 0% |
| G4 — Documentation and delivery | in progress | 15% (hosted CI on the pull request) |
