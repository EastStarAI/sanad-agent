---
title: "Message Edit and Retry QA Matrix"
description: "Quality Assurance matrix and test cases for the message edit and retry flow."
---

# Message Edit and Retry QA Matrix

## Inline presentation

- The latest durable **root** user bubble exposes Edit and Retry immediately
  after its live turn completes, without navigation or reconnect.
- Pending, delivered, and embedded steer bubbles do not expose Edit or Retry.
- Edit replaces the root bubble with one multiline input in place.
- Send and Cancel render below the input at the leading edge.
- Desktop Enter submits, desktop Shift+Enter inserts a newline, and Android/iOS
  software-keyboard Enter inserts a newline without submitting.
- Cancel restores the original message without a protocol command.
- Session, device, and New Conversation navigation discard the inline draft.
- Pending confirmation/dispatch disables duplicate Edit, Retry, Send, and Cancel
  actions.

## Boundary validation

- A latest active root user turn with `message_id`, `turn_id`, raw request
  identity, `input_kind=root_turn`, and `replay_eligible=true` can be retried.
- Missing/false daemon eligibility fails closed even when all three identities
  are present; a legacy user event without those identities has no controls.
- A steer target is rejected before Stop or history mutation.
- An older root user turn is rejected and newer messages remain unchanged.
- A stale revision, superseded target, or missing target does not mutate
  history.
- Accepted replay keeps the original records stored as inactive and shows only
  the replacement turn in the timeline.

## Authoritative idle transition

- Running, queued, waiting, blocked, resuming, and stopping sessions stop
  before replacement dispatch.
- Stopping never admits the replacement turn until the daemon reports `idle`.
- Queued and pending work owned by the same session cannot mix with the
  replacement turn.
- Stopping session A does not alter execution or history in session B.
- Rapid creation of session A and B yields distinct UUID identities, so replay
  isolation cannot collapse through a millisecond timestamp collision.
- Repeated replay commands produce at most one accepted replacement turn.

## Tool replay safety

- No-tool and fully replay-safe turns proceed without a side-effect warning.
- Any explicitly unsafe tool produces the side-effect warning, including an
  unsafe tool that occurred before a later steer in the same root turn.
- Missing safety metadata produces the unknown-safety warning.
- A turn that contains steers also requires confirmation that those steers will
  not be re-injected, even when tool safety is `safe`.
- Canceling either warning sends no confirmed replay, Stop, or history mutation.
- Continuing sends the required confirmation flags and then crosses the idle
  boundary.

## Route selection

- Retry and Edit Send carry the provider instance, model, and thinking mode
  currently selected in the composer.
- A selection changed while the warning is open is read again for the confirmed
  request.
- The daemon does not restore the original turn route implicitly when current
  route fields are supplied.

## Recovery

- Transport timeout leaves the original timeline visible.
- Reopening the session after acceptance hydrates only active history plus the
  replacement turn; superseded rows remain in the database and stay hidden.
- Reconnect cannot resurrect a superseded target from a stale live projection.
