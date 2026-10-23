---
title: "Release, Signing, and Deployment Architecture"
description: "The stable release pipeline, protected signing boundaries, artifact publication, and live-release handoff."
---

# Release, Signing, and Deployment Architecture

## Release boundary

The public `EastStarAI/sanad-agent` repository owns CI, artifact construction,
signing orchestration, the release manifest, update-feed generation, and the
canonical installer sources. The current patch release uses marketing version `1.0.20` and build number `21` for both Sanad Agent and Sanad Client. RC tags use `v1.0.20-rc.N`; Stable uses `v1.0.20`. The unpublished `v1.0.3` candidate tag is retained as failed provenance after its Windows smoke gate rejected a PowerShell reserved-variable collision; it owns no GitHub Release or Production asset. Each later candidate records its increasing build number in the checked-in contract.

Pull-request CI is read-only and never receives signing or deployment credentials. A protected validation-only dispatch from `main` can build the complete signed Agent/Client matrix, including a private IPA, as retained private artifacts without a tag, Draft, Release, TestFlight upload, or deployment. Signing jobs use protected GitHub Environments. Assembly remains contents-read; only the separate Draft and publication jobs receive contents-write.

## Automated release preparation

Future releases use the release-delivery reference loaded on demand by the
repository `Sanad Pull Request Lifecycle` skill and the FVM-managed
`agent/tool/release_tool.dart prepare-release` command. The command
accepts one increasing Stable semantic version and build number, validates every
source surface before writing, and updates Agent/Client package metadata, the
`sanad-client` CLI version literal, release-contract package lock entries, native
Windows version resources, the canonical contract/tag/artifact filenames,
release-note identity, changelog slot, and this current-release statement.
`check-preparation` then rejects stale or unfinished release identity before a
pull request can pass CI. Release prose remains derived from merged Git history
by the skill rather than invented by the mechanical command.

A release-preparation pull request may pass without `release-reviewed` only when
`scripts/release/verify_metadata_release_diff.sh` proves the diff is exactly the
12 established metadata/prose files and every changed mechanical line is a
version, build, tag, or canonical artifact-filename substitution. The twelfth
path, `client/lib/features/client_cli/domain/models/client_cli_version.dart`,
is accepted only when the sole changed line is
`const String sanadClientCliVersion = '<X.Y.Z>';`; any other change to that file
stays a source change that needs protected review. The normal protected review
remains fail-closed for any workflow, signing, deployment,
script, installer-logic, task-plan, unrelated-file, or unexpected-line change.
This narrow exception permits the explicitly requested release-delivery
extension to prepare, push, and squash-merge the metadata PR without introducing
an early publication decision. It grants no Environment, secret, tag rewrite, or publication access.

After merge, the skill creates the immutable tag only on the verified public
`main` commit, requires PR #129 merge commit
`872a5b75aec8303bf59ea39e25826d017d0ad714` and every selected merged change to
be ancestors, and identifies the release workflow by both tag and source SHA.
It uses bounded polling and stops on any failed or ambiguous prerequisite. The
one final human decision is requested only when the complete signed candidate,
metadata, attestations, and private Draft have succeeded and the sole pending
protected deployment is `release-publication`.

## Platform-stable release surface gates

The Agent job validates the same release surface on macOS, Linux, and Windows,
so every gate has to mean the same thing on all three.

Generated sources are compared and hashed as canonical LF text.
`agent/tool/generate_bundled_skills.dart` and
`agent/tool/generate_model_capability_defaults.dart` compare the rendered output
with the on-disk file after collapsing `CRLF` to `LF`, hash and embed bundled
skill content in that canonical form, and validate every manifest path in the
POSIX context before joining it with the platform separator. `.gitattributes`
pins `eol=lf` for `agent/bundled_skills.json`,
`agent/model_capability_defaults.yaml`, the two generated Dart outputs, and
`.agents/skills/**`, because Git for Windows checks text files out with `CRLF`
by default. Without that pin a clean Windows checkout was reported as stale
output, a clean LF-only manifest entry was rejected as `Unsafe skill source`
once the platform path context rewrote its separators, and a Windows build would
have embedded `CRLF` skill bytes that the committed hashes never described.

The embedded-skill smoke proves that the compiled artifact extracts its bundled
skills into a throwaway `SANAD_HOME` without a daemon, network, or sidecar
assets. `version` and the other `SanadCommandRunner.isPureQuery` queries answer
before Home preparation, so they cannot provide that evidence. The smoke first
asserts that the pure query creates no Home, then runs the read-only non-pure
`skills list --json`, which performs Home bootstrap and the bundled-skill
reconcile, and finally requires the main file from every skill, one nested
reference, and each license.

Every `pwsh` step that runs native commands sets
`$ErrorActionPreference = 'Stop'` together with
`$PSNativeCommandUseErrorActionPreference = $true`, or checks `$LASTEXITCODE`
explicitly. PowerShell does not stop on a non-zero native exit by default, so
the Windows release surface step previously continued past both failing
generator checks and was reported only by its final command. The Windows
running-client upgrade guard remains the deliberate exception: that script
asserts specific native calls are rejected and throws on every unexpected
result, so it keeps its own exit-code handling.

## Artifact channels

| Component | Target | Public channel | Authenticity boundary |
|---|---|---|---|
| Agent | macOS arm64/x64 | GitHub Release | Developer ID, notarization, and GitHub attestation |
| Agent | Linux x64 | GitHub Release | SHA-256 plus GitHub attestation |
| Agent | Windows x64 | GitHub Release | Temporarily unsigned Windows build for every release; canonical manifest/URL/size/SHA-256 and protected GitHub provenance |
| Client | macOS universal | GitHub Release | Developer ID, notarization, Sparkle EdDSA |
| Client | Linux x64 `.deb` and portable `tar.gz` | GitHub Release | SHA-256 plus GitHub attestation |
| Client | Windows x64 | GitHub Release | Temporarily unsigned Windows build for every release; WinSparkle DSA plus canonical manifest/URL/size/SHA-256 and protected GitHub provenance |
| Client | Android universal APK | GitHub Release | Android release signature; not a supported user install channel |
| Client | Android AAB | Google Play (`com.eaststarai.sanad`) | Android upload signature plus Play App Signing |
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
for the exact raw CLI. Runtime installers instead require the canonical size and
SHA-256 plus a valid Apple-anchored Developer ID signature with exact Team ID
`UC2824B99G` and publisher name. They do not repeat the nondeterministic ticket
lookup. A runtime rejection reports a typed, sanitized stage such as
`publisher_requirement`; Agents before v1.0.6 still performed the `=notarized`
lookup during `sanad update` and recover through the official installer, as
described in [Release and Update Architecture](../technical/update_architecture.md#legacy-agent-recovery). `spctl --type execute` is not used because it rejects valid notarized
non-bundle executables.

The hosted macOS Client job restores the exported Sparkle Ed25519 key to a
runner-temporary file and passes that file directly to Sparkle `sign_update`.
It does not import the key through `generate_keys` or depend on interactive
Keychain authorization. Local operator builds may continue using the existing
Keychain when no explicit Sparkle key-file path is supplied. Windows signing
likewise passes `WINSPARKLE_PRIVATE_KEY_PATH` directly to `sign_update`; the DSA
private key is never copied into the Client checkout.

## Stable macOS Agent signing identifier

`codesign` derives the signing identifier from the file name when a call omits
`--identifier`, and the Agent artifact name carries the release version. The
identifier is part of the designated requirement, so every release used to
publish a different requirement. macOS records that requirement as the trusted
code of the Keychain items an application creates, which made each release look
like a different program to the login Keychain: an ACL granted to one version
never covered the next one, and an Agent without a user present could block on a
prompt nobody could answer.

The workflow therefore defines one workflow-level
`SANAD_AGENT_CODESIGN_IDENTIFIER` (`com.eaststarai.sanad.agent`) and passes it to
the macOS Agent `codesign` call. The value contains neither the release version
nor the architecture, because both change per artifact while the identifier must
not. After signing, the workflow fails unless `codesign -d --verbose=2` reports
exactly that `Identifier` and `codesign -d -r-` reports a designated requirement
that names the same identifier and the `UC2824B99G` team OU. The
`release-security` CI job additionally guards the env definition, the
`--identifier` argument, and the requirement assertion as static checks that run
on pull requests, so a future edit cannot silently drop them.

The signed Client `.app`, its nested frameworks, helpers, and bundles, and the
signed disk image stay unchanged. A bundle takes its identifier from its own
bundle identifier, and a bare helper executable inside one keeps the stable file
name its bundle layout gives it; neither carries a release version. A disk image
is not an executable whose requirement can become a Keychain ACL entry. Those are
the only other macOS `codesign` calls in the release surface, so no version-named
standalone executable is signed anywhere else.

### Upgrade behaviour

- Keychain items created by v1.0.18 and v1.0.19 carry authorized-application ACL
  entries for those binaries' exact requirements, which contain
  `identifier "sanad-agent-<version>-macos-<arch>"`.
- The first release with the stable identifier can therefore still prompt once
  for such an item. Choosing **Always Allow** adds the new, now
  version-independent requirement to that item, so every later release with the
  same identifier and team is already authorized for it. Users on the x64 and
  arm64 builds share that outcome, because the identifier does not encode the
  architecture.
- A fresh installation creates its items with the stable requirement directly
  and never prompts.
- `MacOsKeychainAgentSecretStore.write` in `agent/lib/core/auth/agent_secret_store.dart`
  performs `SecItemAdd` with only the item class, the service
  `ai.eaststar.sanad.agent`, the account `<scope>:<key>`, the value, and
  `kSecAttrAccessibleAfterFirstUnlock`. It sets no `kSecAttrAccess` ACL and no
  `kSecAttrAccessGroup`, so macOS defaults the item's authorized applications to
  the creating application, matched by its designated requirement. A later
  `SecItemUpdate` rewrites only the value and leaves that ACL untouched, which is
  why an existing item keeps its old requirement until the new binary is
  authorized once.
- Commands that never open the vault never reach this prompt; the prompt can only
  appear on an actual secret read or write.

### Installer and runtime verification

`scripts/install.sh` and the runtime updater keep verifying the Apple-anchored
NanoSoft publisher requirement — team `UC2824B99G` and the exact
`Developer ID Application: NanoSoft LY LLC` common name — instead of pinning the
identifier. `install.sh` resolves its manifest from `SANAD_RELEASE_MANIFEST_URL`
and validates whatever version that manifest declares, so it must still accept an
older artifact that was signed before the stable identifier existed; pinning the
identifier would reject exactly those installer runs. The identifier is also not
a trust boundary: any signer can assert any identifier, while the Apple anchor,
team, and publisher name decide who is allowed to sign. Release CI pins the
identifier so the ACL continuity above holds; installation and update keep
proving the publisher.

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

## Google Play publisher

Android is published only through Google Play under the package identity
`com.eaststarai.sanad`. The store display name is `Sanad Remote` because the
shorter product names were unavailable; the installed product is still Sanad
Client.

- **Signing boundary:** Play App Signing is enabled, so Google owns the app
  signing key and every upload must be signed by the registered upload
  certificate. The release keystore remains the upload key; it must keep
  matching the certificate enrolled in Play Console.
- **App Links:** Production `assetlinks.json` must list the Play app-signing
  certificate fingerprints together with the upload certificate fingerprint.
  Dropping either set silently breaks the OAuth callback association.
- **Version identity:** `versionCode` must strictly increase per upload and is
  never reused. A rejected or superseded upload still consumes its
  `versionCode`, so the pubspec build number always moves forward.
- **Promotion:** internal test track first, then closed testing, then the
  production track with a staged rollout. Each promotion to production requires
  explicit owner approval; no workflow may promote to production on its own.
- **Publication scope:** the AAB is a build output and handoff artifact only. It
  is not attached to public releases and is not a user install source.
- **Automation:** uploading from CI is permitted only as an approval-gated job
  that enters a protected Environment holding the Play service-account
  credential. Automatic production publishing is not part of the release
  contract.

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

### Asset deployment serialization and health sweep resilience

In release v1.0.20 (run `39881789408`), the three Production asset deployment jobs
(`web`, `updates`, and `installers`) ran in parallel on the same Production host.
Workflow-level `concurrency: production-assets` serializes separate workflow
runs against the host, but jobs within a single run ran concurrently. When
`installers` finished promoting its source files, its post-promotion health sweep
checked every Production service. At that exact instant, the parallel `updates`
job was recreating its Docker container, causing a transient connection refusal
on loopback port 8299 (`curl: (7) Failed to connect to 127.0.0.1 port 8299`).
`installers` treated this transient refusal as an immediate verification failure
and executed an automated rollback, even though `updates` became healthy 10
seconds later.

To eliminate cross-job interference while maintaining strict safety boundaries:

1. **Deterministic job serialization:** In `.github/workflows/deploy.yml`, the
   jobs are strictly serialized in the deterministic order:
   `updates` → `web` → `installers`.
2. **Explicit skip and failure propagation:** Jobs must still execute when an
   upstream job is intentionally skipped (for example when `deploy_updates` is
   false), but any job failure must stop all subsequent jobs immediately. This
   is enforced using explicit `needs:` dependencies and fail-closed conditionals:
   - `web`: `needs: updates` with
     `if: always() && inputs.deploy_web == true && (needs.updates.result == 'success' || needs.updates.result == 'skipped')`
   - `installers`: `needs: [updates, web]` with
     `if: always() && inputs.deploy_installers == true && (needs.updates.result == 'success' || needs.updates.result == 'skipped') && (needs.web.result == 'success' || needs.web.result == 'skipped')`
3. **Bounded fail-closed verification sweeps:** Both activation verification
   and rollback verification across all three surfaces (`updates`, `web`, and
   `installers`) use bounded retry loops: up to 12 attempts with a 5-second sleep
   between attempts (a 60-second total deadline per checked endpoint). A single
   transient connection refusal or container restart blip will not trigger an
   immediate rollback. If an endpoint fails to return the expected status or bytes
   within the 60-second deadline, the sweep fails closed and initiates rollback.
   The job's own release surface verification (exact payload bytes, SHA-256
   digests, version markers) is strictly verified and never relaxed.

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
