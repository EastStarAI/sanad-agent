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
`select`.

Events (daemon → client):

| Event | Payload | Meaning |
|---|---|---|
| `stt_status` | `selected`, `models[]`, `supports_dictation`, `reason` | Catalog, install state, readiness |
| `dictation_ready` | `model_id`, `load_ms` | Recognizer loaded, audio accepted |
| `dictation_partial` | `seq`, `text` | Streaming only: open segment, replaced in place |
| `dictation_final` | `seq`, `text`, `audio_ms`, `decode_ms` | Terminal text of segment `seq` |
| `dictation_done` | `segments`, `dropped_chunks` | Session drained; nothing follows |
| `dictation_error` | `code`, `message` | Typed failure; no text is fabricated |

`seq` is the replacement key: a partial and its final share the same `seq`, so
the composer replaces the partial instead of appending, and no text is
duplicated. The transcript is inserted at the caret captured at session start;
typing during a session preserves the user's text and only the dictation-owned
range is rewritten.

Nothing logs audio or transcript text. The daemon logs metadata only: session
start, drain, and `audio_ms`/`decode_ms` per final.

## Batch and streaming

| Mode | Runtime | Behaviour |
|---|---|---|
| `batchVad` (default, Arabic) | whisper.cpp through `dart:ffi` | Audio is buffered and decoded once at stop: exactly one `final`, no partials |
| `streaming` | sherpa-onnx `OnlineRecognizer` | Text grows while the user speaks; a segment closes on real silence and its `final` replaces the partial |

Batch decoding uses a silence-aligned VAD: silence is trimmed, groups stay under
the decoder's 30 s ceiling, and the groups are joined into one transcript. A
half-second of trailing silence is appended before decoding, because a segment
that ends on the last phoneme otherwise loses its final word.

Streaming exists to keep the contract honest, not because Arabic streaming is
available: no sherpa-packaged Arabic streaming model exists today, so the only
streaming entry is English and labelled experimental.

## Model catalog and lifecycle

The catalog is data, not code: adding a model is an entry with pinned URL, size
and SHA-256. A model is installed through the same hosted download path,
verified against its SHA-256, and activated atomically.

| Entry | Mode | Size | Note |
|---|---|---|---|
| `egy-whisper-turbo-ggml-q8` | batch | 834 MB | default; ~1.2 GB RAM while listening |
| `egy-whisper-turbo-ggml-q5` | batch | 547 MB | lighter; ~0.95 GB |
| `whisper-base-int8` | batch | 153 MB | fastest, lowest Arabic accuracy; ~0.76 GB |
| `egy-whisper-turbo-ggml-f16` | batch | 1.6 GB | unquantized; hidden until its artifact is hosted |
| `en-streaming-zipformer-20m` | streaming | 45 MB | English-only proof entry; ~0.2 GB |

The model is **not** kept loaded between sessions. It loads on `start`
(0.2–0.3 s for whisper.cpp, ~1 s for the Egyptian ONNX path) and is freed on
stop, because holding 1–2 GB all day is not acceptable on the machines this runs
on. Measured peaks: daemon idle 46 MB, listening ~1.2 GB with the q8 entry,
~0.6 GB after a session and flat across sessions (no leak).

`stt.model_path` overrides the catalog with a local directory (a sherpa
directory or a single `.bin` ggml file) and requires no download or checksum;
`stt.model_id` pins an entry, including hidden ones.

## Platform gate

macOS on arm64 only in v1. Elsewhere `supports_dictation` is false with a reason
and the mic button is not actionable.

## Related

- [Experimental Realtime Voice](voice_streaming.md) — the duplex voice path,
  which is a different feature.
- Plan and verification record:
  [voice02-local-dictation](../plans/tasks/voice02-local-dictation.md).
