# Sanad 1.0.6

Sanad 1.0.6 is a security and reliability patch release that hardens macOS Agent runtime trust verification and pairing contract validation across all supported release channels.

## Highlights

- **macOS Agent Runtime Trust Hardening:** Enforced strict Developer ID requirement validation on macOS to ensure untrusted binaries cannot execute during staging or bootstrap flows (#105).
- **Installer & Pairing Contract Guards:** Hardened pairing contract verification and manifest integrity checks during Agent installation (#105).
- **Desktop Compact Window & Layout Polish:** Retains all 1.0.5 compact window improvements, collapsible conversation tool groups, and Apple `SecItem` keychain backend.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.6` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.6` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `7` corresponds to marketing version `1.0.6`.
