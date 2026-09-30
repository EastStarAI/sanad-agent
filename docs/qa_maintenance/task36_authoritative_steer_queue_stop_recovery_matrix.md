---
title: "Task 36 Authoritative Steer, Queue, and Stop Recovery QA Matrix"
description: "Regression coverage for daemon-owned delivery classification, pending-steer cancellation, queue mutations, lossless Stop draft recovery, and first-writer restart claims."
---

# Task 36 Authoritative Steer, Queue, and Stop Recovery QA Matrix

## Scope

This matrix verifies that the daemon, not the Flutter processing projection,
classifies delivery; that queue and pending-steer mutations are durable and
idempotent; and that Stop returns unexecuted input to the initiating client's
draft without loss or duplication.

## Delivery classification and identity

| Scenario | Expected result |
|---|---|
| Send `auto` while one owned run is `running` or `resuming` | The daemon classifies the request as pending steer on that exact `ActiveRun.agentRunner`; no second active work item is created. |
| The active run completes while `auto` is in transit | The same request starts once as a normal turn; its text and raw request id are preserved. |
| Send `auto` while the durable state is waiting, blocked, queued, or stopping | No absent or stale runner receives it; the ordinary admission/recovery owner returns the authoritative classification. |
| Send explicit `queue` behind older non-terminal work | One FIFO work item is created and its queued confirmation uses the raw request id. |
| Older work ends before explicit `queue` reaches admission | The request starts normally instead of becoming a queue with no predecessor. |
| A legacy client omits delivery intent | The daemon treats it as `auto`. |
| The UI event id is `user_R` while metadata contains request id `R` | Every promote, delete, cancel, history, and recovery command uses `R`; `user_R` remains display-only. |

## Pending-steer persistence and delivery

| Scenario | Expected result |
|---|---|
| Admit a new steer | The durable `pending` record is saved before confirmation and carries session, raw request, run, generation, receipt time, and revision. |
| Repeat the same admission | No second record, buffer entry, or timeline bubble is created and revision does not advance. |
| Receive duplicate or older lifecycle events | The client retains the highest revision and never resurrects cancelled input. |
| A long tool is executing | One `Pending` user bubble appears, but the text is absent from model context until a safe delivery boundary. |
| Delivery reserves the input and history save succeeds | State advances `pending -> delivering -> delivered`; the same bubble loses its badge and delete action without duplication. |
| History save fails after reservation | No false delivered event is published; the text remains recoverable. |
| Reconnect with delivered history and a pending snapshot | The client merges by raw request id and shows exactly one bubble in the latest state. |
| Daemon restart occurs before delivery | The text is not lost or injected into an unrelated generation; it is restored for its owner or converted to explicit recovery. |

## Cancellation race

| Scenario | Expected result |
|---|---|
| Delete a `pending` steer before reservation | The row and engine buffer become cancelled consistently; the bubble disappears only after confirmation and the text never enters the next model request. |
| Delivery reservation and cancel race | Exactly one compare-and-set transition wins. Cancel returns `cancelled`, or delivery returns `delivery_in_progress`/`already_delivered`; no false deletion occurs. |
| Repeat cancellation after success | `already_cancelled` removes any stale projection without changing revision or another request. |
| Cancel with a stale run/generation | `stale_owner` does not remove or deliver a record owned by a newer run. |
| Cancel an unknown request | `not_found` triggers authoritative hydration and does not mutate another steer. |

## Queue row actions

| Scenario | Expected result |
|---|---|
| Promote queued request R while a steerable run remains | R is removed from FIFO and admitted once as pending steer on the owning runner; the timeline and queue reuse identity R. |
| The run ends during promotion | R becomes a normal turn once rather than being dropped. |
| Stop owns the session during promotion | Promotion is rejected temporarily and R remains available for Stop recovery. |
| Delete a still-queued row | The work item is cancelled and the execution snapshot is recomputed in the same transaction; the UI removes the row after confirmation. |
| Delete a row that became running or processed | The daemon returns the explicit current outcome; the client does not claim deletion of running work. |
| Promote/delete commands are duplicated | Text is never injected or executed twice, and each row maintains action-local progress. |
| Queue-to-steer succeeds | The command carries the original text, stable target request id, and distinct command id; `session.queued_message_steer_result=promoted` removes Queue once and the pending projection appears once. |
| Queue-to-steer is rejected or stale | A typed terminal result ends loading and leaves the authoritative Queue row retryable; navigation is not required to clear progress. |

## Stop barrier and draft recovery

| Scenario | Expected result |
|---|---|
| Pending A/B, queued C/D, and current draft E exist before Stop | The initiating client persists exactly `A\nB\nC\nD\nE`; nothing is auto-sent. |
| Stop recovery contains a `pending_steer` item already visible in the timeline | The same recovery event removes that bubble immediately, restores its text only for the owning composer, and a delayed duplicate pending lifecycle cannot resurrect it. |
| A new request arrives after the Stop barrier | It is excluded from the old recovery outcome and survives for the next generation. |
| A steer is already `delivering` when Stop captures inputs | It follows its proven reservation result and is not falsely recovered as undelivered. |
| The active UI is displaying another session when recovery arrives | Only the stopped session's cached draft changes; the other composer remains untouched. |
| The same outcome arrives through local and cloud routes | `stop_request_id` deduplicates it and the prefix is applied once. |
| Transport disconnects after Stop but before draft acknowledgement | Reconnect retrieves the unacknowledged outcome; acknowledgement occurs only after the draft is persisted. |
| Another client observes queue clearance | It updates shared authoritative projections but does not prepend text to its unrelated local draft. |
| Another client reuses the broadcast `stop_request_id` to acknowledge a user Stop | The daemon rejects the acknowledgement because its private `recovery_owner_token` does not match; the outcome and text remain durable. |
| Daemon restarts with pending or unproven delivering steer | History/startup advertises `recovery_reason = daemon_restart`, `claim_required = true`, an item count, and no recovered text. |
| Two clients claim restart recovery with different command request ids | The first compare-and-set winner alone receives items with `claim_required = false` and matching `claimed_by`; the loser receives no text. |
| A losing restart claimant attempts to acknowledge the outcome | The daemon rejects the acknowledgement because `claimant_id` does not match durable `claimed_by`. |
| The winning client restarts between claim and recovered payload | Its draft-persisted claim id still matches `claimed_by`, so it applies the outcome once and acknowledges it. |
| A delivering steer is already present in durable history at daemon restart | Reconciliation marks it delivered instead of returning the same text to a draft. |
| Recovery acknowledgement succeeds | The daemon timestamps the outcome and clears stored item text; repeating the acknowledgement is harmless. |

## Presentation and accessibility

| Scenario | Expected result |
|---|---|
| Press Enter or click Send during running/resuming | Both send `auto`; the tooltip reads `Press Enter to steer`. After the matching pending-steer lifecycle accepts the request, the sent text is cleared from the composer while any newer edit remains intact. |
| Press Control+Enter or Command+Enter | The composer sends `queue`; no newline is inserted. |
| Render pending steer | `Pending` and `Delete pending message` are exposed in English semantics, and cancellation progress disables only that action. New tool activity stays above the unresolved projection. |
| Deliver a steer after later live activity | The delivered identity/revision replaces the temporary row once and moves it directly after its causal tool/message anchor; duplicate lifecycle and reconnect history preserve that order. |
| A pending steer changes state after the user opens another session | Its session-scoped lifecycle is retained, but neither the lifecycle nor its cancellation outcome inserts a bubble into the currently visible session. |
| Render a queued row | Steer and Delete are independently focusable and keep the row visible while awaiting daemon confirmation. |

## Required regression boundaries

- Terminal commit and active-work uniqueness from Tasks 31 and 35 remain
  unchanged: pending steer never becomes a second active work item.
- Waiting/blocked recovery controls remain operable and an explicit queue intent
  does not accidentally inject text into an absent runner.
- Tool-result steering markers remain model-only; neither logs nor visible tool
  output reveal marker internals or pending user text.
- Live events, history hydration, navigation, reconnect, and restart converge on
  one queue/pending projection per raw request id.

## Automated coverage ownership

- Agent persistence coverage owns lifecycle transitions, revision ordering,
  stale owners, queue mutation transactions, Stop outcome retention, and
  first-writer restart claims plus acknowledgement idempotency.
- Agent orchestration and engine coverage owns active-run selection, safe tool
  boundaries, history-save ordering, cancellation races, Stop barriers, and
  restart recovery.
- Protocol coverage owns typed intents, confirmations, lifecycle/mutation
  outcomes, raw request-id parity, origin routing, and history hydration.
- Client store/model coverage owns revision reducers, per-session isolation,
  history/live deduplication, and Stop draft correlation.
- Client widget coverage owns keyboard intent, tooltips, queue actions, pending
  presentation, progress, and English accessibility labels.
- Daemon-backed integration coverage owns long-tool cancel/delivery, restart,
  reconnect, and the complete A-through-E Stop recovery scenario.
