# Sanad 1.0.24

> [!IMPORTANT]
> **This is a release candidate, not a Stable release.** Sanad `1.0.24-rc.1` is a pre-release candidate for marketing version `1.0.24`, build number `25`. It is published on the release-candidate channel only (`release-manifest-rc.json`, `appcast-rc.xml`) and never replaces a Stable download, the Stable manifest, or the Stable update feed. A Stable `1.0.24` is published only after a separate publication decision.

Sanad 1.0.24-rc.1 fixes a dictation download that could not be completed or cleaned up on Windows, and makes a tagged release publish the build that was already validated instead of rebuilding it.

## Dictation

- A dictation model download that fails or is cancelled now releases its file on every platform, so the next activation renames the finished file into place, deletes it on a checksum mismatch, or repairs it for resume, exactly as the model store does in the statement after the download closes. On Windows the previous behaviour could fail an activation after a completed 1.6 GB download and then leave a partial file that could be neither resumed nor removed until the Agent exited.

## Release trust

- When a validation run has already proved the exact commit being tagged, the tag release now publishes those signed, notarized, and attested bytes instead of rebuilding the whole matrix from the same source, so what you download is the build that passed validation. A tag release also finishes about 11-12 minutes sooner because it no longer repeats the Agent and Client builds.

## Reliability

- A Windows CI lane now reports a test result for the dictation download pipeline instead of `errno 32`, because the refused-write test closes the download it opens, and the dictation cost gate measures its own process rather than its neighbours' contention.
- A merge no longer re-runs lanes that already passed on the exact merged commit, so post-merge CI on `main` no longer duplicates a validated run while every lane still runs once against that commit.
- `main` now requires a branch to be up to date before merge instead of using the merge queue. The protected-label re-check that the queue performed at merge time is part of the maintainer's merge procedure, and no CI job, lane, or required check is removed.

This release candidate was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest-rc.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.24` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.24` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `25` corresponds to marketing version `1.0.24`.
