# Release contract

`release-contract.json` is the marketing-version, build, channel-file, artifact-name, platform, and signature source of truth. The agent and client pubspec versions, Git tag, build number, workflow outputs, installers, updater, Appcast, checksums, and release documentation must agree with it.

The shared Dart models and validators live beside the data contract in `release/contract/`; there is no separate top-level shared release island.

## Channels

The accepted tags are exactly the stable tag `v<marketing-version>` or an RC tag `v<marketing-version>-rc.<positive-number>`. Stable uses `release-manifest.json` and `appcast.xml`. RC uses the separate `release-manifest-rc.json` and `appcast-rc.xml`; stable clients never consume the RC feed.

A protected `validation_only` dispatch from `main` validates an intended RC or Stable identity and builds the complete Agent and Client matrix—including a private signed IPA—without requiring a tag and without creating any Draft or Release. It produces only retained private workflow artifacts and attestations. A tag or non-validation candidate dispatch additionally requires the tagged commit and creates a GitHub **Draft** only in a separate contents-write job. The build/assembly path remains contents-read. Publication is a separate least-privilege job guarded by the `release-publication` Environment and its required owner approval. Rejection or cancellation leaves only the private Draft.

The workflow refuses any existing Draft or published Release for the tag. Once created, a candidate is not replaced in place. A correction uses a new RC or patch tag and a fresh protected run.

## Outputs

The checked-in contract contains no generated hashes, signatures, timestamps, or credentials. Automation creates the channel-specific manifest, `SHA256SUMS`, SBOM, attestations, and channel-specific Appcast only after every required artifact exists.

Public assets use:

`<component>-<release-version>-<platform>-<architecture>.<extension>`

For RCs, `<release-version>` includes `-rc.N`; therefore RC1, RC2, and Stable downloads never collide on disk even though all share the same marketing version.

Windows Agent artifacts use `unsigned+github-attestation`; Client artifacts use `unsigned+winsparkle-dsa` until the documented Authenticode transition is completed. The release notes disclose the missing Authenticode publisher and retain official-origin, manifest, size, SHA-256, SBOM, and GitHub-provenance verification.
