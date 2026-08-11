---
title: "Sidebar Resize Boundary and Persistence"
status: "implemented"
---

# Sidebar Resize Boundary and Persistence

## Goal

Make the desktop Home sidebar resize handle coincide with the visible sidebar
edge, and restore the user's chosen sidebar width after restarting the client.

## Acceptance criteria

- The horizontal resize cursor and drag target are centered on the visible
  sidebar boundary, including the macOS shell margin.
- Dragging keeps the existing 220–420 pixel bounds.
- The final width is stored in the client SharedPreferences namespace.
- A valid stored width is restored on Home layout creation; missing or invalid
  values use the 300 pixel default and remain bounded.
- Mobile and drawer layouts are unchanged.

## Implementation

- `SidebarPreferences` owns the stable SharedPreferences key for this
  application-level layout preference.
- `ConversationWorkspaceLayout` loads the preference synchronously during
  state initialization and writes it when a resize gesture ends.
- The resize handle is overlaid at the actual sidebar edge instead of being
  placed after a separate spacer in the layout row.

## Verification

- Unit-test the preference read/write behavior and unrelated-key isolation.
- Run the focused client test and `fvm flutter analyze`.
