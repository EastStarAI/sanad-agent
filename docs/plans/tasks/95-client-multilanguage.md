---
id: 95
title: Client Multilingual Interface (English / Arabic)
status: in-progress
gate: G4
created: 2026-09-18
branch: feature/95-client-multilanguage
---

# Task 95 — Client Multilingual Interface

## Goal
Transform the Sanad Client from a single-language (English) UI into a multilingual interface, starting with English and Arabic, so the whole interface renders in the user's chosen language at runtime.

## Locked Decisions & Scope
- Start with exactly two locales: `en` (default) and `ar` (with RTL support).
- Localization happens at the **client UI layer only**; agent daemon behavior is out of scope.
- UI text remains English-only in source code; Arabic lives in translation files (per repo UI localization constraint).
- Language preference persists (same home-derived preference isolation boundary) and is honored on restart.
- Existing localization setup must be audited first; if Flutter `gen_l10n` is already scaffolded, extend it rather than replacing.

## Gates

### G0 — Discovery & Audit ✅
- [x] Audit current localization state: no existing l10n scaffold (no `l10n.yaml`, no `AppLocalizations`).
- [x] Inventory the high-traffic UI surfaces: chat, composer, settings pages, sidebar, MCP screens, provider setup.
- [x] Translation format decision: `client/l10n.yaml` → `client/lib/l10n/app_{en,ar}.arb` with `gen_l10n`; generated output in `client/lib/l10n/` is git-ignored.
- [x] RTL: `ar` maps to RTL via `MaterialApp.locale` + `Directionality` (standard).

### G1 — Localization Scaffolding ✅
- [x] `l10n.yaml` + `flutter: generate: true` + `flutter_localizations` dependency; delegates wired into `MaterialApp.router`.
- [x] `LocaleCubit` with `SharedPreferences` persistence (`app_locale`), silent fallback to `en` for unknown stored values.
- [x] Language switcher (segmented en/ar) in Settings → General with `language_selector` key.
- [x] Tests: `client/test/core/locale_cubit_test.dart` (fallback + supported locales + en/ar key parity via fixtures).

### G2 — English Baseline Extraction ✅ (partial, see remaining report)
- [x] `app_en.arb` seeded; localized: dashboard/AppShell, General settings page, settings navigation tree, sidebar sections (workspaces/conversations/load-more), new-chat help messages, MCP both screens, relative time (per-second formatting), workspace chat view title.
- [ ] Remaining ~81 presentation files tracked in `docs/qa_maintenance/task95-remaining-ui-strings.md` for a follow-up pass.

### G3 — Arabic Localization & RTL ✅
- [x] `app_ar.arb` covering every key of `app_en.arb` (parity test green).
- [x] RTL: workspace layout mirrors via `Directionality.of(context)` — Row order automatic, hover edge / animated sidebar / button row use `left/right` selection; verified live (sidebar right, conversation full-width).
- [x] Comprehensive RTL / LTR Directionality Audit & Fixes:
  - [x] **ToastUtils (`toast_utils.dart`)**: Dynamic toast alignment (`topLeft` for RTL vs `topRight` for LTR on desktop) and adaptive direction (`direction: isRtl ? TextDirection.rtl : TextDirection.ltr`).
  - [x] **ConversationAppBar (`conversation_app_bar.dart`)**: Removed hardcoded `textDirection: TextDirection.ltr` from mobile layout `Row`, allowing header actions and title to inherit ambient directionality while retaining content-level bidi for titles.
  - [x] **ConversationWorkspaceLayout (`conversation_workspace_layout.dart`)**: Fixed RTL sidebar drag-resize inversion (inverted `details.delta.dx` in RTL so dragging left widens the right-docked sidebar) and adjusted `resizeHandle` translate offset.
  - [x] **EventTile (`event_tile.dart`)**: Removed forced `TextDirection.ltr` wrapper from `_buildFinalAnswerFooter` so response metadata and actions follow ambient directionality; updated `_buildThinkingPreview` to use dynamic `TextUtils.getTextDirection(preview)`.
  - [x] **ConversationActivityTile (`conversation_activity_tile.dart`)**: Removed forced `TextDirection.ltr` from status and tool labels so localized activity texts flow with ambient directionality, while preserving LTR for tabular elapsed seconds (`elapsedText`).
  - [x] **Intentional LTR Preservations**: Code blocks (`_CodeBlockBuilder`), inline code (`_InlineCodeBuilder`), terminal logs (`InstallationTerminalView`), and macOS traffic lights leading insets remain strictly LTR for technical and OS compatibility.
- [x] Tracked generated `app_localizations*.dart` files removed from git and ignored.
- [x] Live screenshots verified: `/tmp/sanad95-arabic-persist.png`, `/tmp/sanad95-rtl-fixed.png`, `/tmp/sanad95-ar-final.png`.

### G4 — QA & Docs
- [x] Unit tests pass (`locale_cubit_test`: locale fallback, supported locales, en/ar parity; `conversation_app_bar_test`: mobile RTL inheritance).
- [x] `fvm flutter analyze` clean.
- [x] Live verification through `sanad-dev run --driver` (home `~/.sanad-test`): language switch en↔ar, restart persistence (arabic survives restart), settings renders Arabic, sidebar positions correct.
- [x] Remaining-strings report: `docs/qa_maintenance/task95-remaining-ui-strings.md`.
- [ ] Docs: update client contract page for locale switch + RTL notes; graphify update.
- [ ] Full fast suite re-run right before delivery.
- [ ] Update `client/AGENTS.md` only if the localization law changes; add a `docs/technical/` page documenting the locale/RTL behavior per DoD.

## Acceptance Criteria
- [ ] Given a fresh launch with stored locale `ar`, when the client starts, then every UI surface defined as in-scope renders in Arabic and the layout is mirrored RTL.
- [ ] Given locale `en`, the UI renders identical to the current single-language behavior (regression: no lost/placeholder strings).
- [ ] Changing language from settings persists across restart and works even if the locale is unsupported elsewhere (fallback to `en`).
- [ ] Generated localization key parity test passes: `app_ar` has exactly the same keys as `app_en` and no stale keys.
- [ ] No repo law violations: no Arabic literals in widget code, no hardcoded strings in inventoried UI surfaces.
- [ ] RTL layouts correctly handle drag gestures, toast alignments, and mobile app bar actions without inverted interaction or clipped window chrome.

## Definition of Done
- [ ] `fvm flutter analyze` passes.
- [ ] Focused Flutter tests pass (`fvm flutter test` per changed areas; full fast suite only for broad shared surfaces).
- [ ] Docs updated (client contract + 5-Pillars page when applicable).
- [ ] `graphify update .` run after code changes.
- [ ] No commit/push without explicit user permission (user law).

## Current Status
- Gate: G4
- Remaining: Final documentation verification and fast test suite pass.
