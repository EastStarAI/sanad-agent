# Sanad 1.0.17

Sanad 1.0.17 adds confirmed account deletion from the Client Profile, with clear localized explanations of what is removed and what stays on your Agent (#204).

## Highlights

- **Confirmed Account Deletion:** Delete your Sanad cloud account from Profile after an explicit confirmation. Cancelling leaves the account unchanged.
- **Local Data Preserved:** Account deletion does not erase Agent-local files or conversation history.
- **Truthful Deletion Outcomes:** The Client distinguishes confirmed deletion, temporary unavailability, and an unknown outcome when a response is lost; it does not silently retry a destructive request.
- **Arabic and English Guidance:** Localized confirmation and provider-owned guidance explain the account and Apple authorization boundaries without claiming that Apple authorization was automatically revoked.

There are no Agent runtime changes in this patch; Agent artifacts retain the shared release version.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.17` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.17` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `18` corresponds to marketing version `1.0.17`.
