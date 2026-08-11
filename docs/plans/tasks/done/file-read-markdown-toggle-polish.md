---
title: "File Read Markdown Toggle Polish"
status: done
---

# File Read Markdown Toggle Polish

## Goal

Prevent layout movement when switching File Read Markdown views and align the selector styling with the application theme.

## Implementation

- Give Raw and MD one shared 350px content viewport with internal scrolling.
- Use an 8px selector radius.
- Fill the selected segment with the application primary color at 20% opacity.
- Match the selector border to the subtle tool-surface border treatment.
- Extend focused widget coverage to assert stable height and selected styling.

## Definition of Done

- Switching Raw and MD preserves the content viewport height.
- The selected segment uses the requested radius and theme color treatment.
- Focused widget tests and client analysis pass.
- The live client is reloaded.
- The plan is moved to `docs/plans/tasks/done/`.

## Verification

- Stable-height and selector-style widget assertions pass.
- Client analyzer passes without issues.
- Live client reload completed for review.
