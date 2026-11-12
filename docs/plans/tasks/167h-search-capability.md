---
title: "Task 167h: Search Capability — Curated Providers and Routing"
description: "Curated search bindings with independent defaults and routing, preserving the built-in engine and legacy environment path."
status: "pending"
current_gate: "Ready for 167h-R0"
priority: "medium"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
reference_grounding: "required"
file_budget: 16
---

# Task 167h: Search Capability — Curated Providers and Routing

## 1. Goal

Web search becomes a provider capability with curated templates, one adapter per
vendor, an independent default, and real routing from the existing search tool.
The keyless built-in engine stays the default when nothing is configured, and the
existing environment-based configuration keeps working untouched.

## 2. Scope

- Capability `search` templates with binding data: Serper (reusing the current
  adapter), Brave, Tavily, Exa, and SearXNG (self-hosted, no key).
- One adapter per vendor with its own auth form, request shape, and response
  normalization into the existing result contract (title, url, snippet, optional
  direct answer).
- No search SDK as a dependency: the available Dart clients are per-vendor
  community packages that wrap a single POST, so the adapters are ours.
- The self-hosted engine's source is read for its response shape only. Its
  license forbids copying code into this repository, so no block is taken from it
  and no derivative of it is embedded.
- Routing: the search tool resolves a default search instance when one exists;
  otherwise it keeps today's ordered built-in behavior, including the
  environment-configured path. No migration, no rewriting of stored keys.
- Readiness and test for search: a bounded one-word query proves the credential
  and wire without being counted as usage noise.
- Search instances appear in the existing provider list under the search filter,
  with the same default and guard rules as other capabilities.
- No model selection step for search.

## 3. Invariants

- Custom instances can never carry search; the daemon rejects it.
- Result safety filtering stays mandatory and provider-independent.
- A search provider failure degrades to the next configured source and then to
  the built-in engine; it never surfaces a raw vendor error to the agent.
- No API key is ever logged, echoed, or stored outside the vault.
- Search probes/fallback never verify images or become an image execution path;
  non-idempotent image generation cannot inherit search's fallback policy.
- Domain restriction and result limits keep their current semantics for every
  adapter.

## 4. Gates

### R0 — Reference grounding

- [ ] Pinned evidence per vendor: endpoint, auth header, request fields, response
      shape, rate/limit behavior.
- [ ] Adopt/Adapt/Reject recorded.

### G1 — Templates and adapters

- [ ] Each vendor has one adapter and one template entry; no vendor logic in the
      tool.
- [ ] Response normalization yields the existing result contract for every
      vendor, including a missing-snippet case.
- [ ] SearXNG works keyless and with a self-hosted base URL.

### G2 — Routing and default

- [ ] A configured default search instance is used by the tool.
- [ ] With no search instance, behavior is byte-identical to today.
- [ ] Failure order is deterministic and logged once, with codes only.
- [ ] Setting or clearing the search default is capability-scoped.

### G3 — Readiness, test, and safety

- [ ] Test performs one bounded query and reports a typed result.
- [ ] Unsafe or non-public URLs are filtered for every adapter.
- [ ] Deleting the search default is refused until another default exists.

## 5. Definition of Done

- Tests cover: per-vendor normalization from fixtures, routing preference, fallback
  order, keyless SearXNG, safety filtering, guard refusal, and unchanged behavior
  with no instance.
- `fvm dart analyze` clean in `agent/`; focused search tests green.
- `docs/technical/web_search_runtime.md` owns providers and routing;
  `docs/technical/provider_protocol.md` gains the search capability rules.

## 6. Success test scenario

1. With no search instance, run a query and assert the response matches the
   pre-change behavior fixture.
2. Add a Brave instance with a key, make it the search default, and assert the
   tool queries Brave and returns normalized hits.
3. Break the key and assert fallback to the built-in engine with one coded log
   line and no raw vendor error.
4. Attempt to create a custom instance with search; assert refusal.

## 7. Out of scope

Custom search providers and any mapping language; search UI beyond the provider
list; transcription work; image generation and image retry/failover policies.
