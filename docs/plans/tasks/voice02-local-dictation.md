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
- **Hosting for the Egyptian ONNX artifact — decided (owner, live-test follow-up).** The light model already reuses the public `csukuangfj/sherpa-onnx-whisper-base` repository; nothing new is published for it. The Egyptian fine-tune upstream (`mohammedaly22/whisper-large-v3-turbo-egyptian-code-switching`) is public but ships PyTorch weights only, so sherpa cannot consume it. Decision: publish our exported ONNX in a dedicated public Hugging Face model repo under the org (`EastStarAI/sanad-egy-whisper-turbo-int8`, ~989 MB: encoder 674,622,359 B, decoder 361,070,805 B, tokens 816,730 B, plus the shared `silero_vad.onnx`), free and fully under our control, with the pinned SHA-256 digests already recorded in G0. Optional later: propose the same folder upstream so the fine-tune repo also carries the sherpa artifacts. Until the repo is published the catalog keeps `hosted: false` and `stt.model_path` stays the supported local path.
- **No automatic model selection.** After a download completes the user still presses Use; the client never sends `select` on its own.
- **Mic press policy.** One press starts recording when a model is selected and installed; when none is ready it opens the model sheet. Long press always opens the sheet.

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

### G2b — Parity hardening from the Hermes reference study (owner-approved, six items)
Reference: `refrence_projects/hermes-agent` (`use-voice-recorder.ts`, `stt-lease.ts`, `use-composer-draft.ts`, `undo-history.ts`, `voice-activity.tsx`). Each item closes a verified gap in our v1 surface; order is the implementation order.

- [x] **1. Pre-session audio must not be dropped.** `DictationAudioBuffer` (bounded, 4 MiB) holds socket frames until `session.start()` and flushes them in arrival order; flushed chunks and dropped bytes are logged as counts only. Flushed only after `session.start()` subscribes, so no frame is lost either side of the model load.
- [x] **2. Insertion safety: never break IME or steal the caret.** `DictationInsertion` defers writes while `composing` is live and replays them when composition ends (the button listens to the controller), and `_adjustSelection` shifts offsets by the replaced-range delta instead of collapsing the caret — a caret inside the range follows it, a caret outside never moves.
- [x] **3. Bind the session to its scope.** `DictationMicButton.scopeKey` (the conversation id) cancels the live session and drops the owned range when the composer switches conversations, and the controller/scope changes reset local insertion state; async UI callbacks re-check `mounted`.
- [x] **4. Feedback the user can see.** Localized `no_speech` (a drain with zero segments and no text), a visible `m:ss` elapsed counter with the client mirroring the 5-minute cap (`stopForLimit` → `session_limit`), localized `microphone_denied`/`dictation_busy` snackbars, and focus returned to the composer when the session settles.
- [x] **5. One undo step per dictation session.** Cancel removes the whole session range in one write, returning the composer to its pre-session text; edits the user made outside the range are untouched (covered by widget and insertion tests). No client-side undo stack exists to integrate with, so the session is its own unit.
- [x] **6. One dictation lease per daemon.** `DictationService.acquireSession()/releaseSession()` allows a single session; a second one is refused with `dictation_busy`, the lease is released on teardown and on engine-start failure, and `stt_status` advertises `busy`.

### G2c — Live-test findings (owner-reported, in progress)
Reported while testing the running build: no visible download state, the sheet reopening on every press, and the hosted-model question.

- [x] **Install progress is owned by the cubit, not the sheet.** `DictationModelStatus.installingModelId` is set when `install` is sent and cleared only when `stt_status` reports that model installed or a `dictation_error` arrives, so the bar survives rebuilds; the tile shows a spinner plus a percentage and a localized "Downloading…" label.
- [x] **Cumulative progress in the daemon.** `SttModelStore.install` counts the shared VAD plus every catalog file into one grand total and reports `offsetBase + received` against it, so the bar rises monotonically instead of restarting per file.
- [x] **Mic press policy.** One press starts recording when the selected model is installed; when nothing is ready it opens the sheet, and a long press always opens it. The sticky `sessionNeedsFirstUseSheet` flag no longer drives the button, so a completed install cannot re-open the sheet on every press.
- [x] **No auto-select after download** (owner decision): the user still presses Use.
- [x] **Publish the Egyptian ONNX** and flip the catalog entry to `hosted: true`. Done 2026-11-05: public repo `AhmedAttia3/sanad-egy-whisper-turbo-int8` (MIT, model card, three artifacts with pinned sizes/SHAs); a clean-home download verified 1037 MB at 2.8 MB/s with checksum match. `EastStarAI` does not exist on the Hub (404) and the token cannot create orgs, so the namespace is the owner's account until the org is created and the repo transferred (one URL edit here).
- [ ] Tests for the new state (install start → progress → completion clears; press policy with and without a ready model).

### G2d — Single-pass batch, cursor insertion, state-driven mic UI (owner-corrected 2026-11-05)

Live testing showed the chunked attempt itself is the defect: a 4 s forced cut lands in
mid-word, so each segment decodes from a broken boundary and the composer receives
fragmented text. The owner rejected that behaviour: a model either streams, or receives
the whole utterance once.

- [ ] **Engine contract carries the capability.** `SttCatalogEntry.mode` (`batchVad` | `streaming`) plus `supportsPartial` reach the client through `stt_status`, so the UI picks the interaction per model instead of assuming one.
- [ ] **Batch = one decode, at the end.** The daemon buffers the whole session audio (16 kHz mono PCM16) up to the cap and decodes once on `stop`; no forced cut, no mid-speech `partial`/`final`, exactly one `dictation_final` (empty when nothing was recognized) followed by `dictation_done`. The 4 s cut and the segment cadence are removed, not tuned.
- [ ] **Streaming = one decode loop, live text.** A `mode: streaming` entry feeds `OnlineRecognizer` chunk by chunk and publishes incremental text; the client renders it in place.
- [ ] **Session cap by bytes** (5 minutes of PCM16 ≈ 9.6 MB) with the existing `session_limit` error, since unbounded buffering is the one new risk of single-pass.
- [ ] **Insertion anchored at the caret.** The insertion range is captured at session start and the final text is written there once; nothing accumulates across sessions and user text before/after the caret is untouched.
- [ ] **Mic UI is state-driven.** No elapsed timer: `loading` while the model readies → `ready/listening` with the loudness meter **drawn inside the mic button** (log-scale level, ~16 Hz) → `loading` again from stop until the transcript lands in the composer.
- [ ] **Preview policy control removed** (owner decision 2026-11-05): the sheet's Live/When-stopped switch promised a behaviour the batch path no longer has. `previewPolicy` stays internal (live by default) so a streaming model renders partials without any UI change.
- [ ] Tests: daemon (single decode, no partial for batch, cap), cubit (one final, no partial for batch, insertion offsets), widget (no timer key, three-state affordance, text lands at the caret with surrounding draft preserved).

### G7 — whisper.cpp engine behind the catalog (owner-requested 2026-11-05)

**Why.** sherpa-onnx copies the full int8 weights into RAM and keeps one arena
per thread: peak RSS for the Egyptian turbo model is 2.4–3.0 GB at 6 threads.
Handy, using whisper.cpp with the same model, peaks at ~1.5 GB because ggml
weights are `mmap`ed and there are no per-thread arenas. Owner priority: the
agent also runs on low-resource machines, so memory is a first-class constraint.

**Scope (in-process only, no sidecar/CLI/HTTP).**
1. `SttCatalogEntry.engine` (`sherpa` | `whispercpp`), default `sherpa`; the
   resolver picks the implementation, nothing else in the daemon changes.
2. `dart:ffi` binding to `libwhisper` (init from file, full params, full,
   segment text, free) behind the existing `SttEngine` contract, so
   `DictationSession` keeps its event vocabulary.
3. ggml artifacts hosted next to the ONNX ones (turbo `q5_0` ≈574 MB, `q8_0`
   ≈874 MB) with sha256 in the catalog, installed by the same store.
4. Threads from `stt.threads`; `enableTokenTimestamps`/`tailPaddings` mapped to
   the whisper params we already tuned.

**Acceptance.**
- Same transcript quality as G2d on the Egyptian fixture (word-for-word check of
  the recorded sample).
- Peak RSS during a 30 s decode **below 1.6 GB** (vs 2.4–3.0 GB today) measured
  by `stt_probe` on the same machine.
- Load time below 0.7 s (mmap) and decode not slower than RTF 0.55 on 6 threads.
- `agent` tests green including a fake-engine test of the catalog switch, and
  no change in client behaviour (client is engine-agnostic by design).

**Rollback.** The engine is chosen per catalog entry; deleting the entry (or
flipping `engine` back to `sherpa`) restores today's behaviour with no code
revert. If the FFI binding proves unstable, drop the binding commit — the
`engine` field and the sherpa path stay intact.

**Risk.** Native crashes under FFI, per-platform library builds (macOS arm64
first, Linux/Windows later), and losing sherpa's ready-made silero VAD (the
batch path does not need VAD, so this is acceptable for v1).

### G5 — Streaming path proven with a light English model (owner-approved, after G2d)
- [ ] `StreamingSttEngine` adapter over sherpa `OnlineRecognizer`, selected by `mode: streaming`; the worker isolate is reused and no transport/UI fork is introduced.
- [ ] Catalog entry with `mode: streaming` pointing at a public, sherpa-packaged, light English streaming model (English-only is acceptable and expected; no Arabic streaming model exists in sherpa today), installed through the same hosted download path.
- [ ] Live A/B evidence: the streaming entry shows live text in the composer while the Arabic batch entry lands one text block at stop, both inserted at the caret.
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
- [ ] Given a batch model, when the user stops the session, then exactly one `final` carries the whole utterance and no text was published mid-speech.
- [ ] Given any model, when the transcript lands, then it starts at the caret captured at session start and leaves the user's surrounding draft untouched.
- [ ] Given a streaming model, when the user speaks, then partial text updates in place and the final replaces it without duplication.
- [ ] Given a dictation session, when the model is readying or the transcript is still being drained, then the mic shows a loading affordance, and a voice visualization only while audio is being captured (no elapsed timer).
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
- Current gate: **G7** (whisper.cpp engine behind the catalog) — G2d is
  committed as `d8497896` after live acceptance (full transcript, meter, send
  waits for the transcript). G5 (English streaming proof) and G3 close v1.
- Memory baseline to beat (macOS arm64, Egyptian turbo int8): daemon idle 46 MB,
  listening 448 MB, one model in a clean process 1.5–1.8 GB, peak with 6
  threads + daemon ≈2.4–3.0 GB. Handy/whisper.cpp reference: ~1.5 GB.
- Remaining work: G7 then G5 then G3 (v1, local macOS). G0b (Nawah) is
  deprioritized pending a sherpa-packaged Arabic artifact.
- TEMP diagnostics still enabled (`dictation level window`, `dictation audio
  window`, `dictation final: audio_ms`) — removed in G3 after G7 acceptance.
