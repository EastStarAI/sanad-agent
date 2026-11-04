# Local Dictation — Microphone Button with Live Transcript in the Composer

## Goal
Add a dictation mic button to the conversation composer that sends microphone PCM to the agent daemon, transcribes it **inside the daemon** with a local sherpa-onnx model, and streams transcript events back so the user watches the text appear live in the composer field — on macOS arm64 first, with no cloud provider involved.

## Scope and locked decisions
- **Ownership:** transcription happens only in the daemon (`agent`). The client records microphone PCM, sends it, renders transcript events, and inserts them into the composer. The client never runs a model.
- **Scope:** dictation only. No assistant reply, no auto-send, no TTS, no `supports_voice_call` change. The existing experimental Gemini realtime voice path stays untouched and hidden.
- **Transport (v1):** reuse the existing voice WebSocket contract shape on a new local route `/ws?type=dictation&session_id=<session>&device_id=<device>`, authenticated with the same active-Home Local Gateway credential. Client microphone → daemon audio is 16 kHz mono PCM16 little-endian; the daemon converts to Float32 for the recognizer. A hosted transport is out of scope here and is tracked outside this public plan.
- **One native engine:** `sherpa_onnx` is the only STT native dependency. No sidecar, subprocess, CLI, local HTTP server, or Python runtime may perform transcription.
- **Pluggable engines, not one model:** a daemon-side `SttEngine` interface declares `streaming` / `batch_vad` / `interimResults` / languages / readiness. The v1 catalog has **two** `batch_vad` whisper entries (no streaming entry exists for Arabic yet). Adding a streaming model later is a catalog entry plus an adapter, never a transport or UI rewrite.
- **Event contract is final for both modes:** `partial` (mutable, monotonic `seq`, replaces its own inserted range) and `final` (terminal, published once). A batch model emits finals at VAD segment ends; a future streaming model emits partials continuously into the same contract.
- **Models are not bundled.** Nothing is shipped in the repo or installer. The daemon owns model files under `Sanad Home/models/stt/<model-id>/`, verified by pinned SHA-256 with atomic activation.
- **Download is explicit and on demand.** No download at install or first launch. On the first mic press with no model installed, the client shows one sheet listing the catalog entries (label, size, recommended note) where the user picks and confirms the download (progress + cancel), then dictation starts.
- **`config.yaml` overrides the catalog:** `stt.enabled`, `stt.model_id`, `stt.model_path` (wins over `model_id`, no download and no SHA check), `stt.language` (default `ar`), `stt.threads` (default 4). Any sherpa-compatible ONNX model directory can be used this way without code changes; its readiness is required-files presence plus a recognizer load probe.
- **Two v1 catalog entries:** `egy-whisper-turbo-int8` (Whisper large-v3-turbo Egyptian fine-tune, default, best Arabic accuracy, large) and `whisper-base-int8` (light/fast, explicitly labeled lower Arabic accuracy). No RAM probing in v1; the picker labels the light entry as suitable for weak devices.
- **Platform gate:** `supports_dictation` is advertised true only where the native library loads and a model is usable (macOS arm64 for v1). Windows/Linux report false with a reason until A2 measurements exist. Unsupported devices get a disabled mic button with a visible reason — never a silent cloud fallback.
- **Failure behavior:** a missing, corrupt, or unloadable model produces a typed error, the mic button returns to idle, and the composer draft is preserved. Typed errors never fabricate text.
- **Lifecycle bounds:** max dictation session 5 minutes, bounded audio queue with an explicit drop policy, recognizer loaded on first press and released after 5 minutes idle, cancellation on `dictation_cancel`, client disconnect, and daemon shutdown.
- **Privacy:** no raw audio, transcript text, credential, or absolute model path in logs. Metrics only: model load, first-final latency, processing RTF, queue high-water/drops, cancel time, total duration.
- **Client routing has one owner.** The client resolves local vs hosted transport in a single place, exactly like the existing voice path (`VoiceStreamCubit` + `DeviceConnectionCoordinator`). No other dictation code may branch on connection scope.
- **Preview policy is a switch, not a protocol.** `dictation_preview: live | on_stop` — `live` inserts each final as it arrives (default), `on_stop` buffers finals and inserts them when the session stops. No transport or daemon change either way.
- **Streaming is supported generically, not per model.** `SttModelMode.streaming` and `dictation_partial` already exist; a future streaming adapter (sherpa `OnlineRecognizer`) plus a catalog entry is the entire remaining work. Model-specific ONNX surgery for third-party exports is out of scope.
- **Out of scope:** streaming-catalog model, Windows/Linux support, language auto-detection, multi-model simultaneous load, dictation into any field other than the composer, changes to the text protocol, changes to `AgentRunner`.

## Open decision (owner)
- **Hosting for the Egyptian ONNX artifact.** The light model can be pinned from the public sherpa-onnx whisper-base release. The Egyptian model has no public URL yet. Until the owner publishes it (recommended: a Hugging Face repo with pinned file list, sizes, and SHA-256), the supported path is `stt.model_path` pointing at a locally exported ONNX directory, and `egy-whisper-turbo-int8` is marked "not hosted yet" in the catalog. This does not block G0/G1/G2.

## Gates

### G0 — Discovery and feasibility proof
- [x] `sherpa_onnx` resolves inside `agent/pubspec.yaml` (`fvm dart pub get`, resolved `1.13.8`), and `fvm dart compile exe bin/sanad_agent.dart` still builds the daemon (12 s) with the transitive `flutter: sdk: flutter` dependency present.
- [x] In-process load on macOS arm64 proven: `initBindings()` (auto path) + `OfflineRecognizer` decoded a WAV fixture with zero Flutter imports, no platform channel, no subprocess (`agent/tool/stt_probe.dart`).
- [x] macOS code-sign requirement from Plan 61 A1 did not reproduce on this host (macOS 27, pub cache `1.13.8`): `dlopen` succeeded without `codesign`. Kept as a release-packaging check, not a dev step.
- [x] Egyptian checkpoint exported to sherpa whisper ONNX int8 (upstream `scripts/whisper/export-onnx.py` with an HF → openai-whisper key remap): `egy-whisper-turbo-encoder.int8.onnx` 674,622,359 B `c8b11061…951b1`, `egy-whisper-turbo-decoder.int8.onnx` 361,070,805 B `e6c33908…0aa7`, `egy-whisper-turbo-tokens.txt` 816,730 B `b34b360d…2fa126`.
- [x] Light model resolved from the public `csukuangfj/sherpa-onnx-whisper-base` tree: `base-encoder.int8.onnx` 29,120,534 B `0b8fb130…0a1e11`, `base-decoder.int8.onnx` 130,672,026 B `9759d217…09dc02d`, `base-tokens.txt` 816,730 B `b34b360d…2fa126` (161 MB total).
- [x] Arabic fixture: 25 s mono 16 kHz clip plus the whole 60 s clip, with the ggml (whisper.cpp) transcript kept as the reference. Measured: base-int8 load 1318 ms / RTF 0.056 / RSS 785 MB; Egyptian-int8 load 765 ms / RTF 0.530 / RSS 2373 MB (CPU-only, 2 threads).
- [x] Egyptian ONNX transcript matches the ggml reference on the same audio (same content, same code-switch segments: `Cloud Code`, `Social Media`), so the export route is accepted.
- [x] Reuse audit: confirmed the route/event/capability shape against `docs/technical/voice_streaming.md`, `local_daemon_server_platform.dart:304`, `capabilities.dart`, and `client/lib/features/voice/AGENTS.md`; G1 touches only `infrastructure/stt/`, `capabilities*.dart`, and the dictation route branch.
- [x] Prove the VAD + `OfflineRecognizer` segment pipeline end-to-end on the 60 s fixture (segment lengths, first-final latency per segment), because sherpa's whisper decoder rejects anything over 30 s.

### G1 — Daemon dictation runtime
- [x] `agent/lib/infrastructure/stt/`: `stt_types.dart` (catalog/event/error types), `stt_engine.dart` (`SttEngine` + `SherpaSttEngine` isolate handle), `stt_isolate.dart` (worker: recognizer + VAD + decode loop), no Flutter import anywhere.
- [x] `sherpa_stt_engine.dart` equivalent delivered as `stt_isolate.dart`: sherpa `OfflineRecognizer` + `VoiceActivityDetector`, one `final` per VAD segment, forced cut every 4 s so continuous narration cannot produce 20 s segments, typed errors.
- [x] `stt_catalog.dart`: data-only catalog (id, label, note, mode, family files with url/size/sha256, language, `isDefault`, `hosted`) with the two v1 entries plus the shared Silero VAD asset.
- [x] Model lifecycle (`stt_model_store.dart`): streamed download with progress, pinned SHA-256 and size verification, `.partial` staging, atomic rename activation, cancel, hard-link-free single writer, plus `_shared/silero_vad.onnx`.
- [x] `stt_settings.dart`: `stt.enabled`, `model_id` (validated against the catalog), `model_path` (override wins), `language`, `threads` (1..16, default 4); wrong types fail with the offending key.
- [x] `dictation_session.dart`: one session per socket, bounded queue (200 chunks ≈ 20 s) with counted drops, 5 minute cap with `session_limit`, `partial`/`final` sequencing, idempotent stop, cancel on disconnect.
- [x] `local_daemon_server_platform.dart`: `type == 'dictation'` route beside `voice`, same Local Gateway credential gate, voice path untouched.
- [x] Client-facing events: `stt_status`, `stt_download_progress`, `dictation_ready`, `dictation_partial`, `dictation_final`, `dictation_done`, `dictation_error` (`stt_install`/`stt_select` accepted as commands).
- [x] `capabilities.dart` + `capabilities_loader.dart`: `supports_dictation` plus `dictation_unavailable_reason`; `supports_voice_call` still absent.
- [x] Focused tests (39 passing): catalog invariants, settings parsing/validation, checksum rejection, cancel, unhosted refusal, atomic activation, path override discovery, incomplete/detached-VAD errors, session readiness/final forwarding, session limit, cancel-without-finish, error passthrough, selection precedence, status payload.

### G2 — Client dictation surface
- [x] **One routing owner:** a single `DictationTransportResolver` (same pattern as `DeviceConnectionCoordinator`) decides which transport a session uses; no other dictation code branches on connection scope. Any additional transport is added inside that resolver and nowhere else.
- [x] `client/lib/features/dictation/` with `DictationCubit` (lifecycle, resolved transport, model state, preview policy, error projection) and a capture class that reuses the 16 kHz PCM16 primitive without touching the voice path's recorder session.
- [x] Composer mic button (`dictation_mic_btn`) in the conversation input row, gated by `capabilities.supportsDictation`, with recording/processing/error states and localized tooltips.
- [x] Live insertion: `partial` replaces only the range it owns using a tracked start offset, `final` commits and advances the offset, stop keeps the text, cancel reverts the uncommitted range, and a manual edit during dictation resets the tracked offset so user text is never overwritten.
- [x] `dictation_preview: live | on_stop` — `on_stop` suppresses partials and shows committed text only; default `live`.
- [x] First-use sheet reuses the existing `full_access_confirmation_dialog.dart` pattern (same shape, typography, RTL, and button treatment) for model choice + download consent with progress; no new visual language.
- [ ] Settings surface — **deferred to G6 by owner decision.** Model, installed size, preview policy, and the daemon-reported unavailable reason are already covered by the model sheet; the enable toggle and model selection move to the device settings page described in G6. `stt.enabled` in `config.yaml` is the only switch that exists until then, and the client already surfaces `dictation_disabled` when it is off.
- [x] Localized strings only (English + Arabic) — no new literals outside `AppLocalizations`.
- [x] Widget/unit tests (16 passing): capability-independent button render, press starts a session, inert with no device, finalized text lands in the composer, insertion range/manual-edit/cancel, preview-policy buffering, missing-model recovery, unavailable transport, cancel clearing, stop draining.

### G6 — Device settings: Dictation section (deferred, owner-decided shape)
- [ ] Add a **Dictation** section to the existing **device settings page** (not a new page, not the composer): selected model with installed size, an enable/disable toggle, and the daemon-reported unavailable reason.
- [ ] The client **never edits agent configuration directly**. Every change is sent as a command over the existing connection layer — the same pattern as the current agent settings (`update_session_preferences`, `update_session_title`) and not a special case.
- [ ] The daemon owns persistence of the new values, re-advertises `supports_dictation` / reason afterwards, and the client only reflects the capability.
- [ ] Model switching uses the existing `stt_select` path; the enable toggle needs one new settings command plus daemon persistence and tests (nothing is wired to the file system from the client).
- [ ] Out of scope: writing `config.yaml` from the client, a client-local toggle that hides the button without telling the daemon, and any settings surface outside the device settings page.

### G5 — Generic streaming engine (after v1)
- [ ] `StreamingSttEngine` adapter over sherpa `OnlineRecognizer` emitting `dictation_partial` + `dictation_final`; the worker isolate is reused.
- [ ] Catalog entry with `mode: streaming`, validated with a public English streaming model (no Arabic streaming model exists in sherpa today).
- [ ] No transport, protocol, or UI change: the client already renders partials and honours `dictation_preview`.
- [ ] Explicitly excluded: model-specific ONNX surgery for third-party exports (see G0b).

### G0b — Nawah (NeMo TDT, Arabic) — deprioritized
- [x] Probed `oddadmix/Nawah-ASR-60M-Max-Arabic-ONNX` (69 MB int8). Not sherpa-packaged: the encoder lacks the `vocab_size` metadata sherpa requires, the blank convention is inverted (`<blk>` is id 0 inside the vocab while sherpa expects `1024` as the last `tokens.txt` line), and the encoder consumes full-context features, so it is not streaming despite the transducer architecture.
- [ ] Decision: **model-specific work is not worth it** (~80% quality). Revisit only if an Arabic *sherpa-packaged* streaming/light model appears, or a chunked-encoder export with sherpa metadata is published. This gate closes on such an artifact, never on hand-written ONNX surgery.

### G3 — Documentation, verification, delivery
- [ ] New `docs/technical/local_dictation.md` (ownership, transport, event contract, model lifecycle, platform gate) and a pointer from `docs/technical/voice_streaming.md`.
- [ ] Update `docs/llms.txt`, `docs/product/features.md`, and the `agent`/`client` AGENTS.md ownership lines.
- [ ] `fvm dart analyze` and `fvm flutter analyze` clean; focused tests green in both projects.
- [ ] Live acceptance via `sanad-dev` on macOS arm64: press the mic, speak Arabic, watch text appear and finalize, verify draft preservation on cancel and on model failure.
- [ ] Bounded live evidence recorded (first-final latency, RTF, RSS, load time) with no audio/transcript logging in the daemon.
- [ ] Graph maintenance per `graphify` rules when code files change.
- [ ] Commit inside the worktree with the `sanad-agent@eaststarai.com` identity and a plan-referenced message; open the PR with verification results.

## Acceptance Criteria
- [ ] Given a macOS arm64 device with dictation supported and no model installed, when the user presses the mic button, then one sheet offers the catalog entries, and after a confirmed download the session starts without leaving the composer.
- [ ] Given an active dictation session, when the user speaks Arabic, then daemon-emitted transcript text appears in the composer within the measured first-final latency and is never sourced from the client.
- [ ] Given a batch model, when a VAD segment ends, then exactly one `final` for that segment is published and no later event mutates it.
- [ ] Given a partial is displayed, when the user types into the composer, then the typed text is preserved and only the dictation-owned range is replaced.
- [ ] Given the client disconnects, cancels, or the daemon shuts down mid-session, then no further transcript event is published, the recognizer and queue are released, and the composer keeps the last committed text.
- [ ] Given `stt.model_path` points at a valid sherpa ONNX directory, when the daemon starts, then that model is used with no download and no SHA requirement.
- [ ] Given a corrupt or missing model file, then the mic button is disabled or errors with a localized reason and no text is fabricated.
- [ ] Given Windows or Linux in v1, then `supports_dictation` is false with a reason and the button is not actionable.
- [ ] Automated coverage proves sha mismatch rejection, atomic activation, cancel during download/load/decode, partial-after-final rejection, queue overflow, and capability-driven button visibility.
- [ ] Automated coverage fails if the client project gains a model/runtime dependency, or if the daemon imports Flutter in dictation code, or if transcript text or audio reaches the logs.

## Definition of Done
Analyzer and focused tests pass in `agent` and `client`; the two-model catalog, `config.yaml` overrides, and the partial/final contract are documented; live macOS arm64 acceptance is recorded with measured latency/RTF/RSS; platform gating is honest on unsupported systems; no bundled model artifacts; graph maintenance ran for changed code; delivery happens only after explicit owner approval for commit and PR.

## G0 evidence (2026-11-04, macOS arm64)

| Item | Result |
|---|---|
| `sherpa_onnx` in `agent` | resolves `1.13.8`; `dart compile exe` OK (12 s) |
| Pure-Dart decode | `OfflineRecognizer` works, no Flutter import |
| whisper-base int8 (161 MB) | load 1318 ms, RTF 0.056, RSS 785 MB |
| Egyptian turbo int8 (1.04 GB) | load 765 ms, RTF 0.530, RSS 2373 MB |
| Egyptian text quality | matches ggml reference transcript |
| Hard limit found | sherpa whisper decoder accepts **< 30 s** per decode → VAD segmentation is mandatory, not optional |

Artifacts exported outside the repo at `/Volumes/Storage/caches/stt-models/egy-turbo/`.

## G1 evidence (2026-11-04, macOS arm64)

Pipeline run through the real isolate engine with 100 ms chunks at wall-clock rate
(`agent/tool/stt_stream_probe.dart`), shared `silero_vad.onnx`:

| Model | Segments | Decode per segment | Drops | Notes |
|---|---|---|---|---|
| whisper-base int8, 60 s clip | 5 | ≈1.0 s | 0 | RTF ≈0.09 in the pipeline |
| Egyptian turbo int8, 25 s clip, 2 threads, 6 s cut | 4 | ≈4.9 s | 0 | too slow for live typing |
| Egyptian turbo int8, 25 s clip, 6 threads, 6 s cut | 4 | ≈3.1 s | 0 | better |
| **Egyptian turbo int8, 4 threads, 4 s cut (default)** | 6 | ≈2.4–2.7 s | 0 | text cadence ≈2.5 s, first text ≈6 s after start |

Tuning decisions taken from these runs: default `stt.threads = 4`, forced cut
every 4 s (maxSpeechDuration alone was not honoured — 10 s and 20 s segments were
observed), queue high-water 200 chunks (≈20 s) so the longest decode never drops
audio.

## Current status
- Current gate: `G2 — Client dictation surface` closed (settings surface deferred to G6 by owner decision); v1 closes locally at G3.
- Remaining work: G2 then G3 (v1, local macOS). G5 (generic streaming engine) follows v1. G0b (Nawah) is deprioritized pending a sherpa-packaged Arabic artifact. Hosted delivery is not tracked in this public plan.
- Uncommitted at handoff: G1 daemon runtime, catalog, store, settings, session, route, capability, 39 tests, probe tools.
- Open owner decision: hosting URL for the Egyptian ONNX artifacts (see "Open decision"); the light public model unblocks the full download path meanwhile.
