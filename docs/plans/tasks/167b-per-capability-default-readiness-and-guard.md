---
title: "Task 167b: Per-Capability Default, Readiness, Test, and Delete Guard"
description: "Independent capability defaults, readiness/test policies, and guards, with no image-account eligibility probe."
status: "pending"
current_gate: "Ready for 167b-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 16
---

# Task 167b: Per-Capability Default, Readiness, Test, and Delete Guard

## 1. Goal

Each capability owns its default instance, its own readiness, and its own
verification policy/result. The single runtime-wide default disappears in favor
of a default per capability, and a capability default can never be deleted or
disabled into an unusable runtime.

## 2. Scope

- Default flag becomes capability-scoped, enforced by a uniqueness constraint
  and by the existing default transaction, with the current runtime default
  migrating to the `chat` default.
- Readiness is projected per capability: a chat instance can be ready for chat
  and not ready for transcription.
- Verification is per capability with a capability-appropriate policy:
  chat (existing model discovery/probe), transcription (a bounded audio probe),
  search (a bounded one-word query).
- Image support is provider-declared; image configuration checks binding and
  required local credential/options only. No entitlement call, sample generation,
  previous successful image request, or chat-model verification is required.
  Its account-test policy is explicitly not required, never a forged success.
  Ordinary credential resolution/refresh occurs on actual use.
- Deleting the default instance of a capability, or disabling the capability
  that holds the default, is refused with a typed reason until another default
  exists.
- "Configured" and "verified" stay separate facts per capability.

## 3. Invariants

- At most one default per capability; newly available capabilities have none
  until explicitly selected. Existing chat defaults are preserved.
- A capability without models (search), or with a server-managed image model, is
  not "unready" because it has no selectable model list.
- Deleting a non-default instance still removes its credential and cache as
  today.
- Auto-failover and rate limiting keep their current semantics per instance and
  never cross capability boundaries. Non-idempotent image dispatch does not
  inherit automatic chat/search retry or failover.
- No capability default is invented implicitly on startup; the migration creates
  the chat default only from the existing runtime default.
- Declared support, local configuration, and execution outcomes stay separate.
  Real image permission/quota/auth errors do not remove provider support or
  introduce an account-check prerequisite, and do not block unrelated chat.

## 4. Gates

### G1 — Default per capability

- [ ] Default storage is capability-scoped with a uniqueness constraint.
- [ ] `setDefault` is capability-scoped and atomic.
- [ ] Migration maps the previous single default to the chat default exactly
      once.
- [ ] A second default for one capability is impossible at the database level,
      not only in the service.
- [ ] Added image support invents no image default; selecting one never changes
      active chat routing or its selected model.

### G2 — Readiness and verification

- [ ] Readiness projects per capability on the catalog and instance views.
- [ ] Each capability has an explicit verification policy; a passing chat probe
      never marks transcription verified or claims image-account eligibility.
- [ ] A no-model capability is ready under its declared policy: applicable probes
      for search, local configuration only for images.
- [ ] Probe failures are reported with sanitized, capability-scoped reasons.
- [ ] Image listing/edit/save/default/test paths issue zero entitlement or
      generation requests, even with a legacy generic probe flag.
- [ ] An image test reports configuration/policy only, not a sample or successful
      account verification; it works without chat-model discovery/cache.
- [ ] A real image error remains a typed execution outcome, with provider support
      and unrelated capability state intact.

### G3 — Guard

- [ ] Delete of a capability default is refused with a typed reason naming the
      capability.
- [ ] Disabling the capability that holds its default is refused the same way.
- [ ] After another default is set, the previous default deletes and disables
      normally.
- [ ] Multi-capability deletion checks every affected default atomically.
- [ ] Guards are enforced in the daemon; the client message is a projection.

## 5. Definition of Done

- Tests cover: single-default enforcement, migration default mapping, disabled
  default refusal, delete refusal then success after reassignment, search-style
  capability without models reported ready, cross-capability probe isolation,
  image configuration independent of chat discovery, and zero image setup probes.
- `fvm dart analyze` clean in `agent/`; focused tests green.
- `docs/technical/provider_protocol.md` and
  `docs/technical/agent_database_schema.md` reflect capability-scoped defaults.

## 6. Success test scenario

1. Create one chat default and one transcription instance.
2. Attempt to delete the transcription instance after making it the
   transcription default; assert refusal with the typed reason.
3. Set a second transcription instance as default; delete the first; assert
   success and that chat routing is untouched.
4. Break the transcription credential but leave chat valid; assert chat readiness
   is unaffected and transcription reports its own reason.
5. Configure images on a fixture whose chat discovery fails; assert image
   configuration/default/test still work without an outbound image check, no
   account-verified result is invented, and a quota failure does not erase support.

## 7. Out of scope

Protocol and CLI exposure; client presentation; execution adapters;
account-entitlement verification; and automatic image sample generation.
