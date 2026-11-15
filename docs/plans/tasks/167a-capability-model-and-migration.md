---
title: "Task 167a: Capability Vocabulary, Template Declarations, and Instance Persistence"
description: "Introduce four provider capabilities, safe legacy chat migration, and automatic curated-template reconciliation."
status: "pending"
current_gate: "Ready for 167a-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 14
---

# Task 167a: Capability Vocabulary, Template Declarations, and Instance Persistence

## 1. Goal

Capability becomes a first-class dimension of the provider model: a curated
template declares an immutable capability set, an instance stores the
capabilities it actually serves, and every existing row migrates to `chat`
without losing routing, defaults, cache, or credentials. Curated instances then
acquire newly shipped declarations automatically through idempotent template
reconciliation, not a manual capability edit or a second account connection.

This task changes no user-facing behavior and no transcription, search, or image
execution behavior.

## 2. Scope

- A closed capability vocabulary (`chat`, `transcription`, `search`,
  `image_generation`) with reserved `text_to_speech` not yet enumerated.
- `ProviderProfile` gains an immutable capability declaration, with per-capability
  binding data where a capability needs its own protocol, endpoint, default
  models, model-selection policy, or mode.
- `ProviderInstance` gains persisted capability state: curated effective sets
  follow shipped declarations; custom keeps its explicit selected set.
- Storage: a migration that adds the capability record and backfills every
  existing instance to `chat`, preserving the current default, model cache, and
  recent selections.
- Reconciliation adds newly shipped curated capabilities without creating a
  UUID, credential, capability default, or account-verification success. Explicit
  execution settings, including disable flags, and custom selections survive.
- Creation/validation: a curated instance inherits its template's set;
  `custom` accepts only `{chat}`, `{transcription}`, `{chat, transcription}`.
- Registry: current curated templates retain `chat`; OpenAI and Groq also
  declare `transcription` binding data. Image binding shape/fixtures are supported
  here, but production Codex/OpenAI image declarations ship with working adapters.
- Capability constants live in the existing provider vocabulary file; no raw
  literals anywhere else.

## 3. Invariants

- A credential is per instance, never per capability.
- The instance UUID remains the only routing identity.
- An absent capability from a legacy row means `chat`.
- `custom` + `search` or `image_generation` is rejected by the daemon, not merely
  hidden by the client.
- A capability the template does not declare cannot be enabled, even by an
  explicit command. A model's vision/input flag never grants image generation.
- Capability declaration order in the registry is the catalog order; nothing
  re-sorts it later.
- Support is a validated provider declaration, not a per-user entitlement test;
  reconciliation makes no network request or default mutation.

## 4. Gates

### G1 — Vocabulary and template shape

- [ ] Capability vocabulary and validation helpers exist in one owning file.
- [ ] `ProviderProfile` carries capability declarations plus per-capability
      binding (protocol, endpoint, default models, model policy, mode) without
      duplicating the chat fields for templates that only serve chat.
- [ ] Every existing curated chat binding behaves identically to today; additional
      declarations do not contradict the preserved chat capability.
- [ ] OpenAI and Groq declare `transcription` with batch binding data.
- [ ] Image bindings can express selectable/server-managed models without using
      chat discovery or advertising an unimplemented production adapter.
- [ ] `text_to_speech` is reserved in prose only; it is not enumerated in code.

### G2 — Instance persistence

- [ ] Schema migration adds the capability record with an explicit backfill to
      `chat`; the migration is idempotent and runs inside the existing ordered
      schema module list.
- [ ] Re-opening a migrated database produces no duplicate capability rows.
- [ ] Instance read/write round-trips a multi-capability set in declaration order.
- [ ] Repository queries used by routing, catalog, and cache keep working
      unchanged for chat instances.
- [ ] Adding a shipped image declaration to existing Codex/OpenAI fixtures and
      reconciling twice adds support once, without reconnect, new secret/default,
      account probe, or loss of existing settings/cache/chat routing.
- [ ] Explicit custom selections and per-capability disable state are preserved.

### G3 — Creation and validation

- [ ] Curated instance creation derives capabilities from the template and
      ignores any client-supplied set.
- [ ] Custom instance creation accepts only the three allowed combinations and
      rejects `search` and `image_generation` with a typed reason.
- [ ] Enabling a capability requires its binding data to be resolvable; a
      template that declares transcription without an endpoint fails closed.
- [ ] Existing tests for instance creation, rename, and delete still pass.

### G4 — Compatibility

- [ ] A pre-update client request without capability is served as chat.
- [ ] A capability-aware request for an unknown capability fails with a typed
      reason and no partial write.

## 5. Definition of Done

- Migration and validation tests cover: legacy row backfill, idempotent reopen,
  curated inheritance/reconciliation, all three custom combinations, rejected
  custom search/images, absent capability, unknown capability, preserved secrets,
  settings, defaults, and cache.
- `fvm dart analyze` clean in `agent/`; focused provider tests green.
- No user-facing string added; no client file touched.
- `docs/technical/agent_database_schema.md` and
  `docs/technical/provider_protocol.md` updated in this task.

## 6. Success test scenario

1. Start from a database created by the previous release containing two chat
   instances, one of them default, with a model cache row.
2. Run the migration; assert both rows carry `chat`, the same default survives,
   and the cache row is still bound to its instance.
3. Re-run startup twice; assert no duplicate capability rows and no second
   default.
4. Attempt to create a custom instance with `search` or `image_generation`;
   assert refusal and that no row was written.
5. Add image declarations to Codex/OpenAI registry fixtures and reconcile twice;
   assert existing instances gain support once with zero network requests,
   preserved chat/credential state, and no image default.

## 7. Out of scope

Per-capability default flag, readiness, and test; protocol surface; any client
change; execution adapters; and account-entitlement verification.
