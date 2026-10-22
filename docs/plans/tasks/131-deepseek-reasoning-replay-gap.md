---
id: 131
title: DeepSeek same-route reasoning replay gap
status: completed
gate: accepted
created: 2026-10-22
parent_task: none (release blocker)
depends_on: [116]
delivery: own commit on fix/deepseek-reasoning-replay-gap (no push)
---

# Task 131 — DeepSeek Same-Route Reasoning Replay Gap

## Goal

Every assistant message that was produced by the destination route and carries
`tool_calls` must replay a `reasoning_content` key when the request targets a
route that declares `interleaved.field: reasoning_content` and the request is in
thinking mode. Missing content becomes the provider's own zero-reasoning shape
(`""`), never a fabricated reasoning text, never a cross-route echo.

## Live Evidence (2026-10-22)

- Route: OpenCode Go / `deepseek-v4.1-flash`, OpenAI-compatible Chat, thinking
  `max`, one long tool-using `sanad run`; **same route throughout**, no provider
  switch.
- Upstream rejection: `invalid_request_error`, "The reasoning_content in the
  thinking mode must be passed back to the API".
- Rejected body: 67 messages, 27 assistant messages, all 27 with `tool_calls`.
  24 carried `reasoning_content` (12 of them `""`), **3 carried no
  `reasoning_content` key at all**. Earlier assistant indices with a falsy
  value: 2, 5, 8, 11, 18, 23, 28, 34, 38, 42.
- Recurs inside one session and in the user's UI conversations; stopping and
  continuing sometimes clears it. Same-route only.
- Raw request dumps and `~/.sanad` were not read for this task (credentials).

## Root Cause

`ChatReasoningReplayPolicy._recorded` projected a same-route assistant message
"as recorded": when the producing response had **no** `reasoning_content`
(`reasoning_field: absent`) or an explicit `null`, the projection emitted
nothing. That was 116's probe-pending default, and 116's live probes never
exercised a reasoning-bearing history (`reasoning_tokens` was 0 for every probe),
so the omission looked accepted.

The destination, however, rejects the whole request when a thinking-mode
assistant tool turn carries no `reasoning_content` key. Presence — not the
text — is what the provider requires. 24 of the 27 stored turns replayed the key
(12 of them the empty string), so the 3 `absent` turns are the ones that made
the provider reject the request. Task 98 had already fixed the producer side
(stream presence is tracked independently of text length); 116 then chose
omission as the replay default, which closed the loop back into the same
provider error.

`Message` provenance was intact and the messages were correctly identified as
same-route; only the projection value decision was wrong.

## Case Matrix (D1 producing shapes → replayed wire)

| # | Producing shape | Stored state | Pre-131 replay | Post-131 replay |
|---|---|---|---|---|
| A | provider returned `reasoning_content: "think"` (sync or stream) | `reasoning_content` string | `"think"` | `"think"` (unchanged) |
| B | provider returned `reasoning_content: ""` | `reasoning_content: ""`, `reasoning_field: string` | `""` | `""` (unchanged) |
| C | provider returned no field (sync message or tool-call-only deltas) | no `reasoning_content`, `reasoning_field: absent` | **key omitted → provider 400** | `""` |
| D | provider returned `reasoning_content: null` | no `reasoning_content`, `reasoning_field: null` | `null` | `""` |
| E | provider returned only `reasoning_details` (no `reasoning_content`) | `reasoning_details` only, `reasoning_field: absent` | details + **no key** | details + `""` |
| F | turn persisted and reloaded (JSON/DB round trip) | unchanged | key omitted for C/D/E | `""` |
| G | compaction-shaped retained tail (messages copied, tool results pruned) | unchanged | key omitted for C/D/E | `""` |
| H | retried turn (bounded retry without the thinking field, or a resumed turn) that produced no reasoning | `reasoning_field: absent` | key omitted | `""` |
| I | same model on another provider instance / endpoint (cross route) | same namespace, other issuer | key omitted | key omitted (unchanged) |
| J | another model on the same instance (for example Kimi state on the DeepSeek route) | `issuer_model` mismatch | key omitted | key omitted (unchanged) |
| K | foreign protocol state (Codex Responses) or an unrecorded tool turn | none/foreign | key omitted | key omitted (unchanged) |
| L | request with thinking explicitly disabled, or a route whose models.dev entry does not declare the echo field | any | as recorded | as recorded (unchanged) |

Rows C, D, E and their persistence/compaction/retry projections (F, G, H) are
the same defect: a same-route tool turn whose producer gave no reasoning string.

## Design

Data, not logic, at the existing seam:
`ChatReasoningReplayPolicy.defaultDecisions` gains the accepted outcome
`ReplayDecision.emptyString` for the two same-route cells that carry no
provider string (`sameRouteAbsent`, `sameRouteNull`). The policy applies it only
when all of the following hold:

1. the message is same instance, protocol, endpoint and model (116 D2),
2. it carries `tool_calls` (a plain assistant text turn keeps its recorded
   shape),
3. the destination's exact models.dev entry declares
   `interleaved.field: reasoning_content`,
4. the request is not explicitly thinking-off.

A recorded string (including `""`) is always replayed verbatim. An explicit
`null` becomes `""` because the field is string-typed and `""` is the shape the
route itself produced for zero-reasoning turns; canonical stored state keeps the
`reasoning_field` distinction, so no history is rewritten. `ReplayDecision.reject`
still wins over the new default and keeps the pre-dispatch rejection path
(116 D4) intact. Foreign and unrecorded turns stay untouched (116 boundary).

## Boundaries

- No canonical history rewrite, no new provider-state key, no schema/column
  change, no issuer change.
- No fabricated reasoning text: the only synthesized value is the empty string.
- No change to cross-route, cross-model, foreign-protocol, strict-route or
  explicitly non-thinking behavior.
- No runtime, provider, credential, Home or session action in this task.

## Gates

- [x] Red-first fixture/adapter test that builds the reported 27-turn history
      and the C/D/E producing shapes, failing on the current source.
- [x] `fvm dart analyze` clean.
- [x] Adapter/replay focused suites green, including 116's cross-route,
      non-thinking and rejection cases.
- [x] Full agent unit suite with temporary `HOME`/`SANAD_HOME` (never
      `~/.sanad`): +3427 ~15 passed, 0 failures.
- [x] Owning docs updated (`docs/technical/provider_protocol.md`,
      `docs/qa_maintenance/provider_projection_qa.md`, `agent/AGENTS.md`,
      `agent/lib/engine/adapters/AGENTS.md`) plus this plan.
- [x] Ready for orchestrator review and commit (no commit or push from implementer).

## Round Log

### Round 1 — 2026-10-22 (writer, in progress)

- Base `182d6a40`, branch `fix/deepseek-reasoning-replay-gap`.
- Correlated the live counts with source: provenance (`issuer_model`,
  `reasoning_field`) was correct; only `_recorded` omitted the key for
  `absent`/`null`, and 12 of 27 turns replayed `""` unchanged.
- Confirmed the live route declares `interleaved.field: reasoning_content`
  (`opencode-go`/`deepseek-v4.1-flash` from the public models.dev catalog), so
  the echo gate is active in production.
- Recorded producing cases C/D/E and their persistence, compaction and retry
  projections as the same defect.
- Built red-first suite in `agent/test/engine/adapters/deepseek_reasoning_replay_gap_test.dart`
  reproducing the 27-turn live history and the producing shapes matrix (9 failed tests).

### Round 2 — 2026-10-22 (implementer)

- Added `ReplayDecision.emptyString` to `ChatReasoningReplayPolicy`.
- Updated `defaultDecisions` to map `sameRouteAbsent` and `sameRouteNull` to `ReplayDecision.emptyString`.
- Updated `ChatReasoningReplayPolicy.plan` to project `reasoning_content: ""` for same-route assistant tool turns when the destination route declares `interleaved.field: reasoning_content` and thinking mode is active.
- Ensured plain assistant text turns, non-thinking turns, strict routes without echo declaration, and foreign/unrecorded tool turns remain strictly unpadded (`asRecorded`).
- Handled explicit `null` in `_sameRouteCell` and `_recorded` so it maps to `sameRouteNull` and projects `""` on thinking echo routes instead of JSON `null`.
- Updated existing test suites (`chat_reasoning_replay_policy_test.dart`, `chat_reasoning_replay_wire_test.dart`, `cross_provider_projection_runner_test.dart`) to align with post-131 thinking-mode same-route zero-reasoning replay.
- Verified focused suites: 39 tests passed across all 4 files. `fvm dart analyze` clean (0 issues).
- Ran full agent unit suite with temporary `SANAD_HOME`: 3,427 passed, 15 skipped, 0 failures.
- Updated owning contracts and technical docs: `agent/AGENTS.md`, `agent/lib/engine/adapters/AGENTS.md`, `docs/technical/provider_protocol.md`, and `docs/qa_maintenance/provider_projection_qa.md`.
