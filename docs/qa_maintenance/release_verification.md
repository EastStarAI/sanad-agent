---
title: "Release Verification Matrix"
description: "Required local and hosted evidence for Sanad release, signing, installation, update, and rollback."
---

# Release Verification Matrix

## Candidate invariants

Every candidate must match the release contract for marketing version, increasing build, Stable or numbered RC tag, derived channel, tagged commit, component, platform, architecture, filename, size, and SHA-256. RC filenames must include the full `-rc.N` identity and must not collide with another RC or Stable download. A candidate is
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

The credential scan runs the pinned open-source Gitleaks CLI directly rather
than the organization-licensed GitHub Action. CI downloads the official Linux
archive over HTTPS, verifies its pinned SHA-256 before extraction, scans the
complete checked-out Git history with redaction enabled, and requires no
repository secret or commercial license. The tracked configuration extends the
default rules and narrowly allows only the reviewed `generic-api-key` fixtures
in three exact credential/redaction test files; production paths and all other
rules remain fail-closed.

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

Hosted validation begins with a `validation_only` full-matrix run from protected `main`. It requires no tag and must leave zero Drafts and Releases while retaining private Agent/Client artifacts, the signed IPA, manifest, checksums, SBOM, Appcast, and attestations. Later lifecycle validation additionally exercises interrupted downloads, wrong architecture, corrupted size and checksum, replacement failure, service restart, retained Sanad Home, repeated update requests, and rollback to the prior signed version.

## Installer coverage

The canonical installer sources accept only the creation-time pairing token;
they never accept or expose the durable device credential. They select the
release through the manifest, validate repository URLs, architecture, size,
and SHA-256, preserve Sanad Home, prepare pairing, and register the background
service. Release validation must cover clean install, pairing-token replay,
lost-success retry, durable reconnect, reinstall, upgrade, failed verification,
interrupted replacement, and uninstall on each supported desktop host.

## First hosted validation-only probe

Run `30723337563` validated the no-tag safety boundary and signing-Environment approvals. It created no tag, Draft, or Release. Agent Linux, Client Linux/Web, and signed Android APK/AAB completed successfully. The remaining jobs exposed workflow defects rather than invalid signing material:

- Windows Agent invoked FVM from Git Bash, where the Windows pub-cache executable was not on PATH; Windows Agent commands now use PowerShell.
- Both signed and notarized macOS Agent binaries reached the final check, where Gatekeeper rejected raw CLI executables as non-app bundles; raw CLIs retain codesign and notary acceptance checks without the inapplicable `spctl` app assessment.
- Client macOS recursively changed all runner-temporary permissions, including GitHub command files; permission hardening is now limited to the three restored signing files.
- Client iOS attempted automatic Development signing during archive; it now creates an unsigned archive and performs the manual App Store Distribution export with the installed profile.
- Client Windows encountered a transient Chocolatey `504` for NSIS and continued into update signing without an installer; NSIS installation now has bounded retries and the packaging helper fails immediately when the build or output is missing.

Run `30724542547` confirmed the first fixes: both macOS Agent architectures, signed iOS IPA, Linux Agent, Linux/Web Client, and signed Android APK/AAB passed. It exposed three remaining hosted issues: Client macOS needed `flutter precache --macos` before manual CocoaPods installation; the Chocolatey NSIS service remained unavailable after all retries, so Windows now downloads the pinned official NSIS 3.12 installer over HTTPS and verifies its reviewed size and SHA-256 before silent installation; and the full Windows Agent suite contains unrelated Windows cleanup/path/timing failures, so the release job runs analyzer plus the focused release/update suite while normal broad CI remains authoritative.

Run `30725502085` then passed the complete Agent matrix plus Linux/Web, iOS, and Android Clients. Client macOS exposed a secret-encoding mismatch, corrected by storing the base64-encoded Sparkle key file as required by the workflow. Client Windows showed that PowerShell's web cmdlet received non-canonical SourceForge redirect bytes; the download now uses bounded `curl.exe` HTTPS redirects and verifies both the exact reviewed byte size and SHA-256. A further validation-only rerun must close these final two hosted defects before the matrix is accepted.

Run `30726573652` confirmed every Agent target and the Linux/Web, iOS, Android,
and Windows Clients. The macOS Client completed Developer ID signing,
notarization, stapling, and Gatekeeper assessment, then remained inside the
same build step before producing its Sparkle update signature. The workflow had
imported the restored Sparkle key with `generate_keys -f` and invoked
`sign_update` indirectly without a key-file argument; Sparkle documents that
this Keychain path may request interactive authorization. Hosted macOS signing
now passes the runner-temporary exported key directly to `sign_update` through
`--ed-key-file`, while preserving the Keychain fallback for operator builds.
A replacement validation-only run must complete the macOS Client, assembly,
manifest, SBOM, and attestations before the hosted matrix is accepted.

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

The Windows workflow and installer now produce the approved unsigned `1.0.0` artifacts without a PFX requirement, retain WinSparkle DSA for client updates, and require explicit disclosure plus checksum, manifest, SBOM, and provenance metadata. Hosted Linux/Windows/Android builds, Appcast publication, clean-machine lifecycle tests, Windows 10/11 Defender and SmartScreen observations, and Internal TestFlight remain hosted/live evidence and must not be represented as completed. Authenticode/SignPath is post-v1 work.
