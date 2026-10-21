---
id: 115
title: Provider-specific thinking admission regression after PR 201
status: completed
gate: completed-with-106b-follow-up-pr
created: 2026-10-18
parent_task: 106
delivery: "[PR229](https://github.com/EastStarAI/sanad-agent/pull/229)"
---

# Task 115 — Provider-Specific Thinking Admission Regression

## Goal

Restore legitimate message execution for the affected provider/model routes while describing native thinking capabilities truthfully, preserving valid user selections, and retaining the working ChatGPT/Codex route.

## Completion — 2026-10-21

Delivered in [PR229](https://github.com/EastStarAI/sanad-agent/pull/229) with Task 106's follow-up (see [Task 106](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md)). The sections after this one are the historical working record.

- **Admission repair.** Carried, persisted and explicit selections are distinguished at admission. A stale target-route preference is revalidated before rejection, legacy same-route sessions without provenance are handled, and an explicit default/reset (`selectionId: null`, `restorePreserved: false`) no longer resurrects the previous session mode (`thinking_route_session_sync.dart`). Genuine invalid explicit selections still fail with `thinking_option_unavailable_for_route`.
- **Truthful capabilities.** Replaced by the five-layer authority (user config → provider metadata → shipped defaults `agent/model_capability_defaults.yaml` → models.dev vendor → models.dev canonical; otherwise unknown and admitted with the provider default). Moonshot `kimi-for-coding` is now `endpoint_declared` from Kimi `/models` discovery.
- **Client.** The thinking menu stays visible; opening a session no longer writes its selection; a carried selection is admitted per route.
- **Automated evidence.** Agent +2844 ~14, Client +1649, analyzers clean. Key suites: `agent/test/interfaces/runtime/carried_thinking_selection_admission_test.dart`, `agent/test/core/provider_thinking/thinking_route_session_sync_test.dart`, `agent/test/core/provider_thinking/layered_thinking_authority_test.dart`, `client/test/widget/route_thinking_mode_carried_selection_test.dart`.
- **Live evidence (Test Home, r2/r3).** Moonshot `kimi-for-coding` `high` completed with `reasoning_effort="high"`, HTTP 200. ChatGPT/Codex `gpt-6-luna` control completed with Responses `reasoning.effort="high"`. OpenCode Go `deepseek-v4.1-flash` `low`/`off`, `deepseek-v4-pro` `off`/`high` and `glm-5.2` `high` completed with the expected wire directives. `glm-5.2` `none` was rejected before dispatch with CLI exit 1 and zero provider calls.
- **Not closed here.** OpenCode Go `gpt-6-luna` now has a truthful descriptor but still fails on the Chat wire; per-model protocol routing is [Task 120](docs/plans/tasks/120-opencode-go-per-model-protocol.md). `qwen3.7-max` on Go remains unknown.

## Dependency and Activation

- PR210 is merged; delivery now belongs to Task106's single follow-up PR. [Task106's consolidated queue](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md) owns authorization and integration in `.agent/worktrees/106-compaction-resilience-and-token-estimation-repair`; no child PR.
- User amendment (2026-10-20): bounded read-only owner/dependency triage may start now. Isolated implementation may overlap106 once source evidence establishes disjoint ownership and an agreed small design; use a separate child worktree with one writer, never concurrent product writers in106. Preparation alone is not implementation or acceptance.
- Stage4 integration/live/checkpoint order remains after earlier106 stages pass their gates. Record exact base/dependencies and preceding accepted checkpoint SHA. Fixture proof may precede that checkpoint; live uses verified Task106 source and user-designated Test Home (`.sanad-test` under user home), never the normal conversation runtime.
- After independent review, automated and principal live acceptance: scoped commit/push under the approved identity and wait for exact-SHA green CI before stage 5. No main merge, protected label, runtime source handoff, new provider, credential copy or silent settings mutation is authorized.

## Parallel Implementation Boundary — 2026-10-20

- Bounded source triage confirms admission owners are disjoint from106 Stage1 repository/dumper repair and116 adapter projection. Isolated fixture-first implementation may start from2607a342 in `.agent/worktrees/115-thinking-admission-regression`;106 remains the integration owner, not a shared writer root.
- Triage suggestions are hypotheses, not accepted policy: do not infer `kimi-for-coding` native controls from a URL/model name, clear persisted valid choices, or bypass unsupported/unknown validation because the Client lacks a control. Prove explicit/default/inherited provenance and actual requested wire semantics; preserve every valid selection and reject genuine invalid requests specifically. Any declaration change needs pinned official evidence.
- Restrict initial repair to existing admission/thinking/turn-route owners and focused fixtures; no `AgentRunner`, adapter, pressure, compaction or persistence refactor. Report a proven broader dependency before expanding. Isolated tests do not replace ordered live/integration/checkpoint acceptance.

## Independent Review Follow-Up — 2026-10-20

- Coordinator does not accept the initial scoped verdict. Amended `temp/115-independent-review.md` §4 proves three gaps: stale target-route preferences still reject before revalidation; same-route legacy sessions lack selection provenance; unscoped correction/default restoration can resurrect a cleared preference. Resolve before isolated candidate acceptance, not as a silent Stage4 integration refinement.
- Preserve disjoint ownership: repair through existing thinking/store/turn-route/session-sync boundaries, not `AgentRunner`, adapters or106 compaction. Prove a broader dependency before expanding scope. Distinguish fresh explicit selection, validated persisted selection, unknown legacy provenance and deliberate provider-default reset; do not implement the review's broad fallback suggestion verbatim.
- Existing18 focused passes prove limited fixtures, not complete acceptance. `_CountingAdapter.lastOptions` proves dispatch intent, not serialized wire or live vendor responses. User-reported Test Home reproduction, serialized wire controls, ordered integration/live and exact-SHA delivery remain open. Keep full timed logs and red/green receipts separately.

### Safe-Point Pause and Latest Review — 2026-10-21

- User requested a session handoff; every worker is settled, no follow-up is running. Latest independent report `temp/115-three-gap-repair-review.md` explicitly REJECTS Gap3B at `thinking_route_session_sync.dart:30`: `selectionId ?? session?.thinkingMode` defeats `selectionId: null, restorePreserved: false`. Gap1, Gap2 and Gap3A have scoped acceptance only. No integration/live/checkpoint/CI acceptance.
- Next repair must test the public sync entry point, returned selection, persisted session thinking mode and route preference, plus restore/default callers. The suggested one-line conditional alone may be insufficient: the later update condition compares result with `currentSelection`, not the previous persisted session value; an explicit null/default can still leave the old session mode unchanged. Verify this with an actual regression rather than accepting a proposed patch by inspection.

## User-Reported Baseline

The regression appeared after [PR 201](https://github.com/EastStarAI/sanad-agent/pull/201), merged on 2026-10-17.

| Provider / adapter | Model | Reported thinking UI | Reported execution |
|---|---|---|---|
| Moonshot | `kimi-for-coding` | Unknown / not reported | Messages fail completely |
| OpenCode Go (reported as OpenCodeGo) | `gpt-6-luna` | Unsupported / no control | Messages fail completely |
| ChatGPT / Codex adapter | `gpt-6-luna` | Not specified | Works normally |

The UI reports: `Thinking controls are unsupported for the active model route.`
The bounded error code is `thinking_capability_unsupported`. The reported path is `ThinkingSelectionResolver.resolve` → `RouteCapabilityResolver.resolveSync/resolve` → `AgentRunner._admitTurnCapabilityProfile` → `AgentRunner.streamMessage` → `SessionTurnExecutor.runTurn`.

## Locked Boundaries

- Provider/model/protocol identity matters: the same model name working through Codex does not establish another provider's native controls or wire contract.
- Distinguish capability evidence, unknown/not-reported state, absence of exposed controls, stored selections and an actual explicit thinking request. Do not assume the root cause before tracing admission.
- Do not fix this by silently lowering, clearing, forcing or substituting the user's valid thinking directives, switching providers, declaring every route supported, or bypassing validation globally.
- Keep the thinking menu visible as required by the Client contract; represent unavailable/unconfirmed choices honestly.
- Keep failures bounded, localized and nonfatal, without raw provider bodies, secrets, user content or stack traces in public feedback.

## Gates

### G0 — Parallel Preparation, Then Ordered Acceptance

- [x] Bound source/owner/dependency triage against106/116; record the smallest design, exact base and disjoint files before isolated implementation. No runtime/model calls during preparation.
- [x] Assign one writer per child worktree; integrate only after the preceding106 stage's review/automated/live/checkpoint/exact-SHA CI gates. Preserve accepted fixes; deliver only through106's follow-up PR.
- [ ] Confirm reviewer and provider/Test Home pair readiness before live execution; missing access is a blocker, never permission to copy credentials.

### G1 — Provider-Specific Triage

- [ ] Reproduce the two reported failures and preserve the working Codex control case using existing authorized configured providers on Test Home; record each exact route and thinking selection separately. In-memory fixtures exist; Test Home/vendor reproduction is not yet run.
- [x] Trace capability resolution, selection persistence/default admission and actual adapter request options; distinguish unsupported controls from an otherwise valid text request.
- [x] Compare the owning PR 201 changes and use pinned official provider evidence for any capability-declaration change. Record the first violated invariant and proposed owning-boundary repair.

### G2 — Scoped Repair and Regression Proof

- [x] Delegate the smallest owning-boundary repair; do not redesign compaction or introduce a global unsupported-thinking bypass.
- [ ] Cover Moonshot, OpenCode Go and Codex independently, including unknown/no-control metadata, persisted selection transitions, valid explicit selections and specific invalid-request rejection. Cross-route fixtures pass; the three independent-review gaps above remain.
- [ ] Prove actual wire behavior and preserved valid thinking directives, not merely UI labels or codec-only serialization; retain red/green evidence. Dispatch-intent assertions alone do not close this gate.

### G3 — Independent Verification and Delivery

- [ ] Run affected analyzers, focused tests and necessary real-daemon coverage; freeze and run required fast suites once with unique timed logs.18 focused tests/analyzer pass on the pre-follow-up candidate; complete gate remains open.
- [ ] Obtain independent user-designated review and principal-owned live acceptance for both repaired routes and the unchanged Codex control case.
- [ ] Update owning technical/QA documentation and graph; commit/push the accepted repair to106's follow-up PR under staged authorization, record exact-SHA CI success and remaining work before advancing, without merging into `main`.

## Acceptance Criteria and Definition of Done

- [x] Both affected routes admit legitimate messages and complete responses using their truthful native capability contracts. Moonshot is live-proven; OpenCode Go `gpt-6-luna` admission is fixed, but its transport needs [Task 120](docs/plans/tasks/120-opencode-go-per-model-protocol.md).
- [x] Existing valid user thinking selections are preserved; genuinely invalid explicit requests still receive safe specific feedback rather than silent recovery.
- [x] `gpt-6-luna` through ChatGPT/Codex remains working; provider-specific behavior is not inferred from the shared model identifier.
- [x] Unknown/not-reported and no-control UI states no longer conceal an unexplained total execution failure.
- [x] Regression tests, review, documentation, live acceptance and exact-head delivery evidence exist separately; no merge or runtime handoff is inferred.
