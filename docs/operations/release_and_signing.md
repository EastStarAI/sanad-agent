---
title: "Release, Signing, and Deployment Architecture"
description: "The stable release pipeline, protected signing boundaries, artifact publication, and live-release handoff."
---

# Release, Signing, and Deployment Architecture

## Release boundary

The public `EastStarAI/sanad-agent` repository owns CI, artifact construction,
signing orchestration, the release manifest, update-feed generation, and the
canonical installer sources. The current patch release uses marketing version `1.0.1` and build number `2` for both Sanad Agent and Sanad Client. RC tags use `v1.0.1-rc.N`; Stable uses `v1.0.1`. Each later candidate records its increasing build number in the checked-in contract.

Pull-request CI is read-only and never receives signing or deployment credentials. A protected validation-only dispatch from `main` can build the complete signed Agent/Client matrix, including a private IPA, as retained private artifacts without a tag, Draft, Release, TestFlight upload, or deployment. Signing jobs use protected GitHub Environments. Assembly remains contents-read; only the separate Draft and publication jobs receive contents-write.

## Artifact channels

| Component | Target | Public channel | Authenticity boundary |
|---|---|---|---|
| Agent | macOS arm64/x64 | GitHub Release | Developer ID, notarization, and GitHub attestation |
| Agent | Linux x64 | GitHub Release | SHA-256 plus GitHub attestation |
| Agent | Windows x64 | GitHub Release | Temporarily unsigned Windows build for every release; canonical manifest/URL/size/SHA-256 and protected GitHub provenance |
| Client | macOS universal | GitHub Release | Developer ID, notarization, Sparkle EdDSA |
| Client | Linux x64 | GitHub Release | SHA-256 plus GitHub attestation |
| Client | Windows x64 | GitHub Release | Temporarily unsigned Windows build for every release; WinSparkle DSA plus canonical manifest/URL/size/SHA-256 and protected GitHub provenance |
| Client | Android universal APK | GitHub Release | Android release signature |
| Client | Android AAB | Private release handoff | Android release signature |
| Client | iOS | Internal TestFlight only | Apple Distribution and provisioning profile |
| Client | Web | EastStar AI server | Manifest checksum and atomic deployment |

The exact filenames are defined in `release/release-contract.json`. Generated
manifests, checksums, SBOMs, attestations, and Appcast files are release outputs,
not source files.

The Windows exception is policy-based, not version-based. Empty, unknown, or
signed metadata is rejected while `unsigned+github-attestation` for Agent and
`unsigned+winsparkle-dsa` for Client are active. Runtime checksum checks do not
claim to reproduce GitHub attestation verification. When Authenticode becomes
available, a separately reviewed transition changes the centralized contract to
signed-only and rejects newly produced unsigned artifacts; the two policies are
never accepted concurrently by default.

Android debug builds never require or consume the release keystore. Gradle only
requires the external `android/key.properties` file when the requested task is
a release task; a missing file must fail release configuration before an
unsigned APK or AAB can be produced.

The macOS Agent uses Hardened Runtime with the narrowly scoped
`com.apple.security.cs.allow-unsigned-executable-memory` entitlement required by
Dart AOT runtime stubs. The workflow injects the validated release-contract
version at compilation, signs with that entitlement, executes the signed binary,
and submits it for notarization. After Apple accepts the submission, the
workflow fetches the authoritative notary log with a bounded retry and requires
`Accepted`, status code zero, no issues, SHA-256 ticket metadata, and an exact
architecture plus `cdhash` match to the signed executable. This avoids relying
on the local `codesign --test-requirement '=notarized'` online-ticket cache,
which remained unavailable for more than ten minutes despite an accepted ticket
for the exact raw CLI. `spctl --type execute` is not used because it rejects
valid notarized non-bundle executables.

The hosted macOS Client job restores the exported Sparkle Ed25519 key to a
runner-temporary file and passes that file directly to Sparkle `sign_update`.
It does not import the key through `generate_keys` or depend on interactive
Keychain authorization. Local operator builds may continue using the existing
Keychain when no explicit Sparkle key-file path is supplied. Windows signing
likewise passes `WINSPARKLE_PRIVATE_KEY_PATH` directly to `sign_update`; the DSA
private key is never copied into the Client checkout.

## Protected environments

| Environment | Responsibility |
|---|---|
| `release-build` | Non-secret release builds and candidate retention |
| `apple-signing` | Developer ID signing, notarization, and Sparkle signing |
| `apple-testflight` | Apple Distribution export and optional Internal TestFlight upload |
| `windows-update-signing` | WinSparkle DSA update signing only; it does not provide Authenticode publisher identity |
| `android-signing` | Android APK/AAB release signing |
| `release-publication` | Atomic publication of an already reviewed Draft RC or Stable Release |
| `client-downloads-production` | Post-publication verification and restricted deployment of Production-only Stable Client redirects |
| `web-production` | Atomic Web deployment |
| `updates-production` | Atomic Appcast deployment |
| `installers-production` | Publishing canonical installer sources |

Signing environments and `release-publication` require the repository owner as reviewer and accept deployments only from protected refs. `release-build` has no signing responsibility. Repository secret scanning and push protection are enabled. Signing secrets were transferred directly from the validated local signing store to their owning Environments without exposing values in Git, logs, or durable temporary files. Publication and production-deployment Environments contain no deployment secret. Fork, pull-request, and Dependabot workflows remain read-only and cannot trigger the tag/manual release workflow or enter protected environments.

## Secret inventory

Secret values never belong in Git, documentation, logs, release archives, or
unprotected artifacts.

| Secret name | Purpose | Owner and rotation |
|---|---|---|
| `MACOS_DEVELOPER_ID_P12_BASE64` / `MACOS_DEVELOPER_ID_P12_PASSWORD` | macOS application and agent signing | NanoSoft LY LLC; rotate on expiry, compromise, or publisher change |
| `APPLE_API_PRIVATE_KEY_P8_BASE64` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID` | notarization and App Store Connect uploads | NanoSoft LY LLC; scoped CI key, revoke and replace on compromise |
| `APPLE_DISTRIBUTION_P12_BASE64` / `APPLE_DISTRIBUTION_P12_PASSWORD` | iOS distribution signing | NanoSoft LY LLC; rotate on expiry or compromise |
| `IOS_APP_STORE_PROFILE_BASE64` | `com.eaststarai.sanad` App Store profile | NanoSoft LY LLC; regenerate when certificate, entitlement, or App ID changes |
| `WINDOWS_SIGNING_PFX_BASE64` / `WINDOWS_SIGNING_PFX_PASSWORD` | Future Windows Authenticode signed-only transition | Release owner; not yet available and not required while the temporary unsigned policy is active |
| `ANDROID_KEYSTORE_BASE64` / passwords / `ANDROID_KEY_ALIAS` | Android APK/AAB signing | Release owner; retain encrypted recovery copy for the lifetime of the package ID |
| `SPARKLE_ED25519_PRIVATE_KEY_BASE64` | macOS update signatures | Release owner; rotate only with a documented public-key transition |
| `WINSPARKLE_DSA_PRIVATE_KEY_BASE64` | Windows update signatures | Release owner; rotate only with a documented public-key transition |
| `DEPLOY_SSH_PRIVATE_KEY` / host / user / known-hosts | Web, Appcast, and installer deployment | Server operator; dedicated restricted account and pinned host key |

`GITHUB_TOKEN` is workflow-scoped and receives only the permissions declared by
the owning job.

## Apple publisher

Apple signing and Internal TestFlight distribution use the NanoSoft LY LLC
team. The display name is `Sanad` and the bundle identifier is
`com.eaststarai.sanad`. The App Store Connect record is named `Sanad Remote`
because the shorter product names were unavailable; this does not change the
installed display name. Internal TestFlight is the only iOS distribution
channel for the first release; external testing and App Store review are a
separate future decision.

## Atomic publication and rollback

A separate read-only publication-guard probe may enter the protected
`release-publication` Environment only to verify approval or rejection behavior.
It requires an exact public `main` commit, inventories existing `v1` tags and
Releases before the gate, has no write permission, and never creates a candidate.
Probe approval is not Release publication approval.

The candidate workflow creates a private Draft and fails if the tag already owns any Draft or published Release. A separate least-privilege publication job can make that reviewed Draft public only after the required owner approval on `release-publication`. Rejected or cancelled approval leaves no partial public Release. Public release files use published checksums. After an approved Stable publication, the protected Client-download job downloads the public manifest, checksum file, and three desktop Client artifacts; verifies canonical URLs, byte sizes, SHA-256 values, and GitHub attestations; generates a deterministic Nginx redirect include; and sends only that include to the server's restricted control command. RC publication never enters this path. The server remains a redirector rather than an artifact mirror and owns candidate validation, atomic activation, public regression verification, and automatic rollback.

Production Web, Appcast, and installer releases use `/opt/sanad-sites/assets/web`, `/opt/sanad-sites/assets/updates`, and `/opt/sanad-sites/assets/install`; the obsolete `/srv/sanad/*` workflow roots are not valid deployment targets. The private Web handoff
is downloaded from the explicitly selected successful release-workflow run and
verified against its GitHub build attestation. Server deployment then writes a
versioned directory and changes a `current` symlink only after the transfer
succeeds. The Web handoff records its exact public commit, validates the Flutter
shell, bootstrap, favicon, version marker, and hosted readability before
activation, then verifies the public Production URL. A failed public probe
restores the preceding selector automatically. Rollback switches that symlink
to the last known good version; it does not rebuild or mutate a published
release.

Web assets use content-hashed Flutter output plus a small no-cache
`version.json`. The server must route unknown application paths to
`index.html`, serve immutable hashed assets with long-lived caching, and serve
the shell, version marker, and Appcast without stale caching.

## Readiness and live handoff

Local verification proves the release contract, manifest/checksum generation,
macOS universal packaging and Developer ID signatures, iOS signed export,
Sparkle signatures, Web packaging, analyzers, and updater tests.

The protected validation-only run at public `main` commit `c2bd6b3b` passed the
complete hosted Agent and Client matrix. It exercised the protected signing
Environments, generated the assembled manifest, checksums, Appcast, SBOM, and
attestations as private retained artifacts, and created no tag, Draft, or
Release. Read-only guard probe `30730348167` was then rejected by the repository
owner at `release-publication`; the protected step did not run and post-run
inventory remained at zero `v1` tags and zero Releases or Drafts.

The following remain live-release gates:

- the workflow and installer implement the approved unsigned Windows `1.0.0`
  policy while retaining WinSparkle DSA, manifest, checksum, SBOM, provenance,
  and disclosure checks; Windows 11 Defender, SmartScreen, and lifecycle evidence
  passed. Windows 10 clean-machine validation is not part of the `1.0.0` release
  gate and must not be represented as tested;
- use the completed App Store Connect API key and application record for
  Internal TestFlight upload; hosted notarization, staple, and Gatekeeper
  verification have passed;
- build and review tagged RC candidates, publish each immutable Release only
  after its separate owner approval, stage Web/Appcast/installers, and exercise
  clean installation, real upgrade, failure recovery, and rollback paths.

Those actions are owned by the later public-release task and do not weaken the
prepared workflows.
