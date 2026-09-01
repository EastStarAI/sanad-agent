---
title: Conversation Navigation UX Spec
description: UX specifications for conversation navigation destinations, history, deletion, and restart recovery.
---

# Conversation Navigation UX Spec

## Overview

This document defines the user experience for conversation navigation, including typed destinations, back/forward history, New Conversation, and deletion safety. It is part of Plan 32e (Conversation Navigation History and Deletion Safety).

## Destinations

### Types

| Kind | Route | Description |
|------|-------|-------------|
| `session` | `/conversations/:deviceId/:sessionId` | An existing conversation session |
| `newConversation` | `/conversations/:deviceId/new` | The New Conversation surface (no session yet) |
| `conversationsList` | `/conversations/:deviceId` | Device conversation list without a session selected |

### New Conversation Surface

- **Route**: `/conversations/:deviceId/new` — not a session route with null id.
- **App Bar**: Hidden. A large title (`Sanad Agent`) with a contextual hint is shown.
- **Device & Workspace pickers**: Visible above composer ONLY in this state.
- **Workspace**: Optional. `workspaceId` may be passed as query param `?workspace=:id` for preselection.
- **Session creation**: Session is created only when the first message is sent.
- **Composer state**: Full-width with provider/model/thinking pickers.

### Session Destination

- **Route**: `/conversations/:deviceId/:sessionId`
- **App Bar**: Shown, displays workspace name (if any) and conversation title.
- **Workspace**: Fixed after session creation — cannot be changed.
- **Device & Workspace pickers**: Hidden from composer area.

## Navigation History

### Stacks

The `NavigationHistoryController` maintains three stacks:

1. **Back stack**: Destinations the user visited before the current one. Most recent last.
2. **Current**: The destination currently presented.
3. **Forward stack**: Destinations the user went back from. Most recent last.

### Rules

1. Navigating to a new destination pushes current onto back and clears forward.
2. Re-selecting the current destination is a no-op (no duplicate entry).
3. Back pops the last entry from back stack, moves current to forward.
4. Forward pops the last entry from forward stack, moves current to back.
5. Deleted/invalid destinations are silently skipped during back/forward.
6. Across-device navigation is allowed; the active device switches first, then history updates.

### Back/Forward Buttons

- Desktop/tablet: Show Back and Forward buttons in the sidebar header.
- Mobile narrow: Hide buttons; system/gesture navigation handles back.

## Deletion UX

### Non-current session deletion

- User deletes a session from the sidebar.
- Session disappears from sidebar, cache, drafts, and history stacks.
- Current conversation is completely unaffected.

### Current session deletion

1. User confirms deletion of the currently open session.
2. UI stays on the current conversation briefly (no flash) while:
   - Deletion is sent to daemon.
   - Daemon confirms success.
3. After confirmation:
   - Current session messages disappear.
   - Fallback destination is determined.
   - Route is replaced (not pushed) to the fallback.
4. Fallback order:
   a. Last valid same-device session from back stack (walked top to bottom).
   b. Last valid same-device session from forward stack (walked bottom to top).
   c. New Conversation for the same device.
5. Route replacement prevents Back from returning to the deleted URL.

### External deletion event

- Session deleted from another device or the daemon.
- Same invariants as local deletion.
- If current, fallback is applied immediately without a confirmation dialog.

## Long Conversation History

- Opening a conversation displays its newest bounded page without waiting for
  the complete transcript.
- Scrolling toward either loaded boundary prefetches the next older/newer page
  before the boundary enters view. Short slices auto-fill in both directions.
  Pagination and retry buttons never appear inside the transcript.
- Loading older messages never blanks the conversation or forces the viewport
  back to the tail. The first visible event keeps the same screen position after
  prepend, and live responses may continue at the tail without duplication.
- An anchored slice can be browsed in both directions. Downward intent loads the
  next newer page without tail-follow until the reader explicitly reaches the
  newest boundary.
- Tool calls that form one visible run remain one group when a newer page joins
  them. Historical reasoning hidden from the timeline does not create an
  invisible group boundary; visible messages, thinking rows, final answers, and
  `system_ask_user` remain explicit boundaries.
- Each conversation owns its saved top-visible event independently. Navigating
  away and back restores that event instead of reusing another conversation's
  offset or reopening at the tail.
- A short first page may auto-fill at most three older pages, then stops at a
  filled viewport, exhaustion, or error.
- When no older page remains, the earlier-history control disappears.

## Restart Recovery

- The last typed `ConversationDestination` per device is restored from `ConversationCacheStore`.
- A saved session destination reopens that session; a saved New Conversation destination reopens `/conversations/:deviceId/new`.
- New Conversation restores its nullable workspace preselection; `null` means no workspace is selected. A workspace known to be removed is dropped.
- `lastSelectedSessionId` is used only to inherit previous session context and never determines the restart route.
- A missing saved destination defaults to New Conversation. If a saved session was deleted while offline, recovery also falls back to New Conversation.
- An idle session with a saved viewport event requests the bounded page containing
  that event and reopens it near the visible top. Active work always opens at the
  live tail. A missing, compacted, or stale event safely retains the newest tail.

## Test Scenarios

See `docs/qa_maintenance/conversation_navigation_recovery_matrix.md` for the full QA matrix.
