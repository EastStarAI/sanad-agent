# Sanad 1.0.1

Sanad 1.0.1 is a patch release focused on secure local operation, reliable recovery, desktop lifecycle hardening, and a more consistent client experience.

## Highlights

- Hardened Sanad Home, Local Gateway admission, desktop authentication synchronization, and remote-management boundaries.
- Improved session recovery, message acceptance feedback, streaming/final Markdown parity, workspace caching, and provider account presentation.
- Added form-first MCP server configuration with isolated runtime ownership.
- Completed verified desktop Client-Agent installation, exact-version update, restart, reconnect, and bounded rollback paths.
- Improved Windows replacement safety, startup health confirmation, and terminal restoration.
- Restored Web startup reliability and updated cross-platform release assets.
- Removed the Xcode 26 layered macOS icon path that added light side rims; macOS now uses the same opaque flat composition as the corrected iOS icon.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.1` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.1` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `2` corresponds to marketing version `1.0.1`.
