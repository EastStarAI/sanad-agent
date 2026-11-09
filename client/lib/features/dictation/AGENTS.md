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
- `seq` is the **replacement key** of a transcript segment, and the Client keys the session by it: `DictationState.segments` is indexed by `seq`, so a final **replaces** the segment its partial previewed, a repeated final for one `seq` replaces again instead of appending a second copy, and a late partial never rewrites a `seq` the daemon already finalized. Appending every final — the previous behavior — wrote one phrase into the composer twice.
- A batch engine emits finals only; `dictation_final` for a segment is terminal and never mutates afterwards.
- The daemon buffers socket audio until the session engine is running (bounded), so the first words spoken during a model load are not lost; it also holds a single dictation lease and refuses a second session with `dictation_busy`.
- Never log audio bytes or transcript text; log counts, codes, and durations only.
- The hosted channel must produce the same `{"event", ...fields}` maps as the local one, so no state machine above the transport can tell them apart. Only the transport may depend on the relay envelope: it claims with the `dictation` command before opening the route, splits frames to the advertised bound, carries `stop`/`cancel` as the ordered `dictation_end`, and re-checks identity on every relayed event. The wire contract is [Dictation Transport Protocol](../../../../docs/technical/dictation_transport_protocol.md).
- `stt_status.supported` is the platform verdict; `ready` plus `reason` is the current state. Keep them separate: a supported device that is missing its native runtime must keep its reason so the setup action stays reachable.
- `ready` covers the whole start, not just the engine: a Home with no installed model reports `ready: false, reason: model_not_installed`, and a streaming entry whose engine libraries cannot be resolved reports `sherpa_runtime_missing`. Trusting the daemon flag is correct **because** the daemon owns that fact; deriving readiness from a catalog row instead is what once made a model-less device look ready.

## Composer Insertion
- `DictationInsertion` owns the composer range dictation writes into: partials replace only that range, finals commit and advance it, cancel removes it in one step.
- A manual edit inside the owned range ends dictation's ownership of it; the user's text is never overwritten.
- A write never duplicates the session text: when the owned range was lost (a rebuild, a transient empty partial) the helper recovers it from the text this session already wrote and **replaces** that span. Appending the session text again is the defect that put one phrase in the composer twice.
- A live IME composition defers the write and replays it when composition ends, so Arabic preedit is never destroyed.
- The caret is never stolen: an offset outside the range keeps its place (shifted by the delta), and an offset inside it follows the replacement.
- A session belongs to one `scopeKey` (conversation); switching it cancels the live session so no transcript crosses conversations.

## Driver Seam
- `ext.sanad_client.dictation_control` locates the composer through `findElementByKey` (`client/lib/driver/driver_widget_filters.dart`), the same whole-tree traversal the inspector uses. It must never reintroduce a visited-element cap: a bounded walk answers `composer_not_mounted` on any Home with history while `inspect_ui` finds the same key instantly.
- `dictation_control{action:compose}` reports the composer from the composer's own `TextEditingController`, not from `DictationState`: the cubit drops its text when the session settles while the editor keeps it, so reading state answered `present: false, chars: 0` for a successful session.
- `ext.sanad_client.dictation_probe` counts **both** sources: `SanadSocketService.events` for the relay classes (`dictation_event`, `dictation_route_ack`, `dictation_route_error`, `voice_relay_error`, `voice_audio_chunk_relay`) and `DictationCubit.lifecycleEvents` — the events the cubit consumed from the dictation transport — for the local ones (`stt_status`, `dictation_ready`, `dictation_partial`, `dictation_final`, `dictation_done`, `dictation_error`). A local session opens its own WebSocket and never reaches the main socket, so the main-socket-only probe reported `total: 0` for a healthy local session. A local event carries no identity, so it counts as matched rather than foreign; only relay events can be foreign.
- Acceptance audio is committed: `client/test/fixtures/dictation/en_streaming_quick_brown_fox.pcm` (English streaming leg, paired with an English streaming model) and `ar_batch_dictation_check.pcm` (Arabic batch leg, paired with `egy-whisper-turbo-ggml-q8`) are raw PCM16LE, 16 kHz mono, under 200 KB, and asserted by `test/unit/dictation/dictation_audio_fixtures_test.dart`. A fixture decoded by the wrong language's model returns an empty final with no error, so the pairing is part of the leg.

## Settings
- The client never edits agent configuration directly. Dictation settings (model selection, enable toggle) are sent as commands over the existing connection layer and persisted by the daemon, which then re-advertises `supports_dictation`.
- The Dictation section of the device settings page renders the daemon's own `dictation` projection (enabled, `managed_externally`, selected model, size, readiness, busy, reason). It must not read `config.yaml` or keep a second copy of that state, and it hides itself when the Agent serves no such block.
- A catalog row carries identity and facts, never sentences: `name` is the model's own proper noun (identical in every locale), `description` is the model's locale map (`{en, ar}`, English fallback), and `badge`, `speed_tier`, `streaming`, `location`, `size_bytes` are facts. A row the daemon owns but did not publish as a model — the `stt.model_path` override — carries `label_code` instead. Badges, titles, and every other word stay Client strings.
- The model description is the **one** exception to "the daemon ships no user-facing copy": it belongs to the model, so it travels with the model. Adding a model must never require a Client string.
- `location` is `local` today and is already part of the row: the surface renders the field, not an assumption, so a `cloud` model is a catalog change rather than a UI change.

## Presentation
- The mic button renders only when `capabilities.supportsDictation` is true; an unsupported device must explain the daemon-reported reason instead of degrading silently.
- The mic button is never hidden on a device that changes channel: readiness comes from `blockedReason`, and every terminal code has a localized notice (`relay_unavailable`, `dictation_disabled`, `update_required`, `invalid_session_identity`, `remote_only_platform`, `dictation_unavailable`).
- The button is a session control, not a meter: idle shows the mic, an active session shows a Stop icon, and neither carries visible text — the tooltip is the only label.
- The live meter is drawn **inside the composer's bottom action row** (key `dictation_row_meter`), never in the composer background. While it is visible, the row's selectors (permission picker, model selector, thinking-level selector) are hidden and the meter takes their width; the Stop and Send buttons stay. Ending the session — Stop, auto-stop, error, or cancel — restores the row exactly as it was, because none of those controls change state while hidden.
- The meter's samples, smoothing, grow-in, floor, painter, and bar geometry are one implementation (`dictation_composer_backdrop.dart`); only its container adapts to the row (24 px height, leading-edge direction per `TextDirection`, and an opacity ramp that stays readable beside 32 px buttons).
- The model sheet reuses the `full_access_confirmation_dialog.dart` visual pattern and is localized for English and Arabic.
- A model row renders its name, badge, localized description, size, speed bars, and a streaming icon; installed rows come first. There is no search, no grouping, and no accuracy grade — a rank the catalog does not publish must not be invented in the UI. Every row field the driver projection must prove carries a key: `dictation_model_name_<id>`, `dictation_badge_<id>`, `dictation_model_description_<id>`, `dictation_speed_<id>`, `dictation_model_size_<id>`.
- First use is one path with one destination: a single press on a device that is not ready (no model, missing engine) opens the model sheet instead of starting a session. A session that is refused for `model_not_installed` after it started ends in the same sheet through the cubit's `sessionNeedsFirstUseSheet` flag — the only reader of that flag — plus a localized notice. Long-press keeps opening the sheet as the explicit settings route.
- The device settings card offers the same install route (key `device_settings_dictation_manage`), so a user fixing dictation from Settings never has to leave the page; there is exactly one install surface, and it is the sheet.
- Every readiness reason the daemon can report has a localized sentence (`model_not_installed`, `sherpa_runtime_missing`, `native_runtime_missing`, `native_runtime_preparing`, `native_runtime_install_failed`, `unsupported_platform`, `dictation_disabled`); an unknown code falls back to a neutral sentence and is never rendered verbatim.
