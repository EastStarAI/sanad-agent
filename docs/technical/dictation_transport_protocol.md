---
title: "Dictation Transport Protocol"
description: "Authoritative, source-neutral wire contract for dictation: channel-neutral daemon vocabulary, hosted relay envelopes, binary PCM framing, session/request/route/seq identity, origin-only delivery, admission and lifecycle limits, capability schema, and legacy voice origin correlation."
---

# Dictation Transport Protocol

This document is the single authoritative wire contract for dictation. It is
written for the Client, the Agent daemon, and the hosted Gateway at once, so no
repository may define a second vocabulary for the same traffic.

Dictation is one feature with two transports. The daemon always owns
recognition. Only the channel that carries commands and audio changes, and only
one component may choose it: `DictationTransportResolver` in the Client and the
cloud platform adapter in the daemon. Any other branch on transport scope is a
contract violation.

| Concern | Owner |
|---|---|
| Capture, composer insertion, session UI state | Client dictation feature |
| Session, engine, catalog, transcription | Agent daemon |
| Transport selection | Client `DictationTransportResolver`; daemon cloud platform |
| Authenticated relay, origin routing, admission, limits | Hosted Gateway |
| Recognition settings and model download | Agent daemon |

Local dictation behavior, model catalog, residency, and the platform gate are
owned by [Local Dictation](local_dictation.md). This document owns the traffic.

## 1. Identity model

Five values appear on the wire. Anything else is a payload field, not an
identity.

| Identity | Minted by | Scope | Rule |
|---|---|---|---|
| `device_id` | Gateway/account | Account device row | On the hosted channel it MUST be the account-owned device id, never a hardware id. The Gateway resolves the daemon socket from this value only. |
| `dictation_id` | Client | One dictation transport session | Opaque, 1–128 characters from `[A-Za-z0-9._:-]`, collision-resistant (UUIDv4 or 128-bit random). Stable for the whole session, including every model command issued over that session. |
| `request_id` | Client | Origin claim | MUST be client-supplied for dictation traffic and MUST equal `dictation_id`. The Gateway binds it to the originating app socket as an immutable claim (§5); the daemon echoes it verbatim on every event it produces. |
| `seq` | Client | One audio route | Starts at `0`, increases by exactly `1` per accepted audio frame, never wraps. |
| `event_id` | Daemon | One emitted event | Opaque, unique per emitted event; used for cross-transport deduplication. |

There is no separate wire route identity. The Gateway's relay route record is
keyed by `dictation_id`; the Client never addresses a route by any other value.

A timestamp or counter is not a valid identity. Identities reach the Gateway's
routing and admission machinery, so they MUST be collisions-resistant; the local
channel's current timestamp-only session factory is not sufficient for the
hosted channel and is replaced by the same generator on both.

`dictation_id` and `session_id` are the same identity under two carriers. The
local channel already carries it as the `session_id` query parameter of
`/ws?type=dictation`; the hosted channel carries it as `dictation_id`. Producers
MUST use one generator so both channels address the same session value.

`dictation_id` is a transport session, not a conversation session. No layer may
register it as a conversation session, attach it to conversation bookkeeping, or
use it to recover agent turns.

## 2. Capability contract

Dictation availability is a configuration/platform fact computed once when the
daemon registers. Readiness at this instant is never a capability.

| Capability | Meaning | Rule |
|---|---|---|
| `supports_dictation` | This Agent can dictate at all | Existing field. False or absent means no dictation on any channel, including hosted relay. |
| `dictation_unavailable_reason` | Machine-readable reason | Present only with `supports_dictation: false`; the Client localizes it. |
| `dictation_relay_v1` | This Agent accepts the hosted dictation relay | Additive metadata. Absent means unavailable at the consumer; malformed recognized metadata fails registration. The Client also refuses unsupported versions defensively. |
| `voice_origin_v1` | This Agent produces origin-correlated voice output | Additive flag required by the legacy voice repair in §10. Absent means the Gateway MUST NOT relay that device's voice output. |

```jsonc
"dictation_relay_v1": {
  "version": 1,
  "audio": {"encoding": "pcm16le", "sample_rate": 16000, "channels": 1},
  "max_session_seconds": 300,
  "max_frame_bytes": 32768,
  "max_session_bytes": 12582912
}
```

Validation rules:

- `dictation_relay_v1` is a recognized field, not an opaque blob: it MUST survive
  a registration round trip through the Gateway's capability store. A Gateway
  that discards it makes the hosted channel unreachable by design, so preserving
  it is part of the contract, not an optimization.
- Unknown additive keys are ignored and MUST NOT fail registration. Recognized
  fields are validated strictly: malformed `dictation_relay_v1` or
  `voice_origin_v1` content — wrong version, wrong encoding, wrong sample rate,
  wrong channel count, wrong types, non-positive limits — fails capability
  validation and therefore registration. A Gateway MUST NOT coerce, sanitize, or
  downgrade a malformed recognized capability into "absent".
- Absent and malformed are different outcomes. Absent (older Agent, or a Gateway
  that predates the key) means the hosted channel is unavailable to that
  consumer. Malformed is rejected at the producer boundary so a device can never
  register while advertising a capability it cannot honor.
- `dictation_unavailable_reason` is a machine-readable code. The Client localizes
  it for display; a raw code is never shown to the user as-is. The producer emits
  it only beside `supports_dictation: false`, and only when the value matches the
  Gateway's reason-code shape. A supported device that is merely not ready yet
  (model not installed, native runtime preparing) advertises plain support and
  keeps that reason on the live dictation status path; the envelope never carries
  readiness, so a missing model can never fail `register_device`.
- Limits are the Agent's own declaration and never grant admission by
  themselves. The Gateway's bounds in §6.5 still apply and win when smaller.
- Capability discovery never costs a device its registration. The Agent builds
  this envelope from several sources (workspace runtime, appearance store,
  dictation service); a source that is missing or fails degrades **that one
  capability** — an unresolvable dictation service advertises
  `supports_dictation: false` and no `dictation_relay_v1` — while the device
  still registers. Validation strictness is unchanged: the Gateway still rejects
  a malformed recognized field, and the producer never emits one it could not
  compute.
- A consumer parses limits defensively. A bound of the wrong type or a
  non-integer is malformed, so the Client falls back to the contract maximum
  instead of throwing or truncating: one bad advertisement can never break
  capability parsing for the whole device list.
- Capabilities never carry transient state. Model install progress and native
  runtime preparation are reported only through live events.

## 3. Canonical daemon vocabulary

This vocabulary is identical on both channels. A channel adapter translates
transport framing only; it never renames, merges, or reorders these items.

Commands (Client → daemon):

| Command | Extra fields | Effect |
|---|---|---|
| `start` | — | Load the selected recognizer and open one session. |
| `stop` | — | Drain the session; final transcripts then `dictation_done`. |
| `cancel` | — | Abandon the session and drop its transcript. |
| `status` | — | Emit a fresh `stt_status`. |
| `install` | `model_id` | Download and verify one catalog model, streaming progress. |
| `select` | `model_id` | Persist the selected model and emit `stt_status`. |
| `prepareRuntime` | — | Start native runtime preparation, then emit `stt_status`. |

Events (daemon → Client):

| Event | Fields | Meaning |
|---|---|---|
| `stt_status` | `supported`, `ready`, `reason?`, `busy`, `selected`, `has_model_path`, `models[]` | Catalog, install state, readiness. No host filesystem path is ever included: `has_model_path` only says an `stt.model_path` override exists, and the override row carries `label_code` without a `note`. |
| `stt_download_progress` | `model_id`, `received_bytes`, `total_bytes` | Install progress |
| `dictation_ready` | `model_id`, `load_ms` | Recognizer loaded; audio is accepted from now on |
| `dictation_partial` | `seq`, `text` | Streaming only: mutable segment text, replacing its own range |
| `dictation_final` | `seq`, `text`, `audio_ms`, `decode_ms` | Terminal text of that segment |
| `dictation_done` | `segments`, `dropped_chunks` | Session drained; nothing follows |
| `dictation_error` | `code`, `message`, `reason?` | Typed failure; no text is fabricated |

`seq` inside these events is the **transcript segment index** owned by the
daemon. It is distinct from the audio-frame `seq` in §6 and the two must never be
compared or merged.

Transport carriers differ while this vocabulary does not: on the hosted channel,
`stop` and `cancel` are carried by the ordered route control of §6.3 and the rest
of the commands by §5; on the local channel every command is a text frame.

## 4. Local channel

Unchanged and authoritative for its own details: an authenticated loopback
WebSocket at `/ws?type=dictation&session_id=<dictation_id>&device_id=<id>`,
binary frames carrying raw PCM, text frames carrying
`{"event": "<command>", ...fields}` verbatim from §3, and daemon events sent as
`{"event": "<event>", ...fields}`.

Two local properties are contract, because the hosted channel must not weaken
them: the daemon sends `stt_status` as soon as a dictation channel opens, and the
daemon buffers a bounded amount of pre-session audio so the first words spoken
during a model load are not lost.

## 5. Hosted channel: control commands

Control commands ride the existing, already-authenticated command path. No new
authentication, connection, or ownership mechanism is introduced. The hosted
channel is platform-neutral: any authenticated Client that can capture audio —
desktop, Web, or mobile — may dictate to a device whose Agent supports dictation.
Recognition never leaves the Agent, and the Agent's own platform gate decides
`supports_dictation`.

Client → Gateway → daemon:

```jsonc
// Socket.IO event: device_command
{
  "device_id": "<account device id>",
  "command": "dictation",
  "payload": {
    "version": "v1",
    "dictation_id": "<identity>",
    "request_id": "<equal to dictation_id>",
    "op": "start|status|install|select|prepareRuntime",
    "model_id": "<catalog id>"   // install and select only
  }
}
```

`stop` and `cancel` are not carried here: over the hosted channel they travel on
the ordered route channel (§6.3) so they can never overtake admitted audio. The
daemon-facing vocabulary is unchanged; only the carrier differs.

Producer order is an obligation, not a convenience:

- A transport is built silent. The claim command is the only thing that may create
  the session, and it MUST precede every route packet for that session.
- A route packet never mints a claim. A producer that emits `dictation_start`
  before its claim command will be refused with `forbidden` and MUST NOT treat
  that refusal as a transport outage.
- Exactly one route is opened per session, and the opening call is idempotent, so
  a repeated `start` cannot emit a second `dictation_start` for one
  `dictation_id`.
- A claim whose route is refused still names a live session, but the command path cannot end it: a `dictation` command `op: cancel` is rejected by the daemon relay with `invalid_request`, by design. Teardown therefore travels on the ordered control — `dictation_end{reason: cancelled}` — when the route is still healthy, and nowhere at all when the route has already failed (it admits nothing; the daemon's first-audio watchdog releases the engine and the Gateway retires the route). A producer that simply stops talking keeps the Gateway's route occupied until its idle TTL, and every press on every client is answered `busy` in the meantime.
- Frames and the ordered `dictation_end` are refused from the moment a route
  fails, so a failed route is not a reusable transport: a new session
  (`dictation_id` is a fresh UUID) is the only way back.

### 5.1 Origin claim

Origin is server-bound socket authority. It is never derived from a payload
field, from `origin_client`, or from display metadata. The existing origin
registry is extended, not duplicated:

- A claim is keyed by `(user_id, device_id, request_id)` and stores the
  originating app socket id plus the device and session identity it was created
  for.
- A claim carries an explicit `scope` of `recipient` or `session`. Generic
  commands create `recipient` claims, which bind delivery of that command's
  reply only. The dictation and realtime-voice families create `session` claims,
  which additionally bind `session_id` and authorize their stream packets
  (`dictation_start`, `dictation_audio`, `dictation_end`, `voice_audio_chunk`,
  `voice_control`). Only a `session` claim may authorize a stream packet; a
  `recipient` claim never widens into one, and a later generic command for the
  same `request_id` never mutates the scope of a live session claim.
- Claim creation is atomic and owner-bound. The first writer wins: a create uses
  set-if-absent semantics with the TTL, so two concurrent app sockets in the same
  account cannot both own the same `request_id`.
- Re-registration by the owning socket refreshes the TTL and is idempotent.
  Re-registration by any other socket is refused with `origin_conflict`, and the
  refused packet is not forwarded anywhere.
- The claim is immutable while it lives: no command, route packet, event, or
  reconnect may transfer it to another socket. There is no reassignment path.
- On socket disconnect the Gateway retires every claim owned by that socket
  through the same per-socket cleanup sweep that terminates its routes. A retired
  claim has no recipient and cannot forward events or packets.
- Retired and logically expired ids are not immediately reusable. The existing
  registry retains a bounded retirement record for at least the maximum producer
  lifetime after the last admitted activity (the existing origin-route TTL,
  currently 3600 seconds). Attempts to bind that id to any socket during this
  interval fail with `origin_conflict`; a new transport session uses a fresh UUID.
  Logical claim expiry must not delete this protection before its retirement
  interval ends. This is per-request metadata, not packet history.
- No daemon producer, including a control-only operation or legacy voice session,
  may keep emitting after that maximum interval without new admitted activity.
  Disconnect cancellation and producer deadlines are therefore enforced, not
  inferred from route deletion. Queued or late daemon events are dropped against
  the retired claim and can never reach a later owner. Gateway restart preserves
  the registry's claim and retirement authority; it does not authorize rebinding.
- The claim is verified **before** forwarding any stream packet — dictation
  control, `dictation_start`, `dictation_audio`, `dictation_end`, voice
  `voice_audio_chunk`, `voice_control`, and daemon `device_voice_audio_chunk`.
  A packet whose `request_id` is claimed by another socket, or whose claimed
  device/session does not match the packet, is rejected without forwarding.

A generic command carrying an active stream's `request_id` is therefore inert
with respect to that stream: it may be routed as its own command or rejected, but
it can never overwrite the active recipient.

### 5.2 Gateway obligations

1. Authenticate the app socket and verify the caller owns `device_id`; reject
   otherwise without forwarding.
2. Establish or refresh the origin claim of §5.1 before anything is forwarded,
   and refuse foreign claims with `origin_conflict`.
3. Attach the authenticated origin projection to the routed command. It is
   informational: it never selects a recipient and never overrides the claim.
4. Unicast to the owning daemon socket only. Never a user room.
5. Preserve `version`, `dictation_id`, `request_id`, `op`, and `model_id`
   unchanged.

### 5.3 Daemon obligations

1. Dispatch `command == "dictation"` in the early command-dispatch chain,
   **before** the fall-through that registers a conversation session channel for
   the envelope's session. A dictation command must not create a session
   channel, session identity, or client tag.
2. Parse `op` with the same parser the local channel uses. An unknown `op` is a
   typed `dictation_error`, never a silent drop.
3. Serve `status`, `install`, `select`, and `prepareRuntime` from the shared
   service path, so the local and hosted channels cannot diverge in catalog,
   install, selection, or preparation behavior. These four commands are
   stateless and create no per-`dictation_id` context: at most one install is in
   flight per device, `status` and `select` answer synchronously, and
   `prepareRuntime` keeps its existing single-flight guard.
4. `prepareRuntime` remains the owner-only fixed action it is on the local
   channel: the daemon runs its own preparation entry point and accepts no
   caller-supplied path, command, or argument of any kind.
5. `start` opens at most one hosted dictation session. A second `start` for a
   different `dictation_id` while one is live is refused with
   `dictation_error.code = "dictation_busy"`, delivered to the origin only.
6. Reply to every command with daemon events per §7. Never to a room.
7. Start the session from the `dictation` command with `op: "start"` alone.
   `dictation_start` is Gateway-local route admission (§6.1) and is **not**
   forwarded to the daemon: the daemon never learns of it and must not wait for
   it. A Client that opens the route but sends no `start` command creates no
   session, and the route expires on its own TTL.

### 5.4 Where a rejection is reported

Failures are reported on the carrier that owns them, and only there:

| Failure owner | Carrier | Event |
|---|---|---|
| Gateway admission (claim, version, ownership, capability, route limits) | origin app socket | `dictation_route_error` (§6.4) |
| Daemon command execution (unknown `op`, missing model, busy session, preparation failure) | origin app socket, as a relayed event | `dictation_event` whose payload type is `dictation_error` (§7) |

A Gateway refusal therefore never appears as a daemon `dictation_error`, and a
daemon failure never appears as `dictation_route_error`. The Client treats both
as terminal for the session and maps each code to its own user-facing state;
neither is retried automatically.

## 6. Hosted channel: audio route

Audio never enters command payloads. It travels on a metadata-only relay route
that reuses the Gateway's existing binary relay machinery — route admission,
ownership binding, origin binding, TTL, active-route accounting, token bucket,
and per-socket cleanup — with a dictation-specific route kind.

### 6.1 Route open

```jsonc
// Client → Gateway. Socket.IO event: dictation_start
{
  "version": "v1",
  "dictation_id": "<identity>",
  "device_id": "<account device id>",
  "request_id": "<equal to dictation_id>",
  "audio": {"encoding": "pcm16le", "sample_rate": 16000, "channels": 1},
  "max_bytes": 12582912
}
```

The Gateway creates one route bound to the authenticated user, the originating
app socket and hardware, the target device, the session identity, and the
declared byte cap. Admission is fail-closed:

- the caller MUST be an authenticated app connection that owns `device_id`;
- the device MUST be online in the owned delivery room;
- the device MUST advertise `supports_dictation` **and** `dictation_relay_v1`;
- `audio` MUST be exactly 16 kHz mono PCM16 little-endian;
- `max_bytes` MUST be within `1 … 12 MiB`;
- a second live route for the same user and device is refused with `busy`;
- the origin claim of §5.1 MUST already exist and be owned by this socket for
  this `request_id`, `device_id`, and session; a missing claim is refused with
  `forbidden` and a foreign claim with `origin_conflict`.

A route never exists without a claim, and a claim is never created by a route
packet. Route admission therefore cannot create or transfer origin authority.

### 6.2 Frames

```jsonc
// Client → Gateway → daemon delivery room. Socket.IO event: dictation_audio
{
  "version": "v1",
  "dictation_id": "<identity>",
  "seq": 0,
  "data": <raw bytes>          // binary, never base64, never in a JSON string
}
```

The Gateway adds `device_id`, `request_id`, and the authenticated user context
it already has, and forwards the frame unchanged in order. It never reorders,
coalesces, retransmits, encodes, or inspects audio content. `dictation_end` is
forwarded the same way, carrying `device_id`, `dictation_id`, `session_id`,
`request_id`, and `reason`, so the daemon can verify the identity of a control
packet without trusting the room.

Payload format is exactly the local channel's: raw signed 16-bit little-endian
samples, 16 kHz, one channel, no container, no header, no framing header. Frame
boundaries are transport framing only; the recognizer is agnostic to them.

`data` is a **binary attachment**, never a payload value. Socket.IO encodes the
frame as a `BINARY_EVENT` with one attachment only when its encoder finds a
binary buffer inside the packet; anything else falls back to JSON text. The
producer therefore MUST put a typed byte buffer there (`Uint8List` in Dart) and
MUST NOT send base64, a JSON string, or a JSON array of integers. An integer
array is not raw bytes, and the Gateway refuses it with `invalid_request` for
that session (§8). The container the capture layer hands over is not a wire fact:
the channel adapter normalizes every frame before emitting it.

Two tests hold this shape from both ends, against one shared field table
(`client/test/fixtures/dictation/hosted_audio_frame.json`):

- `client/test/unit/dictation/hosted_dictation_wire_test.dart` encodes the frame
  the Client builds with the real Socket.IO parser and asserts a `BINARY_EVENT`
  carrying exactly one attachment whose bytes are the PCM samples — and keeps the
  integer-array shape executable as the recorded failure mode.
- `backend/tests/unit/test_dictation_relay_wire_mirror.py` is the hosted
  Gateway's read-only mirror: it asserts the same field table (version,
  identity, `seq`, data bytes) against its own copy of that fixture and that the
  forwarded frame carries those bytes unchanged.

### 6.3 Ordered route control

```jsonc
// Client → Gateway → daemon delivery room. Socket.IO event: dictation_end
{"version": "v1", "dictation_id": "<identity>", "reason": "stopped|cancelled"}
```

`dictation_end` is the hosted carrier for the daemon's `stop` and `cancel`
commands. It is admitted only when the caller's claim of §5.1 is present and
owned; a foreign or missing claim is rejected with `forbidden` and nothing is
forwarded.

The Gateway forwards it to the daemon delivery room as an ordered route control:
for a given `dictation_id`, route packets — `dictation_audio` frames and
`dictation_end` — are processed under one per-route FIFO. A control packet can
never be emitted ahead of a frame that was admitted before it, and a frame can
never be admitted after the control. This is the same per-route ordering
primitive the relay already uses for concurrent media handlers, not a new
mechanism.

The daemon maps the reason to its existing command: `stopped` → `stop` (drain,
final transcripts, then `dictation_done`), `cancelled` → `cancel` (discard). An
`dictation_end` that arrives for a session the daemon no longer holds is
answered with `dictation_error{code:"unavailable"}` to the claim owner and is
otherwise inert.

`dictation_end` also terminates the route ingress: no frame admitted after it.
It does **not** retire the claim. The drain it asks for still has results —
`dictation_final`, then `dictation_done` — and those are delivered to the claim
owner after ingress has closed. The claim therefore stays valid for delivery
until the daemon reports its terminal `dictation_done`, or until the producer
deadline of §5.1 expires, whichever comes first. The daemon arms that deadline as
a real per-session timer when the session begins and re-arms it on admitted
activity; it is cancelled on close, and a callback that fires after close can
never end a later owner's session. An idle producer that loses its abort
notice therefore cancels itself and releases the lease instead of holding it
until the socket drops. Retirement on disconnect, on
supersede, or on expiry is unchanged; retiring at end-receipt is a contract
violation because it would silently discard the transcript of a normal stop.

When no route was ever opened — the Client aborted before the first frame — the
same claim check applies and the ordered control is still delivered, so a
session can always be ended without a route.

### 6.4 Gateway → Client acknowledgements

```jsonc
// Origin app socket only. Socket.IO event: dictation_route_ack
{"version": "v1", "dictation_id": "<identity>", "state": "started|ended", "next_seq": 0}

// Origin app socket only. Socket.IO event: dictation_route_error
{"version": "v1", "dictation_id": "<identity>", "error_code": "<code>", "detail_code": "<optional>"}
```

`dictation_route_error` is terminal: the route is gone and the Client MUST stop
capture and end the dictation session. `dictation_route_ack` is informational
and MUST NOT gate capture; capture is gated by `dictation_ready` (§6.7).

Route error codes: `invalid_request`, `incompatible`, `offline`, `forbidden`,
`origin_conflict`, `busy`, `size_limit`, `rate_limited`, `expired`,
`sequence_conflict`, `unavailable`.

### 6.5 Ordering, limits, and lifecycle

| Rule | Value | Enforced by |
|---|---|---|
| Audio encoding | 16 kHz mono PCM16 LE | Client, Gateway, daemon |
| Audio frame size | ≤ 32 KiB (≈1024 ms); SHOULD be 20–100 ms | Client splits; Gateway rejects larger with `size_limit` |
| Session audio cap | declared `max_bytes`, bounded 12 MiB | Gateway and daemon |
| Session duration | 300 s (existing five-minute cap) | Client and daemon |
| Sustained rate | 4 MiB/s with 8 MiB burst, per user+device, own bucket | Gateway |
| Route TTL | 300 s, refreshed by accepted frames | Gateway |
| Active routes | exactly one per user+device | Gateway |
| Frame ordering | `seq` strictly increases; a repeated or regressed value is `sequence_conflict` and closes the route | Gateway; daemon independently requires contiguity and reports drops |

Ordering authority is split on purpose, and the split is normative. The Gateway
enforces replay and regression protection because it owns admission: it admits a
frame only when its `seq` is greater than every `seq` already admitted on that
route, and a repeat or regression is `sequence_conflict`, which closes the route.
The daemon enforces contiguity because it owns the transcript: a forwarded frame
whose `seq` skips a value ends the session as
`dictation_error.code = "audio_gap"` instead of emitting a transcript with a hole
in it, and exact duplicates are dropped and counted in `dropped_chunks`, which
`dictation_done` already reports. A gap therefore fails closed once, at the owner
of the text, and no layer ever fabricates continuity.

Enforcement is atomic and shared. Ownership, ordering, the byte cap, and the rate
bucket are enforced through the existing registry and limiter, so the result is
identical on whichever Gateway worker handles the packet: a stream packet is
admitted only if shared state admits it. Counters are bounded and shared, and no
per-frame history is retained — the route record keeps totals and the last
admitted `seq`, not a frame log. A cheaper hot path is legitimate only as a later
optimization backed by measured evidence; correctness of ownership, ordering,
caps, and rate always wins over it, and no per-worker cache may become the
authority for any of them.

Cleanup is mandatory in both directions:

| Trigger | Gateway | Daemon |
|---|---|---|
| Client socket disconnects | Terminate every route owned by that socket; emit `dictation_abort{reason:"client_disconnect"}` to the daemon room | Close the matching hosted session and release the recognizer |
| Route expires | Emit `dictation_route_error{expired}` to the origin socket and `dictation_abort{reason:"expired"}` to the daemon room | Same as above |
| Daemon socket disconnects | Stop admitting frames for that device; the next frame fails with `offline` | All hosted dictation sessions close |
| Client sends `dictation_end` | Forward the ordered control, then terminate the route | Drain or discard per the reason, then emit terminal events |
| Session reaches its duration cap | Nothing extra: the Client sends `dictation_end`; TTL is the backstop | Emit `dictation_error{code:"session_limit"}` as today |

```jsonc
// Gateway → daemon delivery room. Socket.IO event: dictation_abort
{"version": "v1", "dictation_id": "<identity>", "reason": "client_disconnect|expired|superseded|backend_error"}
```

`dictation_abort` is advisory-but-authoritative: on receipt the daemon MUST
cancel the session. Losing it must not leak an engine, so the daemon also closes
hosted sessions on socket disconnect and on its own session caps.

### 6.6 Control-only lifecycle

`status`, `install`, `select`, and `prepareRuntime` can run with no route at all,
so their lifecycle is bounded without route cleanup:

- they create no per-`dictation_id` state in the daemon and no listener that
  outlives the operation; replies are addressed by the origin claim alone;
- at most one install is in flight per device; progress streams to the claim
  owner and nowhere else;
- when the owner's socket disconnects or its claim expires, an in-flight install
  is abandoned with its partial artifacts discarded and the daemon keeps no
  pending operation, so a later session starts clean;
- after claim retirement the Gateway rejects further events for that `request_id`;
  the daemon's operation finishes or aborts within the producer deadline of §5.1,
  with cancellation signalled even when no audio route was opened;
- no control-channel map may grow with command count: the daemon holds at most
  one hosted dictation session and one in-flight install per device.

### 6.7 Capture start is handshake-gated, and ordering is not delegated to it

The Client MUST NOT start microphone capture until it receives
`dictation_ready` for its own `dictation_id`, exactly as on the local channel.
That is a user-experience and session-ordering guarantee, not the admission
authority: the Gateway still rejects a frame for an unknown or unclaimed
`dictation_id` whatever the Client does, and a frame that arrives without a route
is rejected with `forbidden` or `expired` rather than buffered indefinitely. The
daemon keeps its existing bounded pre-session buffer as a safety net for
reconnects and duplicate presses; that buffer is bounded by bytes and is not a
replay channel.

No layer may claim ordering safety from this handshake. Cross-packet ordering is
guaranteed by the per-route FIFO of §6.3, and rejection of unadmitted traffic by
the claim check of §5.1.

## 7. Hosted channel: daemon events to the origin

Daemon events ride the existing `device_event` path with the existing declarative
delivery envelope. The Gateway routes by `delivery.scope` only; it never inspects
the event name.

```jsonc
// Socket.IO event: device_event
{
  "device_id": "<authenticated device id>",
  "type": "device_event",
  "event": "dictation_event",
  "event_id": "<opaque unique id>",
  "delivery": {"scope": "origin", "request_id": "<the registered request id>"},
  "payload": {
    "version": "v1",
    "dictation_id": "<identity>",
    "type": "stt_status|stt_download_progress|dictation_ready|dictation_partial|dictation_final|dictation_done|dictation_error",
    // …the canonical event fields from §3, unchanged
  }
}
```

Rules:

- `delivery.scope` MUST be `origin`. Dictation is never broadcast: not to
  `platform_family`, not to `hardware`, not to a user room.
- A missing, expired, or unmatched `request_id` is dropped fail-closed. There is
  no broadcast fallback and no room fallback.
- `payload.type` carries the canonical event name unchanged; the remaining
  payload fields are that event's fields verbatim. One relayed event name keeps
  the relayed channel addressable while preserving vocabulary parity.
- The envelope carries no `session_id`. A dictation transport session is not a
  conversation session, so tagging one on the envelope would create a false
  conversation identity; identity lives in the payload as `dictation_id`.
- The Client adapter reshapes `device_event.payload` into
  `{"event": payload.type, ...payload fields}` so the dictation session, cubit,
  and UI consume identical shapes from both channels. No client state machine
  may learn which channel produced an event.
- Delivery metadata (`origin_client`) is informational only and never affects
  authorization, execution, or recipient selection.

## 8. Client-visible outcome mapping

Transport failures are a different namespace from recognition failures. The
Client adapter maps route errors onto the existing dictation error surface so the
session, cubit, and UI need no new states:

| Route error | Client dictation code |
|---|---|
| `busy` | `dictation_busy` |
| `size_limit`, `rate_limited` | `session_limit` |
| `invalid_request` | `relay_invalid_request` |
| `forbidden`, `origin_conflict` | `relay_forbidden` |
| `incompatible` | `update_required` |
| `offline`, `expired`, `unavailable`, anything undeclared | `relay_unavailable` |

`relay_invalid_request` exists because "the request this Client just built was
refused as malformed" is diagnosable and is not a retry-later outcome; folding it
into `relay_unavailable` hid a wire-encoding defect behind a generic connection
notice. It is still not a version mismatch, so it is never promoted to
`update_required`.

`relay_forbidden` exists for the opposite reason: `forbidden` means there was no
claim for this route or order, and `origin_conflict` means the id is already bound
to another producer. Both are refusals of **authority**, not connectivity — a
Client-ordering defect surfaced to the owner as "this device cannot relay
dictation on the current connection", which blames a network that was never
involved. One code covers both: what the owner must do is identical (start a fresh
session), and the raw Gateway code stays in the transport log for diagnosis.

`incompatible` is a version mismatch: retrying the same build can never clear it,
so it is the one refusal that is actionable and it reuses the existing
`update_required` verdict instead of a new sentence.

`offline`, `expired`, `unavailable`, and any code a later Gateway adds remain
retry-later outcomes.

Recognition failures keep their daemon codes (`unavailable`, `model_unknown`,
`model_not_installed`, `dictation_busy`, `session_limit`, `no_speech`,
`install_in_progress`, `prepare_unavailable`, `internal`, `audio_gap`, plus the
readiness reasons `dictation_disabled`, `unsupported_platform`,
`native_runtime_missing`, `native_runtime_preparing`,
`native_runtime_install_failed`).

`native_runtime_install_failed` means a packaged `agent-runtime` download,
verification, or extraction failed for this Agent. It never fails the Agent
install or update: it disables dictation only, and `prepareRuntime` re-attempts
the verified download (a source checkout starts the developer tool instead). See
[native_stt_runtime_platforms.md](native_stt_runtime_platforms.md#failure-policy-dictation-only).

## 9. Compatibility and fail-closed policy

| Combination | Required behavior |
|---|---|
| New Client, old daemon (no `dictation_relay_v1`) | Dictation stays local-only. A remote device keeps the existing "not available on this connection" outcome; the Client never attempts the relay. |
| New daemon, old Client | Unaffected. The old Client never emits dictation relay traffic and keeps its current behavior. |
| New Client, old Gateway (capability discarded) | The Client sees no `dictation_relay_v1`, so the hosted channel is treated as unavailable. No partial feature, no silent fallback. |
| Old daemon, new Gateway | `dictation_start` fails closed with `incompatible`; nothing is admitted, nothing is broadcast. |
| Any version mismatch in `version` | Fail closed with `incompatible` on the route and `invalid_request` on commands. |

There is no downgrade path that widens delivery scope. A missing identity, a
missing capability, an expired route, or an unknown version always ends in a
typed error to the origin socket.

## 10. Legacy voice origin correlation

The realtime voice path predates origin delivery and currently leaks and drops
traffic in four source-verifiable ways:

1. Daemon output audio is emitted with only `device_id` and the audio bytes, so
   the Gateway cannot identify the originating client and broadcasts the relayed
   audio to the account's whole app room. Every Client in the account plays it.
2. Daemon control and transcript events (`voice_text_response`,
   `voice_user_transcription`, `voice_interrupted`) are emitted as bare
   `device_event` frames with no delivery envelope, so the Gateway rejects them
   fail-closed and remote users never receive transcription or interruption
   state.
3. Client → daemon audio and control frames carry no session or request
   identity, so a daemon serving two Clients cannot attribute audio to the
   session that produced it, and cannot correlate any reply.
4. The Client plays any relayed audio frame it receives without checking device
   or session identity, which turns the broadcast in (1) into cross-client
   playback.

Repairing this cannot be a Gateway-only change: the existing payloads do not
carry enough identity for the Gateway to select a single recipient, so the
daemon, the Client, and the Gateway must all change together under one contract.

### 10.1 Required contract

- One voice session identity, minted by the Client with the same
  collision-resistant generator as `dictation_id` and used for the whole
  session: `voice_session_id`, carried as the existing `session_id` field.
- One correlation identity per voice session: `request_id`, client-supplied and
  equal to `voice_session_id`. The `start_voice` command claims it under the
  §5.1 rules: atomic, owner-bound, immutable, and retired on disconnect with
  bounded protection against late traffic and id reuse. A
  foreign claim is refused with `voice_relay_error{code:"origin_conflict"}` and
  nothing is forwarded.
- Client → Gateway: `voice_audio_chunk` and `voice_control` MUST include
  `session_id` and `request_id`, and the Gateway MUST reject frames without them
  with `voice_relay_error{code:"identity_required"}` to the originating socket.
- Gateway → daemon: `voice_audio_chunk_relay` and `voice_control_relay` MUST
  carry `session_id` and `request_id` alongside the payload they already carry,
  and the claim in §5.1 is verified before forwarding either direction.
- Daemon → Gateway audio: `device_voice_audio_chunk` MUST carry `device_id`,
  `session_id`, `request_id`, and the audio bytes.
- Gateway → Client audio: the Gateway MUST resolve `request_id` in the origin
  registry and unicast to exactly that app socket. Missing, expired, or
  mismatched routes are dropped with no room fallback.
- Daemon → Gateway control/transcript: `device_event` with
  `delivery: {scope: "origin", request_id}`, `event_id`, and `session_id`.
- Origin loss reuses the control path instead of adding an event: when the
  Gateway can no longer deliver voice output to a claim, it sends
  `voice_control_relay{event: "stop_voice", session_id, request_id}` to the
  daemon so the producer ends that session instead of emitting into a dead
  route. `stop_voice` is already terminal in the daemon and already filtered by
  identity, so no new vocabulary and no separate cancellation channel appear.
- Daemon in: the cloud voice channel MUST subscribe per session and ignore
  relayed frames whose `session_id`/`request_id` are not its own, so one daemon
  serving two sessions can never cross-wire audio.
- Client in: the cloud voice branch MUST ignore relayed audio and device events
  whose `session_id`/`request_id` are not its own active session, in addition to
  its existing device check.

```jsonc
// Client → Gateway → daemon
{"device_id": "<account device id>", "session_id": "<voice session>", "request_id": "<equal to session_id>", "data": <raw bytes>}   // voice_audio_chunk / voice_audio_chunk_relay
{"device_id": "<account device id>", "event": "interrupt", "session_id": "<voice session>", "request_id": "<equal to session_id>"} // voice_control / voice_control_relay

// Daemon → Gateway → origin app socket only
{"device_id": "<authenticated device id>", "session_id": "<voice session>", "request_id": "<equal to session_id>", "data": <raw bytes>} // device_voice_audio_chunk
{"device_id": "<authenticated device id>", "type": "device_event", "event": "voice_text_response", "event_id": "<id>",
 "session_id": "<voice session>", "delivery": {"scope": "origin", "request_id": "<equal to session_id>"},
 "payload": {"text": "…"}}

// Gateway → originating app socket only
{"version": "v1", "session_id": "<voice session>", "request_id": "<equal to session_id>", "error_code": "identity_required|origin_conflict|forbidden|offline|expired|incompatible"}
```

### 10.2 Compatibility policy

The repair is deliberately not backward compatible with unidentified voice
traffic, because the only available fallback is the broadcast that causes the
leak. A client that sends no identity receives
`voice_relay_error{code:"identity_required"}` and the session ends; the UI MUST
present an update-required state instead of degraded behavior. Devices that do
not advertise `voice_origin_v1` are not relayed at all. Agent and Client ship the
repair together, and the Gateway treats unidentified voice traffic as a protocol
violation from that point on.

## 11. Privacy and logging invariants

- No audio bytes, no transcript text, no model file contents, no credentials, and
  no local filesystem paths in any log or diagnostic event at any layer.
- Gateway diagnostics may record lifecycle, type, count, and code metadata only:
  route opened, closed, expired; frames forwarded and rejected counts; error
  codes. Never payload content.
- Relay state is metadata-only. Audio bytes never enter Redis, PostgreSQL, the
  filesystem, `device_command`, or `device_event`.
- Dictation events keep their existing no-text logging rule: session start,
  drain, `audio_ms`/`decode_ms` per final, and error codes only.

## 12. Testable invariants

Local and hosted channels must satisfy the same set, because the vocabulary is
identical:

- **D1** A hosted session produces the same ordered event sequence as the local
  session for the same audio fixture and model mode.
- **D2** `dictation_event` is delivered only to the originating app socket; a
  second authenticated client of the same account receives nothing.
- **D3** A frame whose `seq` repeats or regresses fails closed with
  `sequence_conflict` and the route stops admitting frames; a forwarded gap ends
  the daemon session with `audio_gap`.
- **D4** A frame larger than 32 KiB is rejected with `size_limit` and never
  reaches the daemon.
- **D5** `dictation_start` from a device without `dictation_relay_v1` fails with
  `incompatible`; no route is created and nothing is forwarded.
- **D6** A second concurrent `dictation_start` for the same user and device fails
  with `busy`.
- **D7** An expired route rejects further frames with `expired` and notifies both
  the origin socket and the daemon room.
- **D8** Client socket disconnect terminates its routes, closes the daemon's
  hosted session, and releases its owned lease and engine borrow. No active
  session leaks; the shared engine's bounded idle-residency policy is unchanged.
- **D9** A daemon event with no `delivery` envelope, or with `scope != "origin"`,
  is never delivered to any client.
- **D10** No log line, metric, or stored route record contains audio bytes or
  transcript text.
- **D11** Model `status`, `install`, `select`, and `prepareRuntime` behave
  identically over both channels, including progress events, and every reply is
  origin-only.
- **D12** A dictation command creates no conversation session channel, session
  identity, or client tag in the daemon.
- **D13** Origin takeover is impossible: a second authenticated app socket of the
  same account cannot claim or take over an active `request_id`, and a generic
  command carrying that `request_id` cannot change the active stream's
  recipient.
- **D14** Disconnect retires the claim and terminates its routes in the same
  pass. Rebinding the id is refused throughout the bounded retirement interval;
  delayed events, control-only progress, and packets from the old producer have
  no recipient. Fake-clock expiry and Gateway-restart tests prove that no
  producer can outlive that protection or send to a later owner.
- **D15** `stop`/`cancel` (`dictation_end`) never overtake a frame that was
  admitted before them, and state stays bounded: no per-frame history, no
  unbounded per-command or per-`dictation_id` maps.
- **D16** Unknown additive capability keys do not fail registration, while a
  malformed recognized `dictation_relay_v1` or `voice_origin_v1` does, so a
  device can never register advertising a capability it cannot honor.

Legacy voice:

- **V1** Daemon output audio reaches only the originating app socket.
- **V2** Transcript and interruption events reach only the originating app
  socket.
- **V3** Unidentified voice traffic is rejected with `identity_required` and is
  never broadcast.
- **V4** A daemon serving two voice sessions never delivers one session's audio
  to the other's frame stream.
- **V5** A Client ignores relayed voice audio that does not match its own
  session identity.
- **V6** A second app socket in the same account cannot claim an active voice
  `request_id`; its `voice_audio_chunk`, `voice_control`, and `start_voice` are
  refused with `origin_conflict` and never forwarded.

## Related

- [Local Dictation](local_dictation.md) — ownership boundary, model catalog,
  residency, and the platform gate.
- [Experimental Realtime Voice](voice_streaming.md) — the duplex voice path this
  document repairs for origin delivery.
- [Hosted Services Boundary](hosted_services_boundary.md) — what the hosted
  Gateway owns and what stays local.
