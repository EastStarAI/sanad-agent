---
title: "Release Verification Matrix"
description: "Required local and hosted evidence for Sanad release, signing, installation, update, and rollback."
---

# Release Verification Matrix

## Candidate invariants

Every candidate must match the release contract for version, build, tag,
component, platform, architecture, filename, size, and SHA-256. A candidate is
rejected when its source commit differs from the release tag, required outputs
are missing, or generated metadata is not deterministic.

CI and source audits must also prove that no Firebase dependency removed for v1
has returned, no private signing material is tracked, the generated Appcast is
untracked, and pull-request workflows cannot access signing or deployment
environments. The shared FVM setup must activate FVM in its isolated
`PUB_CACHE`, then invoke the explicit `fvm:main` package entrypoint through
Dart. This keeps bootstrap portable when Windows exposes `PUB_CACHE` as a
Git-Bash-incompatible drive path and avoids the implicit package entrypoint
that is absent from current FVM releases.

## Platform matrix

| Target | Local evidence | Hosted or clean-machine evidence still required |
|---|---|---|
| Agent macOS arm64/x64 | compilation, version, architecture, Developer ID verification | both hosted runners, clean install, real upgrade and rollback |
| Agent Linux x64 | contract and workflow path | hosted build, provenance, clean install, service/update/rollback |
| Agent Windows x64 | contract and workflow path | Unsigned Windows build disclosure, SHA-256/manifest/provenance, Defender/SmartScreen on Windows 10/11, service/update/rollback |
| Client macOS universal | universal Mach-O inspection, Developer ID-signed and notarized DMG, staple, Gatekeeper, Sparkle signature | clean update and rollback |
| Client Linux x64 | Web/Linux workflow definition | hosted package, dependency audit, clean install/update/uninstall |
| Client Windows x64 | installer and current fail-closed signing workflow definition | SANAD-12 unsigned-policy workflow adaptation, disclosure, SHA-256/manifest/provenance, clean installer/update/rollback, Defender/SmartScreen |
| Client Android APK/AAB | signed local APK/AAB, package identity and keystore fingerprint | signed hosted build, clean install/upgrade |
| Client iOS | signed IPA export for NanoSoft LY LLC; App Store Connect record and API key ready | Internal TestFlight upload |
| Client Web | release build and version marker | protected atomic deployment, cache/SPA checks, rollback |

## Update failure coverage

Automated tests cover contract parsing, invalid tag rejection, deterministic
Appcast output, source-managed no-mutation behavior, checksum rejection, client
bootstrap selection, and existing daemon-controller behavior.

Hosted validation additionally exercises interrupted downloads, wrong
architecture, corrupted size and checksum, replacement failure, service restart,
retained Sanad Home, repeated update requests, and rollback to the prior signed
version.

## Installer coverage

The canonical installer sources accept only the creation-time pairing token;
they never accept or expose the durable device credential. They select the
release through the manifest, validate repository URLs, architecture, size,
and SHA-256, preserve Sanad Home, prepare pairing, and register the background
service. Release validation must cover clean install, pairing-token replay,
lost-success retry, durable reconnect, reinstall, upgrade, failed verification,
interrupted replacement, and uninstall on each supported desktop host.

## SANAD-08 local evidence

The preparation worktree passed both analyzers, the complete Backend suite
(154 passing), the complete fast agent suite (877 passing, 2 skipped), and the
complete fast client suite (724 passing).
Focused release/updater and bootstrap suites also passed after the final trust
boundary changes.

The release fixture validated `v1.0.0+1`, required every contracted candidate,
published only the eight public manifest entries/checksums, rejected
non-canonical URLs, and produced two deterministic Appcast platform entries.
Flutter Web built from the public production profile. YAML, shell, iOS launch
storyboard, documentation, private-material, credential-literal, Firebase
regression, and whitespace checks passed locally.

On macOS, the local agent binary reported version `1.0.0`, matched arm64, and
passed Developer ID validation for NanoSoft LY LLC. The client build produced a
universal arm64/x64 application and Developer ID-signed DMG with a Sparkle
signature. Apple accepted notarization, staple validation passed, and
Gatekeeper reported a notarized Developer ID source. The first submission
exposed an invalid nested Sparkle `Autoupdate` signature; the packaging helper
now signs every nested Mach-O and verifies the expected Team ID before creating
the DMG. A signed iOS IPA for `com.eaststarai.sanad` was exported with the
NanoSoft LY LLC Apple Distribution identity. The generic Flutter launch-image
placeholder was removed after that probe; the resulting plain launch
storyboard passes XML validation and receives its final hosted build check in
the release workflow.

The local Android release produced signed APK and AAB files for
`com.eaststarai.sanad` version `1.0.0`; the APK certificate fingerprint matched
the external `sanad-release` keystore and the AAB JAR signature verified.

Hosted Linux/Windows/Android builds, the SANAD-12 Windows unsigned-policy
workflow adaptation, Appcast publication, clean-machine lifecycle tests, and
Internal TestFlight remain hosted/live evidence and must not be represented as
locally completed. The current Windows workflow remains fail-closed until
SANAD-12 replaces the signing requirement with explicit `Unsigned Windows
build` disclosure plus checksum, manifest, provenance, Defender, and
SmartScreen gates. Authenticode/SignPath is post-v1 work.
