---
title: "Local Dictation"
description: "In-process speech-to-text dictation: ownership boundary, transport, event contract, model catalog and lifecycle, platform gate."
---

# Local Dictation

Dictation turns the microphone into text in the composer without sending audio
anywhere. Recognition runs **inside the agent daemon**; the Flutter client only
captures PCM and displays the transcript.

## Ownership boundary

| Concern | Owner |
|---|---|
| Microphone capture, insertion at the caret, draft preservation | `client/lib/features/dictation/` |
| Transport (WebSocket), command handling, session lifecycle | `agent/lib/infrastructure/stt/dictation_service.dart` |
| Pre-session microphone buffer (frames captured while the model loads) | `agent/lib/infrastructure/stt/dictation_audio_buffer.dart` |
| Recognition runtime (native, in-process) | `agent/lib/infrastructure/stt/stt_engine.dart` + worker isolate |
| Model catalog, download, checksum, activation | `agent/lib/infrastructure/stt/stt_catalog.dart`, `stt_model_store.dart` |

Two rules hold the boundary:

- The client never imports a recognizer and never depends on a model format. A
  test fails the build if the client project gains an STT dependency.
- The daemon never imports Flutter in dictation code, and no sidecar, CLI or
  local HTTP server is spawned: the runtime is a native binding in the daemon
  process.

## Transport and event contract

The client opens `ws://127.0.0.1:<port>/ws?type=dictation` on the local gateway
(authenticated with the owner-only local credential). Binary frames are 16 kHz
mono PCM16 little-endian audio; text frames are JSON commands.

Commands (client → daemon): `start`, `stop`, `cancel`, `status`, `install`,
`cancelInstall`, `select`.

Events (daemon → client):

| Event | Payload | Meaning |
|---|---|---|
| `stt_status` | `selected`, `models[]`, `supports_dictation`, `reason`, `install?` | Catalog, install truth, readiness |
| `dictation_ready` | `model_id`, `load_ms` | Recognizer loaded, audio accepted |
| `dictation_partial` | `seq`, `text` | Streaming only: open segment, replaced in place |
| `dictation_final` | `seq`, `text`, `audio_ms`, `decode_ms` | Terminal text of segment `seq` |
| `dictation_done` | `segments`, `dropped_chunks` | Session drained; nothing follows |
| `stt_download_progress` | `model_id`, `received_bytes`, `total_bytes`, `phase`, `bytes_per_second` | Coalesced install progress; `phase` is `downloading`, `verifying`, or `activating` |
| `dictation_error` | `code`, `reason`, `message` | Typed failure; no text is fabricated |

`seq` is the replacement key: a partial and its final share the same `seq`, so
the composer replaces the partial instead of appending, and no text is
duplicated. The transcript is inserted at the caret captured at session start;
typing during a session preserves the user's text and only the dictation-owned
range is rewritten.

Nothing logs audio or transcript text. The daemon logs metadata only: session
start, drain, and `audio_ms`/`decode_ms` per final.

### Session lifetime

A session is bounded from both ends, and each bound answers a different question:

- **Audio arrived, then stopped:** the session runs until `maxSessionDuration`
  (10 minutes), checked on every frame, and closes with `session_limit`. Silence
  during an open, speaking session is legitimate — the user may be thinking — so
  it never shortens a session.
- **No audio ever arrived:** `start()` arms `firstAudioTimeout` (15 seconds, a
  named constant beside `maxSessionDuration`) and the first frame disarms it.
  On expiry the daemon logs `audio_ms=0` and the model it was loading, then calls
  `_stop(drain: false)`.

The second bound exists because the dictation lease is daemon-wide: a producer
that vanished between the claim command and its first packet held the only engine
until the Gateway's route TTL released it — five minutes in the live run, during
which every other press was refused with `dictation_busy`. The window keys on
**zero frames ever**, so it never fires for a user who is simply quiet.

The Agent is not the only side that cleans up. A Client that abandons a route ends
it with the ordered `dictation_end{reason: cancelled}`, which ends the daemon
session and releases the Gateway's route. The command path cannot do it: a
`dictation` command `op: cancel` is refused with `invalid_request` by design, so a
Client that relied on it released nothing and left the Gateway holding the device
for its whole idle TTL.

That end is sent **even when the route already failed**, because the two sides
release on different clocks: the watchdog below frees the daemon in 15 s, while a
route the Gateway never saw a frame on lives for 60 s. A Client that skipped the
end after a local refusal therefore left every press on every client answered
`busy` for a minute after a single failed one. The packet costs nothing when the
route is already gone, and a Client sends it at most once per session.

## Batch and streaming

| Mode | Runtime | Behaviour |
|---|---|---|
| `batchVad` (default, Arabic) | whisper.cpp through `dart:ffi` | Audio is buffered and decoded once at stop: exactly one `final`, no partials |
| `streaming` | sherpa-onnx `OnlineRecognizer` | Text grows while the user speaks; a segment closes on real silence and its `final` replaces the partial |

Batch decoding uses a silence-aligned VAD: silence is trimmed, groups stay under
the decoder's 30 s ceiling, and the groups are joined into one transcript. A
half-second of trailing silence is appended before decoding, because a segment
that ends on the last phoneme otherwise loses its final word.

### The decode window

whisper.cpp's encoder defaults to the full 1500-frame (30 s) window for every
utterance, so a five-second dictation used to pay the same encoder pass as a
thirty-second one: **12.4 s of a 12.5 s decode** on the reference Ampere
Neoverse-N1 host. The window now follows the buffered audio; the encoder is the
whole cost of a short decode, so this is where dictation latency lived.

| Parameter | Value | Why |
|---|---|---|
| `audio_ctx` | `clamp(roundUp32(ceil(padded_samples / 320)), 448, whisper_n_audio_ctx(ctx))` | 320 samples per mel frame (10 ms); the ceiling is the loaded model's own window, so a future checkpoint smaller than the floor is still obeyed |
| floor | 448 frames = 8.96 s of audio | measured, not derived: with the bare proportional window **5 of 8 short Arabic clips (1.8–3.9 s) decoded into deterministic phrase loops** — the 3 s clip came back as 42 words of `تماما خلاص كدا` instead of 3. The trigger is trailing silence: the audio path guarantees only 0.5 s after the last phoneme, and a window ending within ~1 s of it leaves whisper no room to close a segment. In a 60-run sweep (6 clips × windows 320–768 frames) every loop sat at a 2.5–4.5 s window and every run at or above 448 frames was clean |
| `greedy.best_of` | 1 | whisper.cpp's default asks for five candidates per temperature tier. At `temperature = 0` it is unused; on a temperature fallback it multiplies the decode five times. Measured: it changed no transcript and rescued no loop |
| repetition guard | one retry at `audio_ctx = 0` | below |

The window is derived by `audioCtxForSamples` in
[`agent/lib/infrastructure/stt/stt_decode_params.dart`](../../agent/lib/infrastructure/stt/stt_decode_params.dart),
which is pure and unit-tested (`agent/test/stt/stt_decode_params_test.dart`), and
applied by the shim in `agent/native/whispercpp/sanad_whisper.c`. `audio_ctx = 0`
stays callable and means whisper's own window.

#### The repetition guard

No fixed window is provably safe — one window value (512 frames) still looped on
one clip in the sweep — so a looped group would reach the composer as visible
garbage. `stt_repetition_guard.dart` therefore re-decodes a group **once** at the
full window when its transcript repeats any 4-gram three times, and keeps that
result. It logs one line (`dictation decode: repetition guard re-decoded group`)
and never logs transcript text.

Repetition alone is not sufficient evidence, and this was measured rather than
assumed: a 24 s group of the **same sentence said three times** repeats a 4-gram
three times, and re-decoding it at the full window on the reference host
**dropped two of the three sentences**. A loop is distinguished by throughput —
it emitted 42 words for 3.0 s of audio (14 words/s), while the deliberate
repetition emitted 36 words in 24 s (1.5 words/s) — so the guard also requires
the transcript to outrun five words per second, which no dictation pace reaches.
The retry is bounded to one attempt, and one decode line is written per actual
decode:

```
dictation decode: samples=85857 audio_ctx=448 threads=4
```

#### Measured decode cost

RTF is decode time ÷ audio duration. The N1 column is the reference host, the
Mac column is Metal on an Apple-silicon laptop; both used the shipped Egyptian
Arabic q8 checkpoint.

| Case | Window | N1 (CPU) | Mac (Metal) |
|---|---|---|---|
| 4.87 s dictation (product buffer) | 1500 (default) | 12.47 s / RTF 2.56 | 3.16 s / RTF 0.65 |
| 4.87 s dictation (product buffer) | 448 | ~2.7 s / RTF 0.55 | 0.73 s / RTF 0.15 |
| 8 s sentence | 448 | 2.93 s / RTF 0.37 (measured) | 0.81 s / RTF 0.10 |
| 24 s group | 1248 | ~10.3 s / RTF 0.43 | 2.82 s / RTF 0.12 |
| 26.3 s take (two groups) | 1248 + 448 | — | 4.21 s / RTF 0.16 |

The 448 row on the N1 interpolates between the measured 384 (2.39 s) and 512
(3.06 s) windows, because the encoder is proportional to the window; the 8 s row
is a direct measurement. The win is concentrated in short dictation, which is
what a composer microphone press is: long takes were never encoder-bound on
either host.

Streaming exists to keep the contract honest, not because Arabic streaming is
available: no sherpa-packaged Arabic streaming model exists today, so the only
streaming entry is English and labelled experimental.

### Builds without the sherpa engine

The sherpa engine is a swappable package, and the Linux arm64 Agent is built
without it (see
[Native Dictation Runtime Platforms](native_stt_runtime_platforms.md#engine-availability)).
On that build:

- the catalog's sherpa entries are not offered — not in the model rows, not as a
  selection, and a stored selection that names one falls back to the default;
- `SttEngineAvailability.streaming` is false, so readiness and the surface report
  batch-only behaviour;
- local dictation runs the whisper.cpp path unchanged, and `select` refuses a
  sherpa model with `model_unavailable` instead of persisting it.

No new Client UI is involved: the Client already renders a session that produces
finals only, and the missing rows simply are not there.

## Model catalog and lifecycle

The catalog is data, not code: adding a model is an entry with pinned URL, size
and SHA-256. A model is installed through the same hosted download path,
verified against its SHA-256, and activated atomically.

### The install belongs to the daemon

An install is daemon-scoped, not connection-scoped. Closing the model sheet,
switching to another device, reconnecting, or a Client restart all detach a
listener and leave the download running; only `cancelInstall` stops it, and even
that keeps the bytes it already received.

The Client side of that rule: a **closed** socket cannot report an install, and a
hard Agent restart ends one (the process that owned it died). So when the dictation
socket closes with an install row on screen, the Client drops the row instead of
leaving a Cancel button that reaches nothing, and re-asks the device for truth a
bounded number of times (three attempts, three seconds apart, silent) so the row
reappears if the daemon was merely reconnecting. That is what `stt_status.install`
exists for: any client that arrives mid-download rebuilds the same bar from the
daemon's own truth instead of relying on a continuous event stream.

The shape of the download is part of that contract, because each property was a
measured defect before it existed:

- **Every attached client sees it, from the start.** A channel attaches by asking for
  `status`, and an install that starts later is announced to every channel that has
  spoken to the control surface — a sheet that was already open learns about a
  download another client began instead of staying blank until it is reopened. A
  client that restarted mid-download, a second client, and a sheet reopened after a
  reconnect all receive the same ticks and the same terminal `stt_status` as the one
  that pressed the button. The terminal status is
  built **after** the install is released: built any earlier it still states
  `install`, and the row it was meant to unfreeze stays frozen until the sheet is
  reopened.
- **One writer per device.** A repeated `install` of a model already downloading
  joins the running install and is answered with its truth; a different model is
  refused with `install_in_progress`, and the refusal also carries the running
  install so the sheet can show it. Two writers could never share one partial
  file, and a second press used to reach a code path that discarded it.
- **Bounded memory, unpaced read.** Bytes cross a bounded write pipeline: the
  reader hands each chunk to a writer isolate and waits only when
  `kSttWriteWindowBytes` (4 MiB) of accepted bytes are already queued ahead of
  the disk. The window is what keeps the bound that PR391 established — an
  `IOSink.add` returns `void`, which let a fast producer queue the whole
  artifact in the Dart heap (measured at 723 MB retained for the 823 MB English
  entry), and a 4 MiB window is 21× the socket buffer the bound test observes
  while staying two orders of magnitude under that defect. Awaiting the write
  inside the reader's isolate bounded the heap too, but it also made the socket
  idle for the whole write: on the reference 4-core host reading alone ran at
  66.1 MB/s and the read-then-await-write loop at 29.1 MB/s, so the pipeline is
  what recovers the difference (61.2 MB/s, 19 CPU-s/GB instead of 43.5). The
  window is also the *only* admission rule: a chunk wider than it — a socket
  hands over whatever it has buffered, megabytes after a pause — is split into
  window-sized pieces and waited for piece by piece, never accepted whole.
- **Resume, not restart.** A `.partial` file is preserved across every
  interruption and continued with `Range: bytes=<n>-`; a prefix is re-read into
  the same SHA-256 hasher, so the final comparison still covers the whole
  artifact. Three retries with linear backoff cover a dropped connection; a
  resumable partial is deleted only when its digest is wrong. A 874 MB model on a
  27 Mbit/s link is a 4.5-minute download, and restarting it from zero at 99 % was
  the normal outcome before this. Resuming is only as good as the host serving it:
  a server that ignores `Range` and answers `200` makes the store rewrite the
  partial from zero, so that attempt's bytes are fetched again instead of
  continued. The artifact still ends up correct and the retry stays bounded, but
  no client-side change can resume against a host that does not honour the range.
- **Refusal beats stalling.** Before the first byte the store asks for the
  volume's free space and refuses with `storage_full` when the artifacts plus a
  256 MB margin do not fit. A write that still fails with `ENOSPC` maps to the
  same typed code, and the retry budget is never spent on either.
- **The projection is truthful before the first byte.** The install seed — the
  resumable partials already on disk, and the total of the artifacts this run holds
  plus the ones it still fetches — is part of `stt_status.install` from the moment
  the install starts, so a resumed download begins its bar at the offset it already
  reached instead of publishing a zero it has to contradict a second later.
- **Progress is cumulative across every artifact of the model**, including the ones
  an earlier run finished. A resumed encoder/decoder pair whose encoder is complete
  therefore opens at the model's real share (complete + partial bytes over the
  model's total), not at the pending file's share of the pending total; only the
  fetch — not the bytes already held — is charged against the volume.
- **Progress is a report, not a firehose.** One coalescing emitter serves both
  transports: at most one tick per 250 ms and one per 1 % of the total, always the
  first tick, every phase change, and the terminal 100 %. The ~160 000 per-chunk
  events of one install become ~100, and the same tick carries the observed rate
  the sheet turns into a remaining-time estimate.

#### What one artifact costs

An install pays for two things — the network that delivers the bytes and the
disk that has to keep them — and it pays for them serially unless the write side
overlaps the read. Three costs were measured rather than assumed, on a 4-core
ARM host against the real catalog URL and on an Apple M4 against a loopback
origin:

- **The digest is a native call.** SHA-256 is computed while the bytes are
  written, so it is a term in every second of every download. Pure Dart ran at
  196 MB/s and 5.25 CPU-s/GB — 42 % of the per-byte cost, and the one stage a
  slow core could cap. The OS already ships a hardware-accelerated
  implementation, so `stt_digest.dart` calls CommonCrypto (macOS),
  `libcrypto` (Linux) or `bcrypt` (Windows) through `dart:ffi`: 2 578 MB/s and
  0.41 CPU-s/GB, 13× the throughput for 13× less CPU, with nothing bundled or
  signed because the library belongs to the OS. A host without one falls back to
  the pure-Dart path silently; both paths are pinned against `package:crypto`
  across every chunking, including chunks wider than the 64 KiB native window.
  What is cached is the availability *answer*, never a context: each digest owns
  its own native state and its owner closes it in a `finally`, because native
  memory has no finalizer and a cancelled or refused transfer never reaches
  `finish()` — a shared context would corrupt two concurrent checksums and be
  freed under the survivor.
- **One connection, not many parallel ranges.** Splitting the artifact into
  concurrent `Range` requests is the obvious way to use an idle link, and it did
  not survive measurement: 1/2/3/4 workers ran at 29.4/31.0/30.1/28.4 MB/s on
  the reference host, because the pacing term is per-byte CPU rather than
  request latency, and the extra connections only added CPU and complexity. What
  did work was removing the pacing terms: HTTP-only read 66.1 MB/s, and the
  pipeline above 61.2 MB/s.
- **Writeback is forced during the transfer, and it does not stop the writer.**
  A write the kernel accepts lives in the page cache, not on the disk, and Linux
  does not start writing it back until `dirty_expire_centisecs` (30 s) unless
  `dirty_background_ratio` is reached first — 10 % of a 24.5 GB host is 2.45 GB,
  far above any single artifact. So the page cache is forced out every
  `kSttFlushWindowBytes` (64 MiB) of written bytes — but from a second isolate
  with its own handle of the same file, never on the writer's thread. That
  distinction is the whole difference between overlapping and re-serializing:
  `fsync` of one window costs about as much as reading it (~1.2 s against
  ~1.3 s per 64 MiB here), so a synchronous flush degenerates into "read a
  window, fsync it, read the next" and the end-to-end stays at their sum
  (measured below: 34.4 s against 31.9 s). The writer is held to **two windows
  ahead of the last completed flush** — past that it stops acknowledging, which
  caps the dirty page cache at ~128 MiB whatever the artifact size and paces the
  read to a disk slower than the link — and a request that arrives while one is
  running is *coalesced* into one remembered request, never a queue. `close()`
  waits for the running flush and then forces the remainder on the writer's own
  handle, so durability against a power cut is exactly what it was. A refused
  flush is the typed failure a refused write is (`storage_full` for `ENOSPC`),
  never a silently short artifact. Two handles are also what `RandomAccessFile`
  requires: it refuses a second concurrent async operation on one handle. A
  platform that refuses that handle — a stricter Windows sharing mode, an
  antivirus lock — degrades instead of failing: one lifecycle line
  (`background writeback unavailable (…), using close-only flush`), no bound, no
  requests, and the single flush at `close`, which is exactly the behaviour
  before this change. A flush that fails *after* the handle opened keeps its
  typed failure, because that one means the disk is gone rather than the
  platform being strict. The bound and the rule are one library of their own
  (`agent/lib/infrastructure/stt/stt_write_bounds.dart`), shared by the isolate
  pipeline and the in-process seam so the rule has a single owner and neither
  file outgrows the 1000-line ratchet.

The two changes together, measured on an Apple M4 against a loopback origin
serving one 1 GiB artifact, median of three runs after a warm-up: **142.9 MB/s
before, 1 137.6 MB/s after** (7.17 s → 0.90 s per GiB), with the same workload
falling from 40.3 s to 13.6 s of process CPU. The loopback origin removes the
network, which is the point: what is left is the cost this change removed.

End to end an install costs about **max(network, disk)** rather than their sum,
because the reader never idles for a write and the disk never waits for `close`
to start. Three builds of the shipped pipeline against the real f16 URL
(1 624 555 275 B), on the reference server, interleaved, median of three:

| Build | End to end | Transfer phase | Tail | Peak `Dirty` | CPU-s/GB |
|---|---|---|---|---|---|
| close-only flush (before #402's follow-up) | **59.12 s** (26.2 MB/s) | 28.9 s | 30.2 s | **1 500 MB** | 27.1 |
| synchronous flush every 64 MiB | **34.37 s** (44.8 MB/s) | 34.3 s | 0.06 s | 58 MB | 27.2 |
| asynchronous flush (this design) | **31.85 s** (48.6 MB/s) | 30.6 s | 1.27 s | 66 MB | 27.6 |

The middle row is why the second isolate exists: the fsync did not disappear, it
moved *into* the transfer phase, so the total was still the sum — and the
46 % it bought over the close-only build was all it could buy. The third row is
the overlap: 30.6 s of reading while the flusher drains, which is `max(read,
disk)` on a host whose disk needs 29.7 s for the same 1.62 GB at 54.7 MB/s. CPU
per byte is unchanged across all three (the fsync is I/O wait, not compute), and
the dirty page cache falls from ~1.5 GB to ~66 MB — one artifact's worth of RAM
that the host used to loan out at the owner's risk.

Pin the size and the digest from the hosting provider's own metadata — the
Hugging Face tree API field `lfs.size`/`lfs.oid`, or the `x-linked-size` and
`x-linked-etag` headers of the `resolve` URL — never from a mirror listing or a
number carried over from an earlier entry. A stale pinned size rejects the
download before the digest is ever compared, so a correct SHA-256 cannot save a
row whose size was never verified against the artifact itself.

| Entry | Decode language | Mode | Size | Note |
|---|---|---|---|---|
| `egy-whisper-turbo-ggml-q8` | `ar` | batch | 834 MB | default; ~1.2 GB RAM while listening |
| `egy-whisper-turbo-ggml-q5` | `ar` | batch | 547 MB | lighter; ~0.95 GB |
| `egy-whisper-turbo-ggml-f16` | `ar` | batch | 1.6 GB | unquantized; ~1.9 GB |
| `whisper-base-int8` | `ar` | batch | 153 MB | fastest, lowest Arabic accuracy; ~0.76 GB; sherpa |
| `whisper-small-en-ggml-q8` | `en` | batch | 264 MB | recommended English; ~0.5 GB |
| `whisper-medium-en-ggml-q8` | `en` | batch | 823 MB | more accurate English, ~3× slower on a CPU |
| `en-streaming-zipformer-kroko-2025-08-06` | `en` | streaming | 71 MB | live English text, sherpa builds only |
| `multilingual-streaming-zipformer-2025-02-10` | `ar` | streaming | 339 MB | live Arabic/English text, sherpa builds only |

### The decode language of a model

A whisper.cpp entry is decoded with the language it declares, because the entry
is the only thing that knows what the checkpoint was trained for: an Arabic
fine-tune handed English audio returns fluent Arabic, and an English-only
checkpoint handed `'ar'` returns Arabic too. `SttModelStore.resolve` therefore
passes `entry.language`, and the value travels unchanged through
`stt_engine.dart` → the whisper worker isolate → `sanad_whisper_run` →
`whisper_full_params.language`.

Two rules follow, and both are pinned by tests:

- `'auto'` is valid only for a multilingual checkpoint. whisper.cpp detects a
  language by scoring the language token of every language, and an English-only
  (`.en`) vocabulary contains none of them, so `'auto'` there would index
  outside the logits. Detection also costs one extra encoder pass, so it is not
  a free default.
- `stt.language` describes a `stt.model_path` override, which has no catalog
  metadata, and never overrides a catalog row.

`recommended` is a per-language badge: exactly one row per language carries it,
and `isDefault` stays unique, because the device still picks one row on its own.

### Residency

The recognizer is not reloaded on every press: the session releases it to the
service, which parks it warm and frees it when `stt.model_idle_minutes` (default
5) elapses — `0` frees it as soon as the session ends. Reloading a 1–2 GB model
per press would cost more than the wait it saves, and holding it all day is not
acceptable on the machines this runs on either. A cold load of the 874 MB
Arabic entry measured 1.5 s on a 4 vCPU arm64 host. Measured peaks: daemon idle
46 MB, listening ~1.2 GB with the q8 entry, ~0.6 GB after a session and flat
across sessions (no leak).

`stt.model_path` overrides the catalog with a local directory (a sherpa
directory or a single `.bin` ggml file) and requires no download or checksum;
that model has no declared language, so `stt.language` is its decode language.
`stt.model_id` pins an entry, including hidden ones.

### The shared VAD asset

A sherpa entry needs the Silero VAD, which is not part of any entry: it is
downloaded once into `<Sanad Home>/models/stt/_shared/` from the pinned
`kSileroVadFile` in the catalog. That descriptor is the store's one injectable
input (`SttModelStore(sharedVadAsset: …)`, defaulting to the catalog entry), so
a unit test of `install` can serve the asset from its own loopback server
instead of depending on a live third-party release host. Nothing else about the
asset is configurable, and the on-disk path stays `<sharedDir>/<name>`.

## Platform gate

The gate is the native target table, not a hard-coded OS list:
`SttNativeTarget.values` in
`agent/lib/infrastructure/stt/stt_native_platform.dart` names exactly the
OS/architecture pairs a runtime is built for — macOS arm64 and x64, Windows x64
and arm64, Linux x64 and arm64. `DictationService` asks
`SttNativeTarget.tryCurrent()?.dictationSupported`, so the daemon and the release
matrix cannot disagree, and an unresolvable host is reported as
`unsupported_platform` instead of being optimistically enabled.

Two facts narrow that table further at runtime, and neither is a platform
verdict:

- A build without the sherpa engine offers batch only (the Linux arm64 Agent);
  see [Native Dictation Runtime Platforms](native_stt_runtime_platforms.md).
- A device that is supported but has no usable model or no loadable runtime
  reports `ready: false` with its own reason, exactly as described below.

## Readiness is two facts, not one

The daemon reports `supported` (can this platform ever run dictation) separately
from `ready` plus `reason` (can it run *right now*). A supported device whose
native shim is missing reports `supported: true, ready: false,
reason: native_runtime_missing`, and the Client keeps that reason so the setup
action stays reachable. Conflating the two is what made the runtime states
unreachable in the composer: a supported device could not explain itself, and a
pressing user was told "not ready" with no way forward.

A recorded packaged-runtime failure reports `native_runtime_install_failed`
instead, which is the same setup action with a truthful reason: the runtime could
not be downloaded or verified, and `prepareRuntime` retries the verified download
without touching the Agent itself.

The second fact is the **model**. A device whose runtime is fine but which has no
loadable model reports `supported: true, ready: false, reason:
model_not_installed`; a streaming entry whose engine libraries cannot be resolved
reports `sherpa_runtime_missing`. Both are answered from the same resolution the
session start uses, so readiness and start cannot disagree, and the composer's
first press opens the model sheet instead of starting a session the daemon would
refuse. A `stt.model_path` override that no longer resolves counts as no model.

Readiness order is runtime before model: a missing engine makes every model
useless, and it is the reason with a build or download action behind it.

### A runtime that exists but cannot load

`engine_load_failed` is a typed status, not a crash. Engine acquisition happens
inside the session's `start`, and a `SttException` there is caught at the
dictation connection boundary: the lease is released, the failed engine is
disposed, `stt_status` is published with `ready: false` and
`reason: engine_load_failed`, and `dictation_error` carries the same code. The
daemon keeps running and the connection keeps answering — a `status` command
right after the failure is served normally.

This is the same contract a missing runtime already had (`native_runtime_missing`,
`native_runtime_install_failed`): a device that cannot dictate says why. It used
to be violated — v1.0.22's first arm64 install raised the load failure through
the command path, the daemon exited `255`, every client socket died, and the
clip that started the session received neither `dictation_ready` nor
`dictation_error`.

The wire carries the code and a stable English sentence only. The detail — which
library the loader refused — is written to the local log, because
`dictation_error` also travels over the hosted relay and a host filesystem path
is never part of a wire payload. Readiness keeps describing what is on disk: a
later `status` request still reports `ready: true` for a runtime that exists,
which is exactly what makes the next press retry the load instead of hiding the
button. The cause of such a failure is the shipped runtime itself; see
[Native Dictation Runtime Platforms](native_stt_runtime_platforms.md#relocatable-runtime-every-member-carries-its-own-search-path).

### Where the streaming engine is loaded from

The daemon resolves one directory and hands it to the worker, which passes it to
`initBindings`. Two sources, in order:

1. `agent/native/<tag>/sherpa/` — the packaged payload a released Agent installs
   from its runtime archive;
2. the engine's own package resolution (`sherpaNativeSourceDirectory()`) — the
   directory a source checkout has, and the exact directory release staging
   copies from.

Passing `null` is never an option: the engine would then resolve the library
itself, and on macOS that is `DynamicLibrary.process()`, which only works inside a
Flutter host. A source checkout therefore needs **no staging step** to run
streaming; `ensure_native_stt --stage` remains the packaging path, not a
developer prerequisite.

The same `reason` string is projected twice — as the platform verdict when
`supported` is false and as the readiness reason when it is true. There is no
second status field on the wire.

## The composer control while dictating

The trailing control of the composer's bottom row — the dictation mic plus the
Send/Stop control — lives in **one stable slot** in every layout. Only the middle
slot swaps: the live meter while a session is listening, the model and thinking
selectors otherwise. This is a correctness rule, not a layout preference.

Pressing Send while speaking stops the session, waits for the final transcript to
land in the composer, and dispatches it once. That wait resumes on the control's
own `BuildContext`; when the row moved the control between branches as the
session left `listening`, the element was unmounted mid-wait, the continuation
returned silently, and the message was never sent (v1.0.22, PR337). The
regression is pinned by
`client/test/widget/dictation/dictation_composer_send_control_test.dart`, which
also asserts that the `send_message_btn` element is identical before and after the
session ends.

The trailing control follows the session, not the turn:

| Dictation state | Trailing control | Turn Stop |
|---|---|---|
| listening | **Send** (enabled, even with an empty composer) | hidden — the mic's own Stop is the only stop |
| finalizing / awaiting transcript | spinner (`send_message_waiting_dictation`); pressing it abandons the automatic send and keeps the text | hidden — this branch is evaluated first |
| idle, composer empty | Send (disabled without content) | shown when the turn can be stopped |
| idle, composer holds text | **Send** | hidden until the text is sent or cleared |

The last row is the ordinary typed-text rule, not a dictation exception: unsent
text keeps the turn Stop hidden because the slot is the send action. A send is
always dispatched as `MessageDeliveryIntent.auto`; the daemon alone decides
whether that becomes a steer or a queued turn, so dictation adds no client-side
delivery logic.

## The first-use sheet states the channel reason

An empty model list has two causes that look identical and mean opposite things:

- **The daemon answered and listed nothing.** That is the install state, and the
  sheet says so (`dictationModelRequired`).
- **The transport boundary refused before any command left the Client.** A hosted
  device without `dictation_relay_v1`, a Gateway that refuses the claim, a frame it
  read as malformed, or an outdated Agent raises `dictation_unavailable`,
  `relay_unavailable`, `relay_forbidden`, `relay_invalid_request`, or
  `update_required` from the resolver. Nothing reached the daemon, so the catalog
  is **unknown**, not empty.

The second case renders the localized channel sentence in the empty slot
(`dictationChannelRefusalLabel`), never the install instruction: a device that
cannot relay very likely has models installed, and telling its owner to install
one sends them after the wrong problem. Readiness reasons keep their own banner
(`dictationReasonLabel`), because a device that answered and reported
`model_not_installed` or a missing runtime is a different state with a different
action.

## One channel, chosen in one place

Dictation is transport-agnostic above the transport boundary. The local socket
channel and the hosted relay produce the same `{event, ...fields}` vocabulary, so
the session, the cubit, the insertion helper, and the widgets never branch on
connection scope. Only `DictationTransportResolver.resolve` chooses a channel,
and it fails closed when the hosted prerequisites are missing (no
`dictation_relay_v1`, no account device id, no authenticated socket). The
D-series invariants and the hosted rules live in
[dictation_transport_protocol.md](dictation_transport_protocol.md).

Consequences that are contract, not implementation detail:

- The mic cannot be hidden on a remote device that can relay; it opens the sheet
  or reports the exact reason.
- The device settings page renders the daemon's own `dictation` projection, so
  it cannot describe a state different from the mic.
- A catalog row carries `name` (the model's real name, a proper noun, identical
  in every locale), `description` (a locale map `{en, ar}`, English fallback),
  and the facts `badge` (`recommended|faster|more_accurate|custom`),
  `speed_tier` (1–4, relative), `size_bytes`, `streaming`, and `location`
  (`local` today, `cloud` when the catalog grows one).
- The description is the **one** exception to "the daemon ships no user-facing
  copy": it belongs to the model, so it travels with the model and adding a model
  never requires a Client string. Badges, titles, and every other word stay codes
  the Client localizes.
- A daemon-owned row that is not a model — the `stt.model_path` override — is
  identified by `label_code` (`path_override`) instead, and carries the `custom`
  badge.
- Adding a model is a catalog change only: one entry in `stt_catalog.dart` with
  its name, descriptions, badge, speed tier, and files.

## Driver acceptance seam

A driver-run acceptance leg can execute this same path without a microphone. The
`driver_main.dart` entry installs `dictationCaptureFactory` **before**
`AppProviders` builds the cubit and registers three `ext.sanad_client.*`
extensions:

- `dictation_capture` arms a bounded 16 kHz mono PCM16LE fixture (even bytes,
  at most 60 s, 320..32000-byte chunks every 10..500 ms). A fixture is
  single-use; arming or disarming during an active session is refused, and
  cancellation stops its timer so no late chunk reaches the transport.
- `dictation_probe` counts known dictation/voice event classes plus
device/dictation identity equality, for **both** transports: the relay classes
and the local ones (`stt_status`, `dictation_ready`, `dictation_partial`,
`dictation_final`, `dictation_done`, `dictation_error`). The local channel opens
its own WebSocket, so its events never appear on the main socket: the probe
subscribes to the main socket **and** to the events the cubit consumed from the
dictation transport (`DictationCubit.lifecycleEvents`), which is why a local leg
is evidential without reading daemon logs. A local event carries no identity, so
it is never counted as foreign. It stores no audio, transcript, or per-frame
history.
- `dictation_control` reports the cubit phase, can invoke the existing
`DictationCubit.cancel()` for a live control leg, and reports the **composer**
from the composer's own `TextEditingController` (`compose` →
`present`/`chars`/hash match). Reading the session state instead answered
`present: false, chars: 0` for a session that had just produced a transcript,
because the cubit drops its text when the session settles while the editor keeps
it. It locates the composer with the inspector's whole-tree traversal
(`findElementByKey`), never a visited-element cap: a bounded walk answered
`composer_not_mounted` on every Home with history while `inspect_ui` found the
same key instantly.


Committed acceptance audio:

| Fixture | Leg | Paired model | Shape |
| --- | --- | --- | --- |
| `client/test/fixtures/dictation/en_streaming_quick_brown_fox.pcm` | English streaming | `en-streaming-zipformer-kroko-2025-08-06` (any English streaming entry) | PCM16LE, 16 kHz mono, 2.7 s |
| `client/test/fixtures/dictation/ar_batch_dictation_check.pcm` | Arabic batch | `egy-whisper-turbo-ggml-q8` (default) | PCM16LE, 16 kHz mono, 4.9 s |

**A fixture is only meaningful against its paired model.** English audio decoded
by the Arabic q8 entry produces an empty final and **no error** — the engine is
working, the language does not match — so a leg that pairs the wrong model reads
like a product failure. Select the model the fixture belongs to (`select`) before
arming it, and select the Arabic entry back when the leg is done.

Both files are raw PCM (no container header), so a leg arms them without
conversion; `test/unit/dictation/dictation_audio_fixtures_test.dart` asserts
their shape and that they are not silence. Regenerate with macOS `say` plus
`afconvert -f WAVE -d LEI16@16000 -c 1` and strip the 44-byte header, or any
16 kHz mono PCM16LE encoder.

Production `main.dart` never installs the seam, so the real microphone remains
the default. Every response is a boolean, count, or phase: audio, transcript
bytes, and daemon messages never cross the driver surface. A VM-only service
extension is only reachable when the selected Client actually exposes a usable
DDS VM URL; that is an environment prerequisite, not something this seam
provides.

## Related

- [Experimental Realtime Voice](voice_streaming.md) — the duplex voice path,
  which is a different feature.
- Plan and verification record:
  [voice02-local-dictation](../plans/tasks/voice02-local-dictation.md).
