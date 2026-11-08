# Local Dictation — Mic Button with Transcript in the Composer

## Goal
A composer mic button sends microphone PCM to the agent daemon, the daemon transcribes it
locally, and transcript events stream back into the composer. No cloud provider is involved.

## Locked decisions
- **Ownership:** transcription runs only in the daemon. The client captures PCM, sends it,
  renders events, and inserts text at the caret. The client never runs a model.
- **Engines by capability:** whisper.cpp is the **batch** runtime, sherpa-onnx is the
  **streaming** runtime. A model is treated exactly as its own `mode` declares; faking live
  text from a growing buffer is forbidden.
- **In-process only:** no sidecar, subprocess, CLI, or local HTTP server performs transcription.
- **Transport:** `/ws?type=dictation&session_id=…&device_id=…` with the Local Gateway credential;
  client → daemon audio is 16 kHz mono PCM16 LE.
- **Event contract:** `partial` (mutable, monotonic `seq`, replaces its own range) and `final`
  (terminal, once per `seq`). Batch emits one final at stop; streaming emits partials live.
- **Models are never bundled.** The daemon owns them under `Sanad Home/models/stt/<id>/`, verified
  by pinned SHA-256 with atomic activation; download is explicit on first press.
- **`config.yaml` overrides the catalog:** `stt.enabled`, `model_id`, `model_path` (wins, no SHA),
  `language`, `threads`, `use_gpu`, `model_idle_minutes`.
- **Routing has one owner:** `DictationTransportResolver`; cloud relay is a separate task.
- **Privacy:** logs carry metadata only — never audio, transcript text, credentials, or paths.
- **Capability contract:** `supports_dictation` means "enabled and valid for this agent"; transient
  readiness lives only in the live `stt_status`, never in capabilities (computed at connect).

## Gates

### G0 — Discovery and feasibility
- [x] `sherpa_onnx` resolves in `agent`; `dart compile exe` still builds the daemon.
- [x] In-process load on macOS arm64 proven with zero Flutter imports (`tool/stt_probe.dart`).
- [x] Egyptian checkpoint exported to sherpa ONNX int8 with pinned sizes and SHAs.
- [x] Light base model resolved from the public sherpa tree with pinned SHAs.
- [x] Arabic fixture decoded; transcript matches the ggml reference.
- [x] Hard limit recorded: sherpa whisper accepts < 30 s per decode → segmentation is mandatory.

### G1 — Daemon dictation runtime
- [x] `infrastructure/stt/`: types, engine contract, isolate worker, no Flutter imports.
- [x] Worker: `OfflineRecognizer` + VAD, typed errors, no transcript in logs.
- [x] Catalog: data-only entries with url/size/sha256, language, mode, hosted flag.
- [x] Model store: streamed download, SHA + size verification, `.partial` staging, atomic rename.
- [x] Settings: `enabled`, `model_id`, `model_path` (override wins), `language`, `threads`.
- [x] Session: one per socket, bounded queue with counted drops, 5-minute cap, idempotent stop.
- [x] `type == 'dictation'` route beside `voice`, same Local Gateway credential.
- [x] Events: `stt_status`, `stt_download_progress`, `dictation_ready|partial|final|done|error`.
- [x] Capabilities: `supports_dictation` + `dictation_unavailable_reason`; voice caps untouched.

### G2 — Client dictation surface
- [x] One routing owner: `DictationTransportResolver` decides the transport.
- [x] `DictationCubit` (lifecycle, transport, model state, errors) + capture on 16 kHz PCM16.
- [x] Composer mic button with recording/processing states and localized tooltips.
- [x] Live insertion at the caret; partials replace their own range; manual edits are never overwritten.
- [x] Cancel removes the whole session range; stop keeps the committed text.
- [x] First-use sheet for model choice + download consent with progress.
- [x] English + Arabic strings only, no inline literals.
- [ ] Settings surface — **deferred to G6**; until then `stt.enabled` is the only switch.

### G6 — Device settings: Dictation section (deferred)
- [ ] Add a Dictation section to the device settings page (model + size, enable toggle, reason).
- [ ] Every change goes as a command over the existing connection layer; no client-side file edits.
- [ ] The daemon persists and re-advertises the capability; the client only reflects it.
- [ ] Enable toggle needs one new settings command plus daemon persistence and tests.

### G2b — Parity hardening from the Hermes study
- [x] Pre-session audio buffered and flushed after `session.start()` (nothing lost).
- [x] IME-safe insertion: writes deferred during composition, caret offsets preserved.
- [x] Session bound to its composer scope; switching conversations cancels and drops the range.
- [x] Visible feedback: `no_speech`, elapsed counter with the 5-minute mirror, denied/busy notices.
- [x] One undo step per session: cancel restores the pre-session text in one write.
- [x] One dictation lease per daemon; a second session is refused with `dictation_busy`.

### G2c — Live-test findings
- [x] Install progress owned by the cubit (survives rebuilds), with percentage and localized label.
- [x] Cumulative progress across the shared VAD and all catalog files.
- [x] Press policy: one press starts when ready, otherwise opens the sheet; long press always opens it.
- [x] No auto-select after download.
- [x] Egyptian ggml model published and set as the default entry.
- [ ] Dedicated tests for install-progress state transitions (partially covered by the current suite).

### G2d — Single-pass batch and state-driven mic (delivered via G7/G5b)
- [x] Model `mode` reaches the client through `stt_status`.
- [x] Batch decodes once at stop; exactly one `dictation_final` then `dictation_done`.
- [x] Streaming feeds the recognizer per chunk and publishes partials.
- [x] Session cap enforced (5 minutes) with the existing `session_limit` error.
- [x] Insertion anchored at the caret captured at session start.
- [x] Mic UI is state-driven with the level meter inside the button; preview switch removed.

### G7 — whisper.cpp engine behind the catalog
- [x] `SttCatalogEntry.engine` (`sherpa` | `whispercpp`); the resolver picks the implementation.
- [x] `dart:ffi` binding to `libwhisper` behind the existing `SttEngine` contract.
- [x] ggml artifacts hosted with sha256 and installed by the same store.
- [x] Threads and decode parameters mapped through the shim; log callback silenced.
- [x] Acceptance: same transcript quality, RSS below 1.6 GB, load below 0.7 s, decode within budget.
- [x] Metal build (`GGML_METAL=ON`) with `use_gpu` and automatic CPU fallback.

### G5 / G5b — Streaming path
- [x] Streaming adapter over `OnlineRecognizer`, selected by `mode: streaming`, same worker/contract.
- [x] Real streaming entries installed through the hosted path with pinned SHAs.
- [x] `modelType` travels with the entry (`zipformer2`), fixing the metadata failure.
- [x] `sherpa_onnx 2.0.1`; the 20M build retired and resolvable but never selectable.
- [x] Measured through the daemon: first partial ≈1.2–2.0 s, correct first word, no audio loss.
- [x] Owner rule recorded: a model's capability decides its treatment (no pseudo-streaming).

### G0b — Nawah (NeMo TDT, Arabic)
- [x] Probed: not sherpa-packaged, blank convention differs, not streaming (~80 % quality).
- [ ] Closed unless a sherpa-ready Arabic streaming artifact appears; no hand-written ONNX surgery.

### G3 — Documentation, verification, delivery
- [x] `docs/technical/local_dictation.md` plus a pointer from `voice_streaming.md`.
- [x] `docs/llms.txt`, `docs/product/features.md`, and agent/client `AGENTS.md` updated.
- [x] Analyzer clean and focused tests green in both projects.
- [x] Live acceptance on macOS arm64 (owner pass 2026-11-08 against the test home).
- [x] Bounded evidence recorded; no audio or transcript in the daemon logs.
- [x] Graph maintenance ran for changed code.
- [ ] Commit + PR with owner approval (in progress).

### G8 — Mic button on every surface (redefined 2026-11-08)

Owner decisions:
- The mic is **never hidden**. Permanent states render it inactive with an explanation that opens
  `dictation_model_sheet`; transient states (preparing, install failure) keep it usable.
- **No toast** for dictation lifecycle states: the sheet is the only surface.
- Visibility follows the **agent** capability; the client never hardcodes a platform.
- macOS Intel support is a **separate follow-up after G8**; cloud relay is out of scope here.

- [x] Capability contract stays config/platform only; transient state lives in `stt_status`.
- [x] Composer renders the mic whenever an active agent exists; capability drives styling only.
- [x] Daemon command `prepareRuntime` runs `ensure_native_stt` detached (log `native/.stt-prepare.log`).
- [x] Sheet status row: ready / preparing / missing ("تجهيز الآن") / failed / disabled.
- [x] Mic keeps the send button's **32×32** footprint with symmetric gaps (8 px wide, 4 px compact).
- [x] Web: no `dart:io` in the dictation path; `flutter build web` clean in 34 s (`record-use`).
- [x] Permission declarations verified: macOS entitlements + `Info.plist`, iOS `Info.plist`,
      Android `RECORD_AUDIO`; Windows/Linux use the OS privacy setting.
- [x] Client test: button reacts to the daemon capability, not a platform check
      (`conversation_input_composer_toggle_test.dart`: `supportsDictation: false` + active agent ⇒ mic rendered).
- [x] Live permission pass on macOS (owner, 2026-11-08).
- [ ] Live permission pass on Windows/Linux/web/mobile.
- [x] `native-stt` green on macOS, Linux and Windows (run 42458788755) and listed in `all-required`.
- [x] Branch merged with `main` and `ci.yml` conflicts resolved.

### G9 — App-wide toast (done 2026-11-08)
- [x] Dictation notices use `ToastUtils.showInfo`; no `SnackBar` in the feature.
- [x] Last two client sites (schedules run-failure and refused action) moved to `ToastUtils`.
- [x] Rule recorded in `client/AGENTS.md`; tests assert through `debugOnShowError`/`debugOnShowInfo`.

## Measurements (macOS arm64, owner machine)

| Metric | Value |
|---|---|
| Decode before Metal (6 s Arabic, q8) | 3531 ms |
| Decode with Metal (daemon session) | **1082–1141 ms** |
| Probe: Metal vs CPU, 4 threads | 1615 ms vs 4110 ms (same transcript) |
| Idle unload (`model_idle_minutes: 1`) | unloaded at 60 s, footprint 622 MB |
| Thread curve (4 / 5 / 6 / 8) | 1607 / 1060 / 1069 / 1049 ms |
| Daemon RSS, listening with q8 | ~1.2 GB (vs 2.4–3.0 GB on sherpa int8) |
| Tests | agent **77** STT, client **12** dictation widgets, **60** schedules |

## Architecture facts

- **Daemon:** `dictation_service.dart` (readiness, status, residency), `dictation_session.dart`
  (queue, caps), `stt_engine.dart` + `stt_isolate.dart` / `whispercpp_isolate.dart` (workers),
  `stt_catalog.dart`, `stt_model_store.dart`, `stt_settings.dart`, `whispercpp_bindings.dart`.
- **Client:** `features/dictation/**` (cubit, resolver, capture, sheet, mic button) and
  `composer_container.dart` (row layout).
- **Residency:** warm between sessions, unload after `stt.model_idle_minutes` (default 5; `0` =
  immediately, negative = daemon lifetime), both engines via `acquireEngine`/`releaseEngine`.
- **Threads:** `sttThreadsFor(cores)` = `min(4, cores)` under eight cores, **6** from eight up.
- **Speech gate:** scale-invariant (`peak >= 0.004`, `crest >= 3.5`) plus decode gain to `peak=0.85`.
- **Catalog:** `egy-whisper-turbo-ggml-q8` (default), `-q5`, `-f16`, `whisper-base-int8`, plus
  streaming `en-streaming-zipformer-kroko-2025-08-06` and `multilingual-streaming-zipformer-2025-02-10`.

## Platform scope and binaries

- Targets: macOS arm64, Windows x64/arm64, Linux x64/arm64; loader picks
  `libsanad_whisper.dylib` / `sanad_whisper.dll` / `libsanad_whisper.so` (`SANAD_WHISPER_LIBRARY` override).
- **Verified:** macOS arm64 locally; Windows x64 and Linux x64 compile in CI (`native-stt` green on
  `ubuntu-24.04`, `macos-26`, `windows-2025`). ARM runners are not exercised yet.
- **Binaries are not tracked.** `.gitignore` excludes `agent/native/*/*.{dylib,so,dll}`;
  `tool/ensure_native_stt.dart` verifies checksums → downloads (`--base-url`) → builds from a
  discovered or `--whisper-src` tree → else exits 2 with instructions. It refuses incomplete builds,
  writes `native/.stt-preparing` while working, and the dev CLI starts it detached on `run`.
- Six dylibs removed from the index still exist in older commits; history rewrite is required
  before merge (owner approved).

## Later tasks (owner-requested)

- A genuinely accurate English streaming model (keep the multilingual entry untouched; probe first).
- Daemon idle-memory work: measure AOT vs JIT first, then an old-gen heap cap, then post-session retention.
- [ ] After G8: `macos-x64` (Intel) — build job, checksums, artifact, platform gate. Recorded here
      deliberately: it is a separate follow-up, not dropped.
- Optional: shard `Test client`; default to `q5` on low-RAM devices; owner's verdict on the
  composer-wide meter (it paints: `shifts=181 max=0.506`).
- Separate task: cloud relay for dictation (`voice02-dictation-cloud-relay.md`); local relay is done.

## Definition of done

Analyzer and focused tests green in `agent` and `client`; batch/streaming contracts documented and
enforced by each model's own capability; live macOS acceptance recorded; the native runtime is
reproducible from a clean clone on every supported OS (green `native-stt`); no binaries in history;
no audio/transcript in logs; delivery only after explicit owner approval.
