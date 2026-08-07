---
title: "Release and Update Architecture"
description: "The shared release manifest and the update ownership of the Sanad agent and client on every runtime."
---

# Release and Update Architecture

## Shared release contract

`release/release-contract.json` defines the release identity, repository,
canonical artifact names, supported platform/architecture pairs, and exact
signature metadata. `release/contract/` parses both that contract and generated
manifests. A manifest is accepted only when its schema, repository, tag,
channel, version, commit, canonical URL, positive size, SHA-256, and exact
component/platform signature type are valid.

`ReleaseArtifactTrustPolicy` is the shared metadata authority used by manifest
validation, Client bootstrap, and Agent update. Unknown or empty signature
metadata fails closed. Runtime checksum verification is distinct from protected
release-pipeline provenance verification: a runtime never claims to validate a
GitHub attestation locally.

## Trust by platform

| Component/platform | Required manifest trust metadata | Runtime proof |
|---|---|---|
| Agent macOS | `developer-id+notarization+github-attestation` | canonical URL, size, SHA-256, Developer ID identity, and the raw-CLI `codesign --test-requirement '=notarized'` ticket check |
| Agent Windows | `unsigned+github-attestation` | canonical URL, size, and SHA-256; provenance is proved by protected release CI |
| Agent Linux | `github-attestation` | canonical URL, size, and SHA-256 |
| Client macOS | `developer-id+notarization+sparkle-ed25519` | Sparkle EdDSA plus Apple package trust |
| Client Windows | `unsigned+winsparkle-dsa` | WinSparkle DSA plus manifest/checksum/provenance release gates |
| Client Linux | `github-attestation` | manual discovery of a canonical release artifact |

Windows remains intentionally unsigned for every release until an explicit
signed-only migration changes this centralized policy. Signed and unsigned
Windows types are not accepted together. Acquiring Authenticode requires a
separate policy transition that rejects unsigned artifacts for subsequent
releases.

## Exact Client–Agent pairing

Packaged Desktop releases pair Client and Agent with one exact release version.
The Client sends `target_version` to the authenticated local `/update` endpoint.
Both bootstrap and Agent update reject a latest manifest whose version differs
from that target before downloading an artifact. An older Agent may move only
to the exact target. A newer Agent is never downgraded automatically.

A successful lifecycle result means authenticated health reports the target
version and the local WebSocket reaches ready. Download, staging, replacement,
or restart request alone are not success. Typed failures distinguish network,
manifest, target, trust, checksum, replacement/rollback, service registration,
start, health, version, authentication, and socket stages.

## First install and retry

`VerifiedAgentBootstrapInstaller` is used only when the packaged Desktop Client
cannot reach an installed Agent. It validates the exact manifest and artifact,
stages beside the target, preserves the previous executable, performs an atomic
move, and restores the previous executable when replacement fails.
`StandaloneDaemonController` then registers the platform service idempotently,
starts it, and polls authenticated health with bounded backoff.

The connection coordinator proves the authenticated local socket after health.
A failed socket attempt is not cached permanently; a later retry creates a new
attempt without deleting Sanad Home, identity, provider configuration, or a
previous valid executable.

## Installed Agent update

`AgentUpdateService` is the sole native replacement owner. Source/FVM runtimes
return `source_managed` and never mutate Git. Standalone runtimes select and
verify the exact target artifact under an exclusive update lock.

On macOS and Linux, replacement is atomic and preserves a rollback executable;
replacement failure restores it before reporting failure. If macOS restart does
not return target-version health, the Client restores the backup and starts the
previous Agent before returning `rollback_completed`. launchd/systemd owns
restart after the daemon returns the typed response. A bounded
`SANAD_SERVICE_INSTANCE` suffix exists for isolated real-machine lifecycle tests
so their launchd/systemd registration cannot replace the user's service.

The macOS Dart AOT executable is signed with Hardened Runtime and only
`com.apple.security.cs.allow-unsigned-executable-memory`, which Dart requires
for runtime stubs. The release workflow supplies the contract version through
`SANAD_AGENT_VERSION`; compiled releases do not retain a hardcoded `1.0.0`
identity. On Windows, verified bytes
are staged for a detached adapter. The daemon stops only after scheduling is
accepted. Native Scheduled Task, PowerShell replacement, and rollback/start
evidence remain Task 67B work and must not be inferred from shared tests.

## Client self-update

Packaged macOS and Windows clients initialize only the Stable Appcast and issue
one non-blocking startup check. Feed failure never blocks application startup,
and concurrent manual checks reuse one in-flight operation. Source clients do
not initialize packaged update machinery. macOS retains Sparkle's native quit,
installation, Developer ID, notarization, and EdDSA handoff. WinSparkle's native
quit/install handoff remains a Windows Task 67B gate.

Linux has no background poll, download, package replacement, privilege request,
or rollback claim. **Settings → General → Check for Updates** performs a
user-initiated manifest check. Only a newer canonical Linux x64 Client artifact
is opened in the external browser; up-to-date and discovery failures remain
non-blocking.

## Publication boundary

Stable uses `release-manifest.json` and `appcast.xml`; RC uses isolated RC
surfaces. Stable clients cannot discover RC artifacts. Generated manifests,
checksums, SBOMs, attestations, and Appcasts are release outputs, not tracked
source. No Task 67A verification publishes a tag, Release, Appcast, or artifact.
