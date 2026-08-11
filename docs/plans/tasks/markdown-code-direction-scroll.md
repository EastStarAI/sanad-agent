---
title: "Markdown Code Block Direction and Scroll Origin"
status: "implemented"
---

# Markdown Code Block Direction and Scroll Origin

## Goal

Make fenced/multiline Markdown code blocks detect their content direction while
keeping the horizontal viewport itself left-to-right.

## Acceptance criteria

- Arabic-containing code is rendered with RTL text direction.
- Code without Arabic/RTL characters is rendered with LTR text direction.
- The horizontal scroll axis remains LTR for both directions.
- A long code block opens at horizontal offset zero, showing its left edge.
- Inline code and existing Markdown styling remain unchanged.

## Implementation

- Reuse `TextUtils.getTextDirection` for content detection.
- Render the scroll viewport under LTR `Directionality`, with the code text
  under a nested detected direction.
- Keep the multiline code block as an application-owned widget so direction and
  scroll behavior are testable independently of the Markdown parser.

## Verification

- Widget-test Arabic and English code direction.
- Assert the horizontal scroll position starts at zero.
- Run the focused Markdown test and `fvm flutter analyze`.
