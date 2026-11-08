# Dictation Feature Contract

## Scope
This contract applies to `client/lib/features/dictation/`.

## Runtime Ownership
- Transcription belongs to the agent daemon. The client only captures microphone audio, forwards PCM16, and renders daemon events; it never transcribes, edits, or fabricates transcript text.
- `DictationCubit` owns session lifecycle, model state, preview policy, and error projection. It holds **one** transport per session: a stale transport is detached (listener cancelled before close) and closed before a replacement is created, so no orphan socket keeps a daemon lease alive.
- `DictationTransportResolver` is the **only** place that decides which transport a session uses. No other dictation code may branch on connection scope, and a new transport is added inside that resolver and nowhere else.
- Capture uses 16 kHz mono PCM16 little-endian and stays separate from the voice-call service: no playback, no echo-cancellation session.
- Local dictation is desktop-only and uses the same active-Home Local Gateway credential as other local transports; never place the credential in the WebSocket URL.
- Session identity is minted by `DictationIdentity` (`dict-<uuid>`), never derived from a timestamp, a counter, or a conversation id. The hosted channel carries it as both `dictation_id` and `request_id`, and the local channel as `session_id`.

## Protocol
- Commands sent to the daemon: `start`, `stop`, `cancel`, `status`, `install`, `select` (`event` field, optional `model_id`).
- Events consumed: `stt_status`, `stt_download_progress`, `dictation_ready`, `dictation_partial`, `dictation_final`, `dictation_done`, `dictation_error`.
- A batch engine emits finals only; `dictation_final` for a segment is terminal and never mutates afterwards.
- The daemon buffers socket audio until the session engine is running (bounded), so the first words spoken during a model load are not lost; it also holds a single dictation lease and refuses a second session with `dictation_busy`.
- Never log audio bytes or transcript text; log counts, codes, and durations only.
- The hosted channel must produce the same `{"event", ...fields}` maps as the local one, so no state machine above the transport can tell them apart. Only the transport may depend on the relay envelope: it claims with the `dictation` command before opening the route, splits frames to the advertised bound, carries `stop`/`cancel` as the ordered `dictation_end`, and re-checks identity on every relayed event. The wire contract is [Dictation Transport Protocol](../../../../docs/technical/dictation_transport_protocol.md).
- `stt_status.supported` is the platform verdict; `ready` plus `reason` is the current state. Keep them separate: a supported device that is missing its native runtime must keep its reason so the setup action stays reachable.

## Composer Insertion
- `DictationInsertion` owns the composer range dictation writes into: partials replace only that range, finals commit and advance it, cancel removes it in one step.
- A manual edit inside the owned range ends dictation's ownership of it; the user's text is never overwritten.
- A live IME composition defers the write and replays it when composition ends, so Arabic preedit is never destroyed.
- The caret is never stolen: an offset outside the range keeps its place (shifted by the delta), and an offset inside it follows the replacement.
- A session belongs to one `scopeKey` (conversation); switching it cancels the live session so no transcript crosses conversations.

## Settings
- The client never edits agent configuration directly. Dictation settings (model selection, enable toggle) are sent as commands over the existing connection layer and persisted by the daemon, which then re-advertises `supports_dictation`.
- The Dictation section of the device settings page renders the daemon's own `dictation` projection (enabled, `managed_externally`, selected model, size, readiness, busy, reason). It must not read `config.yaml` or keep a second copy of that state, and it hides itself when the Agent serves no such block.
- A catalog row owned by the daemon is identified by `label_code` (`path_override`) and localized here; the daemon never ships user-facing copy.

## Presentation
- The mic button renders only when `capabilities.supportsDictation` is true; an unsupported device must explain the daemon-reported reason instead of degrading silently.
- The mic button is never hidden on a device that changes channel: readiness comes from `blockedReason`, and every terminal code has a localized notice (`relay_unavailable`, `dictation_disabled`, `update_required`, `invalid_session_identity`, `remote_only_platform`, `dictation_unavailable`).
- The model sheet reuses the `full_access_confirmation_dialog.dart` visual pattern and is localized for English and Arabic.
