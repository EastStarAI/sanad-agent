---
title: "Conversation Fork QA Matrix"
description: "Quality assurance matrix for materialized conversation fork, lineage, and parent/child independence."
---

# Conversation Fork QA Matrix

## Controls

- Every durable active terminal final answer exposes Fork immediately in the
  live timeline and when loaded through pagination; reconnect is not required.
- User, steer, reasoning, tool, and in-flight rows do not expose Fork.
- A second press during an in-flight request does not send another command.
- The same `request_id` with the same source and target returns the existing
  child without creating another; reuse with a different command is rejected.

## Prefix and independence

- The child contains the active prefix through the selected turn, inclusive.
- Later parent turns, queued input, and pending steers are absent from the child.
- Parent history is unchanged after fork.
- A new user turn in the child does not appear in the parent, and the reverse.
- A local navigation failure after daemon acceptance keeps the child in the
  sidebar and reports that creation succeeded rather than inviting a retry.
- Tool calls are not re-executed during fork.

## Timeline marker and opening

- The authoritative session list places the newly committed child first, and
  the client sidebar preserves that position while opening the child.
- Restart repairs forks created by older builds when copied message recency left
  their ordering timestamp older than `created_at`; they then appear first.
- Child history contains exactly one trailing `session.forked` row with stable
  `fork_<child_session_id>` identity, including after reconnect/restart.
- The marker uses the context-compaction divider/icon/label/tooltip layout.
- Opening the child after hydration scrolls to the tail so the marker is visible,
  even when the copied prefix is long or an older viewport anchor exists.
- The marker is absent from the persisted `messages` table and from every LLM
  request projection.

## Lineage and delete

- The first fork is titled `(1) <base title>`; a second fork in the same tree
  is `(2) ...` even when created from the child.
- Renaming the parent after the first fork does not change later `(n)` titles.
- A superseded, incomplete, `superseded_by_steer`, or unknown-finish assistant
  without a durable terminal marker is rejected and creates no child.
- Deleting the parent leaves the child readable and continuable.
- If parent deletion is rejected, the parent and every child's parent link are
  preserved; no partial lineage detachment is committed.
- Deleting the child does not change the parent or siblings.
- Restart and reconnect restore the same child history and lineage fields.
