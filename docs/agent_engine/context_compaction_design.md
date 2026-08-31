---
title: "Context Compaction Engine Design"
description: "Goal-preserving compaction engine contracts for pressure measurement, tail selection, summarization, and continuity validation."
---

# Context Compaction Engine Design

Plan 53c owns the provider-neutral compaction engine under `agent/lib/engine/context/`. Persistence and activation live in 53b; orchestration and protocol wiring live in 53d; client timeline UX lives in 53e.

## Pipeline

```text
CompactionEngineRequest
  -> RequestPressureEvaluator (prospective full-request estimate)
  -> CompactionTailSelector (tool-pair aware verbatim tail)
  -> CompactionToolPruner (model projection only)
  -> CompactionSummaryPrompt + CompactionSummarizer
  -> CompactionContinuityValidator (anchors + required sections)
  -> CompactionCandidate or typed CompactionEngineFailure
```

The coordinator selects immutable source/tail ranges synchronously, persists the
exclusive started claim, and publishes the compacting barrier before the first
summarizer await. `CompactionActivationService` activates only a validated
candidate; summarizer, validation, or cancellation failure closes the claimed
row as typed failed and never mutates canonical history.

## Pressure and budgeting

- Full-request estimation separates system prompt, runtime context, tool schemas,
  media-heavy fields, conversation history, reasoning, and provider replay. When
  a protocol adapter exposes its wire projection, that projection wins over the
  provider-neutral fallback so alternative replay/content forms are not counted twice.
- Effective input window uses `inputLimitTokens` when present, otherwise the
  route `contextWindowTokens`, then subtracts output reservation (`4096` default)
  and safety headroom (`1024` default).
- Provider-confirmed input usage is authoritative only for the same route and
  byte-equivalent measured request prefix. Preflight starts from that value and
  estimates only newly appended messages (`confirmed` / `mixed`).
- A route/model/config revision, prompt, tool-schema, or measured-prefix change
  invalidates the snapshot and returns to an explicitly estimated projection.
- Tool-schema token estimates are cached by route identity + schema fingerprint
  so stable schemas are cheap to re-evaluate and routes never share a cache entry.
- Declared `media_bytes`, `data:*;base64,...` payloads, and long base64 blobs with
  alphabet markers use byte-based media accounting; homogeneous filler text stays
  on the chars/4 estimator.
- Automatic compaction triggers above `80%` of the effective input window by
  default. The retained-history suffix has a separate `10%` target. Both ratios
  may be overridden per exact normalized model id in `SANAD_HOME/config.yaml`.
- Output reservation and safety headroom remain internal safeguards. On tiny
  test/local windows where their fixed sum would consume the whole window, the
  combined reservation is bounded to `25%`; normal model windows retain the
  fixed `4096 + 1024` reservation.
- After a boundary is active, automatic preflight measures summary + retained
  tail + post-boundary rows. It must not remeasure the hidden canonical head,
  otherwise every later turn would retrigger compaction.

## Tail selection and projection pruning (C1–C2)

- `CompactionTailSelector` partitions durable `messages.id` ranges into compressible
  head and tool-pair-aware retained tail.
- A tail boundary that lands on any result inside a contiguous multi-tool batch
  expands to the assistant message that owns the complete batch; it does not
  assume the result immediately follows the assistant call message.
- Projection hydration rejects a persisted boundary when its retained tail
  contains a tool result without the owning assistant tool call. This preserves
  canonical fallback and lets a later compaction replace an older unsafe boundary.
- Selection walks backward from the newest row and produces one connected suffix.
  Every model-visible canonical row is therefore either summary source or retained
  tail; no middle gap is permitted.
- Summarizer input describes media and truncates oversized tool results; protected
  tail rows stay verbatim for summarizer partitioning.
- When a single recent tool/media payload would keep the post-compaction request
  over budget, `CompactionToolPruner.pruneOversizedForProjection` shrinks
  projection-only copies so the engine can still emit a candidate. Canonical rows
  are never rewritten.

## Goal preservation

Structured summary sections:

1. Current Goal and Success Criteria
2. Active Constraints and User Preferences
3. Completed Work and Verified Results
4. Current State and In-Progress Work
5. Key Decisions and Rationale
6. Blockers, Errors, and Unresolved Questions
7. Pending User Asks
8. Relevant Files, Symbols, IDs, and External State
9. Remaining Work and Safest Next Action
10. Critical Context That Must Not Be Lost

Continuity anchors extracted before summarization must survive validation. One
bounded repair attempt is allowed; weak fallback summaries never activate a
boundary. Failures may carry `CompactionAntiThrashingHints` for 53d cooldown.

## Summarizer contract (C3)

- Prompts are redacted before send; responses are stripped of reasoning tags and
  re-redacted via continuity validation.
- Over-budget source material is split into at most four contiguous passes.
- Deterministic and live summarizers must not execute tools.

## Repeated compaction

- Previous internal summary is passed as a separate anchor, not as an extra system/history message.
- The next source range begins after the previous source-range end; already
  summarized canonical rows are not summarized again.
- Latest successful boundary alone truncates the active model projection.
- Retained tail stays verbatim and never splits an incomplete tool batch.

## Engine boundaries

- No database imports inside `agent/lib/engine/context/`.
- Summarizer runs without tools and redacts secrets before persistence.
- Overflow/manual/auto differ only by `CompactionTrigger`; engine policy is shared.
- Pre-compaction metrics retain their `estimated`, `confirmed`, or `mixed`
  provenance. The projection estimate remains available after activation, then
  the first provider response writes a separate confirmed after-value; the two
  values are never silently conflated.
- A live 53g example makes the accounting explicit: the `58,506` pre-confirmation
  after-estimate was `38,979` retained-tail tokens plus `19,527` estimated
  summary/system/runtime/tool/media overhead. The first provider request then
  confirmed `40,829`. Persistence retains both provenances for diagnostics, while
  the UI replaces the superseded after-estimate with the provider-confirmed value.

## Model-aware startup configuration (53g)

`SANAD_HOME/config.yaml` is the canonical non-secret source and is read once at
daemon startup. Changes require restart. `context.modelLimits` resolves model
windows independently from `compaction` trigger/tail policy:

```yaml
context:
  modelLimits:
    gpt-5.6-sol: 258000
compaction:
  threshold: 0.80
  targetRatio: 0.10
  models:
    gpt-5.6-sol:
      threshold: 0.85
      targetRatio: 0.08
```

Absent sections use `{}`, `0.80`, and `0.10`. Per-model keys inherit global
values independently. Unknown keys, non-positive model limits, and ratios outside
`(0, 1)` fail startup safely. `thresholdTokens`, `modelThresholds`, wildcards,
and legacy `.env` `CONTEXT_LIMIT` are not supported.

## Verification fixtures

Golden semantic fixtures live under `agent/test/engine/fixtures/context_compaction/` and cover:

- multi-step goals with files, blockers, and pending asks
- repeated compaction preserving unresolved work
- tool-pair tail boundaries and orphan prevention

See `docs/qa_maintenance/context_compaction_qa.md` for integration scenarios exercised in 53f.
