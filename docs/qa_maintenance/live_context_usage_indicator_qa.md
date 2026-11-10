---
title: "Live Context Usage Indicator QA"
description: "Regression matrix for latest provider usage, cached-input visibility, tool-loop updates, and history restoration."
---

# Live Context Usage Indicator QA

## Provider value fidelity

- A provider response containing input, output, total, cached-input, and reasoning values preserves each value exactly after canonical key normalization.
- A later response missing total or cached-input clears those fields from the latest projection instead of retaining earlier values.
- Missing total is not derived from input plus output.
- Multiple model invocations in one tool loop do not accumulate into the visible projection.
- Cache-write usage is never rendered in the context tooltip.

## Live tool-loop behavior

- A model response that requests a tool updates the indicator when `tool_use` arrives, before the tool result and final answer.
- Multiple tools from one model invocation reuse the same context snapshot.
- The next model invocation replaces the prior snapshot with its own provider-reported values.
- A provider response without usage leaves the previous confirmed session snapshot intact and does not fabricate a percentage.

## History and session isolation

- Opening a historical conversation displays its latest persisted context snapshot as soon as history hydration completes.
- Legacy history without a session projection falls back to the last assistant message carrying valid provider usage.
- The fallback never combines multiple historical messages.
- Switching sessions never shows the previously opened session's usage after the atomic history swap.
- A conversation with no saved usage keeps the indicator hidden.

## Presentation and accessibility

- The circular progress value reflects input tokens divided by the active model's **resolved** context window (the effective value after the global `context.maxLimit` cap and the shipped per-model defaults; `docs/technical/context_window_resolution.md`).
- Hovering on desktop and tapping the indicator reveal the same English tooltip.
- `Cached input` appears only when the provider supplied a cached-token value.
- The tooltip exposes input usage, context-window size, and any available output, total, reasoning, model, and update-time values. A historical message keeps the window that was in force when it was written, so one conversation may legitimately show two denominators.
- The indicator provides an accessible semantic label and remains keyboard discoverable.
