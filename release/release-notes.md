# Sanad 1.0.9

Sanad 1.0.9 introduces provider-backed multilingual context compaction, causal turn identity and steer ordering, and streaming markdown formatting fixes.

## Highlights

- **Provider-Backed Multilingual Context Compaction:** Conversation compaction now summarizes using the active provider model with structured JSON validation, ensuring high-quality semantic summaries across Arabic, English, and multilingual conversations (#139).
- **Authoritative Turn Identity & Steer Ordering:** Live execution events propagate causal turn, run, and step IDs, while steering inputs are anchored to durable tool-call references. Timeline reconciliation prevents duplicated messages on reopen and unifies replay confirmation into a single dialog (#142).
- **Streaming Markdown Heading Preservation:** The Client preserves structural whitespace and newline chunks during assistant streaming, preventing markdown headings from collapsing into preceding body text (#143).
- **Workspace Cache Consistency:** Removed workspaces are immediately invalidated from device-scoped cache, preventing stale background refresh responses from restoring them (#138).
- **Provider Routing & Attribution:** Added session affinity headers for OpenCode provider requests and canonical application attribution for OpenRouter requests (#140, #141).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.9` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.9` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `10` corresponds to marketing version `1.0.9`.
