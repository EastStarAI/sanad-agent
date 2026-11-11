---
title: "Release, Signing, and Deployment Architecture"
description: "The stable release pipeline, protected signing boundaries, artifact publication, and live-release handoff."
---

# Release, Signing, and Deployment Architecture

## Release boundary

The public `EastStarAI/sanad-agent` repository owns CI, artifact construction,
signing orchestration, the release manifest, update-feed generation, and the
canonical installer sources. The current patch release uses marketing version `1.0.24` and build number `25` for both Sanad Agent and Sanad Client. RC tags use `v1.0.24-rc.N`; Stable uses `v1.0.24`. The unpublished `v1.0.3` candidate tag is retained as failed provenance after its Windows smoke gate rejected a PowerShell reserved-variable collision; it owns no GitHub Release or Production asset. Each later candidate records its increasing build number in the checked-in contract.

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
pull request can pass CI. The artifact filenames it owns include the
`agent-runtime` archives (`sanad-agent-runtime-<version>-<platform>-<arch>.tar.gz`),
which are published by the native-runtime workflow rather than the Agent
installer: they are renamed with every other versioned artifact, and a stale
literal is rejected by name instead of surfacing later as a duplicate-filename
contract error. Release prose remains derived from merged Git history
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

### The tag run publishes the validated candidate

A release is not built twice. The tag run's `candidate` job looks for the newest
`workflow_dispatch` run of `release.yml` on `main` for the tag's exact commit and
proves, before using anything from it, that the run built this commit on `main`
with this workflow file, that `validate`, every `agent` lane, every `client-*`
lane and `assemble` succeeded in its latest attempt, that exactly one
`<channel>-release-candidate` artifact appears in a bounded one-page response and
is unexpired with more than an hour left, and that the downloaded bytes still
match the manifest, the release contract at
this commit, `SHA256SUMS` and one attestation per attested subject that names
that run, that workflow, `refs/heads/main` and this commit on a GitHub-hosted
runner. The file-set proof also requires the SBOM, every private contract
artifact, exactly the sidecars declared by the manifest, and exactly the native
staging tree declared by its per-target descriptors; hidden entries, missing
entries, symlinks, special files, and any extra file or directory are refused.
It then re-uploads the verified bytes into the tag run under the same
artifact name, so the Draft, the Client-alias job and the Production deployment
read one artifact from `github.run_id` exactly as before.

The rollout switch is the repository variable `RELEASE_CANDIDATE_PROMOTION`:
`enabled` promotes, `shadow` runs every check and reports `would-promote` in the
job summary but always rebuilds, and unset or any other value skips selection
entirely. Any failure — an unreadable API, candidate-job infrastructure, a
missing or expired artifact, a mismatched manifest, a changed byte, a failed
attestation, or a defect in `scripts/release/promote_release_candidate.sh` —
leaves the tag run on its ordinary rebuild path. Promotion alone requires the
candidate job to succeed; rebuild assembly instead requires every producing
Agent and Client job explicitly, so selector failure cannot suppress the normal
release. Deleting the variable is the instant rollback and needs
no pull request. Because the credential scan, the tag-equals-commit check, the
macOS full-suite gate, `--verify-tag`, the single `release-publication` approval,
the alias verification and every `deploy.yml` check still run, promotion removes
a duplicate build rather than a gate.

## Platform-stable release surface gates

The Agent job validates the same release surface on macOS, Linux, and Windows,
so every gate has to mean the same thing on all three.

### Release test scope

A release run proves the complete agent suite on **Linux only** (x64 and arm64),
and the platform-sensitive **macOS subset** plus the CWD-sensitive suites on both
macOS architectures. `scripts/ci/list_test_shard.sh --platform-macos` is the one
declaration of that subset; it covers the real Keychain and file credential
stores, launchd service management, POSIX permissions and atomic rollback, file
locks and Home ownership, native dictation, build-tool paths, and the process and
filesystem owners that use POSIX-only primitives. The Windows lane runs no Agent
suite; it runs the one release-contract test its packaging needs.

The rest of the suite is not unproven, it is proven elsewhere: Public CI runs all
381 agent test files on four Ubuntu shards for every pull request and merge, and
`.github/workflows/macos-full-suite.yml` runs the same complete suite on
`macos-26` and `macos-15-intel` on every push to `main`. That workflow is
deliberately not a required check — it reports on the merge commit and is fixed
forward — so a red `macOS full suite` run blocks the next release even though it
does not block a merge. `docs/operations/continuous_integration.md` owns the
split and the reasons behind it.

Two consequences are worth stating explicitly, because they are easy to get
wrong:

- "The release is green" is never evidence that the whole macOS suite is green.
  Only the subset ran there.
- A macOS-only regression must be caught by the post-merge workflow before a
  release tag is cut. The release workflow enforces exactly that, rather than
  relying on the operator to check it.

### Release gate on the macOS full suite

`validate` refuses to let a release proceed unless `.github/workflows/macos-full-suite.yml`
has a **successful run on the exact commit** being released. The check queries
the Actions API by `head_sha`, so a green suite on a nearby commit, on `main`
after a later merge, or on the candidate's own release lanes is not accepted as
evidence for this commit.

The gate runs in `validate`, which `draft`, `publish`, `client-download-aliases`,
and `production-assets` all depend on, so a failure stops the release before any
artifact is built. It refuses on every state that is not proof:

| Observed state | Tagged / publishing run | `validation_only` run |
| --- | --- | --- |
| Successful run on this commit | passes | passes |
| No run for this commit | **fails** | warning only |
| Run still queued or in progress | **fails** | warning only |
| Run concluded `failure`, `cancelled`, or `timed_out` | **fails** | warning only |
| Actions API unreadable, or a reply that is not a run list | **fails** | warning only |

Two details matter for reading the failure:

- **A cancelled newer run does not un-prove the commit.** `macos-full-suite.yml`
  cancels a superseded `main` run, so the newest run for a commit can be
  `cancelled` while an earlier run on the same commit succeeded. Any successful
  run on that commit is accepted; the failure message names the newest run so the
  operator can see what happened.
- **"Still running" is a refusal, not a wait.** The gate does not poll, because a
  release candidate's macOS jobs compete with that suite for the same five-job
  account cap. Wait for the suite to finish, then re-run the workflow: the same
  refusal is what keeps a candidate from being dispatched on top of a running
  suite.
- **No surviving run on the commit.** When every run on the release commit was
  cancelled because `main` moved on, dispatch the suite on a ref whose head is
  exactly that commit (the release tag itself, `gh workflow run
  macos-full-suite.yml --ref <tag>`); its concurrency group is per ref, so later
  `main` pushes do not cancel it. Then re-run the release workflow.

`validation_only` dispatches publish nothing and are the normal way to build the
matrix before a tag exists, so for them the same evidence is reported as a
warning. Publication from a dispatch (`request_publication`) and any tagged run
are the two paths the gate enforces.

### Release run concurrency

A release run is cancellable only when it cannot publish anything.

| Run | Concurrency group | Cancellable |
| --- | --- | --- |
| Tagged run (`push` of `v*`) | `protected-<ref name>` | never while running; a pending one only by a newer protected run on the same ref |
| Dispatch with `request_publication` | `protected-<ref name>` | never while running; a pending one only by a newer protected run on the same ref |
| Dispatch with `validation_only` | `validation-<ref>` | superseded by a newer one |

The two conditions are the same three-part test, so a run that can reach
`publish` can never land in the cancellable group: it must be a
`workflow_dispatch`, with `validation_only` true and `request_publication` not
true. A contradictory dispatch (`validation_only` with `request_publication`)
stays in the protected group and then fails at `validate`, where that combination
is already rejected.

The separation matters because a validation dispatch and a publishable run can
share a ref: before this split both were `release-candidate-<ref>` with
`cancel-in-progress: false`, so a validation dispatch queued behind a running
publishable run, and a fresh validation dispatch replaced any publishable run
still *pending* in that group. Publishing runs are now serialized only against
each other: a newer one waits for the older one and supersedes only a *pending*
run, never a running one, and a validation dispatch can no longer touch either.

The suite a release lane *does* run must stay priced: a fixed per-case
`dart run` compilation is the largest avoidable cost on the slowest runner, so
real-CLI tests spawn one compiled kernel artifact per suite
(`agent/test/support/compiled_agent_cli.dart`), and a cross-process wait is a
state observation with a measured deadline rather than a short fixed timer.

Linux arm64 is a supported Agent target and uses the GitHub-hosted
`ubuntu-24.04-arm` runner with the same steps, `release-build` Environment, and
trust policy as Linux x64: both carry SHA-256 plus GitHub attestation and no
platform code signature. `requiredAgentReleaseTargets` in
`release/contract/lib/release_contract.dart` is the single declaration of that
matrix; `validate-contract` and `check-preparation` fail when a contract omits a
declared target, and the release-security CI job fails when the release matrix
and that list disagree. Adding an architecture therefore means adding the
contract row and the release job together. The public installer resolves the
Agent by platform plus architecture only, so it reports the requested target
instead of substituting a different architecture's binary.

The pinned Flutter SDK publishes no Linux arm64 archive, so the arm64 job cannot
use the FVM-managed Flutter SDK that every other Agent job installs. The Agent
build needs the Dart AOT compiler only, so that job installs the standalone Dart
SDK through `.github/actions/setup-dart`: the version comes from
`scripts/ci/dart_sdk_version.txt`, the archive is the publisher's
`dartsdk-linux-arm64-release.zip` verified against the checksum pinned in that
action, and the action fails unless `dart --version` reports the pin. The pin and
the Dart SDK bundled with `.fvmrc`'s Flutter must match, and
`agent/test/guards/dart_sdk_pin_test.dart` fails on the ordinary lanes as soon as
they diverge. No lane may install an unpinned or architecture-mismatched SDK.

That lane produces the whole Agent payload, not just the executable: it builds
and verifies the whisper runtime with its own Dart, stages it into the same
`dist/`, archives `sanad-agent-runtime-<release>-linux-arm64.tar.gz`, and loads
the packaged library in a real process before the artifact is uploaded. Every
runtime step in that job therefore selects the executable through the job's
`DART` variable instead of naming `fvm dart`, and the whisper build cache is
keyed by the runner label so an arm64 slice is never restored from an x64 build.
The contract row for that archive is `linux`/`arm64`, and
`agent/test/tool/native_runtime_package_contract_test.dart` fails when a
published Agent target has no matching `agent-runtime` row.

The official Agent target list is a build-matrix statement, not a statement
about packaging. A Linux arm64 **Client** package (`.deb` and portable `tar.gz`)
remains a separate follow-up: it needs an arm64 Linux build gate, an arm64
`flutter build linux` verification, and its own manifest and alias handling,
and it cannot reuse this Dart-only path because the Flutter SDK itself has no
Linux arm64 distribution.

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
| Agent | Linux arm64 | GitHub Release | SHA-256 plus GitHub attestation |
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

### Verifying a published asset

Published assets carry the Sigstore attestation of the run that built them. When
the release was promoted on tag, that run is the `workflow_dispatch` validation
run on `main`, not the tag run: promotion publishes the proved bytes rather than
rebuilding them, so the provenance names `refs/heads/main` together with the
commit the tag points at. Both cases verify with the same command, and the commit
is always the tag's commit:

```bash
gh attestation verify <file> \
  --repo EastStarAI/sanad-agent \
  --signer-workflow EastStarAI/sanad-agent/.github/workflows/release.yml \
  --source-digest <tag commit>
```

`SHA256SUMS`, the manifest and the Appcast are attested the same way. A
non-reproducible artifact (the macOS and Windows Agents, the DMG, the Windows
exe, the APK) has one attestation per releasing run, so a file that was built and
published twice keeps the earlier attestation only when its bytes were
identical. The tag-run promotion path never adds a second, unproved build to
these assets.

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
- A daemon never reaches it either. `SecretVaultPolicy.daemonEntryDecision` is
  `forbidden` (`daemon_background`), so a daemon either opens its vault without a
  dialog or reports it closed; the one interactive path is `sanad vault authorize`,
  which a person runs in a terminal and which prints no value. A daemon also starts
  its vault without waiting for the store (`SecretVaults.beginOpen()`), so an
  authorization requirement cannot delay its listener or `/health`.
- A source checkout still reads the same `ai.eaststar.sanad.agent` service and the
  same per-Home account as the packaged Agent, so the two identities compete for
  one item. Separating them by runtime kind is the follow-up tracked in
  `docs/plans/tasks/151-vault-startup-and-runtime-isolation.md`; until it lands, a
  development runtime is expected to report `authorization_denied` instead of
  prompting.

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

### iOS Universal Link entitlement

The installed iOS app can only claim `applinks:app.sanad.eaststarai.com` (and the
Development/Staging hosts) when two independent conditions both hold:

1. The **archive is signed**. Exporting an unsigned `--no-codesign` archive with
   a separate `xcodebuild -exportArchive` re-signs the app from the profile alone
   and drops its own `CODE_SIGN_ENTITLEMENTS`, so
   `com.apple.developer.associated-domains` disappears from the IPA even when the
   profile grants it.
2. The **distribution profile grants the capability**. Provisioning profiles
   snapshot App ID capabilities at creation time, and signing is manual with the
   profile named in `client/release/ios/ExportOptions.plist`.

When either is missing, iOS keeps the authentication return in Safari, the
Public edge answers `303 /oauth/ios/callback-failed`, and login fails with
"Authentication return failed" even though the portal, PKCE, and callback code
are correct.

`client/release/ios/build_signed_ipa.sh` is the single owner of the iOS binary:
both the private release `client-ios` job and `Internal TestFlight` call it, and
neither workflow builds or exports an IPA itself. It generates the Flutter
artifacts with `--no-codesign`, then archives through `xcodebuild archive` with
`CODE_SIGN_STYLE=Manual` and the profile named in the export options, because a
hosted runner has no Apple ID account for automatic signing, and an unsigned
archive loses the app entitlements on export. It then exports with
`-exportOptionsPlist` and fails the job unless the exported app claims every host
listed in `client/ios/Runner/Runner.entitlements`, its embedded profile grants the
capability, and that profile is the one the export options name. It reads the
profile name from the export options, so the reviewed profile has a single
declaration. Enable the capability on `UC2824B99G.com.eaststarai.sanad`,
regenerate the `Sanad App Store` profile, and update
`IOS_APP_STORE_PROFILE_BASE64` before the next upload.

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

The candidate workflow creates a private Draft and fails if the tag already owns any Draft or published Release. On a tag whose commit already carries a proved `workflow_dispatch` candidate, the Draft is built from that candidate's exact bytes (see [The tag run publishes the validated candidate](#the-tag-run-publishes-the-validated-candidate)); otherwise the tag run builds them itself. A separate least-privilege publication job can make that reviewed Draft public only after the required owner approval on `release-publication`. Rejected or cancelled approval leaves no partial public Release. Public release files use published checksums. After an approved Stable publication, the protected Client-download job downloads the public manifest, checksum file, and three desktop Client artifacts; verifies canonical URLs, byte sizes, SHA-256 values, and GitHub attestations; generates a deterministic Nginx redirect include; and uploads only that bounded include through the Production forced-command deployment broker. The broker verifies the exact byte count and digest, and the root-owned controller invokes the fixed alias validator with the verified payload. The Stable release then calls the reusable Production asset workflow with Web, Appcast, and installers enabled and its own release run ID. This ordering serializes the redirect deployment before the remaining Production assets and prevents an asset handoff when publication or redirect verification fails. RC and validation-only runs never enter either Production path. The server remains a redirector rather than an artifact mirror and owns candidate validation, atomic activation, public regression verification, and automatic rollback.

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

## Release announcement handoff

`discord-notifications.yml` publishes the Discord release announcement, and it
never announces a Release before Production. A GitHub Release is published with
the repository `GITHUB_TOKEN`, and GitHub starts no workflow from an event that
token produced, so the previous `release: published` subscription announced
nothing after `v1.0.0-rc.1`.

The workflow therefore follows the completing `Prepare stable release` run
(`workflow_run`, `completed`) on the default branch instead of a Release event,
and it sends an announcement only when every condition below holds:

- the release run concluded `success`;
- that same run published a Stable Release: the newest Release that is neither a
  Draft nor a pre-release, whose tag matches `vX.Y.Z`, whose tag commit equals
  the run's commit, and whose `published_at` falls inside the run's lifetime;
- the reusable Production deployment of that run reported `success` for all
  three serialized asset jobs, `Deploy Stable Production assets / updates`,
  `/ web`, and `/ installers`.

An RC candidate, a validation-only dispatch, a rejected publication approval, a
failed release run, and a Production asset failure therefore never announce. A
Production failure is recovered by re-running the failed jobs of the same
release run, and the announcement then fires once, for the successful attempt.

Announcements are idempotent per tag. After a successful send the workflow
stores a `discord-announcement-<tag>` ledger artifact, and any later re-run of
the release workflow or of the announcement workflow skips a tag that already
owns a live ledger entry. The ledger is retained for 90 days, so a manual re-run
of the same successful release run after that window is the only path that could
repeat a notification.

The notification contract itself is unchanged: one embed, mentions suppressed,
`DISCORD_WEBHOOK_URL` read only by the final send step, and no protected
environment, signing credential, or deployment authority. The completing-run
checks add only `actions: read` to the existing `contents: read` and
`pull-requests: read` scopes.

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
