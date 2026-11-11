---
title: "Task 167f: Cloud Transcription — Streaming Adapters"
description: "محوّل تدفقي لكل مزود (OpenAI Realtime وDeepgram وAssemblyAI) مع توحيد الأحداث إلى جزئي/نهائي وتمييز الوضع في الكتالوج."
status: "pending"
current_gate: "Ready for 167f-R0"
priority: "high"
depends_on: "167e"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
reference_grounding: "required"
file_budget: 18
---

# Task 167f: Cloud Transcription — Streaming Adapters

## 1. Goal

Genuine streaming transcription with progressive text for the vendors that offer
it. Each vendor is handled by its own adapter because transports, auth, message
placement, and event vocabularies differ; the daemon normalizes them into the one
internal partial/final contract the client already understands.

## 2. Scope

- Three adapters: a realtime transcription session (OpenAI), a live socket with
  binary audio frames and query configuration (Deepgram), a live socket with
  JSON audio chunks and server turn detection (AssemblyAI).
- One connection per session, closed on completion, cancellation, or failure.
- Normalization: interim events become partials for the current segment; a
  committed/final event replaces that segment; a late partial after a final is
  discarded.
- Mode is a template fact: a transcription template declares streaming or batch,
  and the catalog row carries that mode for the UI indicator.
- Bounded behavior: first-audio timeout, idle timeout, session byte and duration
  caps, single reconnect policy that never silently resumes a finished utterance.
- Failure mapping identical in shape to 167e, with vendor-neutral reason codes.

## 3. Invariants

- No audio, transcript, or token is logged; the failure log line names the side
  that decided and the vendor-neutral code only.
- Audio format sent to each vendor is declared by its adapter, not guessed at the
  call site.
- Segment identity is stable: a final for a segment is terminal and never mutates.
- Cancellation tears down the socket in order; no orphan connection survives a
  session.
- A vendor refusal never marks the instance ready for transcription.

## 4. Gates

### R0 — Reference grounding

- [ ] Pinned evidence per vendor: endpoint, auth form, configuration placement,
      audio contract, and event vocabulary.
- [ ] Adopt/Adapt/Reject recorded; adapters follow the source, not a memory of it.

### G1 — Adapter skeleton

- [ ] Each adapter is a separate implementation behind one vendor-neutral seam.
- [ ] Template binding data selects the adapter; no adapter is chosen by a string
      comparison at a call site.
- [ ] A template declaring streaming without a usable adapter fails closed at
      readiness time.

### G2 — Streaming behavior

- [ ] Partials arrive progressively and replace the current segment.
- [ ] A final event is terminal for its segment; duplicates replace, never append.
- [ ] Late partials after a final are discarded.
- [ ] End of utterance triggers the vendor's close/final handshake and yields a
      final transcript without waiting for the idle timeout.

### G3 — Bounds and failures

- [ ] Byte and duration caps end the session with a typed reason and a healthy
      client state.
- [ ] A mid-session disconnect produces one failure reason and one teardown.
- [ ] Reconnect policy is explicit and never replays already-final audio.
- [ ] Every failure mode has a localized client sentence in 167g.

### G4 — Mode projection

- [ ] Catalog rows expose streaming vs batch, and the instance's declared mode
      matches the adapter used.
- [ ] A batch vendor is never presented as streaming, even when both are
      configured.

## 5. Definition of Done

- Tests cover: partial→final replacement per vendor adapter, duplicate final
  replacement, late partial discard, caps, disconnect teardown, mode projection.
  Vendor tests use recorded fixtures, not live calls.
- `fvm dart analyze` clean in `agent/`; dictation tests green and sequential where
  sockets are bound.
- `docs/technical/cloud_transcription.md` extended with the per-vendor wire
  table; `docs/technical/dictation_transport_protocol.md` unchanged unless the
  event set actually changes.

## 6. Success test scenario

1. With a streaming vendor selected, speak a sentence; assert progressive
   partials replace the same segment, one final commits it, and the composer ends
   with one copy of the sentence.
2. Force a disconnect mid-utterance; assert one typed failure, one teardown, and
   no second session on the same lease.
3. Speak past the session duration cap; assert the cap reason and a usable mic
   afterward.
4. Select a batch vendor; assert one final and a batch indicator on the row.

## 7. Out of scope

Batch family (167e); dictation settings UI (167g); search (167h); any change to
local engines.
