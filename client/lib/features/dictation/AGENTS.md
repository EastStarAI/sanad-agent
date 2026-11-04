# Dictation Feature Contract

## Scope
This contract applies to `client/lib/features/dictation/`.

## Runtime Ownership
- Transcription belongs to the agent daemon. The client only captures microphone audio, forwards PCM16, and renders daemon events; it never transcribes, edits, or fabricates transcript text.
- `DictationCubit` owns session lifecycle, model state, preview policy, and error projection.
- `DictationTransportResolver` is the **only** place that decides which transport a session uses. No other dictation code may branch on connection scope, and a new transport is added inside that resolver and nowhere else.
- Capture uses 16 kHz mono PCM16 little-endian and stays separate from the voice-call service: no playback, no echo-cancellation session.
- Local dictation is desktop-only and uses the same active-Home Local Gateway credential as other local transports; never place the credential in the WebSocket URL.

## Protocol
- Commands sent to the daemon: `start`, `stop`, `cancel`, `status`, `install`, `select` (`event` field, optional `model_id`).
- Events consumed: `stt_status`, `stt_download_progress`, `dictation_ready`, `dictation_partial`, `dictation_final`, `dictation_done`, `dictation_error`.
- A batch engine emits finals only; `dictation_final` for a segment is terminal and never mutates afterwards.
- The daemon buffers socket audio until the session engine is running (bounded), so the first words spoken during a model load are not lost; it also holds a single dictation lease and refuses a second session with `dictation_busy`.
- Never log audio bytes or transcript text; log counts, codes, and durations only.

## Composer Insertion
- `DictationInsertion` owns the composer range dictation writes into: partials replace only that range, finals commit and advance it, cancel removes it in one step.
- A manual edit inside the owned range ends dictation's ownership of it; the user's text is never overwritten.
- A live IME composition defers the write and replays it when composition ends, so Arabic preedit is never destroyed.
- The caret is never stolen: an offset outside the range keeps its place (shifted by the delta), and an offset inside it follows the replacement.
- A session belongs to one `scopeKey` (conversation); switching it cancels the live session so no transcript crosses conversations.

## Settings
- The client never edits agent configuration directly. Dictation settings (model selection, enable toggle) are sent as commands over the existing connection layer and persisted by the daemon, which then re-advertises `supports_dictation`.
- A future settings surface lives in the **device settings page** as a Dictation section; the composer only carries the mic button and the first-use model sheet.

## Presentation
- The mic button renders only when `capabilities.supportsDictation` is true; an unsupported device must explain the daemon-reported reason instead of degrading silently.
- The model sheet reuses the `full_access_confirmation_dialog.dart` visual pattern and is localized for English and Arabic.
