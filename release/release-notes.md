# Sanad 1.0.2

Sanad 1.0.2 is a patch release focused on macOS app icon fidelity, Web/PWA dark theme consistency, and refined UI theme contrast and settings presentation.

## Highlights

- Restored native Apple Icon Composer assets (`AppIcon.icon`) to prevent macOS WindowServer squircle backplate borders in the macOS Dock.
- Aligned Web & PWA `theme_color` to `#0A0A0A` and added smooth initial dark splash loading.
- Refined theme contrast tiers across scaffold background, cards, surfaces, outlines, and dividers for light and dark modes.
- Configured dedicated Tooltip container styling and added the active version indicator in the desktop settings screen.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.2` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.2` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `3` corresponds to marketing version `1.0.2`.
