# Sanad 1.0.8

Sanad 1.0.8 is a focused reliability release that lets newly discovered provider models use their advertised context windows and refreshes Client markdown rendering.

## Highlights

- **Dynamic Provider Context Windows:** Agent runtime now consumes the selected provider instance's revision-matched catalog metadata before falling back to general provider metadata. Newly discovered models can use their advertised context window without model-specific code, while explicit `config.yaml` overrides remain authoritative (#136).
- **Safer Context Compaction:** High request pressure no longer causes a turn failure when the active conversation projection has no older source head available to compact (#136).
- **Maintained Markdown Rendering:** The Client now uses the actively maintained `flutter_markdown_plus` package across conversation and web-tool markdown surfaces (#135).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.8` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.8` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `9` corresponds to marketing version `1.0.8`.
