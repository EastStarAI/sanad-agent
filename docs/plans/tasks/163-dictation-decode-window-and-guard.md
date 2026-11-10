# Task 163 — Dictation decode window and repetition guard

Status: implemented (public `EastStarAI/sanad-agent`), one pull request, pending acceptance on the
reference host. Client untouched.

Study: `~/.sanad-delegate/runs/stt-decode-speed-20261110/STUDY.md` (local evidence, not tracked).

## Goal

Cut the wait after a dictation microphone press on the reference aarch64 host from ~12.5 s to a
small multiple of the utterance length, without ever handing the composer a looped transcript.

## Locked decisions

1. **D-A — the encoder window follows the utterance.** `audio_ctx = clamp(roundUp32(ceil(padded /
   320)), 448, whisper_n_audio_ctx(ctx))`, applied in `sanad_whisper.c` through a new argument.
   Variant B: the arithmetic is a pure Dart helper (`stt_decode_params.dart`) so it is unit-tested.
   The floor is **448 mel frames** (9 s), not the cheaper 384 and not the over-cautious 640: it is
   the smallest value that was clean on every clip in a 60-run sweep, and it introduces no
   discontinuity (448 is also the proportional value for an 8 s utterance).
2. **D-B — `greedy.best_of = 1`.** One candidate per temperature tier instead of whisper.cpp's five.
3. **D-F — a repetition guard.** A group whose transcript looks looped is re-decoded **once** at
   `audio_ctx = 0` and that result is kept.
4. **Out of scope:** VAD trimming (D-G), timestamps (D-H), streaming (D-D), thread/flash-attention/
   build-flag changes, and the model-download work (`stt_model_store.dart` is untouched).

### One deviation, forced by measurement

D-F was approved as "repeats any 4-gram three times". Measured while implementing: the 24 s group
in the study is the same sentence said three times, so it repeats a 4-gram three times — and the
full-window retry **dropped two of the three sentences** (36 words → 12). A literal guard therefore
degrades correct dictation. The guard additionally requires the transcript to outrun **five words
per second** (`kMaxPlausibleWordsPerSecond`): the measured loops emitted 42 words for 3.0 s (14
words/s), the deliberate repetition 36 words in 24 s (1.5 words/s). Repetition and impossible
throughput together are the loop; repetition alone is speech.

## Gates

### G0 — Discovery

- [x] Read the owning contracts (`agent/AGENTS.md`, `docs/technical/local_dictation.md`).
- [x] Confirm the pinned whisper.cpp API: `audio_ctx` (`include/whisper.h:515`),
      `greedy.best_of` (`:552`), `whisper_n_audio_ctx` (`:395`), and the `-5` rejection of a window
      larger than the model's (`src/whisper.cpp:7140-7145`).
- [x] Confirm the next free plan number on `main` and in open pull requests (157 is the highest).

### G1 — Implementation

- [x] `agent/lib/infrastructure/stt/stt_decode_params.dart`: `audioCtxForSamples` + named constants.
- [x] `agent/lib/infrastructure/stt/stt_repetition_guard.dart`: `looksRepetitive` and
      `decodeGroupGuarded`.
- [x] `agent/native/whispercpp/sanad_whisper.c`: `audio_ctx` argument, model clamp,
      `greedy.best_of = 1`, `sanad_whisper_audio_ctx` accessor.
- [x] `whispercpp_bindings.dart`: the new ABI argument, the accessor, and a `modelAudioCtx` call.
- [x] `whispercpp_isolate.dart`: window per group, one decode log line, one guarded retry.
- [x] `tool/stt_whispercpp_probe.dart`: measures either window for the same buffer.

### G2 — Verification

- [x] `fvm dart analyze` in `agent/`: no issues.
- [x] `agent/test/stt/stt_decode_params_test.dart` and `stt_repetition_guard_test.dart`.
- [x] `agent/test/tool/native_builder_script_test.dart`: exports, window wiring, `best_of`.
- [x] `fvm dart test test/stt`: 253 passed, 1 skipped.
- [x] Native runtime rebuilt with `agent/tool/build_whispercpp.sh`; the worker isolate on the macOS
      host logs `dictation decode: samples=85857 audio_ctx=448 threads=4` and decodes the product
      fixture to `اختبار الإملاء المحلي على هذا الجهاز.`
- [ ] Acceptance on the reference Neoverse-N1 host (coordinator, after merge to a candidate build).

### G3 — Documentation

- [x] `docs/technical/local_dictation.md`: the decode-window table, the guard, and measured cost.
- [x] `docs/technical/native_stt_runtime_platforms.md`: the portable baseline costs 0.2–0.3 %.
- [x] `agent/AGENTS.md`: the window, `best_of`, and the guard are durable laws.

## Acceptance Criteria

- [x] A 4.87 s dictation is decoded with a 448-frame window and produces the same sentence as the
      full window did.
- [x] A 24 s group uses 1248 frames, keeps all three sentences, and does not trigger the guard.
- [x] No input yields window 0 or a window above the loaded model's.
- [x] A looped transcript triggers exactly one retry, at the full window, and logs one recovery line.
- [x] A deliberate repetition is decoded once.
- [x] Decode logs carry sample count, window, and thread count only.
- [ ] The reference host shows the same improvement under the released runtime.

## Definition of Done

- [x] Analyzer and focused tests green; no test asserts a host-specific time.
- [x] Documentation updated in the same change.
- [x] Diff limited to the decision above; no unrelated cleanup.
- [ ] Reference-host acceptance and the follow-ups in `RESULT.md` (Oracle measurement, optional VAD).
