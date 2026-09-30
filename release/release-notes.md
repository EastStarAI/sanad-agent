# Sanad 1.0.10

Sanad 1.0.10 adds secure account session and device management, authoritative cross-transport delivery presence, and stronger multi-runtime development reliability.

## Highlights

- **Sessions & Devices Management:** The Client now exposes account sessions and registered devices with stable Client identity, clear status, and secure revocation controls.
- **Immediate Distributed Revocation:** Revoking a Client session or Agent device propagates through the hosted system and disconnects the affected runtime without weakening tenant isolation.
- **Authoritative Local/Cloud Delivery:** Device-interest snapshots and presence leases keep Local and Cloud command routing explicit, prevent duplicate egress, and preserve remote-device availability.
- **Trusted Command Origin:** Backend-derived command origin is propagated to the Agent instead of trusting caller-supplied identity.
- **Reusable Multi-Runtime Tooling:** `sanad-dev` now has a standalone package boundary and improved source-matched runtime ownership for reliable macOS, Web, and iOS development and validation.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.10` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.10` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `11` corresponds to marketing version `1.0.10`.
