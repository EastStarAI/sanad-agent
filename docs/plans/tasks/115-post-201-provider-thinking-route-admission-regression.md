---
id: 115
title: Provider-specific thinking admission regression after PR 201
status: planned
gate: 106-consolidated-queue-stage-4
created: 2026-10-18
parent_task: 106
delivery_pr: 210
---

# Task 115 — Provider-Specific Thinking Admission Regression

## Goal

Restore legitimate message execution for the affected provider/model routes while describing native thinking capabilities truthfully, preserving valid user selections, and retaining the working ChatGPT/Codex route.

## Dependency and Activation

- User amendment (2026-10-19): this work package is included in Task 106's existing [PR 210](https://github.com/EastStarAI/sanad-agent/pull/210), in `.agent/worktrees/106-compaction-resilience-and-token-estimation-repair`, not a separate worktree or PR. The owning task list is [Task 106's consolidated repair queue](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md).
- Scheduled as stage 4, after diagnostic-ledger/request-dumping acceptance, compaction resilience and automatic-pressure repair each pass independent review, automated verification, live acceptance and exact-checkpoint CI. Record the preceding accepted checkpoint SHA at activation; do not wait for PR Ready or assume a `main` merge.
- Scoped implementation, verification and live acceptance are authorized under that sequential workflow; execution has not started merely because the plan moved. Use the Task 106 source and the separate user-designated Test Home (`.sanad-test` under the user home), never the normal conversation runtime.
- After independent review, automated and principal live acceptance: scoped commit/push under the approved identity and wait for exact-SHA green CI before stage 5. No main merge, protected label, runtime source handoff, new provider, credential copy or silent settings mutation is authorized.

## User-Reported Baseline — Not Yet Independently Reproduced

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

### G0 — Activate at the Accepted Sequential Checkpoint

- [ ] Verify the preceding Task 106 stage has independent review, automated and Test Home live acceptance, a pushed checkpoint and green CI for its exact SHA; record the SHA.
- [ ] Confirm sole-writer ownership in the existing Task 106 worktree/branch and delivery through PR 210; preserve earlier accepted fixes and do not open another PR.
- [ ] Confirm reviewer readiness, existing provider availability and the isolated Test Home Agent/Client pair before starting work; missing access is a blocker, not permission to copy credentials.

### G1 — Provider-Specific Triage

- [ ] Reproduce the two reported failures and preserve the working Codex control case using existing authorized configured providers on Test Home; record each exact route and thinking selection separately.
- [ ] Trace capability resolution, selection persistence/default admission and actual adapter request options; distinguish unsupported controls from an otherwise valid text request.
- [ ] Compare the owning PR 201 changes and use pinned official provider evidence for any capability-declaration change. Record the first violated invariant and proposed owning-boundary repair.

### G2 — Scoped Repair and Regression Proof

- [ ] Delegate the smallest owning-boundary repair; do not redesign compaction or introduce a global unsupported-thinking bypass.
- [ ] Cover Moonshot, OpenCode Go and Codex independently, including unknown/no-control metadata, persisted selection transitions, valid explicit selections and specific invalid-request rejection.
- [ ] Prove actual wire behavior and preserved valid thinking directives, not merely UI labels or codec-only serialization; retain red/green evidence.

### G3 — Independent Verification and Delivery

- [ ] Run affected analyzers, focused tests and necessary real-daemon coverage; freeze and run required fast suites once with unique timed logs.
- [ ] Obtain independent user-designated review and principal-owned live acceptance for both repaired routes and the unchanged Codex control case.
- [ ] Update owning technical/QA documentation and graph; commit/push the accepted repair to PR 210 under Task 106's staged authorization, record exact-SHA CI success and remaining work before advancing, without merging into `main`.

## Acceptance Criteria and Definition of Done

- [ ] Both affected routes admit legitimate messages and complete responses using their truthful native capability contracts.
- [ ] Existing valid user thinking selections are preserved; genuinely invalid explicit requests still receive safe specific feedback rather than silent recovery.
- [ ] `gpt-6-luna` through ChatGPT/Codex remains working; provider-specific behavior is not inferred from the shared model identifier.
- [ ] Unknown/not-reported and no-control UI states no longer conceal an unexplained total execution failure.
- [ ] Regression tests, review, documentation, live acceptance and exact-head delivery evidence exist separately; no merge or runtime handoff is inferred.
