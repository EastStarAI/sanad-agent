---
title: "Message Edit and Retry UX"
description: "Specification for inline edit and retry of the latest root user turn without deleting original history."
---

# Message Edit and Retry UX

## Scope

Sanad exposes Edit and Retry only for the latest durable **root user turn**
whose canonical event carries stable `message_id`, `turn_id`, and raw
`request_id`, plus daemon-authored `input_kind=root_turn` and
`replay_eligible=true`. Missing or false eligibility fails closed in the UI.
Older root turns remain read-only because replaying one would
discard newer user-owned turns and requires the separate conversation-fork
design.

Steer bubbles are never editable or retryable, including pending steers,
delivered steers, and steers reconstructed from tool-result metadata. Those
events keep their existing Cancel/Delete or read-only presentation.

A completed context-compaction event establishes a simple read-only cutoff. Edit
and Retry are absent from every user message at or before that event; only a new
root user message after the latest completed compaction may expose them. Failed
or cancelled compaction does not establish the cutoff. The daemon enforces the
same rule before Stop or history mutation, so an older client cannot bypass it.

## Inline edit

- Edit replaces the root user message body with an inline multiline input in
  the same timeline position.
- `Send` and `Cancel` appear below the input, aligned to its leading edge.
- Desktop hardware Enter submits the edit and Shift+Enter inserts a line break.
  Android/iOS software-keyboard Enter inserts a line break; the visible Send
  button submits the edit.
- Cancel restores the original bubble without contacting the daemon.
- Navigating to another session, device, or New Conversation cancels the
  transient edit draft.
- The edit controls are disabled while replay confirmation or dispatch is
  pending.

## Retry

Retry reuses the latest root user turn text. Edit Send uses the edited text.
Both use the provider instance, model, and thinking selection currently
displayed when the final replay request is submitted.

## Tool side-effect confirmation

The daemon classifies the target root turn as `safe`, `unsafe`, or `unknown`
from durable tool-call and replay-safety metadata across the whole turn.

- `safe` proceeds without a side-effect warning.
- `unsafe` warns that file or external-system changes may repeat.
- `unknown` warns that Sanad cannot verify replay safety.
- Canceling the warning performs no Stop and no history mutation.
- Continuing submits an explicit confirmation and then enters the authoritative
  idle boundary.

If the original turn contains one or more steers, Sanad also asks the user to
confirm that those steering messages will not be sent again. Canceling that
prompt likewise performs no Stop and no history mutation.

## Original history

Successful Edit or Retry does not delete the original turn. The previous root
message, reasoning, tool calls, and dependent steers remain stored and become
inactive. The timeline shows only the active replacement turn. Reopening the
session after success shows the same active history; the original attempt does
not reappear.

## User-visible failure behavior

Sanad keeps the original timeline unchanged when the turn boundary is missing,
the target is a steer, the target is no longer the latest active root turn,
confirmation is declined, history revision is stale, or the daemon cannot reach
idle. Legacy messages without durable identity are not guessed or replayed.
