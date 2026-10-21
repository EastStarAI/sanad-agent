---
title: "Task 109 — Multi-Chunk Atomic File Edit Support"
status: completed
current_gate: complete
remaining_estimate: 0%
---

# Task 109 — Multi-Chunk Atomic File Edit Support

## Goal

Enable the Sanad Agent's `file_edit` workspace tool to perform multiple non-contiguous modifications across a target file in a single tool call via structured `edits`, while maintaining backwards compatibility for single `old_string`/`new_string` invocations and guaranteeing atomic execution with bottom-to-top range application.

## Locked scope

- Retain `file_edit` as the single canonical file editing tool without introducing redundant competing tool schemas.
- Backward compatibility: Existing single-replacement calls using `path`, `old_string`, and `new_string` remain fully supported.
- Multi-edit support: Accepts an optional `edits` list where each item provides `old_string`, `new_string`, and optional `replace_all`.
- Atomicity: Pre-validate all edit chunks before disk writes. If any chunk cannot be resolved or is ambiguous, abort cleanly with zero modifications written to disk.
- Overlap Detection: Abort cleanly if any two edits target overlapping line or character ranges in the file.
- Reverse-order application: Sort non-overlapping replacements descending by file position (bottom-to-top) to preserve offsets of preceding chunks.
- Format and UI compatibility: Return aggregated diff patches, line numbers, and replacement counts compatible with Flutter Client (`file_tool_tile.dart`) and CLI tool formatting (`cli_tool_formatter.dart`).

## Gates

### G0 — Contract & Discovery
- [x] Review existing `file_edit` tool contract, schema in `LocalRuntimeCatalog`, and execution flow in `FileEditHandler`.
- [x] Define the updated `inputSchema` allowing either single replacement (`old_string`/`new_string`) or multiple chunks (`edits`).

### G1 — Implementation in FileEditHandler
- [x] Implement multi-edit parsing and argument normalization in `FileEditHandler.execute`.
- [x] Implement pre-matching and range validation for each chunk against original content.
- [x] Implement overlap detection between matched chunk ranges.
- [x] Implement reverse-order replacement application (`bottom-to-top`).
- [x] Aggregate combined diff patches, replacement counts, and starting line numbers.
- [x] Update `LocalRuntimeCatalog._buildWorkspaceTools` with the expanded `inputSchema` and clear descriptions.
- [x] Update `CliToolFormatter` to format multi-edit calls gracefully.

### G2 — Verification & Quality
- [x] Add unit tests in `test/capabilities/file_edit_handler_test.dart` for:
  - Multiple non-contiguous edits in a single call (e.g. lines 5 and 20).
  - Atomic failure (when one edit fails to match, entire operation aborts and file remains unchanged).
  - Overlap detection (rejects overlapping edit ranges).
  - Preservation of Windows CRLF and Unix LF line endings with multiple edits.
  - Backward compatibility with single `old_string`/`new_string` calls.
- [x] Run `fvm dart analyze` across `agent/`.
- [x] Run `fvm flutter analyze` across `client/`.
- [x] Run all focused capability and runtime tests.

### G3 — Documentation & PR Lifecycle
- [x] Update relevant documentation in `docs/` or contracts if durable laws changed.
- [x] Mark task checklist items complete and relocate task file per repository lifecycle.
- [x] Commit with conventional commits message, push branch, and create PR using `gh pr create`.
- [x] Watch GitHub PR checks via single command `gh pr checks <PR_NUMBER> --watch --interval 5 --fail-fast`.
- [x] Merge PR, clean up worktree, and update `main`.

## Acceptance criteria

- [x] Given a file with multiple lines, `file_edit` can replace line 5 and line 20 in a single tool invocation via `edits`.
- [x] Given an invalid chunk among valid chunks, `file_edit` rejects the call without modifying the file on disk.
- [x] Given overlapping chunks, `file_edit` rejects the call with an informative error.
- [x] Existing callers using `old_string` and `new_string` without `edits` continue to function identically.
- [x] All analyzer and test suites pass cleanly.

## Definition of Done

- [x] All gates G0-G3 are completed.
- [x] Focused tests verify multi-edit, atomicity, overlap rejection, and backward compatibility.
- [x] Analyzer passes with zero errors/warnings.
- [x] PR created, CI checks pass, squash merged, worktree deleted, and `main` updated.
