---
title: "Task 167g: Dictation Settings — Local/Cloud Sources"
description: "فلتر محلي/سحابي في إعدادات التفريغ، صفوف سحابية بلا تنزيل، اختيار المصدر مع بقاء المحلي افتراضيًا، وإضافة مزود من نفس الصفحة."
status: "pending"
current_gate: "Ready for 167g-G1"
priority: "high"
depends_on: "167e, 167f, 167d"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 16
---

# Task 167g: Dictation Settings — Local/Cloud Sources

## 1. Goal

The dictation surface presents one catalog with two sources. Local rows keep
their download and install behavior; cloud rows are selectable, never
downloadable, and carry their provider identity plus mode. Local remains the
default, and adding a provider happens through the existing picker.

## 2. Scope

- Local/cloud filter (or grouped sections) in the dictation settings surface,
  preserving the current row facts and install behavior for local rows.
- Cloud rows show provider display name, model, mode (streaming or batch), and
  readiness; their primary action is select, and a secondary action opens the
  provider in the existing editor.
- "Add provider" opens the existing provider picker with the transcription
  filter applied, returns to dictation on save, and refreshes the source list.
- Selection marks exactly one active source; selecting cloud clears no local
  install and deleting a local model does not silently change the active source
  without feedback.
- Guarded states: a cloud source whose provider lost its credential, was disabled,
  or was deleted while selected shows a typed reason and a route to fix it.
- Full localization in English and Arabic; stable driver keys for rows, filter,
  mode badge, and readiness.

## 3. Invariants

- The client never reads agent configuration; all state comes from the daemon
  projection.
- No download, progress, size, or speed control appears on a cloud row.
- The local source stays the default; a cloud source is only active when the user
  selected it.
- The dictation surface never becomes a second provider editor.
- An unknown readiness reason falls back to a neutral sentence, never raw text.

## 4. Gates

### G1 — Filter and rows

- [ ] Filter switches between all/local/cloud without re-requesting or reordering
      the catalog.
- [ ] Local rows keep name, badge, description, size, speed, and streaming
      indicator exactly as today.
- [ ] Cloud rows show provider, model, mode, readiness, and no download control.
- [ ] Empty states distinguish "no cloud provider configured" from "no local
      model installed".

### G2 — Selection and guards

- [ ] Selecting a source persists through the daemon and survives restart and
      device switch.
- [ ] A selected source that becomes unusable reports a typed reason with a fix
      action.
- [ ] Selecting a cloud source never mutates local installs.
- [ ] The default remains local until an explicit cloud selection exists.

### G3 — Provider entry point

- [ ] The Add action opens the existing picker with the transcription filter and
      returns to dictation.
- [ ] A saved provider appears as a cloud source without restarting the app.
- [ ] Cancelling the picker returns to dictation unchanged.

### G4 — Verification surface

- [ ] Driver projection exposes rows, filter state, active source, mode, and
      readiness for automated UI verification.
- [ ] Every new string exists in both locales.

## 5. Definition of Done

- Widget tests cover: filter subsets, cloud row without download, selection
  persistence, unusable-source reason, entry-point round trip, empty states.
- `fvm flutter analyze` clean in `client/`; focused widget tests green.
- `docs/product/settings_hub.md` and `docs/technical/local_dictation.md` updated;
  the remaining-string report has no new gaps.

## 6. Success test scenario

1. Open dictation settings with no cloud provider; assert the cloud empty state
   and the local rows unchanged.
2. Use Add provider; save an OpenAI instance; return; assert a cloud row appears
   with its mode and readiness, and no download control.
3. Select the cloud row; restart the client; assert the selection survived.
4. Delete the selected provider's credential; reopen dictation; assert the typed
   reason and that one action leads to the provider editor.

## 7. Out of scope

Provider editing itself (167d); engine behavior (167e/167f); search (167h).
