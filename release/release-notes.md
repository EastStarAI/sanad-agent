# Sanad 1.0.3

Sanad 1.0.3 is a security-focused compatibility release that binds OAuth results to the Client or Agent that initiated authorization, while also delivering the latest runtime, permission, navigation, and interaction improvements from public `main`.

## Security and compatibility

- **Recipient-bound Client sign-in:** Web, desktop, and mobile authentication now use Authorization Code with S256 PKCE and platform-owned callbacks. A copied Portal URL, transaction identifier, or former polling secret cannot deliver a user's credentials.
- **Proof-bound headless authorization:** Headless Agents use a user code plus a vault-backed P-256 key and receive only a `sanad_agent` Device Credential after explicit approval and proof of possession.
- **Key-bound pairing and reconnect:** One-command pairing and Gateway registration require fresh nonce proofs from the enrolled key. Pre-binding Agent credentials without a key thumbprint fail closed.
- **Legacy cutover:** `/auth/start`, `/auth/status`, `/auth/cancel`, and `/handoff` polling clients are intentionally unsupported. Existing pre-binding refresh families are revoked by the hosted migration, so users must update Client and Agent before the server cutover and sign in again afterward.
- **Protected local credentials:** Agent keys and Device Credentials use macOS Keychain, Linux Secret Service, or Windows DPAPI. An unavailable vault does not fall back to plaintext storage.

## Additional improvements

- Added authorized external-workspace file access with explicit permission gates.
- Improved conversation navigation, file drag and drop, skill and Markdown presentation, MCP forms, and onboarding flows.
- Hardened runtime stop/recovery behavior and release-asset rollback handling.
- Added verified mobile callback promotion contracts for Android App Links and iOS Universal Links.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.3` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.3` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `4` corresponds to marketing version `1.0.3`.
