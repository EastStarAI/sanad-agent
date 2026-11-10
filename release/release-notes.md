# Sanad 1.0.23

Sanad 1.0.23 makes dictation dependable and gives every model one consistent context size.

## Dictation

- A model download continues where it stopped instead of starting over, and no longer uses a lot of memory while it runs.
- The download row shows the model size, real progress, and the time left, and reopening the app picks the install back up.
- Send works while you are dictating, and the transcript is sent once.
- When dictation cannot start, the sheet says why instead of claiming that no model is installed.

## Models

- Every model now uses one context size, with a sensible default cap that you can change.
- Image input is recognized again for providers that declare image types such as JPEG or PNG.

## Reliability

- Restarts are more dependable: a restart is reported as successful only once the new Agent is actually running, and a stuck Agent no longer blocks the next start.

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.23` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.23` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `24` corresponds to marketing version `1.0.23`.
