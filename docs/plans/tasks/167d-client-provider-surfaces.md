---
title: "Task 167d: Client Provider Surfaces — Capability Filter and Capability Step"
description: "فلتر القدرات على صفحة المزودين الحالية، وخطوة قدرات تحترم القوالب المثبتة والمخصص، وبطاقة تعرض جاهزية كل قدرة."
status: "pending"
current_gate: "Ready for 167d-G1"
priority: "high"
depends_on: "167b, 167c"
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

- Capability filter (chat / transcription / search) on the existing provider
  list, reusing the existing search-box presentation rules: filtering only,
  registry order preserved, resolvable to a localized empty state.
- Entry points: Providers destination, and the dictation settings "Add provider"
  action which opens the same picker with the transcription filter applied.
- Capability step in the add form: curated templates show their declared set as
  fact; `custom` offers only the allowed combinations and never search.
- Per-capability readiness and test on the card and in Edit, with capability-
  scoped default action and guard messages.
- The model step adapts: a capability without models skips model selection
  instead of showing an empty model list as a failure.
- Localization for every new string in English and Arabic.

## 3. Invariants

- One editor: no second provider page, sheet, or wizard for transcription.
- The client never decides capability validity; it renders the daemon's declared
  sets and surfaces daemon refusals.
- Filtering never re-requests the catalog, reorders it, or mutates state.
- A capability-aware client degrades to a chat-only surface against an older
  agent rather than showing an empty list.
- Credential entry remains one field per instance regardless of capability count.

## 4. Gates

### G1 — List and filter

- [ ] Capability filter changes only the visible subset; order and identity are
      preserved.
- [ ] Each card states the capabilities it serves and its default markers.
- [ ] The dictation entry point opens the same picker with transcription
      preselected and returns to dictation after save.

### G2 — Add and edit

- [ ] Curated capability set renders read-only with no edit affordance.
- [ ] Custom capability selection offers exactly the three allowed combinations
      and cannot produce search.
- [ ] The model step is skipped for a no-model capability and still required for
      chat.
- [ ] Editing an instance without touching capabilities performs no capability
      mutation.

### G3 — Readiness, default, guard

- [ ] Readiness and test are shown per capability with distinct results.
- [ ] Make-default is capability-scoped and labelled with its capability.
- [ ] Delete/disable refusal is presented as an actionable message that leads to
      choosing another default.

### G4 — Compatibility and localization

- [ ] Against an agent without capability data, the UI renders chat-only and
      offers no transcription entry point that cannot work.
- [ ] Every new string exists in the source locale and the Arabic locale.
- [ ] Driver keys exist for the new filter, capability rows, and per-capability
      readiness so UI verification is observable.

## 5. Definition of Done

- Widget tests cover: filter subsets, curated read-only set, custom allowed sets,
  skipped model step, per-capability readiness, guard message, chat-only
  degradation.
- `fvm flutter analyze` clean in `client/`; focused widget tests green.
- `docs/product/settings_hub.md` updated for the filter, entry points, and
  capability card; no other product doc duplicates it.

## 6. Success test scenario

1. Open Providers; switch the filter across the three capabilities and confirm
   the visible subset changes while order is preserved.
2. Add a custom instance; assert only the three combinations are offered and the
   search capability is absent.
3. Add an OpenAI instance; assert transcription appears as a declared, read-only
   capability, and the model step behaves per capability.
4. Try to delete the transcription default; assert the guard message and that
   choosing another default unblocks deletion.

## 7. Out of scope

Cloud transcription execution (167e/167f); dictation source selection and cloud
rows (167g); search routing (167h).
