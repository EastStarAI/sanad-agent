# Sanad release

This release was built from the tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, the channel-specific release manifest, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.0` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. The `1.0.0` clean-machine release gate was validated on Windows 11; Windows 10 was not validated for this release. The client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.0` is distributed exclusively to the internal TestFlight testers of the `NanoSoft LY LLC` team. It is not part of the public downloads in this release, did not enter External TestFlight Review, and is not available via the public App Store. Build number `1` corresponds to the `1.0.0` marketing version; later builds are produced via the protected Internal TestFlight workflow and never republished as part of a public release.
