---
title: "Release and Update Architecture"
description: "The shared release manifest and the update ownership of the Sanad agent and client on every runtime."
---

# Release and Update Architecture

## Shared release contract

`release/release-contract.json` defines the marketing version, build, Stable tag, accepted RC channel files, repository, canonical filename templates, platform, architecture, and expected signature type. RC artifact filenames include the full `-rc.N` release identity while pubspec marketing versions remain `1.0.0`. Tags are either `v<version>` or `v<version>-rc.N`; every other prerelease form is rejected. The shared Dart package under `release/contract/` parses and
validates that contract and the generated release manifest.

The public release manifest is generated only after every public and private
handoff artifact required by the contract exists. Its public entries include
the immutable download URL, byte size, SHA-256 digest, platform, architecture,
component, version, and signature metadata. Private AAB and Web handoffs remain
protected workflow artifacts and are verified by their build attestations. The
workflow refuses version/tag/commit mismatches, missing artifacts,
non-canonical filenames, or checksum differences.

## Agent update ownership

`AgentUpdateService` is the only owner of native-agent replacement.

- `sanad update` calls the service directly.
- The standalone desktop client requests the daemon's update endpoint; it does
  not implement a competing downloader.
- A source/FVM runtime returns `source_managed` immediately and never performs
  Git operations or modifies the checkout.
- A standalone runtime selects the exact operating-system and architecture
  artifact, validates its size and SHA-256, stages it beside the installed
  executable, acquires an update lock, preserves a backup, and performs an
  atomic replacement.
- Replacement failure restores the previous executable. Windows uses a
  detached replacement process because the running executable cannot replace
  itself in place.

The public status vocabulary is `up_to_date`, `update_available`, `updating`,
`restart_required`, `source_managed`, `unsupported_target`,
`verification_failed`, `rollback_completed`, and `failed`.

## First-install exception

When a packaged desktop client cannot find an installed local agent, it may use
`VerifiedAgentBootstrapInstaller` once. This bootstrap consumes the same
release manifest, platform selection, size check, SHA-256 validation, staging,
backup, and atomic replacement rules as the agent updater. After installation,
the operating-system service owns the daemon lifecycle and all later updates
return to `AgentUpdateService`.

Source-mode clients never bootstrap or replace a source daemon.

## Client self-update ownership

Client application updates remain separate from `sanad update`:

- macOS and Windows use the generated Appcast and their native Sparkle/
  WinSparkle signature mechanisms.
- Linux exposes a user-approved release flow; it does not silently replace an
  installed package.
- Android delegates package installation and signature enforcement to the
  operating system.
- iOS is updated through Internal TestFlight for the first release.
- Web compares the deployed `version.json` with its compiled version without
  forcing a reload loop; the browser loads the newer deployment on the next
  user-initiated reload.
- Source/FVM clients disable packaged self-update and leave the checkout under
  developer control.

## Appcast

The Appcast is derived deterministically from the verified channel manifest after the macOS and Windows client packages and their update signatures exist. Stable uses `appcast.xml`; RC uses isolated `appcast-rc.xml` and `release-manifest-rc.json` staging surfaces, so Stable clients cannot discover an RC. Generated feeds are never tracked in Git. Stable production publication remains the SANAD-13 handoff.

## Trust boundaries

Runtime replacement always requires a matching manifest entry and checksum.
Platform code signing adds publisher identity on Apple and Android. Windows `1.0.0` intentionally has no Authenticode publisher identity; its Agent uses GitHub provenance and its Client additionally uses WinSparkle DSA for update integrity.
GitHub artifact attestations bind release outputs to the public workflow and
commit; Linux users and distributors can verify that provenance independently.
No updater accepts tokens, provider credentials, or deployment secrets.
