# Sanad 1.0.27

Sanad 1.0.27 keeps a live answer in the order it was written, makes Windows
dictation load on the processors it declares support for, and removes the last
way a future release could strand an installed Agent.

Versions `1.0.24`, `1.0.25`, and `1.0.26` were skipped, so every platform shares
one version: the desktop Agent and Client, Android on Google Play, iOS on
TestFlight and the App Store, and Web.

## Chat

- A live answer no longer duplicates or reorders its text. Every streamed chunk
  now carries an ordinal that both the Agent and the Client honour, so a chunk
  that arrives late, twice, or ahead of its predecessor is ordered or dropped
  instead of being appended twice or into an answer that already ended. A stream
  whose gap cannot be closed asks once for the in-flight snapshot and keeps its
  last good text until the answer completes. Local and cloud delivery carry the
  same ordinal, so the two copies of one answer render identically.

## Dictation

- Windows dictation loads its model on every x64 processor that meets the
  documented AVX2 baseline. The previous runtime was built with the build
  machine's own instruction set, so an AVX2-only machine faulted while the model
  loaded; the Windows build now configures the CPU backend portably and refuses
  to publish a runtime whose configuration does not prove it.
- Windows x64 dictation uses four threads by default instead of six, and never
  more than the host has cores, because four threads already meet the
  interactive latency targets while six cost materially more CPU time.
- A dictation model download that fails or is cancelled releases its file on
  every platform, so the next attempt can resume, rename the finished file into
  place, or delete a checksum mismatch instead of leaving a partial download
  that could be neither used nor removed until the Agent exited.
- When dictation cannot start, the model sheet states the real reason instead of
  claiming that no model is installed.

## Updates

- A release manifest that declares an artifact type an installed version does not
  know is no longer rejected outright. Trust metadata is resolved only for known
  artifact types while every structural and per-artifact check stays in force,
  so a future release can add a component without breaking the installs that are
  older than it.
- **Installs on v1.0.21 or older must be reinstalled once.** Those versions
  reject every manifest published from v1.0.22 onward while parsing it, so
  neither **Check for Updates** in the Client nor `sanad update` can recover
  them. Reinstall with the official installer for the device: it verifies the
  current artifact, keeps the existing Sanad Home, and restarts the service
  without a new sign-in. The steps are under
  [Reinstalling an Agent that cannot update itself](https://github.com/EastStarAI/sanad-agent/blob/main/docs/operations/user_guide.md#reinstalling-an-agent-that-cannot-update-itself).
- On Windows, **Run local** reports a refused release connection as a trust
  failure with an actionable message instead of raw TLS text, and falls back to
  the hosted release manifest when only the primary host's certificate chain
  cannot be verified. Certificate verification is never relaxed, and an Agent
  artifact is never downloaded from the fallback.

## Providers

- OpenCode Go instances show their account usage limits — session (5-hour),
  weekly, and monthly windows — in Provider Settings. An API-key instance that
  needs a new key now offers **Update API key** instead of an OAuth reconnect
  that cannot repair it.
- Each banked ChatGPT reset credit is listed on its own row with its relative
  expiry and its own reset button, so you can see which credit expires first and
  spend that exact one. Hovering over an expiry shows the full local date and
  time.

## Sanad Client

- The macOS workspace picker can create a folder, so a new workspace no longer
  has to adopt a folder that already exists.

## Documentation

- The iPhone and iPad app is documented as publicly available on the App Store,
  where the listing is `Sanad Remote`; TestFlight is documented as the
  pre-release lane.

## Release tooling

- The release workflow can now publish the signed, notarized, and attested bytes
  a validation run already proved for the exact tagged commit instead of
  rebuilding the matrix. It ships in shadow mode for this release: the tag run
  reports the promotion verdict and still rebuilds and publishes its own bytes.
  The release-candidate identity is derived from the tag.
- A merge no longer re-runs lanes that already passed on the exact merged
  commit, so post-merge CI does not duplicate a validated run while every lane
  still runs once against that commit.
- `main` requires an up-to-date branch before merge instead of a merge queue.
- Every `apt-get` call in the release and CI workflows goes through one install
  action with a bounded acquire phase and retries, so a stalled mirror fails one
  lane quickly instead of costing 20–45 minutes.
- Two macOS Intel timing gates now measure in their own warmed process with
  explicit spawn-and-compile deadlines, and the Windows dictation lane reports
  its own result instead of `errno 32`.
- `sanad-dev setup` prepares native dictation and reports the outcome,
  `sanad-dev run` prepares it in the background without blocking the runtime,
  and a preparation that cannot finish stays dictation-only with the failing
  stage and a retry command.

This Stable release was built from tagged public source by the protected Sanad
release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`,
and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.27` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS:** The App Store still publishes `Sanad Remote` `1.0.21` for iPhone and iPad. The iOS artifact for `1.0.27` is built and signed for `NanoSoft LY LLC` and goes to internal TestFlight and App Store review in parallel with this release, so it is not yet part of the public downloads. Build number `27` corresponds to marketing version `1.0.27`.
