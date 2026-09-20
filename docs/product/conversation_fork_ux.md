---
title: "Conversation Fork UX"
description: "Specification for forking a conversation from a durable final answer into an independent child session."
---

# Conversation Fork UX

## Scope

Sanad exposes **Fork** beneath every durable, active, terminal final answer
that carries stable `message_id` and `turn_id`. The control is not limited to
the latest answer. User messages, reasoning, tool rows, steers, and in-flight
partials do not expose Fork.

## Action

- Fork sits below the final-answer body, separate from Edit/Retry on the root
  user turn.
- The first press sends `session.fork` with source session and target
  identities only. The client never uploads the visible transcript.
- Repeated presses while the request is in flight are ignored. The command
  `request_id` makes a retry idempotent.
- Failure leaves the user on the original conversation. No placeholder child
  appears in the sidebar.
- Success inserts the child at the top of the sidebar and opens it immediately.
  After authoritative history hydration, the timeline opens at its tail so the
  trailing `Conversation forked` marker is visible. If local navigation fails
  after daemon success, the client reports that the fork
  was created and directs the user to the preserved child in the sidebar; it
  does not relabel the committed operation as a creation failure.

## Child session

The child title is `(n) <base title>` assigned by the daemon. The original
conversation is unchanged and remains selectable. Later messages in either
session do not appear in the other.

The child timeline ends with a centered `Conversation forked` marker using the
same divider, compact icon/label, focus, tap, and tooltip treatment as the
context-compaction event. It is display-only history derived from lineage and
is never included in the LLM conversation.
