# Task 72 — Bounded Provider Failover and Accurate Route Label

## Problem

One model invocation can alternate forever between two rate-limited provider instances because each failover decision excludes only the provider that failed most recently. Earlier failed instances become eligible again, so a third qualified provider is never reached and route-transition history grows without a bound.

Separately, the composer can stage a new provider/model pair while its provider label still uses stale display metadata from the selected session. The model changes visibly, but the provider name remains associated with the prior session route.

## Design

1. Keep an invocation-scoped set of provider instance ids that failed before streaming began.
2. Add the current failed provider before selecting a candidate, and pass the complete set to provider-runtime selection.
3. Reuse the set only within one model invocation loop. Each later tool/model step starts a fresh failover chain.
4. When every qualified provider has failed, preserve the existing bounded retry/block behavior; never revisit an instance from the same chain.
5. Resolve cached session provider display metadata only when its provider identity matches the currently displayed provider. Otherwise prefer the daemon-owned provider-instance display map and preserve the existing UUID-hiding fallback.

## Verification

- Agent regression: three same-model providers where A and B return rate limits and C succeeds; assert the request order is exactly A, B, C and no provider is retried by failover.
- Agent regression: when all eligible providers fail, the invocation becomes controllably blocked instead of cycling.
- Client widget regression: a staged provider/model route supersedes stale session display metadata and renders the new provider display name.
- Run focused agent/client tests and both analyzers.
- Update Plan 30 recovery QA documentation with multi-hop failover and stale-label scenarios.

## Definition of Done

- Automatic failover cannot revisit a provider within one model invocation.
- A third qualified provider is reached after two failures.
- Exhausted candidate chains terminate in normal recovery state.
- Provider chips never pair a staged model with stale display metadata from another provider.
- Focused tests and analyzers pass.
