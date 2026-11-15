# Release contract

`release-contract.json` is the marketing-version, build, channel-file, artifact-name, platform, and signature source of truth. The agent and client pubspec versions, Git tag, build number, workflow outputs, installers, updater, Appcast, checksums, and release documentation must agree with it.

The shared Dart models and validators live beside the data contract in `release/contract/`; there is no separate top-level shared release island.

Manifest parsing is forward-compatible and publication is not. A runtime validates trust metadata only for artifacts whose `component:platform` its build knows, so adding a component or platform never invalidates a manifest for an install that predates it; that install still verifies the artifact it actually downloads, and an artifact with an unknown target is never installed or trusted. Because the runtime tolerance cannot help an install older than the addition, `validate-contract` refuses a declared public target without a policy entry and `generate-manifest`/`verify-manifest` call `requireKnownTrustTargets()`, so a release refuses to publish a target its own build cannot verify. Installs older than a newly introduced target recover through the official installer; see [Release and Update Architecture](../docs/technical/update_architecture.md#forward-compatibility-and-the-publisher-gate).

## Channels

The accepted tags are exactly the stable tag `v<marketing-version>` or an RC tag `v<marketing-version>-rc.<positive-number>`. Stable uses `release-manifest.json` and `appcast.xml`. RC uses the separate `release-manifest-rc.json` and `appcast-rc.xml`; stable clients never consume the RC feed.

A protected `validation_only` dispatch from `main` validates an intended RC or Stable identity and builds the complete Agent and Client matrix—including a private signed IPA—without requiring a tag and without creating any Draft or Release. It produces only retained private workflow artifacts and attestations. A tag or non-validation candidate dispatch additionally requires the tagged commit and creates a GitHub **Draft** only in a separate contents-write job. The build/assembly path remains contents-read. Publication is a separate least-privilege job guarded by the `release-publication` Environment and its required owner approval. Rejection or cancellation leaves only the private Draft.

The workflow refuses any existing Draft or published Release for the tag. Once created, a candidate is not replaced in place. A correction uses a new RC or patch tag and a fresh protected run.

## Outputs

The checked-in contract contains no generated hashes, signatures, timestamps, or credentials. Automation creates the channel-specific manifest, `SHA256SUMS`, SBOM, attestations, and channel-specific Appcast only after every required artifact exists.

Public assets use:

`<component>-<release-version>-<platform>-<architecture>.<extension>`

The official Agent targets are macOS arm64 and x64, Linux x64 and arm64, and
Windows x64. Each target has one contract row and one release job, and
`requiredAgentReleaseTargets` in `release/contract/lib/release_contract.dart`
fails contract validation when a target is missing.

For RCs, `<release-version>` includes `-rc.N`; therefore RC1, RC2, and Stable downloads never collide on disk even though all share the same marketing version.

Windows Agent artifacts use `unsigned+github-attestation`; Client artifacts use `unsigned+winsparkle-dsa` until the documented Authenticode transition is completed. The release notes disclose the missing Authenticode publisher and retain official-origin, manifest, size, SHA-256, SBOM, and GitHub-provenance verification.

## Store What's New

`store-whats-new.en.txt` and `store-whats-new.ar.txt` hold the short, user-facing text the stores publish: the App Store "What's New" and the Google Play release notes for `en-US` and `ar`. One file per language is shared by both stores, so the two listings cannot drift apart.

The first line names the release version, for example `1.0.27`, followed by a blank line and three or four short bullets with no technical detail. The text is written for the release and is never extracted from `release/release-notes.md`, because a store listing is a mobile summary while the release notes are the technical release document.

Both stores enforce a hard limit: Google Play accepts 500 characters per language and the App Store accepts 4000. `scripts/release/store_whats_new.py` owns that check for both lanes, and publication refuses when a file is missing, its first line names another version, the text is empty, or the text is over the limit. Bumping the contract does not rewrite these files, so a release refuses to publish under a version whose text has not been written yet.

## Agent native dictation runtime

Every Agent platform also declares one `agent-runtime` artifact:

`sanad-agent-runtime-<release-version>-<platform>-<architecture>.tar.gz`

The archive is produced from the same verified build as the Agent executable, holds `native/<platform>-<architecture>/` with the allowlisted whisper.cpp libraries only (never a model), and is reproducible byte-for-byte from the same libraries. `scripts/install.sh` and `scripts/install.ps1` verify its size and SHA-256 from the manifest, reject any layout other than `native/<tag>/` with library files, and install it as `<home>/bin/native/<platform>-<architecture>/` beside the executable, which is the first location the loader searches. macOS libraries are signed with the same Developer ID identity as the Agent because the released Agent runs with the hardened runtime.

The runtime is a separate component rather than a second `agent` entry: `findArtifact(component: 'agent')`, the Client bootstrap installer, and the installers keep selecting exactly one single-file Agent executable. A release that predates this entry installs the executable alone.

A runtime that cannot be downloaded or verified is a **dictation-only** failure: the Agent still installs, updates, and runs, and the failing component records one machine-readable reason beside the runtime so dictation readiness can name it and offer a retry. Verification is never relaxed — an unverified library is never extracted or loaded. The full policy, the reason vocabulary, and the retry path live in [docs/technical/native_stt_runtime_platforms.md](../docs/technical/native_stt_runtime_platforms.md#failure-policy-dictation-only).
