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
- [x] `StreamingSttEngine` adapter over sherpa `OnlineRecognizer`, selected by `mode: streaming`; the worker isolate is reused and no transport/UI fork is introduced. Implemented inside the existing worker (`_initStreaming`, `_streamAudio`, `_closeStreamingSegment`, `_finishStreaming`); the engine only gained a `partial` message case, so the daemon/UI contract is unchanged.
- [x] Catalog entry with `mode: streaming` pointing at a public, sherpa-packaged, light English streaming model (English-only is acceptable and expected; no Arabic streaming model exists in sherpa today), installed through the same hosted download path. Entry `en-streaming-zipformer-20m` (45 MB, 4 pinned files, sha256 verified); installed in-app-style with `tool/stt_install.dart` at 2.7 MB/s and `installed: true`.
- [x] Live A/B evidence: the streaming entry shows live text in the composer while the Arabic batch entry lands one text block at stop, both inserted at the caret. Measured over the daemon socket (`tool/stt_daemon_ab.dart`, same `ws?type=dictation` transport the client uses) — see the G5 evidence table below.
- [x] Explicitly excluded: model-specific ONNX surgery for third-party exports (see G0b).
- [x] Consequence recorded: streaming works through sherpa, so sherpa is no longer a removable fallback — it is the streaming runtime, and whisper.cpp stays the batch runtime. Deleting either would remove a capability.

### G5b — Runtime upgrade and a real streaming model (owner decision 2026-11-06)
- **Owner rule, permanent:** a model's capability dictates its treatment. A batch model is transcribed as batch; a streaming model is fed as a stream. Pseudo-streaming (decoding a growing buffer to fake live text) is explicitly rejected and must never be reintroduced.
- **The mistake named by the owner:** pinning `sherpa_onnx ^1.13.4`. That runtime cannot read the metadata of current streaming exports (`attention_dims` / `encoder_dims`), which is why G5 fell back to the weakest available model (`en-streaming-zipformer-20m`) instead of the intended `sherpa-onnx-streaming-zipformer-en-2023-06-26`.
- [x] Upgrade `sherpa_onnx` to `^2.0.1` (published 2026-10-26); `dart pub get` resolved 10 dependencies and `dart analyze` is clean with **no source change** (the `Online*` API we use is unchanged).
- [x] **Real root cause found while loading the intended model:** the runtime version was not the blocker. `sherpa-onnx-streaming-zipformer-en-2023-06-26` is a **zipformer2** export, and our worker hard-coded `modelType: 'zipformer'` (the dialect of the 20M build), so sherpa parsed the wrong metadata keys and refused with `'attention_dims' does not exist in the metadata`. With `modelType: 'zipformer2'` the same model loads and transcribes correctly. The model type now travels with the entry: `SttCatalogEntry.streamingModelType` → `SttModelFiles` → worker `init` payload.
- [x] Added `en-streaming-zipformer-2023-06-26` (left-64 int8: encoder 71,082,637 B `0d072fd4…`, decoder 1,307,236 B `98da299f…`, joiner 259,335 B `d944208d…`, tokens 5,048 B `49e3c264…`; total 72,654,256 B) and installed it through the normal hosted path.
- [x] Measured end to end through the daemon (`tool/stt_daemon_ab.dart`, 6.6 s WAV): `ready load_ms=432`, **first partial after 1.52 s** with the correct opening word, 16 partials, one final, `audio=6625ms` — i.e. no audio loss and no missing first word, versus 3.5–5 s and `"Hello world" → T` before.
- [x] Retired the 20M build: still in the catalog (hidden) so an old install resolves its files, and the selection guard falls back to the default when a hidden entry is the stored choice, so it can never remain active.
- [x] Keep the two engines as they are: whisper.cpp = batch runtime, sherpa = streaming runtime. Both engines and both model kinds stay supported — that is the task's goal.

### G0b — Nawah (NeMo TDT, Arabic) — deprioritized
- [x] Probed `oddadmix/Nawah-ASR-60M-Max-Arabic-ONNX` (69 MB int8). Not sherpa-packaged: the encoder lacks the `vocab_size` metadata sherpa requires, the blank convention is inverted (`<blk>` is id 0 inside the vocab while sherpa expects `1024` as the last `tokens.txt` line), and the encoder consumes full-context features, so it is not streaming despite the transducer architecture.
- [ ] Decision: **model-specific work is not worth it** (~80% quality). Revisit only if an Arabic *sherpa-packaged* streaming/light model appears, or a chunked-encoder export with sherpa metadata is published. This gate closes on such an artifact, never on hand-written ONNX surgery.

### G3 — Documentation, verification, delivery
- [x] New `docs/technical/local_dictation.md` (ownership, transport, event contract, model lifecycle, platform gate) and a pointer from `docs/technical/voice_streaming.md`.
- [x] Update `docs/llms.txt`, `docs/product/features.md`, and the `agent`/`client` AGENTS.md ownership lines.
- [x] `fvm dart analyze` and `fvm flutter analyze` clean; focused tests green in both projects (agent `test/stt` 53 passed, client dictation 34 passed).
- [ ] Live acceptance via `sanad-dev` on macOS arm64: press the mic, speak Arabic, watch text appear and finalize, verify draft preservation on cancel and on model failure. — daemon path proven with real audio over the same socket; the microphone half needs the owner in front of the machine.
- [x] Bounded live evidence recorded (first-final latency, RTF, RSS, load time) with no audio/transcript logging in the daemon.
- [x] Graph maintenance per `graphify` rules when code files change (repo graph rebuilt: 43,984 nodes / 63,787 edges).
- [ ] Commit inside the worktree with the `sanad-agent@eaststarai.com` identity and a plan-referenced message; open the PR with verification results.

### G8 — Mic button on every surface (owner request, 2026-11-05)
- [ ] Client review: `composer_container.dart` gates the button on `capabilities.supportsDictation`; prove the capability comes from the daemon per device, never from a hardcoded platform check in the client.
- [ ] Compact/mobile layout: the button keeps a 44 px tap target and does not overflow the composer row; widget test at compact width.
- [ ] Web: the dictation path imports nothing from `dart:io` or native bindings; a web build analyzes clean, and the button is either hidden or explains the unsupported reason.
- [ ] Windows/Linux: `supports_dictation` stays false with a reason and the button is not actionable — client test asserts it.
- [ ] Owner decision needed: does dictation follow the **agent device** (a phone paired to a macOS agent can dictate) or the **client surface** (phone never shows the mic)? The daemon capability is per agent, so the current answer is the former; confirm before writing the mobile behaviour.

### G9 — Replace SnackBars with the app-wide toast (owner request, 2026-11-05)
- [x] Dictation notices (`no_speech`, `session_limit`, `microphone_denied`, `dictation_busy`) now use `ToastUtils.showInfo`; no `SnackBar` remains in the dictation feature.
- [ ] Audit the rest of the client for `ScaffoldMessenger.showSnackBar` / `SnackBar(` and move each one to `ToastUtils` (`showInfo` / `showSuccess` / `showError`), keeping the message text and localized strings unchanged.
- [ ] Record the decision in `client/AGENTS.md`: the toast surface owns transient user feedback; a SnackBar is only acceptable where a toast would be hidden (e.g. a full-screen modal barrier), and that exception must be stated at the call site.

## Live debugging session (2026-11-06): meter, batch gate, streaming

Everything below was measured on the owner's machine through `sanad-dev logs`, never guessed.

### The composer meter never drew (fixed)
- `meter ticker started … active=true muted=false tickerMode=true` yet `stopped after 0 ticks`
  and every paint reported `max=0.000`: the `Ticker` never fired in the desktop runtime.
  Replaced it with level-event-driven shifts (no ticker at all).
- That exposed the second fault, thrown and swallowed on every level event:
  `setState() called during build` — the cubit emits while the composer builds. Samples now live in a
  `ValueNotifier` and are delivered from a post-frame callback when the phase is
  `persistentCallbacks`. Measured after the fix: `meter session: shifts=181 max=0.506`, no exceptions.
- Root cause of the earlier edits going nowhere: hot reload cannot change a `State`'s mixin list, so the
  widget silently stopped building. A class-shape change needs `sanad-dev restart client`, not `reload`.

### "No Speech Detected" on the whisper path (fixed, root cause)
- The gate compared the **absolute** share of frames above `0.02` against a fixed threshold. Measured on
  four real sessions: `loudShare` swung 0.024–0.078 while `peak/rms` (crest) stayed 6.8–10.6 in all of them.
  The failing sessions were rejected purely because the microphone level was lower — a gain-dependent gate.
- Fix: `evaluateSpeechGate` in `stt_speech_gate.dart`. Scale-invariant decision (`peak >= 0.004` and
  `crest >= 3.5`) plus `decodeGain` normalising the utterance to `peak = 0.85` before `whisper_full`
  (whisper.cpp has no AGC; sherpa's batch path normalises features internally, which is why the same
  microphone never failed there). 9 unit tests pin the measured numbers, including the two failing sessions.
- After the fix: four consecutive sessions `segments=1` and `dictation final: audio_ms=9400 decode_ms=3177`,
  with `gate passed: peak=0.0795 rms=0.0092 crest=8.66 gain=10.69x`.

### First word lost on the streaming path (diagnosed; model-level)
- Audio is delivered, not lost: `streaming first audio atMs=311 samples=1600`, `audioMs=6000` for a 6 s session.
- The recognizer itself produces nothing for the opening seconds:
  `streaming partial n=1 atMs=3006..4397 chars=1` and an endpoint closing a **1-character** segment.
  Reproduced with "Hello world" → `T`.
- Added a level-normalising AGC to the streaming feed (seeded from the first audible chunk, instant attack,
  15% release). It removed the clipping found in the first version (peak 0.177 × gain 9.08 exceeded full scale)
  but did not change the latency: the 20M English model is the limit.
- Conclusion: the runtime pin was the original fault (G5b). No amount of gain tuning fixes a model that
  cannot parse the export metadata, which is why the runtime is now 2.0.1 and a real streaming model is next.

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

## G7 evidence (2026-11-05, macOS arm64)

Same 25 s Egyptian fixture, same machine, clean process (`tool/stt_probe.dart`
vs `tool/stt_whispercpp_probe.dart`):

| Metric | sherpa (int8 ONNX) | whisper.cpp (ggml q5_0) |
|---|---|---|
| Model load | 1414 ms | **195–335 ms** |
| Decode (25 s audio) | 13347 ms (RTF 0.534) | **3389 ms (RTF 0.136)** |
| Peak RSS during decode | 1688 MB | **904–960 MB** |
| RSS after free | — | 258 MB |
| Transcript | `الـSocial Media`, `cloud code`, truncated tail | `السوشيال ميديا`, `كلود كود`, full tail |

In the daemon (model loaded per session, threads 6): idle 46 MB, listening
1216 MB with the ggml model (vs 2.4–3.0 GB with sherpa), back to ~580–670 MB
after the session (allocator retention, flat across sessions — no leak: a second
session starts from the same floor instead of doubling).

Findings that shaped the implementation:
- whisper hallucinates text on silence; the worker now gates on mean amplitude
  (`_speechFloor = 0.004`) and a silent session ends with `segments=0`.
- whisper.cpp prints model-load lines to stderr; the shim silences its log
  callback so the daemon never logs audio or transcript content.
- The ggml artifacts are the official multilingual turbo, not the Egyptian
  fine-tune, and the transcript came out equal or better on the same sample.

Artifacts: `agent/native/macos/` (2.2 MB: shim + whisper + ggml), rebuilt by
`agent/tool/build_whispercpp.sh <whisper.cpp-src>`. Trial without a catalog
download: `stt.model_path` pointing at a directory that holds one `.bin`.

## G7 hosting and default (2026-11-05, later the same day)

`AhmedAttia3/sanad-egy-whisper-turbo-ggml` now hosts the Egyptian model in ggml
form, built from the f16 checkpoint Handy runs:

| Artifact | Size | Peak RSS | RTF | Diff vs f16 |
|---|---|---|---|---|
| `ggml-egy-turbo-q8_0.bin` | 874 MB | 1.19 GB | 0.154 | 1 word |
| `ggml-egy-turbo-q5_0.bin` | 574 MB | 0.95 GB | 0.136 | 4 words (diacritics, Latin casing, one trailing word) |

`egy-whisper-turbo-ggml-q8` is the catalog default (engine `whispercpp`), with
`q5` as the low-memory option and the ONNX int8 entry kept as the sherpa
fallback until G5 decides whether streaming needs sherpa at all. The in-app
install path was verified against the real host: 874 MB at 3.5 MB/s, sha
checked, activated, next session on the new model.

## G5 evidence (2026-11-05, macOS arm64)

Same audio pipeline, same daemon, same socket (`ws?type=dictation`), one variable:
the model. Both runs sent 100 ms frames paced like a live microphone.

| Model | Partials | First partial | Finals | Wall for audio |
|---|---|---|---|---|
| `en-streaming-zipformer-20m` (streaming) | **16**, growing word by word | 1535 ms | 1 at stop (same `seq` as the last partial) | 7.8 s / 7.0 s audio |
| `egy-whisper-turbo-ggml-q8` (batch) | **0** | — | 1 at stop (whole utterance) | 16.6 s / 10.7 s audio |

- Streaming load: 224 ms, RSS 392 MB (Dart VM included), artifact 45 MB.
- Streaming transcript of the English sample: "…THIS IS A LIVE STREAMING
  DICTATION TEST THE WORDS SHOULD APPEAR WHILE I AM STILL SPEAKING NOT AFTER I
  STOP" — the final replaced the partial, nothing duplicated.
- Batch transcript of the Arabic sample: "هذا اختبار للأملاء الصوتي المحلي، النص
  يجب أن يظهر كاملا بعد التوقف، وليس أثناء الكلام." (TTS audio; the voice
  mispronounces إملاء as للأملاء).
- f16 Arabic artifact: rebuilt from the source h5 (h5 → ggml → f16), uploaded to
  `AhmedAttia3/sanad-egy-whisper-turbo-ggml` as `ggml-egy-turbo-f16.bin`, and
  verified against the hosted LFS digest: 1 624 555 275 bytes, sha
  `917a13f15b240a1948f2cddc226e2a197b28efdca67b3b1c53cd1f9a960690a8`. Local
  load 415 ms, RTF 0.280, RSS 1959 MB, correct Arabic transcript. The catalog
  entry «المصري — أقصى دقة» is visible (`hidden: false`).
- The streaming entry is visible and labelled تجريبي so it is never mistaken for
  the Arabic default; if the owner prefers a three-model sheet it flips to
  `hidden: true` without touching code paths.
- Accuracy note from the owner's test: the 20M model renders "Hello, this is …"
  as "o this is …" — a model limitation, not a code one. Two better English
  streaming exports (`sherpa-onnx-streaming-zipformer-en-2023-06-26`, left-64 and
  left-128, 72 MB) were tried and rejected: both fail to load in sherpa 1.13.8
  with `'attention_dims' does not exist in the metadata`, and patching ONNX
  metadata is explicitly out of scope (G5/G0b). The 20M model stays as the proof
  entry.
- Owner-test fixes after the first streaming session: streaming text is
  normalized to sentence case (zipformer emits upper case), the client appends
  finals instead of replacing the transcript (each silence-closed segment used to
  wipe the previous words), the no-speech notice is a toast instead of a SnackBar,
  and the sheet shows a «بث مباشر / Live» badge on streaming entries.

## Decisions taken in the 2026-11-05 session (all owner-approved)

1. **Engine**: whisper.cpp replaces sherpa as the default runtime. sherpa stays
   behind the `engine` field as a fallback until G5 decides whether real
   streaming needs it; if G5 lands with whisper windows, sherpa is deleted.
2. **Model set shown to users**: three entries, each note stating the memory it
   costs — `egy-whisper-turbo-ggml-q8` (default, ~1.2 GB), `egy-whisper-turbo-ggml-q5`
   (~0.95 GB), `whisper-base-int8` (~0.76 GB, lowest accuracy).
   `egy-whisper-turbo-ggml-f16` (~1.9 GB, unquantized) is catalogued but
   **hidden until its 1.6 GB artifact is uploaded**; the ONNX int8 and the
   multilingual turbo entries are hidden fallbacks reachable through
   `stt.model_id`.
3. **No persistent model load**: the model loads on session start and is freed
   on stop. Reloading per session is the accepted cost (1.1–1.5 s sherpa,
   0.2–0.3 s whisper.cpp) instead of holding ~1–2 GB all day.
4. **Noise gate**: a session whose loud-frame share is under 6 % is not decoded
   (whisper hallucinates on silence).
5. **Composer meter (experiment)**: the dictation level is painted across the
   whole composer card while listening; owner verdict pending, revert is one
   line (drop the `ClipRRect`/`Stack` wrapper in `composer_container.dart`).

## Open items and follow-ups (state at 2026-11-05)

- [x] Upload `ggml-egy-turbo-f16.bin` (1.6 GB) to the ggml repo, verify the sha,
      then flip `hidden: false` on `egy-whisper-turbo-ggml-f16` — done 2026-11-06:
      1,624,555,275 bytes, sha `917a13f1…0690a8` matches the hosted digest, entry visible with a test.
- [ ] G5b: load the 2023-06-26 streaming model on `sherpa_onnx 2.0.1`, measure the first partial, then
      decide the fate of `en-streaming-zipformer-20m`.
- [ ] Decide whether the prebuilt dylibs stay in git (`agent/native/macos`, 2.2 MB,
      requires the `release-reviewed` label on every PR) or are built in CI from
      whisper.cpp source (~2 min per build, clean repo).
- [ ] Owner verdict on the composer-wide meter; it now paints (`meter session: shifts=181 max=0.506`)
      and the remaining question is aesthetic only.
- [ ] Optional CI speed-up: shard `Test client` into two parallel jobs
      (~5 min wall instead of ~9).
- [ ] Optional: default to `q5` instead of `q8` on devices with little free RAM.

## Verification facts recorded this session

- **Client CI job history** (same workflow, `Test client` step in brackets):
  2026-10-21 `6a832396` **5m15s** (189 s) · 2026-10-21 `7955d2d5` 7m10s (270 s) ·
  2026-10-23 `4068255f` 11m51s (219 s) · 2026-10-24 `cb9df614` 8m21s (288 s) ·
  2026-11-01 `23cfb0bc` 8m35s (308 s) · 2026-11-04 `5a0afc56` 9m15s (339 s) ·
  2026-11-05 `aea502cf` 9m45s (351 s).
  Cause of the jump, measured not guessed: client test files went **188 → 243 →
  247** (`client/test/**/*_test.dart`) between Oct 21 and Oct 24 (the SRP
  refactor series), and the `Web startup composition` step (34–67 s) appeared in
  the same window. The voice work added 3 tests, so it did not cause the rise;
  the spread between neighbouring runs is runner variance.
- Two client regressions were introduced and fixed within the session: the send
  path read `DictationCubit` unconditionally (ProviderNotFound in every composer
  test, message never dispatched) and the backdrop ticker repeated forever
  (`pumpAndSettle` never settled, 60 fps repaint while idle).
- A bogus `stt.model_path` used to be advertised as an installed model; the
  status payload now resolves the path first and reports `installed: false`.
- PR #337 is green on all platforms (agent, client, CLI automation and
  sanad-dev bootstrap on ubuntu/macos/windows) with `maintainer-reviewed` and
  `release-reviewed` applied.

## Streaming catalog after G5b (2026-11-07)

Two entries were probed offline with `modelType: zipformer2`, installed through the normal hosted path, and
measured end to end through the daemon with `tool/stt_daemon_ab.dart`:

| Entry | Size | Probe | Through the daemon |
|---|---|---|---|
| `en-streaming-zipformer-kroko-2025-08-06` | 71,222,214 B | correct transcript from the first word | `first_partial=2013ms` (load included), 4 partials, 1 final |
| `multilingual-streaming-zipformer-2025-02-10` | 338,633,347 B | Arabic text while the audio plays | `first_partial=1163ms`, 13 partials, 2 finals, Arabic text |

Retired (hidden, still resolvable): `en-streaming-zipformer-20m` and `en-streaming-zipformer-2023-06-26`
(the latter superseded by kroko at the same size after the owner judged it fast-but-inaccurate).

**This closes the "no Arabic streaming model exists" limitation.** Arabic dictation can now run in either
mode, and the rule stands: the model's own capability decides how it is treated.

## Resume here (2026-11-06, end of session — owner closed the machine)

State: committed and pushed on `voice/02-local-dictation`; the test runtime (`~/.sanad-test`) is running.
Working tree clean.

Owner's last finding: the 2023-06-26 streaming model was **fast but inaccurate** for his speech, and he asked
why a tiny model was used. Answer: nothing requires it any more — the small build was forced by the
`modelType` bug, now fixed. Result (implemented and measured, see the section above): kroko replaces it at
the same size, and the multilingual export brings **real Arabic streaming** at 339 MB.

Next actions: the owner's live pass on both new entries (Arabic streaming first), then G3 (docs, verification,
delivery) and the PR. Do not ship a streaming entry that has not been probed.

## Current status
- Current gate: **G5b complete** — `sherpa_onnx 2.0.1`, and the streaming entry is
  `en-streaming-zipformer-2023-06-26` (left-64 int8, 72.7 MB) passing its own `modelType:
  zipformer2`. Measured through the daemon: load 432 ms, first partial 1.52 s, 16 partials, one
  final, no audio loss. The 20M build is retired (hidden) and can never stay selected.
  Next: **G3** (docs, verification, delivery) and the owner's live pass; G6 deferred.
- Engine contract, unchanged and now explicit: whisper.cpp is the **batch** runtime, sherpa is the
  **streaming** runtime; a model is treated exactly as its own capability declares (owner rule 2026-11-06).
- Model sheet today: `egy-whisper-turbo-ggml-q8` (default, ~1.2 GB),
  `egy-whisper-turbo-ggml-q5` (~0.95 GB), `whisper-base-int8` (~0.76 GB),
  `egy-whisper-turbo-ggml-f16` (~1.6 GB, uploaded and visible) and `en-streaming-zipformer-20m`
  (English streaming, ~0.2 GB, known to need ~5 s before its first partial).
- Fixed this session, all measured: composer meter (ticker + setState-during-build), batch speech gate
  (absolute → crest, plus decode normalisation), streaming AGC clipping.
- Test counts now: client 38 dictation tests, agent 73 STT tests (9 of them the new speech gate).
  `dart analyze` / `flutter analyze` clean on both projects.
- Memory facts (macOS arm64): daemon idle 46 MB; listening ~1.2 GB with the
  Egyptian q8 (vs 2.4–3.0 GB on the sherpa int8 path); back to ~0.6 GB after a
  session, flat across sessions (no leak). Egyptian q5 peaks ~0.95 GB, base
  ~0.76 GB, f16 ~1.9 GB.
- Logging contract: metadata only (levels, counts, durations, sizes, gains). Never audio, never
  transcript text. Per-frame logs are summaries — `meter session`, `gate passed/blocked`, `streaming done`.
