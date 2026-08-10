---
title: "RTL Question Header and Runtime Duration"
description: "Align dynamic Arabic event headers and present long event runtimes compactly."
status: "completed"
---

# RTL Question Header and Runtime Duration

## Goal

Make dynamic ask-user event headers follow the detected title direction and keep
event runtime metadata readable from milliseconds through multi-hour runs.

## Implementation

- Resolve event-title direction once and apply it to the complete header row and
  title renderer.
- Preserve left-to-right presentation for English event titles.
- Expose runtime formatting for focused unit coverage and render multi-hour
  durations as hours plus minutes.
- Document and test both presentation behaviors.

## Verification

- `fvm flutter analyze` passes.
- Focused RTL widget and runtime-format unit tests pass.
- Live Arabic `system_ask_user` presentation is reviewed from the target
  worktree runtime.
- `graphify update .` completes when the local graph is available.

## Definition of Done

- [x] Arabic ask-user event headers render as RTL rows.
- [x] English event headers remain LTR.
- [x] Runtime metadata covers milliseconds, seconds, minutes, and hours.
- [x] Product and QA documentation describe the behavior.
