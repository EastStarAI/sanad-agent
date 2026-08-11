---
title: "File Read Markdown View Toggle"
status: done
---

# File Read Markdown View Toggle

## Goal

Let users switch Markdown file reads between the existing raw source presentation and rendered README-style Markdown, with Markdown selected by default.

## Implementation

- Detect `.md` and `.markdown` File Read targets case-insensitively.
- Place a compact `Raw | MD` switch to the right of the target path.
- Keep the existing line-numbered source view under Raw.
- Render MD through the shared application Markdown renderer.
- Leave non-Markdown file reads unchanged.
- Cover default selection, switching, and non-Markdown behavior with focused widget tests.

## Definition of Done

- Markdown reads open in MD mode and switch to Raw without changing tool data.
- Non-Markdown reads retain the existing UI without a switch.
- Client analyzer and focused widget tests pass.
- The client is reloaded for live review.
- This plan is moved to `docs/plans/tasks/done/`.

## Verification

- Focused File Read and skill-load widget tests pass.
- Client analyzer passes without issues.
- Live client reload completed for review.
