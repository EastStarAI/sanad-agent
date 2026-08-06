# PR 70 — Live Default Provider Adapter Resolution

## Problem

Dependency composition cached the first default `LLMAdapter` as a lazy singleton. If that first resolution happened before provider onboarding completed, the process retained a `MissingProviderAdapter` and the first post-onboarding turn could fail until daemon restart.

## Ownership Constraint

Provider handlers own provider workflows and receive runtime dependencies explicitly. They must not reach into the global dependency container or reset unrelated registrations. `AgentRuntimeService` remains the adapter cache owner; dependency composition only resolves its current default.

## Implementation

- Register the default `LLMAdapter` compatibility binding as a factory backed by `AgentRuntimeService.defaultAdapter()`. The runtime's route-signature cache still reuses real adapters, while a pre-onboarding missing adapter is never frozen in dependency injection.
- Keep the shared `ContextEngine` provider-neutral. `AgentRunner` supplies the live turn-scoped adapter to compression for every request.
- Resolve title-generation fallback routes from `AgentRuntimeService` at call time rather than capturing a default adapter when `TitleService` is constructed.
- Provider mutations invalidate only the explicitly injected `AgentRuntimeService` cache; handlers do not access GetIt.

## Verification

A dependency-composition regression test resolves the missing adapter and shared context engine before onboarding, adds a ready default provider, then verifies both a subsequent default resolution and a newly composed runner use the live provider adapter without resetting DI or restarting the process. Focused title, context, provider-runtime, and gateway tests cover the affected boundaries.
