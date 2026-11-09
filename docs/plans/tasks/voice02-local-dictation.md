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
- **Routing has one owner:** `DictationTransportResolver`; the hosted channel is a
  separate task whose wire contract is
  [Dictation Transport Protocol](../../technical/dictation_transport_protocol.md).
- **Privacy:** logs carry metadata only — never audio, transcript text, credentials, or paths.
- **Capability contract:** `supports_dictation` means "enabled and valid for this agent"; transient
  readiness lives only in the live `stt_status`, never in capabilities (computed at connect).

## Gates

### G0 — Discovery and feasibility
- [x] `sherpa_onnx` resolves in `agent`; `dart compile exe` still builds the daemon.
- [x] In-process load on macOS arm64 proven with zero Flutter imports (`agent/packages/stt_sherpa/tool/stt_probe.dart`).
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
- [ ] Settings surface — owned by G6 below (required closure); until then `stt.enabled` is the only switch.

### G6 — Device settings: Dictation section (required closure)
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
- [ ] Dedicated tests for install-progress state transitions (required closure; partially covered today).

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
- macOS Intel support is required public closure, tracked as **G10** below; the
  hosted channel is a separate task.

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

### G10 — macOS Intel (`macos-x64`) public closure

Required for public closure. Not deferrable and not silently dropped: the daemon
platform gate, the checksum manifest, and the CI matrix currently exclude this
target, so an Intel Mac reports `unsupported_platform` and cannot install the
native runtime.

- [ ] Platform gate accepts `Abi.macosX64` beside `Abi.macosArm64` in the dictation
      runtime readiness check, and a unit test covers both macOS ABIs.
- [ ] Loader resolves the shim per macOS architecture: the artifact directory is
      currently arch-stripped (`native/macos/`), so x64 and arm64 binaries must not
      overwrite each other in one checkout. A loader-path test covers the x64
      resolution and the `SANAD_WHISPER_LIBRARY` override.
- [ ] `agent/native/checksums.json` gains a `macos-x64` artifact entry with a
      SHA-256 for every required file (shim plus its ggml/whisper siblings).
      Today only `macos-arm64` exists, so `ensure_native_stt` on Intel reports the
      platform as missing.
- [ ] A build/verification job runs the shim build and checksum verification on an
      x64 macOS runner. The current `native-stt` matrix covers `macos-26` (arm64)
      only; the concrete x64 runner label is confirmed when the job is added.
- [ ] The pinned release archive name for `macos-x64` is published and verified
      through the same download path (`--base-url`) as the other platforms.
- [ ] Checksum-manifest test asserts every platform entry in
      `checksums.json` lists the complete required file set for that platform.

**Facts kept separate:** a green CI build job on an x64 macOS runner proves the
shim builds and verifies; it does not prove transcription quality, Metal fallback,
or memory on real Intel hardware. Real-hardware acceptance on an Intel Mac is
recorded as its own evidence line when it happens and is not implied by the CI
result.

### G11 — Audited repair (reopened claims, required closure)

Historical evidence above keeps its recorded dates and results; nothing is deleted.
These items reopen claims that the audit found unproven or contradictory, and they
are required before the feature is closed.

- [ ] **Owned dictation lease and load cancellation.** A status-only, refused, or
      busy connection currently releases another connection's live lease on teardown.
      Release only the acquired owner token, after engine/session cleanup; prevent
      close-during-load from creating an orphan session or releasing another owner.
      Tests cover non-owner teardown, concurrent starts, delayed load, cancellation,
      and sequential sessions across separate connections.
- [ ] **Readiness reason survives projection.** The daemon can report
      `supported: true`, `ready: false`, and `native_runtime_missing|preparing`, but the
      Client discards the reason whenever `supported` is true. Preserve the reason
      independently of platform support and prove that the sheet renders native
      preparation, progress, failure, and its reachable setup action.
- [ ] **Residency statements.** `docs/technical/local_dictation.md` says the model is
      freed on stop; the implementation keeps it warm for `stt.model_idle_minutes`.
      Reconcile the document with the implemented behavior.
- [ ] **Platform gate.** The readiness gate accepts Windows and Linux ABIs while the
      documented gate says macOS arm64 only, and Intel is rejected by the gate. Make the
      documentation and the gate agree, with G10 covering Intel.
- [ ] **Toast statements.** G8 states no toast for dictation lifecycle states, while G9
      moved dictation notices to `ToastUtils`. Record one behavior and make the docs match.
- [ ] **Native packaging.** The native runtime is reproducible from a clean clone on every
      supported OS. Resolve the six removed dylibs still reachable in feature history
      before delivery; any history rewrite requires fresh explicit owner authorization.

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

- Targets: macOS arm64 **and macOS x64 (Intel, see G10)**, Windows x64/arm64, Linux
  x64/arm64; loader picks
  `libsanad_whisper.dylib` / `sanad_whisper.dll` / `libsanad_whisper.so` (`SANAD_WHISPER_LIBRARY` override).
- **Verified:** macOS arm64 locally; Windows x64 and Linux x64 compile in CI (`native-stt` green on
  `ubuntu-24.04`, `macos-26`, `windows-2025`). ARM runners are not exercised yet, and no
  macOS x64 fact exists yet: the platform tag resolves to `macos-x64`, the checksum
  manifest has no entry for it, and the readiness gate rejects it.
- **Binaries are not tracked.** `.gitignore` excludes `agent/native/*/*.{dylib,so,dll}`;
  `tool/ensure_native_stt.dart` verifies checksums → downloads (`--base-url`) → builds from a
  discovered or `--whisper-src` tree → else exits 2 with instructions. It refuses incomplete builds,
  writes `native/.stt-preparing` while working, and the dev CLI starts it detached on `run`.
- Six dylibs removed from the index still exist in older feature commits. Their delivery
  resolution is pending; historical approval is not authority for a new history rewrite.

## Later tasks (owner-requested, deferred)

Only these are deferred; none is a completion claim for work above. Settings,
install-progress tests, document conflicts, native packaging, the binary-history
blocker, and macOS Intel are required closure in G6, G2c, G10, and G11.

- A genuinely accurate English streaming model (keep the multilingual entry untouched; probe first).
- Daemon idle-memory work: measure AOT vs JIT first, then an old-gen heap cap, then post-session retention.
- Optional: shard `Test client`; default to `q5` on low-RAM devices; owner's verdict on the
  composer-wide meter (it paints: `shifts=181 max=0.506`).
- Separate task: the hosted dictation channel
  (`backend` task `voice02-dictation-cloud-relay`); its shared wire contract is
  [Dictation Transport Protocol](../../technical/dictation_transport_protocol.md). The local
  relay is done.

## G12 — Hosted dictation relay and legacy voice identity repair

Scope: the public Agent/Client half of `voice02-dictation-cloud-relay`, under the shared contract in
[Dictation Transport Protocol](../../technical/dictation_transport_protocol.md).

1. **Agent lease and control surface.** Session ownership is an opaque-owner lease released only
after the session closes; `status`, `install`, `select`, and `prepareRuntime` are served by one
control surface for both channels; install is per-owner single-flight; `start` is generation-guarded
so a cancel during load cannot resurrect a session.
2. **Agent hosted adapter.** `command == "dictation"` is dispatched before conversation-session
registration; events are origin-scoped `device_event`s with `event_id`, no `session_id`, and a
producer deadline; audio/end/abort are validated for identity, `seq` contiguity, and the byte cap;
abort and disconnect call `closeAll` and release the lease.
3. **Capability advertisement.** `dictation_relay_v1` (version plus frame bound) and
`voice_origin_v1` are advertised and parsed strictly; a version this build does not speak resolves
to "unavailable".
4. **Client transport selection.** One resolver chooses local or hosted and fails closed without the
capability, the account device id, or an authenticated socket; the hosted transport reuses the
existing socket, claims before routing, splits frames, carries `stop`/`cancel` on the ordered
`dictation_end`, and reshapes relayed events into the canonical local vocabulary (D1).
5. **Truthful readiness.** `supported` (platform verdict) and `ready` + `reason` (current state) stay
separate, so a supported device missing its runtime keeps its reason and its setup action.
6. **Device settings.** A Dictation section renders the daemon's own projection: enabled (or
`managed_externally`), selected model, size, readiness, and reason.
7. **Legacy voice identity repair.** One minted `voice_session_id` per session with `request_id`
equal to it on `start_voice`, `voice_audio_chunk`, `voice_control`, and `stop_voice`; account device
id instead of the local row id; inbound filtering of foreign identity; `voice_relay_error` →
update-required state.

Acceptance (authored; verification requires the gates below):

- Local and hosted channels produce the same ordered event sequence and the same client state for the
same fixture (D1).
- A second concurrent session is refused as busy and never steals the lease (D6).
- `dictation_event` reaches only the originating socket (D2); a frame whose identity is absent or
foreign is ignored client side (D15 ordered end + bounded state; the client keeps one session, one
control operation, and no per-`dictation_id` map).
- Delayed `dictation_final`/`dictation_done` after the ordered end still reach the client and the
send path, and late traffic stays bounded by retirement (D14 is bounded retirement/late traffic, not
the send path).
- A Gateway capability or identity refusal fails closed with a typed state and no degraded session
(D5, D16: capability validation of recognized fields).
- No audio, transcript, path, or credential appears in any log written by the new code (D10).
- Takeover of a live claim is Gateway-side (D13) and the public side adds no state that could be
resurrected; the client still ignores a post-end producer event instead of replaying it.

Definition of done for G12: both analyzers green; the focused Agent and Client unit suites green;
the hosted parity test green; the contract document and the owning `AGENTS.md` files updated in the
same change set.

Open seams (not completion claims): the native runtime distribution hooks are blocked by the release
contract's trust policy for an `agent-runtime` component; the launcher readiness probe needs the
native arch/target contract; and the Gateway must not retire an origin claim at `dictation_end`
receipt, because the drain results follow it.

## G13 — Narrowed closure (owner decision 2026-11-08)

Ship local + cloud dictation with the scope narrowed to what is already built. No
new tooling, refactors, or distribution features. Recorded here so the decision
outlives the branch.

- [x] **Packaged-runtime failure is dictation-only.** A failure to download or
      verify the `agent-runtime` archive never fails or blocks an Agent install or
      update: the installer, the Agent self-updater, the Client bootstrap, and the
      `sanad-dev` probe all continue, and dictation reports the reason instead.
      Trust strictness is unchanged — an unverified library is never extracted or
      loaded. Owning record:
      [native_stt_runtime_platforms.md](../../technical/native_stt_runtime_platforms.md#failure-policy-dictation-only).
- [x] **Machine-readable reason + retry.** The failing component records one code in
      `<exe dir>/native/.runtime-install-failed`
      (`release/contract/lib/src/native_runtime_install.dart`); readiness reports
      `native_runtime_install_failed`; the Client localizes it and offers the same
      setup action, which re-fetches the verified runtime for a released Agent.
- [x] **STT suite hang fixed at its owner.** `HostedDictationChannel` exposed a
      single-subscription command stream to two readers (the connection and the
      session), so every hosted session died with "Stream has already been
      listened to", and `close()` awaited a `done` future that can never complete
      without a subscriber. Both are product defects in that one file; the suite
      now finishes in seconds instead of timing out per test.

Deferred and **not claimed** by this closure: Windows/Linux packaging proof,
signing/notarization/attestation proof, and test-tooling enhancements beyond the
archive fixture that was corrected.

## G14 — Composer dictation UI (owner decision 2026-11-08)

The dictation surface is the composer's own action row, not its background.

- [x] **The button is a Stop control, not a meter.** While a session is active the
      dictation button shows a stop icon and stops the session when pressed. It
      carries no visible text; the tooltip is its only label, in English and
      Arabic.
- [x] **The visualization lives in the bottom action row.** The same meter widget
      that used to be painted across the whole composer card is re-hosted inside
      the row (driver key `dictation_row_meter`). While it is visible, the row's
      permission picker, model selector, and thinking-level selector are hidden and
      the meter takes their width; the Stop and Send buttons stay visible.
- [x] **Nothing else changes while it is hidden.** Those selectors keep their
      state, so Stop, auto-stop, an error, or a cancel restores the row exactly as
      it was.
- [x] **Only the container adapts.** Samples, smoothing, grow-in, display floor,
      painter, and bar geometry are unchanged; the row adds a 24 px height, mirrors
      the strip for RTL so the newest sample still enters on the leading edge, and
      raises the opacity ramp so the strip stays readable beside 32 px buttons.
- [x] **No composer-background visualization remains.** The `Stack` overlay and the
      `dictation_composer_meter` key are gone; the composer card is a plain clipped
      column.

## G15 — Linux arm64 ships whisper-only (owner decision 2026-11-09)

`sherpa_onnx` requires the Flutter SDK, and the Linux arm64 Agent is built with
the standalone Dart SDK because Flutter publishes no Linux arm64 host SDK. The
owner chose to keep the arm64 target and give it the whisper.cpp engine rather
than drop the target, install Flutter on those lanes, or write our own FFI
binding now.

- [x] **The engine is a swappable package.** The recognizer moved to
      `agent/packages/stt_sherpa` (package name `sanad_stt_sherpa`), and
      `agent/packages/stt_sherpa_stub` exposes the same library and public names
      with `sherpaEngineAvailable = false`. The arm64 lanes copy
      `agent/tool/pubspec_overrides.no_sherpa.yaml` over
      `agent/pubspec_overrides.yaml` before `pub get`, so the Agent resolves,
      compiles, and passes its lanes with the standalone Dart SDK.
- [x] **Capability, not a crash.** `SttEngineAvailability` reports streaming/VAD
      as absent on that build: sherpa catalog entries are not offered, a stored
      sherpa selection falls back to the default, `select` refuses one with
      `model_unavailable`, and local dictation runs the whisper.cpp path
      (batch only). Both builds are unit-tested on one machine
      (`agent/test/stt/engine_availability_test.dart`).
- [x] **Every other platform keeps sherpa streaming and VAD unchanged.**
- [x] **Native loading is fixed for the sherpa platforms.** The engine libraries
      ship inside the per-tag `agent-runtime` archive under `sherpa/`, the daemon
      passes that directory to the engine, and release staging plus the PR lane
      load the library from the packaged archive rather than from a pub cache.
      This was a real defect, not a packaging nicety: `initBindings()` with no
      path only worked in a developer checkout.

Revisit later: our own pure-Dart FFI binding over `libsherpa-onnx-c-api` would
remove the Flutter dependency from the Agent entirely and give arm64 streaming
back. That is a separate task, deliberately not started here.

## G16 — Live-local findings on the first-run path (owner decisions 2026-11-09)

A live run against a Test Home with **no STT model** found that dictation
reported `Ready`, the mic started a session the daemon immediately refused with
`model_not_installed`, the install sheet never appeared, and the Settings card
showed `Ready` for the same state. The owner's rule is unchanged and was simply
broken: with no model, a **single** press opens the model sheet; long-press stays
the explicit settings route.

- [x] **Readiness includes the model.** `readiness()` resolves the model the
      session would load (one resolution for both facts) and reports
      `model_not_installed` when there is none, `sherpa_runtime_missing` when a
      streaming entry's libraries cannot be resolved, and the existing runtime
      reasons otherwise. `stt_status`, the settings projection, and the session
      start all read the same answer.
- [x] **The regression is pinned.** `755b7ee5` made the Client trust the daemon's
      `ready` flag instead of the selected row's `installed` echo — correct — but
      the daemon never counted the model, so nothing replaced that check.
      `agent/test/stt/dictation_model_readiness_test.dart` pins readiness with
      zero models, with an installed override, and with a vanished override path;
      `client/test/widget/dictation/dictation_first_use_sheet_test.dart` pins that
      one press opens the sheet and that a late refusal lands there too.
- [x] **`sessionNeedsFirstUseSheet` has one consumer.** The mic button opens the
      sheet when the cubit sets it, so the flag is no longer dead state; the
      ordinary path still opens the sheet before a session starts.
- [x] **Every reason is localized.** `model_not_installed` and
      `sherpa_runtime_missing` gained en+ar notices and sheet/settings sentences
      through one shared mapper (`dictation_model_text.dart`), so no surface can
      render a daemon code.
- [x] **One install surface, reachable from Settings.** The device settings card
      opens the same model sheet (`device_settings_dictation_manage`) and never
      shows `Ready` without a model, because it renders the daemon's readiness.
- [x] **Catalog rows carry identity, not copy** (owner decision). `name` is the
      model's real name, `description` is a locale map `{en, ar}` with an English
      fallback — the single exception to "the daemon ships no user-facing copy" —
      and `badge`, `speed_tier`, `size_bytes`, `streaming`, `location` are facts.
      The rows render name, badge, description, size, speed bars, and a streaming
      icon, installed rows first; no search, no grouping, no invented accuracy
      grade. Adding a model is a catalog change only.
- [x] **The driver seam works on real trees.** `dictation_control` uses the
      inspector's whole-tree traversal instead of a 4000-element cap, and
      `dictation_probe` counts the local event classes, so a local leg is
      evidential.
- [x] **Acceptance audio is committed.** Two raw PCM16LE fixtures (English
      streaming, Arabic batch) under `client/test/fixtures/dictation/`, shape
      asserted by a test.
- [x] **A source checkout loads streaming with no staging step.** The daemon
      resolves the engine directory from the packaged payload or the checkout's
      own package resolution and passes it explicitly; `null` (the macOS
      `DynamicLibrary.process()` path) is never used.

## Definition of done

Analyzer and focused tests green in `agent` and `client`; batch/streaming contracts documented and
enforced by each model's own capability; live macOS acceptance recorded; the native runtime is
reproducible from a clean clone on every supported OS (green `native-stt`); no binaries in history;
no audio/transcript in logs; delivery only after explicit owner approval.
