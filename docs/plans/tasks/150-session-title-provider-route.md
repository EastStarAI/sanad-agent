# Recovered Session Titles Use the Session's Own Provider Route

## Goal
After a daemon restart, a recovered session's pending title is generated through that session's own provider instance and model, or not at all — never through the process default adapter with a foreign model.

## Scope and locked decisions
- Observed failure: every recovered session logged `Title generation failed: LlmHttpException(404 generateResponse): {"error":"model 'deepseek-v4.1-flash' not found"}`, then fell back to the first user message. Sessions on instance `6982859f-48cb-4025-9821-1326b7d332bf` (OpenCodeGo, `deepseek-v4.1-flash`) kept working for real turns, so only the title route was wrong.
- Root cause is ownership, not the provider: `TitleService._resolveSessionRoute` preferred `AgentRuntimeService.sessionSignature(sessionId)`, which only exists after a turn runs in this process (`TurnRouteState.adapterForTurn`), and otherwise returned `runtime.defaultAdapter()`. `recoverPendingTitles` passes `modelOverride: session.model`, so after a restart that fallback paired the default instance's adapter with the recovered session's model.
- Fixed at the owning layer: a title request is provider-bound. The resolved route is a `TitleRoute` record carrying adapter, model, and provider instance id. Live turns keep the completed-turn `LLMRouteSnapshot`; recovery rebuilds the signature from the session's persisted `provider_id` + `model` via `AgentRuntimeService.resolveSignature`.
- Fail closed: no `defaultAdapter` fallback and no cross-instance model substitution. An unresolvable route (missing persisted provider instance, deleted instance, failed adapter build, or no `AgentRuntimeService`) skips the title with no provider request, and the pending title stays pending for a later terminal turn instead of being finalized from a failed call.
- Recovery only touches sessions whose `title_status = 'pending'`; a finalized title (manual, generated, fallback, migrated) is never regenerated. This is asserted, not assumed.
- Out of scope: provider failover policy, title prompt/cleaning, client rendering, the live turn route snapshot, and any runtime restart or live-Home action.

## Gates

### G0 — Discovery
- [x] Reproduce from source: `TitleService.recoverPendingTitles` -> `generateTitle(modelOverride: session.model)` -> `_resolveSessionRoute` -> `defaultAdapter()`.
- [x] Confirm the live path is unaffected (it passes `agentRunner.lastSuccessfulLlmRoute`, a provider-bound snapshot).
- [x] Confirm `sessions.provider_id` is persisted per session and `AgentRuntimeService.resolveSignature` fails closed for a missing instance.
- [x] Confirm startup recovery is the only caller that supplies a session model without a route.

### G1 — Failing test
- [x] Add `_RestartedRuntime` (no live signature, recording `defaultAdapter`, per-provider fake adapters) and three regression tests in `agent/test/evolution/title_service_test.dart`.
- [x] Observe the pre-fix failures: `defaultAdapterCalls` was 1 for both routing tests, i.e. the default provider adapter served the session's model.

### G2 — Implementation
- [x] Introduce `TitleRoute` (adapter, model override, provider instance id) as the one route shape a title request may consume.
- [x] Rebuild a cold-start route from the session's persisted provider instance and model; never fall back to `defaultAdapter`.
- [x] Skip unrouteable sessions without a provider request and without finalizing a fallback title.
- [x] Propagate `providerInstanceId` into `LLMRequestOptions` for usage and thinking attribution on the routable path.
- [x] Update `SessionTitleRefresher` for the nullable result.

### G3 — Verification and documentation
- [x] `fvm dart analyze` in `agent/`: `No issues found!`.
- [x] `fvm dart test test/evolution/title_service_test.dart test/evolution/session_title_update_test.dart test/interfaces/gateway_delivery_routing_test.dart test/interfaces/interfaces_test.dart test/interfaces/run_session_permission_projection_test.dart`: all passed.
- [x] Record the route law in `agent/lib/evolution/AGENTS.md`, `docs/technical/agent_runtime.md`, and the title QA scenarios.

## Acceptance criteria
- [x] Given a recovered pending session on provider instance P with model M, when startup recovery generates its title, then the request uses P's adapter with model M and `options.providerInstanceId = P`, and the process default adapter is never used.
- [x] Given a recovered pending session with no resolvable provider route, when startup recovery runs, then no provider request is made, the session keeps its pending status, and no fallback title is written.
- [x] Given a session whose title is already final, when startup recovery runs, then no title request is made and the title is unchanged.
- [x] Given a live terminal turn with a completed-turn route snapshot, the title request still uses exactly that adapter, instance, and model.

## Definition of Done
- [x] Analyzer clean; focused and adjacent suites green.
- [x] Owning contract and technical/QA documentation updated in the same change.
- [ ] Pull request opened against `main` for review; merge remains an owner decision.
