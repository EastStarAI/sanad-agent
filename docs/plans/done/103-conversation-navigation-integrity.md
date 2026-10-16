---
title: "Plan 103 — Conversation Back/Forward Navigation Integrity"
status: completed
current_gate: G3
remaining_estimate: 0%
---

# Plan 103 — Conversation Back/Forward Navigation Integrity

## Goal

Make the Client sidebar Back/Forward controls always navigate to the conversation the
user actually came from, across conversations and across devices, and remove the silent
destination rewrites that make Back land on a New Conversation surface.

## Observed defects (live, 2026-10-16)

All three were reproduced on the running primary-checkout Client (two online devices:
`Sanad Agent (Macos)` and `google-vps`) with the `[NavTrace]` diagnostic surface.

### D1 — Back to a session outside the partial page list becomes New Conversation

```
ui.back            | dest=session(59296e00/eab3d346) -> /conversations/59296e00-…/eab3d346-…
nav.goBack         | -> session(59296e00/eab3d346) | current=session(59296e00/eab3d346) fwd=[session(59296e00/a251eb4d)]
home.applySession  | route=session(59296e00/eab3d346) knownSessions=15 branch=FALLBACK-NEW-CONVERSATION
nav.replaceCurrent | -> new(59296e00/-)
```

Reproduction: open a conversation beyond the first page of its section (`load-more`),
navigate to another conversation, let the section refresh (device round-trip), then Back.
Eviction evidence: that workspace's rows returned from 7 to 6, the session disappeared,
and `knownSessions` went from 16 to 15.

Cause: `client/lib/features/home/presentation/screens/home_screen.dart` treats absence from
`agentSessions` (a per-section, first-page-only projection, `_firstPageSize = 6`) as proof
that the destination is invalid. This contradicts
`docs/technical/client_conversation_navigation.md` ("cache absence alone must not … redirect
the result to a new conversation") and `SessionCubit._refreshSelectedSessionFromLists`
("Snapshot absence is not proof of deletion").

### D2 — Back after a device switch returns to the previous device

```
ui.back            | dest=session(2f6a8b0a/6ea1f1c7) -> /conversations/2f6a8b0a-…/6ea1f1c7-…
home.applySession  | route=session(2f6a8b0a/6ea1f1c7) selected=a251eb4d branch=enter
session.selectSession | session=6ea1f1c7 device=2f6a8b0a
```

Cause: `device_workspace_sidebar.dart` switches the device with a bare
`setActiveAgent(device.id)`. No route or history update happens, so the URL and
`NavigationHistoryController.current` keep pointing at the previous device's session while
the cache, sidebar, and selection already belong to the new device. Verified: no
`home.applyRoute` event is emitted during a device switch.

### D3 — Two route identities for the New Conversation surface

```
router.buildHome       | uri=…/new parsed=new(59296e00/-)
home.selectionListener | forceGo …/new -> …/new?workspace=a1e0755c…
home.applyRoute        | route=new(59296e00/-) current=new(+ws) branch=goBack
nav.navigateTo         | -> new(+ws) … fwd=[]
```

Cause: `startNewChat` resolves a restored `targetWorkspaceId` after the caller has already
built the route, and some callers emit a workspace-less location
(`home_screen.dart` conversations-list branch). The same screen then exists as two typed
destinations, producing a spurious `goBack` and a cleared forward stack.

## Approved decisions (2026-10-16)

1. **One global history, contract-compliant.** Cross-device Back/Forward may return to
   another device's conversation, but it must be deterministic and visible in the URL:
   the device switch becomes a real typed navigation. No per-device history scoping.
2. **No silent rewrite for a genuinely missing session.** Remove the cache-snapshot
   heuristic entirely; a non-existent session surfaces a clear error state with retry.

## Locked scope

- Client-only change. No Agent, socket, protocol, or cache-pagination redesign.
- Only the *interpretation* of cache absence changes; the partial paging model stays.
- `[NavTrace]` stays as a debug-only diagnostic surface (root logger is already
  `OFF` outside debug builds); no runtime flag is added.
- No commit, push, PR, merge, or worktree cleanup inside this task without explicit
  user authorization.

## Delivery model

Implementation happens directly in the **primary checkout** so the running live Client can
be hot-reloaded and verified interactively against the real two-device runtime. Isolation
into a task worktree/branch (`fix/103a-navigation-integrity-repair`) happens only after the
live acceptance passes. Live verification is owned by the orchestrator, never by the
implementer.

## Gates

### G0 — Plan and alignment
- [x] Live reproduction of D1, D2, D3 with log evidence.
- [x] User decisions on cross-device policy and missing-session behavior.
- [ ] Task file with file-level scope and acceptance criteria approved.

### G1 — Single navigation authority
- [x] Device switch performs one typed navigation through
      `ConversationHistoryController` after the cache context has switched.
- [x] Startup restore and device switch share one destination resolver.
- [x] Exactly one stack-reconciliation implementation exists; the unused duplicate is
      removed.
- [x] The selection listener can no longer override a user-initiated Back/Forward.

### G2 — Destination integrity
- [x] Absence from `agentSessions` never rewrites the destination.
- [x] Deletion fallback remains the only automatic New Conversation fallback.
- [x] `startNewChat` returns the resolved destination and every caller navigates with it.
- [x] History is cleared when the authenticated identity changes.

### G3 — Verification and docs
- [x] Widget coverage: evicted-session Back, device-switch Back/Forward, New Conversation
      round-trip preserving Forward.
- [x] Unit coverage for the destination resolver and `startNewChat` return value.
- [x] Analyzer and focused suites pass; no `FALLBACK-NEW-CONVERSATION` in the live matrix.
- [x] Owning docs and `AGENTS.md` contracts updated.

## Acceptance criteria

- [x] Back returns to the conversation the user last viewed, including a session that is
      absent from the currently loaded sidebar pages.
- [x] After a device switch, the URL, history current destination, sidebar selection, and
      displayed conversation all describe the same device; Back and Forward then move
      predictably and are reflected in the URL.
- [x] A New Conversation round-trip keeps Forward enabled and adds exactly one history
      entry per user navigation.
- [x] A genuinely missing session shows an error with retry instead of opening a New
      Conversation surface.
- [x] Same-device Back/Forward behavior is unchanged from the current correct baseline.

## Definition of Done

- [x] `fvm flutter analyze` passes in `client/`.
- [x] Focused widget/unit tests pass; full fast suite run once for the shared navigation surface.
- [x] Live `[NavTrace]` matrix re-run on two devices with the acceptance condition above.
- [x] `docs/technical/client_conversation_navigation.md` and the two owning `AGENTS.md`
      files describe the final law.
- [x] `git diff --check` passes.
- [x] Delivery (commit, push, PR) executed under explicit user authorization; the squash
      merge is the final authorized step.

## Verification ownership

Implementation was delegated to a Sanad worker (`OpenCodeGo / deepseek-v4.1-flash`, session
`b4e1f7a3-5c2d-4a91-9f36-8d7e2c1b0a54`); the orchestrator re-ran the gates, reviewed the diff,
and performed the live two-device acceptance recorded in
[tasks/103a](tasks/done/103a-navigation-integrity-repair.md#live-acceptance-evidence-2026-10-16-primary-checkout-runtime-two-online-devices).

## Task index

- [103a — Navigation integrity repair](tasks/done/103a-navigation-integrity-repair.md)
