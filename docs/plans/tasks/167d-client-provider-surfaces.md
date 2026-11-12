---
title: "Task 167d: Client Provider Surfaces — Capability Filter and Capability Step"
description: "Four capability filters and settings in the existing provider editor, with automatic curated support and no image-account probe."
status: "pending"
current_gate: "Ready for 167d-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 18
---

# Task 167d: Client Provider Surfaces

## 1. Goal

The existing provider editor becomes capability-aware without a second editor:
a capability filter on the list, a capability step that is fixed for curated
templates and selectable for `custom`, and a card that reports readiness per
capability. The Add action inside Dictation settings opens this same picker with
the transcription filter preselected.

## 2. Scope

- Capability filter (chat / transcription / search / image generation) on the
  existing provider list, reusing the existing search-box presentation rules:
  filtering only, registry order preserved, localized empty states.
- Entry points: Providers destination, and the dictation settings "Add provider"
  action which opens the same picker with the transcription filter applied.
- Capability step in the add form: curated templates show their declared set as
  fact; `custom` offers only the allowed combinations, never search or images.
- Existing curated accounts show newly shipped support automatically, without
  reconnecting or asking users to manually select capabilities Sanad knows.
- Per-capability readiness and test policy on the card and in Edit, with scoped
  defaults/guards. Images show provider support and local configuration, not an
  account-verified badge or a sample-generation/eligibility test requirement.
- The model step adapts: a capability without selectable models, including a
  server-managed image binding, skips model selection instead of failing on an
  empty list. Image options follow daemon binding policy, not the chat model.
- Localization for every new string in English and Arabic.

## 3. Invariants

- One editor: no second provider page, sheet, wizard, login, or credential field
  for transcription or images. Feature entry points reuse this filtered picker.
- The client never decides capability validity; it renders the daemon's declared
  sets and surfaces daemon refusals. Vision flags do not imply image generation.
- Filtering never re-requests the catalog, reorders it, or mutates state.
- A capability-aware client degrades to a chat-only surface against an older
  agent rather than showing an empty list.
- Credential entry remains one field per instance regardless of capability count.
- Image save/default/configuration-test actions send no generation/eligibility
  request, do not require chat-model discovery, and do not change chat selection.
- Real generation errors remain execution feedback, not removal of support.

## 4. Gates

### G1 — List and filter

- [ ] Capability filter changes only the visible subset; order and identity are
      preserved.
- [ ] Each card states the capabilities it serves and its default markers.
- [ ] Existing Codex/OpenAI image-binding fixtures show support automatically,
      without a new login, manual declaration, or account probe.
- [ ] The dictation entry point opens the same picker with transcription
      preselected and returns to dictation after save.

### G2 — Add and edit

- [ ] Curated capability set renders read-only with no edit affordance.
- [ ] Custom capability selection offers exactly the three allowed combinations
      and cannot produce search or image generation.
- [ ] The model step is skipped for no-model/server-managed capabilities and
      still required for chat; image options do not come from chat discovery.
- [ ] Editing an instance without touching capabilities performs no capability
      mutation and keeps credentials unless replacement is explicit.

### G3 — Readiness, default, guard

- [ ] Readiness/test policy is shown per capability with distinct results; images
      use configuration feedback with no claim of successful account testing.
- [ ] Image save/default/test works without chat discovery and emits zero
      eligibility/generation requests, including automatic form-save follow-ups.
- [ ] Make-default is capability-scoped and labelled with its capability.
- [ ] Delete/disable refusal is presented as an actionable message that leads to
      choosing another default.

### G4 — Compatibility and localization

- [ ] Against an agent without capability data, the UI renders chat-only and
      offers no transcription/image entry point that cannot work.
- [ ] Every new string exists in the source locale and the Arabic locale.
- [ ] Driver keys exist for filters, support, model policy, per-capability
      readiness, and defaults so UI verification is observable.

## 5. Definition of Done

- Widget tests cover: four filters, curated read-only/automatic support, custom
  allowed sets, no-model/server-managed policy, zero image setup probes,
  per-capability readiness, guard message, and chat-only degradation.
- `fvm flutter analyze` clean in `client/`; focused widget tests green.
- `docs/product/settings_hub.md` updated for the filter, entry points, and
  capability card; no other product doc duplicates it. Localization coverage is
  updated for every new string.

## 6. Success test scenario

1. Open Providers; switch across the four capabilities and confirm the visible
   subset changes while order is preserved.
2. Add a custom instance; assert only the three combinations are offered and
   search/image generation are absent.
3. Add an OpenAI fixture with validated declarations; assert transcription and
   images appear read-only, and the model step follows each binding's policy.
4. Try to delete the transcription default; assert the guard message and that
   choosing another default unblocks deletion.
5. Edit an existing Codex image-capable fixture with chat discovery unavailable;
   assert support/default configuration works with no reconnect or image probe,
   unchanged chat selection, and correct filtered-picker return after save/cancel.

## 7. Out of scope

Execution adapters; dictation source selection/cloud rows; search routing; and
conversation generated-image cards/download.
