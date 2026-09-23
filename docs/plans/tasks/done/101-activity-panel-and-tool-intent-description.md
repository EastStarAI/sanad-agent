---
title: "Task 101: Activity Panel and Tool Intent Description"
status: "in_progress"
current_gate: "G0"
priority: "high"
---

# Task 101: Activity Panel and Tool Intent Description

## Goal

Relocate the live session activity indicator from an item within the scrollable message list to a compact, fixed activity bar positioned directly above and behind the composer, continuously displaying the latest tool intent `description` from terminal tool executions or rotating bilingual agent status phrases when idle/unspecified.

## Locked Decisions and Scope

- **Tool Schema Direction Only**: Direct the model exclusively through tool `inputSchema` property definitions without modifying the agent's system prompt or identity templates.
- **Terminal-First Scope**: Add the new `description` parameter schema strictly to `shell_execute` for now.
- **Intent Display in Timeline**: When `description` is provided in tool input, present it as the primary title/detail in tool tiles instead of the raw shell command.
- **Fixed Activity Bar Placement**:
  - Moved out of the message list (`CustomScrollView`).
  - Positioned above the composer and behind it in the z-order, such that the composer overlaps the bottom portion of the activity bar.
  - Horizontally inset by 16px on each side relative to the composer width.
- **Fixed Activity Bar Placement & Styling**:
  - Moved out of the message list (`CustomScrollView`).
  - Positioned above the composer and behind it in the z-order, such that the composer overlaps the bottom portion of the activity bar.
  - Horizontally inset by 16px on each side relative to the composer width.
  - Compact visible height 38px (52px total with 14px tucking under composer), mathematically centered content.
  - Background: Frosted glass with slightly higher contrast/tint than composer to ensure distinct visual hierarchy.
  - Remains visible as long as the session has active work (`activityEligible && hasActiveWork`).
- **3-Tier Display Priority**:
  - Priority 1: Model reasoning stream (first line truncated to max 7 words + `...`).
  - Priority 2: Tool intent description.
  - Priority 3: Bilingual rotating fallback phrases (3-10s random switch, follows application UI locale).
- **Elapsed Duration Formatting**:
  - Seconds always visible: `1s` -> `1m 1s` -> `1h 1m 1s`.
  - Tabular monospace numbers (`FontFeature.tabularFigures()`) to prevent per-second text layout shifting.
- **Single Central Heartbeat Ticker**:
  - A single 1-second `ValueNotifier<DateTime>` ticker at view level, active only when there are running tasks.
  - Surgical `ValueListenableBuilder` wrapped strictly around the small elapsed duration text widgets (never around the message list or whole view).
- **Terminal Tool Execution Timing**:
  - Live elapsed running timer during execution; static formatted execution time once completed.
  - Authoritative duration loaded and displayed for historical sessions using `started_at`, `terminal_at`, and `runtime_ms` metadata from Agent contract.
- **Tool Group Initial Expansion State**:
  - Inherited from the single first tool tile's expansion state upon initial appearance of the 2-tool group.
- **Message Timestamp Date Extension**:
  - When message is older than 24 hours or not from the current day, displays date alongside time.
- **Message Action Button Compactness on Mobile**:
  - Set `materialTapTargetSize: MaterialTapTargetSize.shrinkWrap` on `ConversationActionStyle` to remove mobile 48x48 padding and keep desktop-identical 28x28 size.

## Gates

### G0 — Discovery and Contract Alignment
- [x] Analyze current `ConversationActivityTile` rendering in `BrainActivityView` and `conversation_timeline_projection.dart`.
- [x] Inspect `shell_execute_tool.dart` schema and `ToolPresentationHelper` title resolution.
- [x] Lock visual layout specifications (height, 16px horizontal margin, background contrast, z-order behind composer).
- [x] Confirm Agent authoritative timing contract (`started_at`, `terminal_at`, `runtime_ms` in `ToolTerminalRecord`).

### G1 — Implementation
- [x] Add `description` parameter to `shell_execute` input schema in `agent/lib/capabilities/tools/system/shell_execute_tool.dart`.
- [x] Update `ToolPresentationHelper` in `client/lib/features/conversations/presentation/utils/tool_presentation_helper.dart` to display `description` when present on tool calls.
- [x] Decouple `ConversationActivity` from message timeline list in `client/lib/features/conversations/presentation/utils/conversation_timeline_projection.dart`.
- [x] Implement the compact, composer-backed activity bar widget with 3-tier priority, 7-word reasoning truncation, and randomized phrase timer.
- [ ] Mount the activity bar with higher background contrast and provide a single central 1-second heartbeat clock in `BrainActivityView`.
- [ ] Update elapsed time formatting to keep seconds always visible (`1s`, `1m 1s`, `1h 1m 1s`).
- [ ] Add live timer and historical runtime display to `TerminalToolTile` using central clock and `runtimeMs`.
- [ ] Inherit tool group expansion state from the first tool tile upon first grouping.
- [ ] Update `EventMetadataFormatter.timestampText` to include date for messages older than 24 hours or not from today.
- [ ] Update `ConversationActionStyle` with `MaterialTapTargetSize.shrinkWrap` to eliminate excessive padding on mobile.
- [ ] Forward `runtime_ms` in `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart` and `agent_to_canonical.dart`.

### G2 — Automated Verification
- [ ] Run `fvm dart analyze` on `agent/`.
- [ ] Run `fvm flutter analyze` on `client/`.
- [ ] Run unit and widget tests across `agent/` and `client/`.

### G3 — Interactive Verification with Sanad Client Tester
- [ ] Verify hot reload / restart in running driver runtime.
- [ ] Validate UI hierarchy, activity bar, terminal tool timer, tool group expansion, and compact action buttons.

## Acceptance Criteria

- Given a `shell_execute` call with `description: "Opening terminal to list files"`, when rendered in the timeline or activity bar, then the text shows the intent description rather than the raw shell command.
- Given an active session without a tool description, then the activity bar displays one of the 10 rotating conventional phrases in Arabic (if the conversation is RTL) or English (if LTR).
- Given the chat viewport, the activity bar is anchored above the composer with 16px side insets, rounded corners, matching background, and bottom portion covered by the composer.
- The activity bar is not present inside the scrollable message list.
- All static analyzers (`dart analyze`, `flutter analyze`) pass with 0 issues.

## Definition of Done

- Gates G0 through G3 completed.
- Automated tests pass.
- Interactive verification via Client Tester complete.
- Documentation and code aligned.
