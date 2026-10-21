---
id: 78
title: Causal order and live/history parity for informational events
status: implemented-awaiting-live-acceptance
gate: E (automated verification complete; live acceptance not run)
created: 2026-10-15
ported: 2026-10-21
depends_on: "Task 31 route transitions, Task 52 session fork, Task 87 conversation identity and ordering, Task 111 terminal classification, Task 117 history integrity"
delivery: "branch fix/78-port (local commits only; supersedes draft PR #207)"
---

# Task 78 — Causal Order and Live/History Parity for Informational Events

## Goal

The two daemon-derived informational events keep the position and
classification they had live, after every reload and on every history page,
exactly once:

1. `session.forked`, the fork marker in a child session.
2. `session_route_transition`, the automatic-failover notice.

Steer, queue and compaction ordering stay owned by Tasks 87 and 106.

## Origin and port

The first attempt lives on `docs/task-78-conversation-delivery-parity`
(draft PR #207, last updated 2026-10-15). Main has since merged the Task 110
SRP refactor and Tasks 111, 116, 117, 120, 108, 118a and 123. The branch was
**not** treated as finished: it was reviewed against this task, and each part
was transplanted, rewritten or dropped (see Mapping and Defects).

### What 111 and 117 already cover

Neither covers this task's behaviour; nothing was dropped as a duplicate of them.

- **111** (`TerminalAssistantClassifier`, `SessionHistoryPage.followingMessage`)
  classifies assistant rows as final answers or thoughts. It does not place
  synthetic informational rows. On main, `session_query_handler.dart` still
  appended `session.forked` to every page tail and placed transitions after the
  request's user row. This port leaves 111's classifier and `followingMessage`
  untouched. The fork anchor is a session-scoped query rather than a page-edge
  inference, so it does not need `followingMessage`.
- **117** keeps `messages.id` stable across in-place rewrites and re-inserts
  only from the first structural divergence. This port anchors failover notices
  by `message_id`, not by row id, so the anchor survives a re-insert too.
- **Already on main from Task 31:** live and reloaded route notices already
  share the identity `route_<session>_<revision>` through `UnifiedDeviceMapper`,
  and `client/test/unit/services/device_conversation_event_handler_test.dart`
  ("history and live route transition share logical dedupe identity") pins it.
  The old branch's reconciler change for route-notice dedupe was redundant and
  is dropped.

## Decisions

1. **Fork marker anchor.** The marker follows the newest active child row with
   `origin_message_id` set, which is the end of the copied prefix. The copy
   rewrites every `message_id`/`turn_id`, so the parent's
   `forked_from_turn_id` never exists in the child. Post-fork rows carry no
   origin, so the anchor is page-independent. The marker sits on the one page
   holding that row, before any compaction marker the child later anchors
   there. A legacy child without origins keeps tail-page placement.
2. **Failover notice anchor.** `session_route_transitions.anchor_message_id`
   (additive column) records the newest active message when the failover
   commits. `RunnerRecoveryCoordinator` reads it through
   `RunnerRecoveryHost.latestPersistedMessageId()` (the `messages` owner) and
   passes it to `SessionRouteMutationCoordinator`, which never reads `messages`
   itself. Tool results are saved before the next model call, so this is
   exactly the last row the user saw live. History inserts the notice right
   after that row, after earlier derived rows at the same anchor (compaction,
   earlier revisions).
3. **Legacy notices** (no anchor, or anchor no longer active) fall back to
   their request's root row. In that turn they go after the tool results whose
   real `terminal_at` precedes the notice. A notice whose identities resolve to
   no active row stays tail-only. Synthetic history timestamps are never
   compared.
4. **One page per notice.** A notice or marker is emitted only on the page
   holding its anchor row, so paging never drops or repeats it.
5. **Source policy = live policy.** The Client renders a timeline notice only
   for `auto_failover`. History keeps projecting only that source, so user and
   recovery switches produce no notice either live or after reload.
6. **Opening a fork child.** The marker governs the opening position only while
   it is the trailing item (a fresh fork). A continued child opens like any
   session, at a saved position or its latest prompt. Main's client logic
   already does this; it is now locked by tests.

## Mapping (old branch to port)

| Old branch change | Port outcome |
|---|---|
| `session_query_handler.dart` fork search by `message_id`/`origin_message_id` plus `forked_from_turn_id` extension | **Rewritten**: anchor is `SessionMessageRepository.lastActiveForkCopiedRowId` (end of copied prefix) |
| `session_query_handler.dart` transition placement (provider/`started_at` heuristics, `received_at` time fallback, all sources) | **Rewritten**: durable `anchor_message_id`, legacy request-turn fallback on real `terminal_at`, auto-failover only |
| Re-sort of transitions by revision | **Dropped**: `findForSession` already orders by `route_revision` |
| `SessionDB.hasMessageWithRequestId` (SQL in the facade) + `SessionManager` delegate | **Replaced** by repository-owned lookups behind the facade |
| `unified_device_mapper.dart` eventId / `source` wire value | **Dropped**: history projects only `auto_failover`, ids already match |
| `session_route_snapshot.dart` `wireValue`, `autoFailover` alias | **Dropped**: the wire never sends camelCase |
| `canonical_timeline_reconciler.dart` informational match block | **Dropped**: redundant (see 111/117 section) and unsafe |
| `brain_activity_view.dart` fork anchoring anywhere | **Dropped**: defect (see D7); main logic kept and locked |
| `agent/test/interfaces/session_informational_event_order_test.dart` | **Rewritten** at `agent/test/interfaces/platforms/sanad_gateway/session_informational_event_order_test.dart` with real fork commits |
| `client/test/unit/stores/canonical_timeline_reconciler_test.dart` additions | **Replaced** by `client/test/unit/stores/informational_event_parity_test.dart` using real mapper output |
| `client/test/widget/brain_activity_view_scroll_test.dart` addition | **Replaced** by two continued-fork opening locks |
| Task file / QA item 19–20 | **Rewritten** here and in the QA pages |

## Defects found in the old branch

| # | Location (old branch) | Defect | Fix in port |
|---|---|---|---|
| D1 | `session_query_handler.dart` fork block | Turn-end extension compares the child's rows with the parent's `forked_from_turn_id`, which fork copy rewrites, so it never matches. The old test fixture hid this by giving child rows the parent ids. | Anchor on the newest active copied row; tests use `SessionManager.commitFork` |
| D2 | same | Per-page search for the target row: on a page edge the marker could land inside a split turn, or vanish from the page that ends the prefix. | Session-scoped anchor; a page-edge test covers this case |
| D3 | `session_query_handler.dart` transitions | Shows `user` and `recovery` switches in history, which the live timeline never renders, so the history/live parity breaks. It also added new "Switched provider…" strings. | Auto-failover only, matching live |
| D4 | same, time fallback | A request-less notice is inserted on every page whose rows precede it, so it repeats across pages. On the tail page it is appended at the end even when every row is newer. | One-page rule; identity-less notices are tail-only |
| D5 | same, heuristic | Placement broke on the first row naming the new provider and on any `started_at`/`terminal_at` after the notice (a tool start time is not a causal bound), and it did not stop at compaction. | Durable anchor plus synthetic-row step |
| D6 | `session_db.dart` `hasMessageWithRequestId` | Raw SQL in the `SessionDB` facade breaks the evolution/db contract ("holds no SQL of its own"). | Lookups live in `SessionMessageRepository` |
| D7 | `brain_activity_view.dart` | It forced the opening position to the fork marker whenever one existed, overriding a saved reading position and the latest-prompt rule for continued children. | Dropped; locked by two widget tests that fail under the old change (`temp/78/client-mutation-old-bav.log`) |
| D8 | `canonical_timeline_reconciler.dart` | It merged any two fork markers and any two equal `route_revision` informational rows regardless of identity, a merge `sessionId == null` did not guard. Its test used a live id (`route_transition_…`) the mapper never produces. | Dropped; the existing identity match covers it |
| D9 | task file | Marked `completed` with all gates checked and no live run, and named the wrong file (`…steer-queue…budget`). | This record; live gate left open |

## Gates

- [x] A — Red tests first. The agent tests failed on main (5 of 7, including
  a duplicated legacy notice across pages: `temp/78/agent-red-1.log`). Anchor
  and runner tests were mutation-checked: removing the anchor or the
  synthetic-row step turns them red (`temp/78/agent-mutation-*.log`).
- [x] B — Fork marker anchored after the copied prefix, once across pages.
- [x] C — Failover notice durable anchor plus legacy fallback, auto-failover only.
- [x] D — Client parity locked; no client production change needed.
- [x] E — Analyzers, focused tests, full suites and local E2E (see Evidence).
- [ ] Live acceptance (scenarios below): not run; needs a Test Home and a
  provider that can be made to fail before streaming.

## Live acceptance scenarios

| # | Scenario | Pass condition |
|---|---|---|
| L1 | Fork a reply, continue the child for two turns, reload | Marker sits between the copied reply and the first child prompt, live and after reload/restart |
| L2 | Long child (more than one page): scroll up past the fork point | Marker appears exactly once, at the copied-prefix end, whether or not that row ends a page |
| L3 | Reopen a continued child, then a fresh child | Continued child opens at its latest prompt or saved position; fresh child opens at the marker |
| L4 | Auto-failover after a tool step (primary returns 429 before streaming, a same-model backup is ready) | Notice appears after the tool result live; after reload it is in the same place with the same text; no duplicate |
| L5 | L4 session grown past one page, scroll up | Notice appears once, on the page holding that turn |
| L6 | Manual model switch, and recovery "continue with provider" | No timeline notice live or after reload; model chip updates |
| L7 | Pre-port session with an older failover notice (no anchor) | Notice is placed after the turn's finished tool results, and appears once across pages |

## Evidence

Logs are in `temp/78/` (workspace root).

| Check | Command | Result | Log |
|---|---|---|---|
| Agent analyzer | `fvm dart analyze` (agent) | No issues | `temp/78/agent-analyze.log` |
| Client analyzer | `fvm flutter analyze` (client) | No issues | `temp/78/client-analyze.log` |
| Agent focused | ordering, runner anchor, gateway, route-state, recovery suites | 264 passed | `temp/78/agent-focused.log` |
| Agent task tests (final) | ordering + runner anchor | 12 passed | `temp/78/agent-focused-final.log` |
| Client focused | parity, scroll, reconciler, event-handler suites | 76 passed | `temp/78/client-focused-2.log` |
| Agent full | `fvm dart test` | 3063 passed, 14 skipped, exit 0 | `temp/78/agent-full.log` |
| Client full | `fvm flutter test` | 1733 passed, 1 skipped; 1 load error (`flutter_tester` WebSocket connect, harness) in `socket_conversation_client_test.dart`, which passes 14/14 on rerun | `temp/78/client-full.log`, `temp/78/client-full-rerun-socket.log` |
| Local E2E | `fvm flutter test e2e_test/ --concurrency=1` | 14 passed | `temp/78/client-e2e.log` |
