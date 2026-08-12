---
title: "Reasoning, Thoughts, and Final Answer Separation"
description: "Protocol, adapter normalization, history, and state for assistant surfaces. Streaming text shares the final-answer Markdown look; provider reasoning is a transient live-only row never rebuilt from history."
---

# Reasoning, Thoughts, and Final Answer Separation

## Overview

Sanad keeps three assistant surfaces semantically distinct while sharing a
quiet primary reading experience:

1. **Reasoning** is visible provider reasoning extracted into
   `Message.reasoning` from structured fields or supported tagged blocks.
2. **Thoughts** are ordinary non-terminal assistant text carried in
   `Message.content` for generic streams or the typed `Message.thought` channel
   when a provider exposes commentary separately.
3. **Final Answer** is terminal, primary user-facing `Message.content`.

The protocol distinction protects history and lifecycle correctness. The UI renders each surface through the same primary Markdown component while
keeping labels, identities, and final-only actions distinct.

## Agent Protocol

| Canonical event | Source | Lifecycle |
|---|---|---|
| `reasoning_stream` | Non-empty `Message.reasoning` delta | Running |
| `reasoning` | Persisted `Message.reasoning` | Done |
| `thought_stream` | Non-terminal `Message.content` delta | Running |
| `thought` | Persisted non-terminal `Message.content` | Done |
| `final_answer` | Terminal `Message.content` | Done |

`AgentToCanonical` classifies reasoning only from a non-empty
`Message.reasoning`. Missing or empty ordinary content never implies reasoning.
`SessionTurnExecutor` sends reasoning callbacks through that field while answer
chunks remain in `Message.content`. OpenAI-compatible, Anthropic Messages,
Ollama Chat, and Codex Responses adapters all normalize visible reasoning to
this same contract; provider-specific structured fields, codecs, and SSE
accumulators never reach the interface layer.

When one persisted assistant message contains both reasoning and content,
history replay emits distinct rows. A tool-bound message emits reasoning and
thought rows before its tool calls. A terminal message emits reasoning followed
by its final answer.

### Tagged reasoning fallback

The OpenAI-compatible adapter recognizes streamed and non-streamed
`<thought>...</thought>`, `<think>...</think>`, `<mm:think>...</mm:think>`, and
`[THOUGHT]...[/THOUGHT]` blocks, including markers split across chunks. The
stream parser buffers only an undecided opening marker or a suffix that may be
the start of a split closing marker; confirmed reasoning is emitted immediately
through `Message.reasoning` while the provider is still generating. Post-tag
answer text then passes through `Message.content`. Marker pairs are removed, so
closing tags cannot leak into the visible answer. This incremental behavior is
required for transient reasoning UI: a tool event must not be able to supersede
the first reasoning row before all tagged reasoning has even been delivered.
Structured reasoning remains preferred over tagged fallback, and opaque
continuation state remains separate.

### Codex Responses phase routing

Codex Responses exposes visible assistant work through multiple typed channels.
Sanad preserves those semantics instead of flattening them into reasoning:

| Codex source | Message field | Canonical stream |
|---|---|---|
| reasoning summary delta or `phase=analysis` | `Message.reasoning` | `reasoning_stream` |
| `phase=commentary` | `Message.thought` | `thought_stream` |
| `phase=final` or `phase=final_answer` | `Message.content` | `final_answer` at completion |

`Message.thought` is streamed through its own callback and never contributes to
the runner's final-content accumulator. It is persisted independently so
history hydration can emit a thought row before tools or a final answer.
Multiple reasoning-summary parts are separated by one blank Markdown line when
their `summary_index` changes; deltas within the same summary part remain
contiguous. This prevents adjacent bold summaries from producing malformed
`****` boundaries.

### In-flight snapshots

The in-flight projection stores one active text stream per session. The
`SessionTurnExecutor` updates this projection once at the stream source, before
`GatewayManager` fans the immutable response out to local and cloud platforms.
Protocol translation is side-effect free, so adding another transport cannot
append a chunk again. Chunks append only when canonical event type, run id, and
model-step id match. A transition from reasoning to ordinary answer text
replaces the snapshot instead of combining the two surfaces. Durable history
restores both after commit.

### Late-steer completion

When a steer is accepted after an assistant model step has already completed,
that pre-steer content is superseded only for model continuation semantics. The
runtime publishes the same segment as a completed `thought` before clearing the
terminal accumulator and starting the next model step. History hydration maps
the persisted `superseded_by_steer` assistant message to the same completed
thought, preserving live/history order instead of dropping visible content.

## Client Mapping and Identity

| Wire event | Client kind | Timeline identity prefix |
|---|---|---|
| `reasoning_stream`, `reasoning` | `EventKind.reasoning` | `reasoning_` |
| `thought_stream`, `thought` | `EventKind.thinking` | `thinking_` |
| `final_answer` | `EventKind.finalAnswer` | final event identity |

Reasoning and thoughts may share a `model_step_id`, but distinct prefixes stop
one stream from overwriting the other. Empty or whitespace-only thought and
reasoning streams are discarded.

## State Reconciliation

- `reasoning` is a **transient, live-only** surface. It exists in the visible
  timeline only while its stream is `running`.
- **Any** successor event that advances the turn — a matching tool call, a
  `thinking`/thought stream, a final answer, or a new user message — **removes**
  the running `reasoning` row from state instead of finalizing it. Matching
  follows the turn identity (modelStepId, else runId, else sessionId).
- A matching tool call completes running thought rows.
- A matching final answer removes only the superseded ordinary running thought.
- History hydration (`ConversationState.setHistory`) **never rebuilds**
  `reasoning` rows, so a session reopened from the DB never renders them. This
  is a performance invariant: reasoning is excluded before any widget is built.
- Stop and cleanup operations treat running reasoning and thoughts as transient.
- Each session projects at most one running row per assistant stream kind. A
  newer reasoning identity replaces a stale concurrent reasoning row without
  removing the distinct thought surface.
- History reconciliation permits current running chunks to merge with the
  latest in-flight projection.

## Shared Primary UI

### Markdown content

`thinking` (Thoughts) and Final Answer pass through the application-owned
`AppMarkdownRenderer` boundary. Both running and completed text always use the
final-answer `MarkdownBody` renderer with the same complete
`MarkdownStyleSheet`, link handling, and inline-code builder. The former
progressive Markdown dependency has been removed, so conversation content has
only one Markdown implementation. There is no content-length threshold and no
separate card, disclosure, measurement probe, bounded viewport, or nested
scrollbar for streaming text.
Long content grows naturally inside the conversation timeline. Programming and
untyped code blocks are LTR and open their horizontal viewport from the left.
Fenced `text` blocks detect their own content direction and use it for both text
layout and the horizontal leading edge. Their shrink-wrapped header anchors the
language label left and the block copy action right without widening short
content to the message width.

Final Answer may append response metadata below the shared renderer. The
streaming `thinking` surface does not receive that metadata but keeps a copy
action below its own content.

### Stream labels

- The streaming `EventKind.thinking` surface renders **without any header
  label or icon** — it looks exactly like the final answer body, minus the
  metadata footer. (The transient `Thinking`/`Thoughts` labels were removed.)
- `EventKind.reasoning` never renders as a Markdown bubble. While running it
  renders a single compact, tool-style row: a small spinner, a dim
  `Thinking:` prefix, then the first five words of the streamed reasoning
  content. It has no copy action, no disclosure, and no Markdown body. Once a
  successor event arrives it is removed from state (see State Reconciliation),
  so it is never seen after the live stream or from history.

Final Answer has no stream label.

### Conversation scrolling

`BrainActivityView` owns the single conversation `ScrollController`. The
streaming `thinking` surface never creates an inner controller or implements
independent auto-follow, pointer-overflow handoff, or scroll-notification
interception. The compact `reasoning` row is a fixed-height single line and
does not drive scroll growth.

When streamed content grows while the conversation is following the bottom, the
existing outer post-layout auto-scroll follows the new conversation extent. If
the user has scrolled away from the bottom, the ordinary conversation policy is
respected for every event kind.

## Source-grounded decisions

The design was informed by two pinned external reference implementations under
evidence ID `55`, especially typed reasoning separation, normal Markdown
rendering, lifecycle-derived labels, and outer sticky-bottom behavior. Sanad
adopts those principles without a nested reasoning viewport.

## Invariants

- Reasoning never enters final-answer content or shares its timeline identity.
- `thought_stream`, `reasoning_stream`, and `final_answer` remain mapped to
  `EventKind.thinking`, `EventKind.reasoning`, and `EventKind.finalAnswer`.
- Codex commentary never enters reasoning or final-answer content.
- Distinct Codex reasoning-summary parts retain a valid Markdown boundary.
- `thinking` (Thoughts) and Final Answer share one primary Markdown renderer;
  reasoning never renders as a Markdown bubble.
- `thinking` renders with no header label or icon; reasoning renders only as a
  transient, single-line, tool-style row (`spinner + "Thinking:" + first five
  words`) while running.
- `thinking` never receives Final Answer metadata but retains its own copy
  action; the transient reasoning row has no copy action.
- Reasoning is removed from state when any successor turn event arrives and is
  never rebuilt from history — it is excluded before widget construction.
- No streaming or reasoning row owns a ScrollController, viewport, disclosure,
  or content measurement lifecycle.
- Conversation streaming follow is owned only by the outer timeline.
- At most one running row per assistant stream kind is projected per session;
  thoughts and reasoning remain independent.
- Empty stream events never create timeline bubbles.
- Supported reasoning tags never appear in final answer content.
