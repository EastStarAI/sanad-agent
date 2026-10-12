---
title: "Task 100: Streaming Text and BiDi Preservation"
status: "completed"
current_gate: "G2"
priority: "high"
---

# Task 100: Streaming Text and BiDi Preservation

## Goal

Prevent text corruption, dropped chunks, and character transposition during live assistant streaming by correcting delta merging in `ConversationState`, ensuring whitespace preservation across streaming mapper events, and safeguarding bidirectional inline text rendering in the Flutter client.

## Locked Decisions and Scope

- Work isolated in worktree `.agent/worktrees/100-streaming-text-and-bidi-preservation` for PR delivery.
- Fix `ConversationState._mergeStreamingText` so that delta chunks matching a prefix of accumulated text (such as `**`, spaces, or punctuation) are never discarded.
- Ensure `UnifiedDeviceMapper` preserves whitespace-only streaming chunks consistently without dropping word-separating spaces.
- Safeguard inline code and text direction in `MarkdownStyleHelper` so that inline code in RTL contexts does not disrupt surrounding Arabic punctuation or word shaping.
- Verify through focused unit and widget tests and client analyzer (`fvm flutter analyze`).
- Restart the Flutter client via `scripts/sanad-dev restart client` and stop before committing to allow user review.

## Gates

### G0 — Discovery and Reproduction
- [x] Trace text corruption during live streaming versus historical replay.
- [x] Identify prefix dropping in `_mergeStreamingText` (`if (existingText.startsWith(incomingText)) return existingText`).
- [x] Identify whitespace stripping in mapper streaming events.

### G1 — Implementation
- [x] Correct `_mergeStreamingText` in `client/lib/features/conversations/domain/stores/conversation_state.dart`.
- [x] Verify whitespace preservation in `client/lib/features/conversations/data/mappers/unified_device_mapper.dart`.

### G2 — Verification and Client Restart
- [x] Add unit tests for `ConversationState` streaming text merging in `client/test/unit/stores/conversation_state_streaming_test.dart`.
- [x] Run focused client unit and widget tests (829 unit tests + 263 widget tests passed).
- [x] Run `fvm flutter analyze` in `client/` (0 issues).
- [x] Restart Flutter client via `scripts/sanad-dev restart client` and verify bounded logs.
- [x] Stop before creating any git commit for user review.

## Acceptance Criteria

- Given an accumulated text starting with `**`, when an incoming delta chunk is `**` or begins with `**`, then the chunk is appended rather than silently dropped.
- Given a streaming event with whitespace-only chunks (`' '` or `'\n'`), then the whitespace is preserved and forwarded.
- Given mixed Arabic, markdown, and English inline code, then text direction and punctuation do not transpose across word boundaries.
- Client analyzer and focused test suites pass with 0 errors.
- Client restarts cleanly via `scripts/sanad-dev restart client`.

## Definition of Done

- Task gates G0 through G2 completed.
- Code changes verified with automated tests.
- Client restarted cleanly.
- No git commits executed.
