# Sanad 1.0.5

Sanad 1.0.5 is a feature and stability release that introduces desktop compact window mode, collapsible conversation tool groups, enhanced macOS Keychain security using the `SecItem` API, serialized permission prompt handling, and automated developer tooling.

## Highlights

- **Desktop Compact Window & Layout Polish:** Introduced a streamlined compact desktop mode with refined dimensions, persistent layout states, and smooth restore behavior for desktop workflows (#97, #103).
- **Conversation Tool Groups:** Grouped tool calls and executions into clear, collapsible presentation units to reduce visual clutter in active conversations (#97, #100).
- **macOS Keychain `SecItem` & Auth Hardening:** Upgraded credential vault storage on macOS to native Apple `SecItem` APIs, sanitized authentication state serialization, and enabled automatic PATH configuration for the `sanad` CLI (#102).
- **Agent Permission Concurrency:** Serialized concurrent permission prompts per session to eliminate approval race conditions and improve interaction safety (#99).
- **Flutter VM Driver CLI:** Added a dedicated VM service driver CLI to support automated Flutter UI testing, inspection, and diagnostics (#98).
- **CI & Toolchain Modernization:** Updated macOS release runner infrastructure to `macos-26` with Xcode 26 support (#101).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.5` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.5` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `6` corresponds to marketing version `1.0.5`.
