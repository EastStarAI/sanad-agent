---
title: "Markdown Code Block Direction and Scroll Origin"
status: "implemented"
---

# Markdown Code Block Direction and Scroll Origin

## Goal

Render compact fenced/multiline Markdown blocks with predictable code/text
direction, content-owned horizontal origins, and block-level copy controls.

## Acceptance criteria

- Programming-language and untyped `Code` blocks render LTR and open at the
  left horizontal edge, even when they contain Arabic strings.
- `text` blocks detect their content direction: Arabic-majority text renders and
  opens from the right; English-majority text renders and opens from the left.
- A compact header shows the fenced language, or `Code` when absent, at the
  block's left edge and keeps the copy control at its right edge.
- Copy copies only the block content and reuses the shared copy feedback.
- The header has no separate background.
- Short blocks wrap their intrinsic content width; neither the header nor copy
  control forces the block to fill the message width.
- Inline code and existing Markdown styling remain unchanged.

## Implementation

- Reuse `TextUtils.getTextDirection` only for fenced `text` content.
- Keep programming and untyped code LTR and use that direction for the
  horizontal viewport.
- Extract fenced language metadata from the Markdown element's `language-*`
  class.
- Keep the header and code in one application-owned block. A shrink-wrapped
  stack anchors the language left and copy action right without `Expanded` or a
  stretched column.
- Reuse the shared `CopyButton` for clipboard behavior and feedback.

## Verification

- Widget-test programming, untyped, Arabic text, and English text directions and
  horizontal origins.
- Run the focused Markdown test and `fvm flutter analyze`.
