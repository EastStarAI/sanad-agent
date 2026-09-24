# Sanad 1.0.13

Sanad 1.0.13 brings Windows-first performance optimizations, native terminal CLI delegation, Arabic and English multilingual UI enhancements, and desktop client refinements.

## Highlights

- **Windows-First Performance & Efficiency:** Reduced CPU and GPU utilization with optimized static indicators, headless daemon execution without console allocation, and turn request deduplication (#168).
- **Native CLI Delegation & Recovery:** Standalone terminal CLI runner (`sanad run`) with automatic session recovery and OpenCode compatibility (#148, #149, #150).
- **Multilingual UI & RTL Support:** Full interface localization in Arabic and English, dynamic layout directionality, and agent appearance customization (#174).
- **Client & Desktop Refinements:** Activity panel with tool execution timer (#175), enhanced model picker (#177), desktop window work-area constraints (#176), and smoother delta streaming (#173).
- **Agent Engine & Context Reliability:** Default context compaction threshold raised to 90%, safe context limit resolution, and automated database maintenance (#153, #163).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.13` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.13` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `14` corresponds to marketing version `1.0.13`.
