---
id: 175
title: Stream delta ordering (G2a/G2b/G2c)
status: complete — G2a, G2b, G2c, CI, and live acceptance closed; merged as bccc652b
gate: closed
created: 2026-11-13
parent_task: none
depends_on: []
delivery: own PR (one plan, three gates)
---

# Task 175 — Stream delta ordering

## Goal

An assistant stream stays readable and correct when its deltas reach a Client
out of order, duplicated, or late: the Agent stamps every thinking and final
stream delta with a monotonic sequence before fan-out on any transport, the
in-flight projection states how much text is complete, and a Client can repair
itself from that projection instead of trusting arrival order. Local, cloud,
and hydrated history stay identical.

## Locked decisions and scope

- **`stream_seq` is additive and optional.** An integer carried inside the
  `thought_stream` / `reasoning_stream` canonical payload, starting at `1` per
  stream key, increasing by exactly `1`, never wrapping. A producer that does
  not send it stays a valid legacy producer.
- **Stream key.** `(stream kind, model_step_id ?? run_id)` inside one run. The
  counter is owned per run, so a new run starts every key at `1` again and the
  same key name never collides across runs.
- **Thinking and final stream are one surface, not one key.** `thought_stream`
  and `reasoning_stream` keep separate keys so one provider surface can never
  consume the other's ordinals. A terminal event (`final_answer`, `thought`,
  `tool_use`, `stopped`, `error`) closes the step's keys.
- **No sequence on terminal events and no sequence in history rows.** A
  terminal carries the complete text; a hydrated row is a whole record, not a
  delta. Sequence metadata must never enter a history row or a durable table,
  so no database migration exists in this plan.
- **The in-flight projection is the repair anchor.** It reports
  `stream_seq` (the sequence of the last delta included in its text) and
  `snapshot: true`, so a consumer that adopts it knows exactly which deltas are
  already contained.
- **Client (G2b).** Drop duplicate/stale deltas, buffer a bounded reorder
  window (500 ms, 32 deltas, 64 KiB, at most 8 stream keys) and then ask
  `session.stream_state` for the authoritative snapshot. A delta without
  `stream_seq` on a key that never established an ordinal is legacy: apply
  best-effort and mark that stream key `unsequenced` for its lifetime. On an
  already sequenced key it stays best-effort without disturbing the window.
- **One narrow repair query.** `session.stream_state` returns the in-flight
  projection or an explicit `absent`, and never rebuilds history.
- **Ordering is transport-agnostic.** The Agent must not depend on any relay,
  queue, or hosting component preserving order, and must not serialize
  independent sessions to protect one stream.
- **Exclusions.** No Client order gate in G2a; no transport-level reordering
  policy; no history-row sequence; no durable sequence state; no dependency on
  any private component or deployment topology.

## Gates

### G2a — Agent contract and producer

- [x] `StreamDeltaSequencer` owned by one run; key `kind` + `model_step_id ?? run_id`.
      `agent/lib/interfaces/runtime/stream_delta_sequencer.dart`, held by `ActiveRun`.
- [x] `GatewayResponse.streamSeq` carried through every copy path, including
      `copyWithDelivery`.
- [x] Sequence allocated before the in-flight append and before fan-out for
      thought, reasoning, streamed content, and suspended-resume deltas.
      Streamed content publishes through `TurnEventPublisher.emitContentDelta`,
      so the executor listener and the delta owner share one path.
- [x] `stream_seq` inside the canonical payload with literal local/cloud parity;
      translation is side-effect free and the value is never re-derived per
      transport.
- [x] In-flight snapshot reports `stream_seq` and `snapshot: true`; history rows
      and the message schema stay unchanged.
- [x] `stream_sequence_v1` capability, ignorable by older Clients.
- [x] `session.stream_state` query with typed validation and `absent`.
- [x] Suspended resume publishes reasoning as reasoning, not as ordinary text.
- [x] Session-scoped FIFO fan-out for platform-family delivery with per-session
      tails, failure containment, and tail cleanup; local-first order preserved.
- [x] Deterministic tests for the sequencer, every delta source, payload parity,
      fan-out order and isolation, the in-flight watermark, the query, and the
      resume stream kind.
- [x] Compatibility coverage for the touched owners still passes
      (`interfaces_test`, `compaction_queue_integration_test`, `sanad_bridge_test`,
      `gateway_delivery_routing_test`, `session_memory_projection_test`,
      `suspended_resume_restart_test`, capability and protocol suites, guards).

**G2a known limitation (carried into G2c):** the suspended-resume path still
keeps no in-flight projection of its own, so a consumer asking
`session.stream_state` during a resume continuation gets `absent` until the
terminal answer. It is not a regression (the projection never covered that path)
and the terminal answer still repairs the surface.

**Restart boundary:** continuity is claimed only for one live run and one model
step. A suspended-resume continuation begins a fresh model step before it
streams, so its keys start at `1` under a new identity and never reuse a key the
consumer already advanced; no sequence counter is durable, and no migration
exists. Pinned by
`agent/test/interfaces/suspended_resume_stream_delta_test.dart`.

**Review notes (closed):**

- R1 — `AgentToCanonical` now classifies reasoning from the presence of
  `Message.reasoning`, not from a non-blank trimmed value. A whitespace-only
  reasoning chunk keeps its `reasoning_stream` kind and the ordinal its
  producer already allocated on the reasoning key, instead of being
  reclassified as ordinary text (which dropped the chunk and desynchronized
  the event from its own sequence). Covered deterministically by
  `agent/test/interfaces/stream_delta_publisher_test.dart` (reasoning `"\n"`,
  event kind and payload matching the reasoning key while the ordinary-text key
  stays at its own number) and by the translator case in
  `agent/test/interfaces/sanad_bridge_test.dart`.
- R2 — `GatewayResponse.copyWithDelivery` is proven to preserve the allocated
  ordinal and event identity, so per-delivery routing copies can never renumber
  a delta. Covered by
  `agent/test/interfaces/delivery_models_test.dart`
  (`streamSeq: 7` and `event_id` survive a rescoped copy and a copy with no
  overrides).
- Scope guard: neither note changed `_lastSeq`, the resume snapshot, the
  session FIFO chain, or `session.stream_state`.

### G2b — Client ingestion

- [x] `stream_sequence_v1` is consumed as an advisory declaration: it enables
      the repair query, never an ordering decision, and a peer that omits it
      loses no event. `Capability.supportsStreamSequence` in the device
      capability model.
- [x] `stream_seq` and `snapshot: true` map into `CanonicalEvent`
      (`streamSeq`, `isSnapshot`) for live deltas and for the in-flight history
      projection; a legacy payload maps to no ordinal and no snapshot flag.
- [x] `StreamDeltaOrderGate` is owned by `DeviceConversationStore`, before any
      timeline apply, keyed by `(kind, model_step_id ?? run_id)` inside the
      session: contiguous applies, duplicate/stale drops, bounded reorder
      buffer (500 ms, 32 deltas, 64 KiB, 8 keys per session), drain on the
      missing arrival.
- [x] An unclosable gap drops the buffer and asks `session.stream_state` once,
      with a 2 s cooldown and one request per session in flight; `absent` keeps
      the last good text and waits for the terminal event without reloading
      history.
- [x] A delta without an ordinal on a key that never established one makes that
      key `unsequenced` for its stream lifetime and keeps plain arrival order.
      On a key that is already sequenced it is applied best-effort without
      clearing the pending window, the watermark, or the repair capability; no
      version is assumed either way.
- [x] A repair answer is bound to the stream that asked for it: a session switch
      or reset, a turn terminal (which advances the session's turn epoch), or
      disposal retires it, so it is neither applied nor allowed to mutate the
      current ordering state. A disposed gate never decides again.
- [x] Snapshot adoption replaces the running text exactly and adopts the
      watermark; deltas at or below it are dropped.
- [x] A terminal event seals its step's keys, clears buffers, and stops a late
      delta from creating a ghost bubble; session switch, reset, and disposal
      release buffers, timers, and request entries.
- [x] Determinism over sleeps: every bound is a named constant, and the timer
      factory plus clock are injectable, so no test waits on wall-clock time.
- [x] Deterministic coverage for every state above plus cross-transport
      interleave, through the real `ConversationEventHandler`,
      `DeviceConversationStore`, and `ConversationState`.
- [x] Compatibility: the unsequenced path keeps the previous arrival-order
      behavior literally, and a numbered whitespace-only reasoning chunk keeps
      its ordinal while an unnumbered one still creates no bubble.

**G2b review notes (closed):**

- F1/F2 — A repair answer is captured against the session object and its turn
  epoch before the request leaves, and is validated after it returns. A switch,
  reset, turn terminal, or disposal makes the answer inert: nothing is applied
  and no current state is cleaned by a stale reply. A turn terminal advances the
  epoch before sealing; a disposed gate refuses `admit`, `noteTerminal`,
  `adoptBaseline`, and repair entirely. Covered by
  `client/test/unit/stores/stream_delta_order_gate_test.dart` and, through the
  real handler and store, by `client/test/unit/services/stream_delta_ingestion_test.dart`.
- F3 — A resumed continuation is pinned to a fresh model step before it streams,
  so it allocates under a new key instead of reusing the checkpoint's; no
  durable sequence state or migration was added, and no documentation claims
  continuity for a key across a restart. Covered by
  `agent/test/interfaces/suspended_resume_stream_delta_test.dart`.
- F4 — A bare delta on a key that is already sequenced is applied best-effort
  without flipping the key to `unsequenced`, dropping the pending window, or
  disabling repair; a bare delta on a key with no established ordinal still
  makes it legacy for its lifetime.
- F5 — Lifecycle comments now match behavior: a finished turn keeps only its
  bounded line of sealed keys, so `trackedSessionCount`/`isIdle` describe
  retained ordering state rather than "no buffered delta".
- F6 — Formatting of the touched handler branch only; no package-wide
  reformatting.

### G2c — Parity, documentation, and acceptance

- [x] Live plus history parity coverage across both transports. Live acceptance
      on 2026-11-15 passed S1–S3 and S6 live, S5 live after the D1 fix, and S4
      by code and tests; the cloud path's repair is covered by deterministic
      tests instead of a live run. Merged as `bccc652b` (#443).
- [x] Documented remaining gaps: suspended-resume in-flight projection and any
      measured repair cost.
- [x] Documentation and graph maintenance for the whole feature.

## Acceptance Criteria

- [x] Given three deltas of one stream key delivered A, B, A, when the Agent
      publishes them, then the sequence is 1, 1, 2 on the matching keys.
- [x] Given a new model step or a new run, when its first delta publishes, then
      its `stream_seq` is 1.
- [x] Given any assistant delta source, when it publishes, then the payload
      carries a contiguous sequence for its key and no other key's ordinal.
- [x] Given one response, when it is serialized for the local and the cloud
      transport, then `stream_seq`, `event_id`, `run_id`, `model_step_id`, and
      the text are identical.
- [x] Given two family events for one session with the first delivery delayed,
      when both complete, then the second is delivered after the first; given
      two sessions, their deliveries are not serialized; given a failing first
      delivery, the tail still delivers the second.
- [x] Given an in-flight stream through sequence N, when the projection is read,
      then it reports `stream_seq = N` and `snapshot: true` and the accumulated
      text, and no history row carries stream sequence metadata.
- [x] Given `session.stream_state`, when the request is valid and a stream is in
      flight, then it returns the snapshot; when the session is idle or unknown,
      then it returns `absent`; when the request is malformed, then it returns a
      typed error.
- [x] Given a suspended resume that streams provider reasoning, when it
      publishes, then the event is `reasoning_stream`.
- [x] Given a Client that receives numbered deltas out of order, when the
      predecessor arrives inside the reorder window, then both apply in sequence
      order; otherwise the Client asks for one snapshot and keeps its last good
      text.
- [x] Given a sealed step, when a late delta arrives, then it creates no bubble
      and never appends after the final answer.
- [x] Automated coverage proves each criterion on the owning boundary.

## Definition of Done

- [x] `fvm dart analyze` and `fvm flutter analyze` clean for the changed packages.
- [x] Focused tests pass for every changed owner; no full-suite run for a change
      of this blast radius unless a shared contract required it.
- [x] Owning contracts and design pages updated in the same change
      (`agent/lib/interfaces/AGENTS.md`, the Sanad Gateway contract,
      `client/lib/features/conversations/AGENTS.md` and its data/domain leaves,
      `docs/technical/communication_protocols.md`,
      `docs/technical/reasoning_thoughts_separation.md`, and the conversation
      event parity QA matrix).
- [x] No non-generated source file exceeds the size ratchet in either package.
- [x] Graph maintenance run after the code change.
- [x] Commit, push, and PR only under explicit user authorization; pull
      request #443 merged as `bccc652b`.

## Current status

Complete, and moved to `docs/plans/tasks/done/`. G2a and G2b were closed,
tested, and reviewed before merge; G2c and live acceptance closed with it. The
Agent stamps every assistant delta on one run-owned counter, publishes a
whole-text projection with a watermark, advertises `stream_sequence_v1`, and
answers `session.stream_state`; the Client orders each stream key, drops
duplicates, holds a bounded window, repairs through that query once per
cooldown, replaces text on a snapshot, and seals a step on its terminal event.

Final evidence: live acceptance on 2026-11-15 passed S1–S3 and S6 live, S5 live
after the D1 fix, and S4 by code and tests, with the cloud-path repair covered
by deterministic tests. The whole feature merged as `bccc652b` (#443), with both
analyzers clean, the focused suites green, and the protected review decision
recorded on the pull request.
