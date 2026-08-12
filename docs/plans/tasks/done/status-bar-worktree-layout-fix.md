---
title: "Status Bar Worktree Layout Fix"
status: done
---

# Status Bar Worktree Layout Fix

## Goal

Keep the environment details, including `SanadAgent`, anchored to the far right when the optional worktree badge is visible.

## Implementation

- Group gateway status and the optional worktree badge in one expandable left section.
- Keep environment details as the fixed trailing section.
- Preserve badge truncation within the available left-side width.

## Definition of Done

- Showing or hiding the worktree badge does not move `SanadAgent` away from the right edge.
- Client analysis passes.
- The live client is reloaded.
- The plan is moved to `docs/plans/tasks/done/`.

## Verification

- Client analyzer passes without issues.
- Live client reload completed for review.
