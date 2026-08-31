---
title: "Session Fork Protocol"
description: "Daemon-authoritative materialized conversation fork with lineage, atomic copy, and idle child admission."
---

# Session Fork Protocol

## Ownership

Fork is a daemon-authoritative materialized copy. The client sends only the
source session and target final-answer identities. The daemon reads the active
prefix from SQLite and does not trust a client transcript or paginated cache.

The target must be an **active** terminal assistant final answer with stable
`message_id` and `turn_id`. Partial, in-flight, superseded, user, steer,
reasoning, and `superseded_by_steer` thought rows are not fork targets. An
assistant row with an unknown finish reason also fails closed unless durable
terminal-work metadata proves completion.

## Lineage

| Field | Owner | Role |
|---|---|---|
| `lineage_id` | one fork tree | Stable across parent deletion and branch-from-branch |
| `parent_session_id` | child session | May become null when the parent is deleted |
| `forked_from_message_id` | child session | Source final-answer `message_id` at fork time |
| `forked_from_turn_id` | child session | Source turn that owns that final answer |
| `fork_sequence` | child session | Unique increasing integer in the lineage; `0` is a root session |
| `lineage_base_title` | lineage | Title snapshot used for `(n) <base>` names; not parsed from the live title |
| `fork_request_id` | child session | Idempotency key for `session.fork` |
| `origin_message_id` | copied message row | Source `message_id`; the copied row has a new `message_id` |

Existing sessions backfill `lineage_id = session_id` and `fork_sequence = 0`.

## Command

`session.fork` carries:

- `session_id`: source session
- `request_id`: idempotent command identity
- `target_message_id`
- `target_turn_id`

A missing identity is `invalid_request`. The daemon does not accept a client
message list. Idempotency binds `request_id` to the immutable source session,
target message, and target turn: only an exact retry returns `already_exists`;
reusing the key with a different command is `invalid_request`.

## Result

`session.fork_result` carries `outcome`, the child session summary when
accepted, and lineage fields.

| Outcome | Mutation | Meaning |
|---|---|---|
| `accepted` | committed child session + copied prefix | Child is idle and selectable |
| `already_exists` | none | Same `request_id` already created this child |
| `target_not_found` | none | Target message/turn is missing |
| `target_not_forkable` | none | Target is not an active terminal final answer |
| `session_not_found` | none | Source session does not exist |
| `invalid_request` | none | Required identities missing |
| `failed` | full rollback | Unexpected failure |

## Prefix

The copied prefix is every **active** history row from the start of the source
session through the end of the target turn, inclusive. The turn ends at the
last active row that shares the target `turn_id`. Queued input, pending steers,
execution snapshots, and later turns are not copied.

Copied rows receive new `message_id` and `turn_id` values. Tool-call pairing
inside the prefix is preserved by rewriting ids consistently. `origin_message_id`
records the source row. Runtime work, notices, and queues are not copied. The
child starts `idle`.

## History-only fork event

A forked child history ends with one derived `session.forked` row. Its stable
`event_id` is `fork_<child_session_id>` and its payload exposes only non-secret
lineage fields needed by the client. The row is synthesized from the child
session lineage during `session_history`; it is not persisted in `messages` and
is therefore outside `AgentRunner` history and every LLM model projection.

The client maps this row to an informational timeline marker styled like the
context-compaction event. Opening a forked child aligns the timeline to this
trailing marker after hydration.

## Naming

The first fork of a lineage is titled `(1) <lineage_base_title>`. Later forks,
including branch-from-branch, increment `fork_sequence` uniquely for that
lineage. `lineage_base_title` is a stored snapshot: the first fork writes the
parent's current title when the field is empty, and later forks reuse that
snapshot even if the parent is renamed. Titles are never parsed with a
regex. Allocation of `fork_sequence` is atomic. Fork creation initializes the child
session ordering timestamp to the fork commit time so the authoritative daemon
session list and client sidebar place the new child first; copied message
timestamps remain unchanged. Startup performs an idempotent repair for forks
created by older builds whose ordering timestamp predates `created_at`.

## Delete

Deleting a parent sets children's `parent_session_id` to null and leaves child
rows, messages, and `lineage_id` intact. Deleting a child does not change the
parent, siblings, or consumed sequence numbers.
