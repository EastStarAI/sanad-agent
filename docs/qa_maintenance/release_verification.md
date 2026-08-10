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
| Agent macOS arm64/x64 | compilation, version, architecture, Developer ID verification, accepted notary log with exact architecture/`cdhash` ticket match | both hosted runners, clean install, real upgrade and rollback |
| Agent Linux x64 | contract and workflow path | hosted build, provenance, clean install, service/update/rollback |
| Agent Windows x64 | contract and workflow path | Unsigned Windows build disclosure, SHA-256/manifest/provenance, Defender/SmartScreen and lifecycle on Windows 11, service/update/rollback |
| Client macOS universal | universal Mach-O inspection, Developer ID-signed and notarized DMG, staple, Gatekeeper, Sparkle signature | clean update and rollback |
| Client Linux x64 | Web/Linux workflow definition | hosted package, dependency audit, clean install/update/uninstall |
| Client Windows x64 | installer and current fail-closed signing workflow definition | SANAD-12 unsigned-policy workflow adaptation, disclosure, SHA-256/manifest/provenance, Windows 11 clean installer/update/rollback and Defender/SmartScreen |
| Client Android APK/AAB | signed local APK/AAB, package identity and keystore fingerprint | signed hosted build, clean install/upgrade |
| Client iOS | signed IPA export for NanoSoft LY LLC; App Store Connect record and API key ready | Internal TestFlight upload |
| Client Web | analyzer, startup contract test, Production-profile release build, exact source and version markers, Flutter shell/bootstrap/favicon probes, and hosted readability | attested-run/source match, protected immutable deployment, public source probe, automatic selector rollback, cache/SPA checks, and clean-browser visible render with no uncaught startup/CSP/CanvasKit/Wasm error |

Windows 11 evidence follows the dedicated
[Windows Release Clean-Machine Validation](windows_release_clean_machine.md)
procedure. Its harness downloads the private validation-only candidate, pins
its source run and commit, verifies manifest/hash/attestation/Authenticode
state, keeps Defender enabled, and records lifecycle checkpoints without
collecting credentials. Windows 10 was not tested and is explicitly excluded
from the `1.0.0` release gate by owner scope decision; no Windows 10 validation
claim may be inferred from the shared x64 artifacts.

## Protected publication rejection probe

The dedicated `Probe release publication guard` workflow validates the
`release-publication` Environment without creating a tag, Draft, candidate, or
Release. Its preflight job is restricted to `contents: read`, requires an exact
40-character public `main` commit, and records the expected counts of `v1` tags
and Releases. The only dependent job enters `release-publication` with the same
read-only permission and can only compare those counts.

For the rejection case, an owner rejects the pending protected deployment. The
run must end without executing the guarded step, and a separate read-only API
inventory must prove the `v1` tag and Release counts remain unchanged. Approval
of this probe is not approval to publish an RC or Stable Release.

Live probe run `30730348167` pinned public `main` commit `ff22d991` and recorded
zero `v1` tags and zero `v1` Releases before entering the Environment. The
repository owner rejected `release-publication`; the guarded job ended as
rejected without executing its read-only step. A separate post-run API
inventory again found zero `v1` tags and zero `v1` Releases or Drafts. This
closes the rejection/no-partial-publication evidence only; it grants no
approval for RC1 or any later publication.

## Stable Client convenience-link gate

Only an approved, published Stable Release may update the Production convenience links. The post-publication job must reject Drafts, prereleases, non-canonical repositories or URLs, missing or duplicate desktop Client entries, Agent artifacts, and any size, SHA-256, checksum-file, or attestation mismatch. Its generated include contains exactly macOS, Windows, and Linux redirects and is retained as workflow evidence. The restricted server command must pass a loopback candidate before atomic activation, verify Production plus Development and Staging regressions, and restore the preceding include on any reload or verification failure. Development and Staging never expose equivalent aliases, and Client bytes continue to download directly from GitHub Releases.

## Stable Production asset handoff gate

A successful Stable publication must deploy the Client aliases first, then call
the reusable Production asset workflow with all three surfaces enabled, the
canonical Stable tag, and the exact producing release run ID. The called jobs
must enter `client-downloads-production`, consume only its restricted deployment
credentials, and retain read-only contents plus attestation permissions. RC and
validation-only runs must not call the Production asset workflow.

Static verification rejects separate `web-production`, `updates-production`, or
`installers-production` references unless those Environments are deliberately
provisioned and protected in a separate reviewed change. Manual recovery from
`main` remains blocked by the Environment branch policy until an operator
explicitly authorizes that ref; tag-restricted automatic releases require no
such exception. Each selector activation and rollback must invoke the bounded
Production static refresh for exactly one service. Updates and downloads
candidates must inherit the preceding static shell, contain `index.html` and
`favicon.svg`, and replace only their release-owned files before atomic
publication. Runtime acceptance requires the exact public Web commit and version
markers, the public Appcast and Stable manifest SHA-256 values, both public
installer-source SHA-256 values, and a clean browser render. A stale bind mount,
incomplete static root, selector-only success, or HTTP-only shell response fails
the gate. A failed surface must restore and publicly verify all its preceding
release-owned bytes without recreating data or application services.

## Update failure coverage

Automated tests cover contract parsing, invalid tag rejection, deterministic
Appcast output, source-managed no-mutation behavior, checksum rejection, client
bootstrap selection, and existing daemon-controller behavior. The native Windows
replacement gate waits for both terminal result publication and detached-script
cleanup, because PowerShell writes the result immediately before its final
self-removal.

Hosted validation begins with a `validation_only` full-matrix run from protected `main`. It requires no tag and must leave zero Drafts and Releases while retaining private Agent/Client artifacts, the signed IPA, manifest, checksums, SBOM, Appcast, and attestations. Later lifecycle validation additionally exercises interrupted downloads, wrong architecture, corrupted size and checksum, replacement failure, service restart, retained Sanad Home, repeated update requests, and rollback to the prior signed version.

Flutter Web acceptance is runtime evidence, not compilation or HTTP evidence.
The release build must start in a clean browser, create a non-empty Flutter
view, and expose the expected application shell. Any uncaught `dart:io`
platform operation, CSP refusal, CanvasKit/WebAssembly bootstrap failure, or
blank view rejects the candidate even when the build, version marker, health
endpoint, and root document all succeed.

## Task 67A Desktop lifecycle regression matrix

Shared automated coverage must prove exact target matching before download,
rejected downgrade, canonical URL/size/SHA-256, exact signature metadata,
Windows Agent `unsigned+github-attestation`, retained WinSparkle DSA, rejected
empty/unknown/signed-under-unsigned-policy metadata, and unchanged macOS
Developer ID/notarization rejection. Bootstrap preserves an existing executable
on checksum/trust/replacement failure. Agent update keeps an exclusive lock,
reports rollback as failure with a restored runtime, and never treats staging as
final health success.

Client tests prove one packaged macOS/Windows startup check, no packaged check in
source mode, no Linux background check, canonical newer-artifact browser launch,
up-to-date behavior, and retry after a failed local socket attempt. macOS
real-machine evidence uses a temporary Sanad Home and records Developer ID,
notarization/Gatekeeper, launchd registration/start, authenticated health,
reported version, local WebSocket readiness, exact-target replacement/reconnect,
and retained Home/old executable on a failure. It must not use Production or the
user's normal Sanad Home.

### Task 67A macOS real-machine evidence — 2026-08-07

The macOS 26 arm64 gate used a temporary Sanad Home, scoped launchd label, and
non-production ports. It produced two Developer ID-signed, Apple-notarized,
stapled Client DMGs with build numbers 1 and 2 and a temporary loopback
Appcast. Sparkle discovered build 2 at startup, rejected the first deliberately
stale signature after stapling, then accepted the corrected post-staple EdDSA
signature, downloaded the DMG, replaced build 1, and relaunched build 2.
`codesign --deep --strict` and Gatekeeper accepted the updated app.

The Agent gate exposed and fixed a real signed-runtime failure: Dart AOT was
killed under Hardened Runtime until the narrowly scoped unsigned-executable-
memory entitlement was added. The corrected arm64 Agent executed, Apple
notarization was accepted, and the raw executable satisfied the explicit
`=notarized` code requirement. A real missing-Agent bootstrap downloaded the
exact official `1.0.0` macOS arm64 artifact to a temporary target after size,
SHA-256, Developer ID, and notarization-ticket verification.

The scoped launchd service then proved authenticated health and WebSocket ready,
an older-to-target atomic replacement, target-version health, reconnect, and
retained `auth.json` plus `state.db`. A replacement that could not execute was
observed as unhealthy; restoring the backup and loading launchd restored
`1.0.0` health and authenticated socket readiness. The scoped service, test
Home, ports, local feed, applications, and artifacts were removed afterward.
The normal user service and Sanad Home were never stopped or modified.

Task 67A does **not** close WinSparkle, NSIS, Scheduled Task, detached PowerShell,
Defender, SmartScreen, reboot, or Windows rollback/start evidence. Those remain
Task 67B native gates even when shared tests pass on macOS.

## Installer coverage

The canonical installer sources accept a creation-time pairing token, Portal
sign-in, or local-only installation; they never accept or expose the durable
device credential. Interactive tokenless installs offer sign-in, while
unattended tokenless installs must not block and default to local-only mode.
The installers select the release through the manifest, validate repository
URLs, architecture, size, and SHA-256, preserve Sanad Home, authenticate before
a clean service start, and refresh an existing service after replacement.
Release validation must cover clean pairing, clean Portal sign-in, clean
local-only and unattended installation, pairing-token replay, lost-success
retry, durable reconnect, reinstall, upgrade, failed or cancelled login, failed
verification, interrupted replacement, service refresh, and uninstall on each
supported desktop host.

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

Replacement validation-only run `30728515333` at public `main` commit
`c2bd6b3b` passed the complete Agent and Client matrix, including macOS Client
Developer ID signing, notarization, stapling, Gatekeeper assessment, and direct
Sparkle update signing. Assembly generated and attested the manifest,
checksums, Appcast, SBOM, and candidate assets; all 11 retained artifacts remain
private. The Draft and publication jobs were skipped, and the run left no tag,
Draft, or Release. This closes the hosted full-matrix build probe; clean-machine
installation, update, rollback, Windows Defender/SmartScreen, and Internal
TestFlight upload remain separate live gates.

## 1.0.1 validation race follow-up

Validation-only run `31293235254` at `b70bd25` accepted both macOS Agent
submissions but exposed that the local raw-CLI ticket cache can remain
unavailable despite Apple acceptance. Local macOS 26 arm64 submissions
`c15943cf-f9a1-4955-817b-740f83b026e9` and
`62b83964-8910-4f08-9882-8d5f18e31c5c` reproduced failure through 120 seconds
and ten minutes respectively. The authoritative replacement gate passed only
a notary log with status code zero, no issues, SHA-256 ticket metadata, and an
exact architecture/`cdhash` match to the signed executable.

Follow-up validation run `31294256992` at `81de416` then reached the hosted
Windows compile step and exposed a separate PowerShell continuation failure:
Dart received `compile exe` without its define, entry point, or output and
reported `Missing Dart entry point`. The workflow now uses one explicitly quoted
PowerShell command line and statically rejects the former backtick form. The
complete matrix must be rerun after both follow-up fixes; neither failed run is
release evidence.

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

The Windows workflow and installer produce the approved unsigned `1.0.0`
artifacts without a PFX requirement, retain WinSparkle DSA for client updates,
and require explicit disclosure plus checksum, manifest, SBOM, and provenance
metadata. Hosted build and Windows 11 clean-machine Defender, SmartScreen,
service, reboot, and uninstall evidence passed. Windows 10 remains untested and
is non-gating for `1.0.0`; Internal TestFlight and the later release lifecycle
remain live evidence. Authenticode/SignPath is post-v1 work.
