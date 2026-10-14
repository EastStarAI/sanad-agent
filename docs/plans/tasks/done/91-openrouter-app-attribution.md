---
title: "Task 91 — OpenRouter App Attribution"
description: "Attribute Sanad Agent requests to the canonical project identity in OpenRouter."
status: complete
current_gate: complete
remaining_estimate: 0%
reference_grounding:
  evidence_id: "91"
  fingerprint: "sha256:87120e0981514e8811b30786fa7a3ff96ffab113e842377bedcd0b2c4c7a5c5a"
---

# Task 91 — OpenRouter App Attribution

## Goal

Ensure new OpenRouter requests identify the application as Sanad Agent instead of Unknown by sending OpenRouter's documented app-attribution headers.

## Locked Decisions and Scope

- Use `https://sanad.eaststarai.com` as the canonical application URL.
- Use `Sanad Agent` as the display title.
- Send modern `X-OpenRouter-Title` rather than relying on legacy `X-Title`.
- Reuse the existing OpenRouter `ProviderProfile.defaultHeaders` owner; do not add a generic attribution subsystem.
- Do not add optional categories, visibility, cache controls, User-Agent impersonation, OAuth, or UI changes.
- Acceptance applies to new requests; historical Unknown usage is outside OpenRouter's documented guarantees.

## Gates

### G0 — Discovery and alignment
- [x] Verify OpenRouter's current official attribution contract.
- [x] Confirm Sanad currently sends only legacy `X-Title` without required `HTTP-Referer`.
- [x] Inspect pinned reference main/auxiliary header propagation.

### G1 — Focused implementation
- [x] Add canonical OpenRouter URL and modern title to the official provider profile.
- [x] Preserve bearer authentication and isolate headers from unrelated profiles.

**Gate closeout:** Complete. Attribution remains profile-owned with bearer authentication unchanged. Remaining estimate after G1: 45%.

### G2 — Regression coverage
- [x] Prove the OpenRouter template exposes the exact documented values.
- [x] Prove actual synchronous and streaming OpenRouter model requests forward both values.
- [x] Prove a non-OpenRouter profile does not receive them.

**Gate closeout:** Complete. Focused regression coverage passes for profile scope, sync/stream propagation, and authorization preservation. Remaining estimate after G2: 25%.

### G3 — Documentation and verification
- [x] Update the provider/adapter design and QA documentation.
- [x] Run formatter, focused tests, analyzer, and documentation lint.
- [x] Run `graphify update .` and review the final diff.
- [x] Complete the reference-grounding audit record.

**Gate closeout:** Complete. Documentation lint, analyzer, 40 adapter tests, Graphify update, grounding audit, and final diff checks pass. Remaining estimate: 0%.

## Acceptance Criteria

- [x] OpenRouter requests contain `HTTP-Referer: https://sanad.eaststarai.com`.
- [x] OpenRouter requests contain `X-OpenRouter-Title: Sanad Agent`.
- [x] Non-OpenRouter provider requests contain neither attribution header.
- [x] Existing authorization, payload, sync, and stream behavior remain unchanged.

## Definition of Done

- [x] The change remains provider-profile-owned and contains no new runtime state.
- [x] Focused regression coverage and `fvm dart analyze` pass.
- [x] Relevant documentation and QA matrix are current.
- [x] Graphify is updated.
- [x] No commit or push occurs without explicit user approval.
