---
title: "Client Conversation Navigation Runtime"
description: "Technical design for device-scoped sidebar projection, atomic history swaps, deletion fallback, and route synchronization."
---

# Client Conversation Navigation Runtime

## State Owners

- `NavigationHistoryController` owns typed back, current, and forward
  destinations.
- `ConversationCacheStore` owns per-device sessions, last destinations, drafts,
  expansion state, and pagination resources.
- `SessionCubit` projects selected-session identity and coordinates typed
  destination intent.
- `SessionMessagesCubit` owns requested-versus-presented session state and the
  atomic history swap.
- `SessionSidebarCubit` is a read-only projection of the active cache device.

## Sidebar Composition

The sidebar shell composes a device header, workspace section, workspace group
rows, conversation rows, and an unscoped conversations section. Conversation
rows are the smallest runtime-state rebuild unit. Unscoped cache changes do not
rebuild workspace groups, and processing or suspension changes rebuild only the
affected row. The legacy `SessionSidebar` remains a forwarding compatibility
surface rather than a second implementation.

## Device-Scoped Selection

Changing the active device switches the cache context before refreshing its
resources. The sidebar body observes device and cache identity together and
keeps rendering the prior matched pair until both have switched, so cached rows
can never dispatch through a stale device object. A selected session belonging
to another device is invalidated, then the target device's typed last
destination is restored. New Conversation and session destinations remain
distinct; `lastSelectedSessionId` is only context inheritance and never decides
the restart route. Background refreshes with usable cached rows are visually
silent; only initial loading and stale errors add sidebar chrome.

## Atomic Session Swap

Navigation sets `requestedSessionId` while retaining the currently presented
`activeSessionId`. History loads through one repository operation and every
request receives a generation. Stream projections are gated while a request is
pending or failed, and stale generations cannot replace the retained timeline.

A delayed-loading indicator appears only when loading exceeds 300 milliseconds,
which avoids flashing transient loading chrome during fast cache/history swaps.
The timer is cancelled on success, failure, supersession, New Conversation, or
disposal. A failed request retains the previous presentation and retries with a
new generation.

Fresh sessions created locally for their first outgoing turn swap immediately
without a history round-trip. During an existing-session transition, timeline
ownership remains with the presented session while composer draft ownership
moves immediately to the requested session.

Client restart may initially restore only the selected session identity while
its authoritative summary and history are still loading. That placeholder does
not own provider/model context and therefore cannot erase the persisted device
route. A complete provider/model pair replaces the route atomically; an
explicit authoritative route revision may also clear or replace it. A repeated
snapshot at the already-confirmed revision may repair only locally missing route
fields; it cannot overwrite non-empty local intent awaiting confirmation. This
keeps the composer sendable across runtime-source handoff while preserving
daemon route authority once hydration completes.

## Incremental History Loading

The initial atomic session swap requests only the newest history page. The
conversation client keeps the daemon's opaque cursor per device and exposes
whether another page exists. `SessionMessagesCubit` serializes older-page
requests, ignores stale completions after session or device changes, prepends
only newly discovered canonical event ids, and retains the current page when an
older-page request fails.

The timeline offers an English **Show earlier** action and automatically
prefetches when a manual upward scroll approaches the start. Loading and retry
states remain inside the upward-growing sliver. Because older rows are inserted
before the centered anchor sliver, the currently visible event retains its
viewport position rather than jumping when a page arrives. Exhausted history
removes the control.

## Timeline Opening Position

The conversation timeline uses a centered sliver layout so a long history can
open at a selected event without building every older row. An idle session opens
at its saved manual viewport event when valid, then falls back to its latest user
message; that event begins near the visible top. A session with authoritative
active work ignores the saved reading position and opens at the live tail: the
latest event ends at the visible bottom boundary immediately above the composer.
The active-tail layout keeps old history in the upward-growing sliver without
eagerly building it, while the latest mutable event stays in the normal
downward-growing sliver. The timeline is not painted against the estimated
composer height; after the first real composer measurement, a hidden layout pass
places the latest event above the composer. If the complete rendered timeline is
shorter than the viewport, the same pass clamps it to the visible top instead of
leaving an empty upper page. Long history retains lazy tail opening.

A newly accepted user message changes the opening anchor only when the prior
timeline is empty: that first message begins near the visible top so the
assistant response can grow below it. If the timeline already contains any
event, the user message appends in canonical order without rebuilding the
anchor. Once its row is laid out, a fully visible message preserves the exact
offset. A row clipped by or below the composer receives only the smallest direct
`jumpTo` delta that places its bottom at the visible composer boundary. If lazy
layout has not built the row yet, bounded direct probes bring it into layout and
the final geometry correction restores the exact minimal offset. This reveal is
not a tail jump, uses no animation, and does not change follow eligibility.

Automatic assistant follow has two separate conditions. Follow eligibility is
granted only by an authoritative active-tail opening or by the user manually
returning to the bottom. Active tail follow remains separate and starts only
when an eligible structurally new event reaches the visible composer boundary.
A new agent event enters visually through a paint-only 220ms fade/slide
transition. When active tail follow was already set, the viewport also follows
that structural event with one latest-generation 280ms `easeOutCubic` scroll,
then directly corrects any final extent drift. Eligible-but-inactive activation
and every non-structural placement remain direct.
The opacity and transform subtree exists only during that interval; completion
returns the row to its raw child under a non-composited layout measurement box.
History rows, user rows, and repeated updates to the same event id do not replay
that transition, and events do not retain per-row repaint boundaries. Updating an existing thinking, reasoning, or final-answer row
preserves the exact viewport while follow is disabled. While active follow is
set, growth moves only by the minimum direct delta needed when the row bottom
crosses behind the composer; fully visible growth does not move. Any manual
movement away clears eligibility and active follow immediately, and later events
cannot restore either state. A manual return to the bottom restores eligibility
and boundary-gated minimal follow.

## Deletion and Route Replacement

Confirmed deletion removes cache, draft, and history identity. Non-current
deletion does not change presentation. Current deletion consumes the newest
valid same-device back destination, then the newest valid forward destination,
then New Conversation. Route replacement prevents the deleted URL from
returning through Back. External deletion uses the same fallback path.

GoRouter synchronization compares typed history state before navigation and
performs presentation-triggered route changes after the current frame. Late
history responses for deleted or superseded sessions are discarded.
