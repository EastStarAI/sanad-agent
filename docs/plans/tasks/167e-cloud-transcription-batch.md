---
title: "Task 167e: Cloud Transcription — Batch Family and Source Selection"
description: "محرك تفريغ سحابي دفعي عبر العائلة المتوافقة مع OpenAI، واختيار مصدر التفريغ مع بقاء المحلي افتراضيًا."
status: "pending"
current_gate: "Ready for 167e-R0"
priority: "high"
depends_on: "167b, 167c"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
reference_grounding: "required"
file_budget: 16
---

# Task 167e: Cloud Transcription — Batch Family and Source Selection

## 1. Goal

A dictation session can be served by a cloud provider instead of a local model.
The first slice is the only genuinely standardized wire family: OpenAI-compatible
batch transcription, covering OpenAI, Groq, and a `custom` instance. It produces
final text per utterance, and the local model remains the default source.

## 2. Scope

- One cloud recognition seam with two shapes over the same events: a full-batch
  recognizer and a streaming recognizer. Session, lease, buffer, caps, and
  insertion stay unchanged downstream because they see one seam.
- A batch recognizer for the OpenAI-compatible family: multipart upload of one
  utterance at its end, single final result. A batch-only vendor is presented as
  streaming by the local speech gate plus VAD segmenting the audio into
  utterances — the same behavior the local batch mode already has.
- Local speech gating and VAD stay local; only the utterance is uploaded.
- Source selection: dictation source becomes `local` or `instance+model`, with
  one selection authority; local is the default when nothing is chosen.
- Catalog integration: cloud transcription models appear as rows with a cloud
  location, no files, no download, and readiness from credential plus probe.
- Typed failure mapping for auth, rate limit, size, timeout, and connectivity,
  each with a localized client sentence; no provider body reaches the UI.

## 3. Invariants

- Audio bytes and transcript text are never logged; only counts, codes, sizes,
  and durations.
- One dictation lease; a second session is refused as busy, never queued.
- Session byte, duration, and first-audio bounds apply to cloud sessions too.
- A cloud session never writes to the local model store and never triggers a
  download.
- Language/dialect is sent explicitly with every request; the provider default is
  never relied upon.
- No vendor SDK becomes a dependency; wire facts come from the pinned reference
  source, and any copied block is a single function with an attribution note.
- The utterance boundary is ours: in batch mode the vendor never decides when a
  Sanad segment ends.
- Credentials are resolved at session start through the existing resolver; the
  client never sees a key.

## 4. Gates

### R0 — Reference grounding

- [ ] Pinned evidence exists for the OpenAI-compatible transcription wire and for
      each vendor's language and size limits.
- [ ] Adopt/Adapt/Reject recorded; no vendor detail leaks into tracked docs.

### G1 — Engine seam

- [ ] The seam exposes a batch recognizer and a streaming recognizer; a batch-only
      vendor reaches the client through the wrapper, never through a second path.
- [ ] The cloud engine satisfies the same contract as a local engine and is
      selected per session, not per process.
- [ ] A session bound to a cloud source never loads a local model.
- [ ] Cancellation and completion release the engine, the lease, and the socket.

### G2 — Batch adapter

- [ ] One upload per utterance end; exactly one final event per segment.
- [ ] Empty or silent utterances produce no transcription and no error noise.
- [ ] A failed upload surfaces one typed reason and ends the session cleanly.
- [ ] Size and duration limits are enforced before upload.

### G3 — Selection and projection

- [ ] Source selection persists in the daemon and is re-read by clients; local is
      the default with no selection.
- [ ] Cloud rows carry cloud location, no file list, and no download action.
- [ ] Readiness reflects credential state, not model presence.
- [ ] Switching source mid-session is refused; the next session uses the new
      source.

## 5. Definition of Done

- Tests cover: source resolution, no local load for cloud, one-final-per-segment,
  typed failures, size/duration enforcement, catalog row shape, busy refusal.
- `fvm dart analyze` clean in `agent/`; focused dictation tests green, sequential
  where a socket or port is bound.
- `docs/technical/local_dictation.md` becomes the transcription runtime contract
  and owns both sources; `docs/technical/cloud_transcription.md` created here for
  the batch wire and extended in 167f.

## 6. Success test scenario

1. Configure an OpenAI instance with transcription and make it the transcription
   default; speak one utterance; assert exactly one final transcript, no model
   load, and no download.
2. Remove the credential; press the mic; assert a typed auth reason and a
   completed session with no leaked body.
3. Send a long utterance beyond the size bound; assert the session refuses it
   before upload with a typed reason.
4. Switch the selection back to a local model; assert a local session starts and
   the cloud instance is not contacted.

## 7. Out of scope

Streaming partials (167f); dictation settings UI (167g); search (167h); any new
local model.
