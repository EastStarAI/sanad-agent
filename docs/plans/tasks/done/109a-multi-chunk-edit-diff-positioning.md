---
title: "Task 109a — Multi-Chunk Edit Diff Positioning and Quiet File Tool Tile"
status: completed
current_gate: complete
remaining_estimate: 0%
---

# Task 109a — Multi-Chunk Edit Diff Positioning and Quiet File Tool Tile

## Goal

Make the Client render multi-chunk `file_edit` results at the true file positions by
consuming the per-chunk `editStartLines` reported by the Agent, make the rendered diff
text selectable without polluting the selection with gutter numbers, and remove the
per-event diagnostic log that the file tool tile printed for every edit event.

## Locked scope

- Consume the Agent's multi-chunk result contract (`numEdits`, `editStartLines`) exactly as
  emitted; do not invent a second wire field or re-derive chunk positions in the Client.
- Re-anchor the diff line counters at each `---` hunk separator using `editStartLines`.
- Payloads without `editStartLines` (single edits, older Agents) keep sequential numbering.
- The diff block is selectable as one surface; line-number and prefix gutters stay excluded.
- Remove `_loggedEvents` and its `debugPrint` block from `file_tool_tile.dart`; no replacement
  per-event logging is introduced (clean logging contract).
- Out of scope: changing the Agent patch format, extracting duplicated tool-tile path handling,
  or any other unrelated cleanup.

## Gates

### G0 — Contract alignment
- [x] Confirm the Agent result contract for multi-chunk edits (`numEdits`, `editStartLines`,
      `---`-separated hunks) in `file_edit_handler.dart`.
- [x] Confirm the Client parsing surface (`FileToolTile.parseAndPairDiff`, `_buildDiffBlock`).

### G1 — Implementation
- [x] Report `editStartLines` from `FileEditHandler` for multi-chunk results.
- [x] Re-anchor diff counters per hunk and reuse one path-basename helper in
      `ToolPresentationHelper`.
- [x] Wrap the diff block in `SelectionArea` and disable selection on the gutters.
- [x] Remove the diagnostic `debugPrint` block and its `_loggedEvents` state.

### G2 — Verification and documentation
- [x] Add focused Agent coverage for `editStartLines`.
- [x] Add focused widget coverage for hunk anchoring, sequential fallback, selection, and log silence.
- [x] Run `fvm dart analyze` in `agent/` and `fvm flutter analyze` in `client/`.
- [x] Run the focused Agent and Client test files.
- [x] Update the owning documentation pages under `docs/`.

## Acceptance criteria

- [x] Given a multi-chunk edit on lines 5 and 20, the Client diff shows 5/5 then 20/20.
- [x] Given a payload without `editStartLines`, the diff still renders with sequential numbering.
- [x] Diff text can be selected across lines while gutter numbers are excluded.
- [x] Rendering a `file_edit` tile produces no diagnostic debug output.
- [x] Analyzer and focused tests pass cleanly.

## Definition of Done

- [x] All gates completed with focused evidence.
- [x] Owning documentation updated in the same change.
- [x] PR created with mandatory `type/*` and `comp/*` labels, CI green, squash merged.
- [x] Worktree removed and `main` updated.
