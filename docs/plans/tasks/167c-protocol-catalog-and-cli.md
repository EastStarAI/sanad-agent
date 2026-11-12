---
title: "Task 167c: Protocol, Catalog, and CLI Carry Capability"
description: "Carry four provider capabilities through protocol, catalog, and CLI while preserving legacy peers and provider-declared image support."
status: "pending"
current_gate: "Ready for 167c-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 14
---

# Task 167c: Protocol, Catalog, and CLI Carry Capability

## 1. Goal

Every provider command, payload, and catalog projection can express capability,
so one management surface can render and edit chat, transcription, search, and
image-generation instances without a second protocol family. Older peers keep
working unchanged.

## 2. Scope

- Canonical command names, payload fields, and reason codes for capability.
- `provider.catalog` (and the client-facing template projection) exposes each
  template's declared capability set and, for `custom`, the allowed combinations.
- Instance payloads expose effective capabilities, per-capability default state,
  per-capability readiness, and per-capability verification policy/result.
- Image projections distinguish declared support, local configuration, and
  account testing not required. Image test commands perform no generation or
  entitlement request, including when a generic probe flag is supplied.
- Model policy distinguishes selectable, absent, and server-managed dimensions,
  independently of chat-model cache; vision flags do not grant image generation.
- Delete/disable guard refusals travel as typed reasons, not prose.
- CLI surfaces that create, list, or select providers accept a capability and
  present it in human-readable output. Curated support is derived automatically,
  not manually entered by the user.
- Capability is optional on the wire; omission means chat.

## 3. Invariants

- No capability-aware field is required for a pre-update peer to succeed.
- An unknown capability in a request is refused with a typed reason; it never
  degrades silently into chat.
- Catalog filters are presentation-only: the authoritative order is the registry
  declaration order, and no command re-sorts it.
- Reason codes are stable strings published from one owner.
- No raw credential or invented account-verification success reaches projections.

## 4. Gates

### G1 — Command and payload contract

- [ ] Capability fields and reason codes are defined in the canonical protocol
      owner, not inline in a handler.
- [ ] Create/update/delete/default/test commands accept and echo capability.
- [ ] Omitted capability is served as chat for catalog, routing, and mutation.
- [ ] Unknown capability is refused before any write.
- [ ] Image configuration/test paths cannot dispatch entitlement or generation
      probes, including requests carrying a legacy generic probe flag.

### G2 — Catalog projection

- [ ] The template projection exposes declared capabilities and allowed custom
      combinations; existing curated instances acquire shipped support without
      reconnecting while custom selections remain unchanged.
- [ ] The instance projection exposes per-capability default, readiness, and
      verification policy, with honest no-model/server-managed image semantics.
- [ ] New clients detect old agents from actual missing capability data or their
      existing unsupported-command behavior, not a new signal an old agent
      cannot emit. Recorded old responses support chat-only degradation.

### G3 — CLI

- [ ] Provider listing shows each instance's capabilities and per-capability
      default markers.
- [ ] Provider creation derives curated sets, accepts explicit custom selections,
      and rejects the same invalid combinations as the daemon.
- [ ] Model listing and selection keep working for chat, no-model, and
      server-managed capabilities.
- [ ] Image default/options configuration is independent of chat and its test
      explains that no account eligibility was checked; zero image requests occur.

## 5. Definition of Done

- Contract tests cover: omitted capability, unknown capability, catalog
  projection shape, guard reason codes, CLI create/list round-trip, image policy,
  no-probe behavior, curated additions, and actual old-peer payloads.
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
5. Configure/test images through a validated binding fixture; assert honest
   model/support policy, zero eligibility/generation calls, and no chat mutation.

## 7. Out of scope

Client widgets; execution adapters; media transport; and user mutation of curated
capabilities.
