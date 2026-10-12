# Sanad 1.0.16

Sanad 1.0.16 introduces conversation history search, provider-aware thinking mode and route controls, daemon lifecycle and interactive wait preservation, tool timing telemetry, context compaction safety, and Linux unprivileged installation improvements.

## Highlights

- **Conversation History Search:** Added dedicated conversation history search with localized interface controls (#147, #199).
- **Thinking Mode & Route Controls:** Integrated provider-aware thinking mode configuration and model route controls within the agent engine (#194).
- **Daemon Lifecycle & Interactive Waits:** Preserved interactive user-input wait states across managed daemon stops and prevented duplicate session stop acknowledgment recovery (#196, #197).
- **Tool Timing & Execution Telemetry:** Tracked detailed tool execution duration and exposed execution timings in shell execution results (#192).
- **Runtime Healing & Terminal Validation:** Added self-healing recovery for stale runtime instances, enforced deterministic process identity, and improved result data fidelity (#190, #191).
- **Context Compaction & Limit Safety:** Resolved local model context boundary resolution and hardened context compaction thresholds (#193).
- **Linux Client Agent Installation:** Streamlined Client Agent installation on Linux without requiring root privilege elevation (#198).
- **Navigation & History Stability:** Guarded navigation history loading and deduplicated sidebar workspace refreshes (#189).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.16` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.16` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `17` corresponds to marketing version `1.0.16`.
