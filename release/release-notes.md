# Sanad 1.0.2

Sanad 1.0.2 is a patch release focusing on cross-process authentication safety, local-first onboarding, UI fidelity and theme contrast, macOS native icon presentation, and Web/PWA theme harmonization.

## Highlights

- **Desktop Authentication Concurrency:** Serialized credential refresh across the Flutter client, Dart daemon, and CLI using native cross-process file locks (`shared/auth_lock`) to eliminate token refresh race conditions (#59).
- **macOS App Icon Fidelity:** Restored native Apple Icon Composer (`AppIcon.icon`) asset definitions to eliminate squircle container backplates on the macOS Dock (#61).
- **RTL & Event Presentation:** Added automatic right-to-left (RTL) text alignment for Arabic question headers and event cards (#62).
- **Local-First Onboarding:** Streamlined initial onboarding and workspace initialization with local-first discovery (#65).
- **Theme & Contrast Tiers:** Polished surface, card, outline, and divider contrast levels for light/dark themes, added dedicated tooltip styling, and added an active version indicator badge in settings (#68).
- **Web & PWA Dark Theme Alignment:** Set `theme_color` to `#0A0A0A` for mobile status bars and integrated a smooth dark startup splash loader (#69).
- **Runtime Development Tooling:** Hardened `sanad-dev switch` runtime handoff to automatically prepare target checkout workspaces (#60).
- **Packaging & Security:** Added compatible Linux DEB packaging (#64) and restricted production deployment privilege boundaries (#66, #67).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.2` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.2` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `3` corresponds to marketing version `1.0.2`.
