# Sanad 1.0.19

Sanad 1.0.19 is a patch release that restores the Sanad Web app and makes the model catalog command report exactly what you ask for.

## Client interface

- **Sanad Web opens again.** In 1.0.18 the Web app stopped on the splash screen because startup read a desktop-only setting that browsers cannot provide. The desktop-only `sanad-client` endpoint is now set up only on desktop, so Web and mobile start normally, and desktop behaviour is unchanged (#262).

## Command line

- **`sanad models` honours its filters.** `--provider` selects one configured provider by id, template, or name, `--model` narrows the list to one cached model, and `--json` prints a single machine-readable catalog. An unknown or ambiguous selector now fails with a clear message instead of silently listing every provider (#261).
- **Shell loops keep their input.** `sanad run --no-stdin` leaves piped input alone, so a `while read` loop that runs `sanad run` once per line no longer stops after the first iteration (#261).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.19` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.19` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `20` corresponds to marketing version `1.0.19`.
