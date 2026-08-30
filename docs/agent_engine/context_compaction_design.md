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

Successful candidates are claimed and activated by `CompactionActivationService` (53b). Failed validation never mutates canonical history.

## Pressure and budgeting

- Full-request estimation includes system prompt, runtime context, tool schemas,
  media-heavy message fields, and conversation history.
- Effective input window uses `inputLimitTokens` when present, otherwise the
  route `contextWindowTokens`, then subtracts output reservation (`4096` default)
  and safety headroom (`1024` default).
- Confirmed provider input usage is a verification signal (`confirmed` / `mixed`);
  prospective `estimatedRequestTokens` remain the preflight decision input.
- Tool-schema token estimates are cached by route identity + schema fingerprint
  so stable schemas are cheap to re-evaluate and routes never share a cache entry.
- Declared `media_bytes`, `data:*;base64,...` payloads, and long base64 blobs with
  alphabet markers use byte-based media accounting; homogeneous filler text stays
  on the chars/4 estimator.
- Target request budget defaults to `70%` of the resolved context window unless
  orchestration overrides it.

## Tail selection and projection pruning (C1–C2)

- `CompactionTailSelector` partitions durable `messages.id` ranges into compressible
  head and tool-pair-aware retained tail.
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
- Latest successful boundary alone truncates the active model projection.
- Retained tail stays verbatim and never splits an incomplete tool batch.

## Engine boundaries

- No database imports inside `agent/lib/engine/context/`.
- Summarizer runs without tools and redacts secrets before persistence.
- Overflow/manual/auto differ only by `CompactionTrigger`; engine policy is shared.

## Verification fixtures

Golden semantic fixtures live under `agent/test/engine/fixtures/context_compaction/` and cover:

- multi-step goals with files, blockers, and pending asks
- repeated compaction preserving unresolved work
- tool-pair tail boundaries and orphan prevention

See `docs/qa_maintenance/context_compaction_qa.md` for integration scenarios exercised in 53f.
