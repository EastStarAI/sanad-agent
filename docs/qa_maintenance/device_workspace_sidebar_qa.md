---
title: "Device Workspace Sidebar QA"
description: "Focused QA coverage for the Plan 32c device-scoped sidebar, including pagination, cache-first rendering, responsive layout, accessibility, and live ordering."
---

# QA: Device Workspace Sidebar

> **Parent:** `docs/qa_maintenance/`
> **Owning task:** `docs/plans/tasks/32c-device-workspace-sidebar.md`

## Connection and Restore Continuity

- Restarting or temporarily disconnecting the local daemon keeps the current timeline, sidebar rows, selected row, and workspace expansion visible.
- Switching devices restores each device's own last destination and highlights only the row matching both its device id and session id.
- Restarting the client with a persisted cloud device never falls back to `local-agent` before cloud inventory resolves and never requests that cloud session through an unrelated device.
- A same-hardware cloud id represented by the merged `local-agent` inventory entry remains selected instead of being treated as authoritatively deleted.

## Manual Validation Scenarios

### 0. Empty inventory loading lifecycle
1. Sign in with no cached or local devices while the cloud inventory response is delayed.
2. **Expected:** The device header shows `Loading devices…`, not `No devices`.
3. Allow the request to settle with an empty response, timeout, or recoverable failure.
4. **Expected:** The progress indicator stops and the header shows `No devices`.
5. While another empty inventory request is pending, trigger a local connection/inventory event.
6. **Expected:** The header remains loading until the pending request itself settles.
7. Sign out while an inventory request is pending.
8. **Expected:** The stale request cannot restore loading after logout, and logout does not claim that another backend request is active.

### 1. Device-scoped rendering
1. Prepare two devices with different workspaces and conversations.
2. Select device A from the sidebar header.
3. **Expected:** Only device A workspaces/conversations are shown.
4. Switch to device B.
5. **Expected:** Device B cached content appears immediately if available, and device A rows disappear from the rendered list.

### 2. Workspace expansion persistence
1. Expand one workspace and collapse another.
2. Restart the app.
3. **Expected:** The same expansion state is restored for that device.
4. Trigger a refresh or receive a live event.
5. **Expected:** Expansion state does not reset.

### 3. Cache-first refresh behavior
1. Open a device with already cached sidebar data.
2. Restart the app or switch away then back.
3. **Expected:** Cached workspaces/conversations render before the remote refresh completes.
4. **Expected:** Refresh status is visible but non-blocking; the list does not blank.

### 4. Offline and stale-error behavior
1. Load sidebar data successfully.
2. Disconnect the daemon or mark the active device offline.
3. Trigger a sidebar refresh.
4. **Expected:** Cached rows remain visible.
5. **Expected:** The sidebar shows an offline or stale-error banner with a retry affordance instead of replacing the list with an empty/error page.

### 5. Workspace and unscoped pagination
1. Load a workspace or unscoped section with more than one page.
2. Tap `Load more` in one section.
3. **Expected:** Only the tapped section appends more rows.
4. **Expected:** Other workspace/unscoped sections do not reload or reorder.
5. Collapse a workspace whose first page has never loaded, then refresh the device.
6. **Expected:** The collapsed workspace remains `notLoaded` until it is expanded.

### 6. New Conversation intents
1. Tap `+` next to `Workspaces`.
2. **Expected:** Workspace creation flow opens.
3. Tap `+` next to a specific workspace.
4. **Expected:** New Conversation opens with the device/workspace preselected.
5. **Expected:** No session is created until the first user message is sent.
6. Tap `+` next to the unscoped `Conversations` heading while a workspace-bound draft exists.
7. **Expected:** New Conversation opens with the workspace selection cleared (`no workspace`); the draft workspace binding is dropped, no session is created, and the route carries no workspace query parameter.

### 7. Live user-message ordering
1. Ensure a session is not currently at the top of its section.
2. Send a canonical user message into that session.
3. **Expected:** The row moves to the top of its own section with a smooth reorder transition.
4. **Expected:** The current selection and scroll position remain intact.
5. Repeat while the section's first-page refresh is still in flight.
6. **Expected:** The canonical bump remains applied after the older response completes.

### 8. Processing and pending-state indicators
1. Put one session in processing state.
2. Put another session in pending permission or pending clarifying-question state.
3. **Expected:** Each row shows the correct indicator and only the affected rows visually change.

### 9. Responsive layout
1. Validate on wide desktop width.
2. Validate on narrow tablet/mobile width.
3. **Expected desktop:** Fixed/resizable sidebar layout and its toggle, Back, and Forward header controls render without overflow on macOS, Linux, and Windows.
4. **Expected mobile/drawer:** Sidebar actions have comfortable touch targets and the drawer closes after selecting a conversation.
5. **Expected macOS:** Traffic-light spacing remains visually clear in the fixed sidebar shell.

### 10. Accessibility checks
1. Inspect the sidebar using accessibility tooling or semantics debugging.
2. **Expected:** The sidebar container, device selector, key actions, and conversation rows expose meaningful labels.
3. **Expected:** Primary drawer/mobile actions keep large touch targets suitable for touch interaction.

### 11. Options menu hover-exit click
1. Hover over a conversation row to reveal the options (`more_vert`) button.
2. Click the options button to open the popup menu containing "Rename" and "Delete".
3. Move the mouse cursor off the conversation row onto the popup menu overlay (triggering hover exit on the row).
4. Click on "Rename" or "Delete".
5. **Expected:** The options menu button doesn't disappear from the tree, and the click successfully triggers the rename or delete modal dialog.

## Automated Coverage

| Scenario | Test file |
|---|---|
| Structure, empty-inventory loading presentation, new-conversation/session-selection intents, offline banner, drawer sizing, options menu hover-exits | `client/test/widget/device_workspace_sidebar_structure_test.dart` |
| Pending-fetch success/failure settlement, local-event isolation, and logout invalidation | `client/test/unit/bloc/device_cubit_test.dart` |
| Pagination and visible live-order transition frames | `client/test/widget/device_workspace_sidebar_pagination_ordering_test.dart` |
| Rebuild-scope verification | `client/test/widget/session_sidebar_rebuild_test.dart` |
| Cubit projection and device snapshot clearing | `client/test/unit/bloc/session_sidebar_cubit_test.dart` |
| Lazy collapsed refresh, pagination, canonical-event/create-workspace races | `client/test/unit/bloc/session_sidebar_cubit_pagination_ordering_test.dart` |
