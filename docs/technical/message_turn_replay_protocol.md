---
title: "Message Turn Replay Protocol"
description: "Technical specification for latest-root-turn replay with stable identity, soft rewind, and authoritative idle admission."
---

# Message Turn Replay Protocol

## Ownership

Historical edit/retry is a daemon-authoritative latest-root-turn replay
operation. It is distinct from `session.runtime_retry`, which resumes a
suspended provider request.

The durable target is the latest **active** user message whose
`input_kind` is `root_turn`. A steer is never a replay boundary, even when it
appears as a user timeline event and carries its own `request_id`.

Task 49 truncated the target turn from durable history. Task 51 replaces that
mutation with **soft rewind**: superseded records remain stored and inactive.

## Identity

These identities are not interchangeable:

| Identity | Owner | Role |
|---|---|---|
| `message_id` | one persisted history record | Stable row identity across hydration, pagination, reconnect, and cache |
| `turn_id` | one execution attempt | Shared by the root user record and every active assistant, tool, reasoning, and delivered-steer record in that attempt |
| `request_id` | one accepted user command or steer | Command correlation only |
| `run_id` | one runtime execution | Work ownership; never a history cursor |
| `history_revision` | one session history CAS | Increments inside the transaction that changes active history |

SQLite `messages.id`, hydration sequence indexes, timestamps, and message text
are not identities. Missing identity yields a typed failure and leaves history
unchanged. Live user echoes and final answers carry the same committed
`message_id` and `turn_id` as hydration; root echoes also carry daemon-authored
`input_kind` and `replay_eligible`. The daemon commits the root history row
before publishing its live `user_message`; model execution reuses that exact
committed input rather than appending a second copy. Controls must not require
reconnect to gain identity. An anchored page with `has_newer=true` is not an
authoritative replay surface until its newer suffix reaches the tail.

## Command

`session.turn_replay` carries:

- `session_id`
- `request_id`: identity of the replacement user turn and command correlation
- `target_message_id`
- `target_turn_id`
- `target_request_id`: raw identity of the root user turn being replaced
- `expected_history_revision`
- `action`: `edit` or `retry`
- `message`: required non-empty replacement text for `edit`
- `confirmed_replay_unsafe`: explicit side-effect confirmation, default false
- `confirmed_drop_steers`: explicit confirmation that dependent steers will not
  be re-injected, default false
- optional current `provider_instance_id`, `model_id`, and `thinking_mode`

A command that omits target message/turn identity or `expected_history_revision`
is `invalid_request`. The daemon does not fall back to `target_request_id` alone.

## Result

`session.turn_replay_result` carries the same session, command, and target
identities plus:

- `outcome`
- `replay_safety`: `safe`, `unsafe`, or `unknown`
- `contains_steers`
- `requires_confirmation`
- `requires_steer_drop_confirmation`
- `history_revision` after a successful commit

### Outcomes

| Outcome | History mutation | Meaning |
|---|---|---|
| `accepted` | committed soft rewind + replacement user record | Replacement turn may dispatch |
| `confirmation_required` | none | `unsafe` or `unknown` tool safety, confirmation not supplied |
| `steer_reinjection_confirmation_required` | none | Target turn contains delivered steers, drop confirmation not supplied |
| `target_not_replayable_input` | none | Target is steer, pending steer, or otherwise not a root turn |
| `identity_incomplete` | none | Legacy or migrated record is not replay-eligible |
| `history_revision_mismatch` | none | `expected_history_revision` is not the current session revision |
| `turn_boundary_not_found` | none | Target message/turn/request combination does not exist |
| `not_latest_turn` | none | Target is not the latest **active** root turn |
| `target_precedes_compaction` | none | A completed context-compaction event follows the target; messages at or before that cutoff are read-only |
| `stale_turn_boundary` | none | Target changed after idle wait or is no longer active |
| `session_not_idle` | none | Authoritative snapshot is not `idle` after scoped stop/wait |
| `already_in_progress` | none | Another replay command already owns the session |
| `empty_message` | none | Edit replacement text is empty |
| `session_not_found` | none | Session does not exist |
| `invalid_request` | none | Required fields missing or action unknown |
| `failed` | none, or full rollback if the transaction did not commit | Unexpected failure |

`confirmation_required` and `steer_reinjection_confirmation_required` may both
apply. The client must resubmit the same target identities with the matching
confirmation flags. Declining confirmation sends no Stop and does not change
`history_revision`.

## Replay safety

The target **root** turn is `safe` when it has no tool calls or every tool call
in that turn, including tools before and after any steer, has durable
replay-safety value true. Any explicit false is `unsafe`. Missing work-item or
per-tool metadata is `unknown` and fails closed to confirmation.

Classification occurs before cancellation. Before tool-safety handling, the
daemon rejects a target whose persisted row is at or before the retained-tail
end of any later completed compaction. This deliberately simple cutoff does not
distinguish summarized source from retained tail. It returns
`target_precedes_compaction` before Stop, soft rewind, or history mutation.
Failed/cancelled compaction does not establish a cutoff.

An unconfirmed `unsafe|unknown` request returns `confirmation_required` without
changing execution or history.

`contains_steers` is true when the active tail of that root turn includes any
delivered or embedded steer. Those steers are superseded with the turn and are
not re-injected into the replacement attempt.

## Idle boundary and history mutation

After safety and steer-drop acceptance, the daemon serializes replay for the
session and applies this order:

1. Inspect identity, `input_kind`, latest-active-root eligibility, tool safety,
   and `contains_steers`.
2. Stop/cancel active, queued, waiting, blocked, resuming, or stopping work
   scoped to the target session, then wait until the authoritative snapshot is
   exactly `idle`. Queued, running, waiting, blocked, and resuming snapshots
   are not immediate failures; they are polled until `idle` or timeout. A
   terminal work item or cancellation acknowledgement is not dispatch
   authority.
3. Re-read the target and `history_revision`. Fail `stale_turn_boundary` or
   `history_revision_mismatch` without mutation if either changed.
4. In one `AgentStateDatabase.transaction`:
   - compare-and-swap `sessions.history_revision`
   - revalidate that the target is still the latest active root turn
   - mark the target root record and every later **active** record in that
     session `superseded`, with `superseded_by_turn_id` set to the replacement
     `turn_id`
   - insert the replacement user record as `active` with new `message_id`,
     `turn_id`, and `request_id`
   - increment `history_revision`
5. Emit `accepted` with the new revision, then dispatch one replacement turn
   using the route fields supplied by the final command.

If step 4 fails, the transaction rolls back and the original turn remains
active. Dispatch happens only after commit. The replacement user record is the
durable accepted input; a later provider failure does not restore superseded
rows.

Normal history, timeline, and model context return `history_status = active`
only. Superseded rows remain in SQLite for audit and recovery and are not
resurrected by reconnect, cache hydration, or late live events.

Clients reconcile by `message_id` and `history_revision`. They must not
optimistically delete the original turn from local cache before `accepted`.
After `accepted`, they hide superseded identities and wait for the replacement
user echo rather than truncating by list index.

## Input classification

Every user-originated history record carries `input_kind`:

- `root_turn`: starts an execution attempt and is the only legal replay target
- `steer`: mid-turn guidance belonging to an existing `turn_id`

Classification is daemon-owned and uses persisted markers, never “last user
event” or the mere presence of `request_id`:

1. A stored `input_kind` wins when valid.
2. `metadata.steer == true` is `steer`.
3. Durable `session_pending_steers` rows are pending input, not history targets.
4. `metadata.steer_messages` entries are `steer` and keep durable `message_id`
   values inside that metadata so hydration does not invent indexes.
5. Any other persisted `role=user` record is `root_turn`.

Pending steers keep Cancel/Delete. They never expose Edit/Retry.

## Compatibility

Messages created before durable user `request_id` persistence, or whose
`input_kind` / `message_id` / `turn_id` cannot be recovered without guessing
from text or timestamp, are non-replayable. The daemon returns
`identity_incomplete` or `turn_boundary_not_found` instead of matching by
content.
