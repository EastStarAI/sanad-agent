---
title: "Release, Signing, and Deployment Architecture"
description: "The stable release pipeline, protected signing boundaries, artifact publication, and live-release handoff."
---

# Release, Signing, and Deployment Architecture

## Release boundary

The public `EastStarAI/sanad-agent` repository owns CI, artifact construction,
signing orchestration, the release manifest, update-feed generation, and the
canonical installer sources. The current patch release uses marketing version `1.0.4` and build number `5` for both Sanad Agent and Sanad Client. RC tags use `v1.0.4-rc.N`; Stable uses `v1.0.4`. The unpublished `v1.0.3` candidate tag is retained as failed provenance after its Windows smoke gate rejected a PowerShell reserved-variable collision; it owns no GitHub Release or Production asset. Each later candidate records its increasing build number in the checked-in contract.

Pull-request CI is read-only and never receives signing or deployment credentials. A protected validation-only dispatch from `main` can build the complete signed Agent/Client matrix, including a private IPA, as retained private artifacts without a tag, Draft, Release, TestFlight upload, or deployment. Signing jobs use protected GitHub Environments. Assembly remains contents-read; only the separate Draft and publication jobs receive contents-write.

## Artifact channels

| Component | Target | Public channel | Authenticity boundary |
|---|---|---|---|
| Agent | macOS arm64/x64 | GitHub Release | Developer ID, notarization, and GitHub attestation |
| Agent | Linux x64 | GitHub Release | SHA-256 plus GitHub attestation |
| Agent | Windows x64 | GitHub Release | Temporarily unsigned Windows build for every release; canonical manifest/URL/size/SHA-256 and protected GitHub provenance |
| Client | macOS universal | GitHub Release | Developer ID, notarization, Sparkle EdDSA |
| Client | Linux x64 `.deb` and portable `tar.gz` | GitHub Release | SHA-256 plus GitHub attestation |
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
| `client-downloads-production` | Restricted Production deployment of Stable Client redirects, Web, Appcast, and canonical installer sources |

Signing Environments keep signing secrets isolated and accept deployments only from their exact custom release refs, but they do not require a human reviewer. The one human release decision belongs to `release-publication`, which requires the repository owner after the complete signed candidate, metadata, checksums, SBOM, attestations, and private Draft exist. `release-build` has no signing responsibility. Repository secret scanning and push protection are enabled. Signing secrets were transferred directly from the validated local signing store to their owning Environments without exposing values in Git, logs, or durable temporary files. The restricted SSH deployment credential set belongs only to `client-downloads-production`; that Environment remains non-interactive and tag-restricted so the already approved Stable release can deploy aliases and Production assets without a second approval. Separate per-surface Environment names must not be introduced without provisioning and protecting them first. Fork, pull-request, and Dependabot workflows remain read-only and cannot trigger the tag/manual release workflow or enter protected environments.

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

The candidate workflow creates a private Draft and fails if the tag already owns any Draft or published Release. A separate least-privilege publication job can make that reviewed Draft public only after the required owner approval on `release-publication`. Rejected or cancelled approval leaves no partial public Release. Public release files use published checksums. After an approved Stable publication, the protected Client-download job downloads the public manifest, checksum file, and three desktop Client artifacts; verifies canonical URLs, byte sizes, SHA-256 values, and GitHub attestations; generates a deterministic Nginx redirect include; and uploads only that bounded include through the Production forced-command deployment broker. The broker verifies the exact byte count and digest, and the root-owned controller invokes the fixed alias validator with the verified payload. The Stable release then calls the reusable Production asset workflow with Web, Appcast, and installers enabled and its own release run ID. This ordering serializes the redirect deployment before the remaining Production assets and prevents an asset handoff when publication or redirect verification fails. RC and validation-only runs never enter either Production path. The server remains a redirector rather than an artifact mirror and owns candidate validation, atomic activation, public regression verification, and automatic rollback.

Every static-surface job captures the preceding identity before activation and
must enter the same verified rollback path when the controller activation
command itself returns nonzero or when later public-byte verification fails.
Shell fail-fast behavior must not exit between a selector-changing activation
and rollback. Rollback command failure is reported separately from rollback
verification failure, and the release job remains failed in either case.

A manual `Deploy prepared release assets` dispatch is recovery-only. It must identify an existing immutable Stable tag and its completed producing release run. Because a default-branch dispatch has `main` as its deployment ref, the `client-downloads-production` Environment must explicitly allow the reviewed `main` recovery ref before credentials are available; normal automatic deployment remains tag-restricted. Changing that policy is a repository-setting mutation and is not implied by a workflow edit.

The producing release run may be completed with `success` or `failure`, because
an asset deployment failure can make the parent release run fail after the
immutable Release and attested Web handoff already exist. A run with no final
conclusion is accepted only when its ID is the current reusable-workflow run;
manual recovery cannot consume an unrelated queued or in-progress run.

The public workflow never names, creates, reads, or selects a live-host release
directory. The private Web handoff is downloaded from the explicitly selected
producing release-workflow run and verified against its GitHub build
attestation. It is packaged with its exact public commit identity and sent to
the Production forced-command broker. The root-owned controller safely extracts
the bounded archive, rejects links, traversal, secret-shaped paths, unexpected
static-overlay files, changed manifests, or non-root-writable promoted content,
and creates the immutable release and selector. Activation recreates exactly
the affected Web, updates, or downloads container because Docker bind mounts
resolve the selected directory when the container is created; selector change
alone does not update a running container.

The Web handoff records its exact public commit and validates the Flutter shell,
bootstrap, favicon, version marker, and hosted readability. Updates releases
publish both attested Stable Appcast and manifest files; installer releases
publish both canonical source files. For each updates or downloads candidate,
the root-owned controller first reverifies and copies the preceding immutable
static release so `index.html` and `favicon.svg` remain present, then overlays
exactly the two allowlisted release-owned files. The workflow cannot request any
other overlay path. The controller manifests and reverifies the complete
candidate before atomic publication. Any public mismatch restores the preceding
selector, refreshes only the affected static container, and verifies all prior
release-owned bytes against hashes read through a filename allowlist. Rollback
never rebuilds or mutates a published release, and the public workflow receives
neither Docker access, filesystem traversal, an interactive shell, nor general
host authority.

Web assets use content-hashed Flutter output plus a small no-cache
`version.json`. The server must route unknown application paths to
`index.html`, serve immutable hashed assets with long-lived caching, and serve
the shell, version marker, and Appcast without stale caching.

## Readiness and live handoff

Local verification proves the release contract, manifest/checksum generation,
macOS universal packaging and Developer ID signatures, iOS signed export,
Sparkle signatures, Web packaging, analyzers, and updater tests.

Production rehearsal run `31346940281` completed the reusable Stable asset
handoff from `v1.0.1` release run `31296207510`. Web, Appcast, Stable manifest,
and both installer sources matched their immutable source identities; clean
Flutter rendering and all three environment regressions passed. The same
workflow is called automatically after every future approved Stable publication.

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
