---
title: "Task 167c: Protocol, Catalog, and CLI Carry Capability"
description: "تمرير القدرة عبر أوامر المزود والكتالوج وواجهة CLI مع توافق خلفي كامل للعملاء والوكلاء الأقدم."
status: "pending"
current_gate: "Ready for 167c-G1"
priority: "high"
depends_on: "167a"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 14
---

# Task 167c: Protocol, Catalog, and CLI Carry Capability

## 1. Goal

Every provider command, payload, and catalog projection can express capability,
so one management surface can render and edit chat, transcription, and search
instances without a second protocol family. Older peers keep working unchanged.

## 2. Scope

- Canonical command names, payload fields, and reason codes for capability.
- `provider.catalog` (and the client-facing template projection) exposes each
  template's declared capability set and, for `custom`, the allowed combinations.
- Instance payloads expose enabled capabilities, per-capability default state,
  per-capability readiness, and per-capability verification.
- Delete/disable guard refusals travel as typed reasons, not prose.
- CLI surfaces that create, list, or select providers accept a capability and
  present it in human-readable output.
- Capability is optional on the wire; omission means chat.

## 3. Invariants

- No capability-aware field is required for a pre-update peer to succeed.
- An unknown capability in a request is refused with a typed reason; it never
  degrades silently into chat.
- Catalog filters are presentation-only: the authoritative order is the registry
  declaration order, and no command re-sorts it.
- Reason codes are stable strings published from one owner.

## 4. Gates

### G1 — Command and payload contract

- [ ] Capability fields and reason codes are defined in the canonical protocol
      owner, not inline in a handler.
- [ ] Create/update/delete/default/test commands accept and echo capability.
- [ ] Omitted capability is served as chat for catalog, routing, and mutation.
- [ ] Unknown capability is refused before any write.

### G2 — Catalog projection

- [ ] The template projection exposes declared capabilities and allowed custom
      combinations.
- [ ] The instance projection exposes per-capability default, readiness, and
      verification.
- [ ] A chat-only agent answering a capability-aware client produces an explicit
      "capability unsupported" signal the client can degrade on.

### G3 — CLI

- [ ] Provider listing shows each instance's capabilities and per-capability
      default markers.
- [ ] Provider creation accepts a capability set and rejects the same invalid
      combinations as the daemon.
- [ ] Model listing and selection keep working for chat and no-model
      capabilities.

## 5. Definition of Done

- Contract tests cover: omitted capability, unknown capability, catalog
  projection shape, guard reason codes, CLI create/list round-trip.
- `fvm dart analyze` clean in `agent/`; focused protocol and CLI tests green.
- `docs/technical/provider_protocol.md` owns the capability fields and reason
  codes; `docs/technical/communication_protocols.md` references it without
  duplicating.

## 6. Success test scenario

1. Drive the daemon with a pre-update style request (no capability) and assert
   normal chat behavior.
2. Request the catalog as a capability-aware client and assert each template
   publishes its declared set and the custom template publishes allowed
   combinations.
3. Send an unknown capability; assert a typed refusal and no new instance.
4. Create a transcription instance through the CLI and assert the listing marks
   its capability and default state.

## 7. Out of scope

Client widgets (167d); execution adapters (167e/167f/167h); mutation of curated
capabilities.
