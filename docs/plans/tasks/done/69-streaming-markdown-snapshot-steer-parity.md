# Task 69 — Streaming Markdown, Snapshot, and Late-Steer Parity

## Goal
Keep progressive Markdown readable, make in-flight projection mutation single-owner, and preserve a completed assistant segment when a late steer continues the same run.

## Implementation
1. Keep one application Markdown abstraction and render both streaming and completed assistant text with the existing final-answer renderer, preserving styles, links, inline code, RTL, selection, and web compatibility. Remove the alternative progressive renderer dependency so only one Markdown implementation can enter the conversation widget tree.
2. Remove in-flight snapshot mutation from per-platform protocol translation and project each response exactly once before platform fan-out.
3. At a late-steer continuation boundary, publish the completed pre-steer assistant segment as a done thought before resetting terminal accumulation and starting the next model step.
4. Hydrate the same superseded assistant segment as a thought from history.
5. Remove unrelated partial-on-Stop changes and add focused agent/client regressions.

## Definition of Done
- Local and cloud fan-out cannot double-append an in-flight chunk.
- Reopening an active session merges one snapshot with subsequent deltas without duplicated characters.
- Live and historical late-steer timelines retain the completed pre-steer content in order.
- Streaming Markdown uses the same final-answer renderer through the application abstraction on desktop, mobile, and web.
- Focused tests plus agent/client analyzers pass; owning technical and QA docs are current.
