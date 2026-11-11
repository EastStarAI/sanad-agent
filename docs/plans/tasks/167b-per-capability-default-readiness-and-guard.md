---
title: "Task 167b: Per-Capability Default, Readiness, Test, and Delete Guard"
description: "افتراضي مستقل لكل قدرة، وجاهزية واختبار لكل قدرة، ورفض حذف أو تعطيل الافتراضي قبل وجود بديل."
status: "pending"
current_gate: "Ready for 167b-G1"
priority: "high"
depends_on: "167a"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 16
---

# Task 167b: Per-Capability Default, Readiness, Test, and Delete Guard

## 1. Goal

Each capability owns one default instance, its own readiness, and its own
verification result. The single runtime-wide default disappears in favor of a
default per capability, and a capability default can never be deleted or
disabled into an unusable runtime.

## 2. Scope

- Default flag becomes capability-scoped, enforced by a uniqueness constraint
  and by the existing default transaction, with the current runtime default
  migrating to the `chat` default.
- Readiness is projected per capability: a chat instance can be ready for chat
  and not ready for transcription.
- Verification is per capability with a capability-appropriate probe:
  chat (existing model discovery/probe), transcription (a bounded audio probe),
  search (a bounded one-word query).
- Deleting the default instance of a capability, or disabling the capability
  that holds the default, is refused with a typed reason until another default
  exists.
- "Configured" and "verified" stay separate facts per capability.

## 3. Invariants

- Exactly one default per capability, or none for a capability that has no
  instance.
- A capability without models (search) is not "unready" because it has no model.
- Deleting a non-default instance still removes its credential and cache as
  today.
- Auto-failover and rate limiting keep their current semantics per instance and
  never cross capability boundaries.
- No capability default is invented implicitly on startup; the migration creates
  the chat default only from the existing runtime default.

## 4. Gates

### G1 — Default per capability

- [ ] Default storage is capability-scoped with a uniqueness constraint.
- [ ] `setDefault` is capability-scoped and atomic.
- [ ] Migration maps the previous single default to the chat default exactly
      once.
- [ ] A second default for one capability is impossible at the database level,
      not only in the service.

### G2 — Readiness and verification

- [ ] Readiness projects per capability on the catalog and instance views.
- [ ] Each capability has one probe; a passing chat probe never marks
      transcription verified.
- [ ] A capability with no model dimension is ready when its credential is
      configured and its probe passes.
- [ ] Probe failures are reported with sanitized, capability-scoped reasons.

### G3 — Guard

- [ ] Delete of a capability default is refused with a typed reason naming the
      capability.
- [ ] Disabling the capability that holds its default is refused the same way.
- [ ] After another default is set, the previous default deletes and disables
      normally.
- [ ] Guards are enforced in the daemon; the client message is a projection.

## 5. Definition of Done

- Tests cover: single-default enforcement, migration default mapping, disabled
  default refusal, delete refusal then success after reassignment, search-style
  capability without models reported ready, cross-capability probe isolation.
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

## 7. Out of scope

Protocol and CLI exposure (167c); client presentation (167d); any adapter work.
