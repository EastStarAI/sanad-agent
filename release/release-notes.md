# Sanad 1.0.7

Sanad 1.0.7 is a reliability and workflow release that makes conversation history and replay more durable, strengthens Agent execution recovery, and expands secure remote and headless operation across supported platforms.

## Highlights

- **Durable Conversation Replay and History:** Adds materialized conversation forks, long-history pagination, hydration reconciliation, and live-history synchronization for replay actions. Mobile loading failures now preserve the app bar and keep the activity overlay below the header (#125, #127, #128, #130, #131).
- **Safer Agent Execution and Recovery:** Prevents controlled restarts from replaying active provider requests, adds run-scoped cancellation and stop parity, contains provider model-refresh failures, compacts context using durable model-aware state, and recovers safely after forced shutdown (#112, #117, #118, #123, #124).
- **Secure Remote and Headless Operation:** Adds durable Linux headless Agent installation and secure device-scoped workspace and MCP control, while hardening Windows Client upgrades (#119, #120, #121).
- **Desktop and Authentication Reliability:** Preserves compact-window positions and menu-button hover navigation, avoids the affected macOS Impeller crash path, and prevents post-login routing loops (#107, #109, #114).
- **Repeatable Release Delivery:** Introduces deterministic cross-platform release identity preparation and fail-closed verification before protected builds and the final publication decision (#132).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.7` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.7` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `8` corresponds to marketing version `1.0.7`.
