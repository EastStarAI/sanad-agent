# Release contract

`release-contract.json` is the marketing-version, build, channel-file, artifact-name, platform, and signature source of truth. The agent and client pubspec versions, Git tag, build number, workflow outputs, installers, updater, Appcast, checksums, and release documentation must agree with it.

The shared Dart models and validators live beside the data contract in `release/contract/`; there is no separate top-level shared release island.

## Channels

The accepted tags are exactly the stable tag `v<marketing-version>` or an RC tag `v<marketing-version>-rc.<positive-number>`. Stable uses `release-manifest.json` and `appcast.xml`. RC uses the separate `release-manifest-rc.json` and `appcast-rc.xml`; stable clients never consume the RC feed.

A tag or manual candidate dispatch validates the tag, channel, build, and tagged commit, builds the matrix, creates attestations, uploads a retained workflow artifact, and creates a GitHub **Draft**. It cannot publish from the build/assembly path. Publication is a separate least-privilege job guarded by the `release-publication` Environment and its required owner approval. Rejection or cancellation leaves only the private Draft.

The workflow refuses any existing Draft or published Release for the tag. Once created, a candidate is not replaced in place. A correction uses a new RC or patch tag and a fresh protected run.

## Outputs

The checked-in contract contains no generated hashes, signatures, timestamps, or credentials. Automation creates the channel-specific manifest, `SHA256SUMS`, SBOM, attestations, and channel-specific Appcast only after every required artifact exists.

Public assets use:

`<component>-<marketing-version>-<platform>-<architecture>.<extension>`

Windows `1.0.0` Agent artifacts use `unsigned+github-attestation`; Client artifacts use `unsigned+winsparkle-dsa`. The release notes disclose the missing Authenticode publisher and retain official-origin, manifest, size, SHA-256, SBOM, and GitHub-provenance verification.
