# fix-search-panel-localization

## Goal
The conversation search entry button and the search panel rendered hardcoded English copy that ignored the app locale. Make every user-visible string of the conversation search surface (sidebar button, field hint, tooltips, empty/idle/error states, match-kind labels, retry/load-more) resolve through `AppLocalizations` so it follows the selected interface language (`en` / `ar`).

## Locked decisions and scope
- In scope: `client/lib/features/conversations/presentation/widgets/sidebar/conversation_search_panel.dart`, `session_search_cubit.dart`, `session_search_state.dart`, `client/lib/l10n/app_en.arb`, `app_ar.arb`, and the focused widget/cubit tests.
- Reuse existing keys where present: `searchConversations`, `retry`, `loadMore`.
- The cubit emitted a hardcoded English `errorMessage`. The failure surface is generic (the real error is swallowed), so the state drops `errorMessage` and the widget renders a localized failure string instead of carrying presentation copy in the bloc.
- Out of scope: other hardcoded-English surfaces (composer, tool tiles, settings), RTL layout changes (the panel already uses start/end semantics), agent-side search strings.

## Gates

### G0 — Discovery
- [x] Locate the search button/panel widget and confirm hardcoded strings.
- [x] Confirm l10n ownership contract (ARB source of truth, generated files git-ignored).
- [x] Identify affected tests and e2e coverage (none reference the changed strings).

### G1 — Implementation
- [x] Add new ARB keys (en source + ar translations) for search panel copy.
- [x] Route all search panel strings through `AppLocalizations.of(context)`.
- [x] Remove hardcoded English `errorMessage` from `SessionSearchCubit`/`SessionSearchState`; widget shows localized failure copy.
- [x] Update widget tests to mount localized surfaces; add an Arabic-locale regression test.
- [x] Run `fvm flutter gen-l10n` after ARB edits.

## Acceptance Criteria
- [x] Given the app locale is Arabic, when the sidebar renders, then the search button shows `ابحث في المحادثات` instead of `Search conversations`.
- [x] Given the app locale is Arabic, when the search panel opens, then the field hint, clear/close tooltips, idle hint, empty state, failure message, and match-kind labels are all Arabic.
- [x] Given the app locale is English, when the search panel renders, then all strings keep the current English copy.
- [x] `fvm flutter analyze` passes with no errors.
- [x] Focused tests (`conversation_search_panel_test.dart`, `session_search_cubit_test.dart`) pass.

## Definition of Done
- [x] Analyzer and focused tests pass.
- [x] Documentation updated in the same session (this plan; `client/AGENTS.md` localization law already covers the rule, no contract change needed).
- [x] Plan file relocated to `docs/plans/tasks/done/` in the delivery commit.
- [x] No commit/push until the user reviews the diff — reviewed and approved by the user on the primary checkout before delivery.
