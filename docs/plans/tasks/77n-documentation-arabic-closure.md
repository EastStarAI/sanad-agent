---
title: "77N — Documentation consistency and Arabic wording closure"
status: "completed"
current_gate: "Scoped docs/Arabic correction independently reviewed; eight localized-copy tests independently pass; accepted for committed preservation and delivery"
---

# Goal and authority

The user delegates final documentation consistency and Arabic wording acceptance before Plan77 PR delivery. Reconcile existing implementation and verified decisions, not a new provider audit or redesign. The user confirms the observed cross-client navigation and stored-value changes were caused by their own concurrent actions; these are not unresolved product defects. Exact restoration of a blank draft's selected model is explicitly cancelled as unimportant.

# Owning decisions

- `docs/plans/tasks/77k-native-thinking-default-selection.md` is the latest native-default UI decision; `docs/plans/tasks/77i5-unified-provider-model-capabilities.md` and `docs/plans/77-view-image-and-multimodal-tool-results.md` own broader scope.
- Known valid native default auto-admits as its real option when there is no valid saved explicit choice. Preserve explicit Off/other options. Unknown default is not guessed. The technical Agent null/omission contract remains valid for callers lacking a declared default.
- No synthetic Default menu row or provider-managed Default chip. The hint `Provider default` / `الافتراضي لدى المزوّد` appears only below the real default option in the expanded menu. Declared options are reversed for display only; IDs and wire values do not change.
- Always-visible states distinguish loading/failure/unknown/no-control. Review English/Arabic meaning against existing source keys, not an invented universal tier ladder. Existing locale support must have one consistent owning contract.

# Bounded scope and triage

1. Read root/closest contracts, `docs/llms.txt` and current implementation before editing. Report concrete stale statements first in the external report, then correct them narrowly.
2. Fix the current authoritative unknown-state section in `docs/technical/provider_protocol.md`, which still describes a Default chip / `route_thinking_mode_provider_managed` while precedence step 4 uses the actual unknown state.
3. Reconcile current Plan77/77I5/77K, relevant product/QA and owning contracts ONLY where contradictory. Clearly historical records may remain historical; do not rewrite old test receipts as new acceptance. Root contract's English-only UI statement conflicts with existing committed Arabic localization: reconcile narrowly to the already-established supported locale behavior.
4. Audit existing thinking-related English/Arabic ARB strings and their generated counterparts for technical and linguistic equivalence. Approve existing accurate Arabic copy with a concise key/value rationale. Correct only demonstrated errors; if ARB changes are required, regenerate through the owning FVM flow and run affected tests/analyzer. No new wording/locale surface or unrelated copy cleanup.
5. Record completed scoped implementation/interactive-report stages using existing evidence. Unreachable optional/config-dependent live scenarios remain NOT EXERCISED/nonblocking limits in the requested delivery closure, never fabricated PASS. No new runtime/UI/configuration work, sends, provider/account/Home/endpoint changes or diagnostic tools.
6. Public docs must never reference private repositories, private plans, local machine paths or external evidence directories. Keep operational evidence and sanitized detailed wording rationale in the external report, not laws. Update closest AGENTS only for a durable/stale rule.

# Principal review — bounded correction before acceptance

The first docs-only result is NOT yet accepted. The following concrete corrections supersede its literal-inventory exemption and docs-only validation limit; this remains the same scoped task:

1. Do not weaken the existing thinking-surface localization requirement to accommodate four English literals. Localize ONLY the existing loading label, retry label, retry tooltip and select-mode tooltip through `AppLocalizations` and paired English/Arabic ARB keys. No new interface surface or behavior. Suggested Arabic: `جارٍ التحميل...`, `إعادة المحاولة`, `تعذّر تحميل خيارات التفكير. انقر لإعادة المحاولة.`, `اختر نمط التفكير`. Preserve exact English copy and native vendor option labels/IDs. Remove the now-unnecessary inventory/count changes instead of adding unrelated task95 scope.
2. Clarify root law: no inline Arabic in HANDWRITTEN Dart/UI code; generated locale Dart naturally contains translated strings and is not forbidden. Supported Arabic UI is expressly allowed through localization.
3. Fix the new provider-protocol omission paragraph: null/blank omission belongs to the Agent wire boundary for callers without an effective explicit selection. The Client first auto-admits a known valid native default as a real selection when no valid saved explicit value exists; do not imply that a cleared Client selection always remains omission or that a native default is only annotated rather than applied.
4. FVM dependency resolution/code generation in THIS isolated build checkout is permitted, preferably `pub get --offline` using the existing package cache; it is not a new application environment. No runtime, real Home or UI lifecycle changes. Regenerate ignored locale outputs normally, run the focused selector/locale tests and Client analysis, and retain exact exits/durations/logs. Add focused Arabic coverage for the four corrected existing strings. No full/E2E rerun for this narrow copy repair.
5. Update your plan/report so the earlier first-pass literal exception, stale counts and validation exclusions do not remain current claims. Leave older source-version receipts explicitly historical and no private references in public docs.

## Principal review resolution

All five bounded corrections are implemented; the earlier first-pass claims are superseded rather than reused:

- [x] **(1) Localize instead of weakening.** The four existing English literals are now `AppLocalizations` entries with paired English/Arabic keys: `thinkingModeLoadingLabel` (`Loading...` / `جارٍ التحميل...`), `thinkingModeRetryLabel` (`Retry` / `إعادة المحاولة`), `thinkingModeFetchFailureTooltip` (`Failed to load thinking options. Click to retry.` / `تعذّر تحميل خيارات التفكير. انقر لإعادة المحاولة.`), `thinkingModeSelectTooltip` (`Select Thinking Mode` / `اختر نمط التفكير`). English copy, declared native option labels/IDs, states, keys and menu behavior are unchanged; only the existing strings' source changed. The thinking-surface localization requirement is restored to its full form, and the Task 95 inventory/count edits are reverted completely.
- [x] **(2) Root law clarified.** `AGENTS.md` §5 now forbids Arabic literals only in handwritten Dart/widget/UI source, states that generated `lib/l10n/app_localizations*.dart` naturally carries translated strings and is not a source restriction, and expressly allows the shipped Arabic UI through localization.
- [x] **(3) Omission paragraph corrected.** `docs/technical/provider_protocol.md` §4 now separates the Agent's wire-level omission boundary (null/blank/whitespace for callers without an effective explicit selection) from the Client's effective-selection resolution, which admits a known valid native default as a real selection (Plan 77 / Task 77K) rather than only annotating it.
- [x] **(4) In-isolation dependency resolution, codegen and focused verification.** `fvm flutter pub get --offline` reused the existing package cache, `fvm flutter gen-l10n` regenerated the ignored locale outputs, focused selector/locale/embedding tests and Client analysis ran with recorded exits and durations, and three new Arabic-locale tests cover the four corrected strings. No runtime, Home or live UI work ran.
- [x] **(5) Plan and report reconciled.** This record and the external report no longer claim a literal exception, a `81 → 82` inventory count change, or a generated-output validation exclusion; older source-version receipts stay explicitly historical and public docs carry no private references.

# Gates and execution record

## G1 — Triage and narrow reconciliation

- [x] Read the root and closest contracts, `docs/llms.txt`, the current Client source and the owning Plan77 decisions before editing; the stale statements were recorded first in the external report.
- [x] Corrected the authoritative unknown-state claim in `docs/technical/provider_protocol.md` §4 Client Thinking Control Lifecycle: it described a `Default` chip / `route_thinking_mode_provider_managed` and now describes the Client's honest unreported state (`Not reported`, `route_thinking_mode_unknown`, `thinkingModeUnknownLabel` / `thinkingModeUnknownTooltip`), its separation from `noControl` and `Unavailable`, and where the provider-default disclosure actually lives (menu-only `thinkingModeProviderDefaultHint`). The section now agrees with precedence step 4 and with the shipped Client.
- [x] Corrected the §4 omission paragraph under principal review: a null, empty or whitespace-only `thinking_mode` is the Agent wire-level omission boundary for callers that hold no effective explicit selection; the Client resolves an effective selection first and admits the route's known valid native default as a real selection through its own composer path (Plan 77 / Task 77K). The paragraph no longer implies that a cleared Client selection always stays omitted or that a native default is only annotated.
- [x] Reconciled the root `AGENTS.md` UI localization law with the already-shipped `en` + `ar` localization: handwritten Dart, widget and UI source carries no Arabic literal, generated `lib/l10n/app_localizations*.dart` naturally carries translated strings and is explicitly not a source restriction, `app_en.arb` remains the authored source locale, and the shipped Arabic UI is expressly supported through `AppLocalizations`.
- [x] Kept the Client thinking-surface localization requirement intact and satisfied it instead of weakening it: the loading label, the retry label, the retry tooltip and the select-mode tooltip now come from `AppLocalizations` (`thinkingModeLoadingLabel`, `thinkingModeRetryLabel`, `thinkingModeFetchFailureTooltip`, `thinkingModeSelectTooltip`) in both locales. Existing English copy, every declared native option label/ID, the rendered states and the menu behavior are unchanged; no new interface surface was added.
- [x] Left the Task 95 remaining-literal inventory and its coverage count untouched: the four literals are localized rather than inventoried, so no unrelated inventory/count edit remains in this change.
- [x] Left clearly historical receipts historical: the superseded synthetic-Default wave inside 77I5 already carries an explicit 77K supersede note, the R16/earlier reviewer receipts keep their source-version framing, and no old test receipt was rewritten as new acceptance.

## G2 — Arabic wording acceptance

- [x] Audited every thinking-surface ARB entry in both locales (15 `thinkingMode*` keys after this repair) with the per-key rationale recorded in the external report. The pre-existing copy is accepted as technically and linguistically equivalent, and the four newly localized existing strings carry the reviewed Arabic copy — `جارٍ التحميل...`, `إعادة المحاولة`, `تعذّر تحميل خيارات التفكير. انقر لإعادة المحاولة.`, `اختر نمط التفكير` — against unchanged English source copy (`Loading...`, `Retry`, `Failed to load thinking options. Click to retry.`, `Select Thinking Mode`).
- [x] Verified structural equivalence: 295 keys in each locale, no missing or extra key, zero placeholder mismatches, `{tokens}` / `{budget}` preserved, and the generated untranslated-message report empty.
- [x] Regenerated the git-ignored locale outputs through the owning FVM flow and confirmed the four getters in the generated Arabic and English localization Dart carry exactly the paired copy above.

## G3 — Verification

- [x] `fvm dart run scripts/lint_wiki.dart` — exit 0, all documentation valid, indexed and healthy on the final changed scope.
- [x] `fvm flutter analyze` in `client/` — `No issues found!`, exit 0 (12 s including its own dependency check).
- [x] Focused tests: `fvm flutter test test/widget/route_thinking_mode_selector_test.dart test/core/locale_cubit_test.dart test/widget/conversation_input_composer_toggle_test.dart` — 79 tests passed, exit 0 (18 s), including three new Arabic-locale tests covering the loading label, the retry label with its explanation, and the select-mode tooltip.
- [x] `fvm dart format --output=none --set-exit-if-changed` on the two changed Dart files — 0 files changed.
- [ ] Full product suites, E2E/integration suites and live/driver UI: NOT EXERCISED. This narrow copy repair changes no runtime, Home, provider or UI lifecycle behavior, and the principal's correction explicitly excludes a full or E2E rerun.

## G4 — Handoff limits

- [x] No commit, push, PR, merge or deployment; no runtime, Home, provider, account, endpoint or configuration action; no second worktree.
- [x] Public docs reference no private repository, private plan, host path or external evidence directory; detailed wording rationale and command logs stay in the external report.
- [x] Superseded first-pass claims are gone from this record: the literal-inventory exception, the `81 → 82` count edit and the generated-output validation exclusion are not current facts.
- [x] Principal reviewed all changed/new paths, accepted the scoped Arabic wording under the user's delegated acceptance, and independently passed all eight localized-copy widget tests (exit 0, approximately 6 seconds). The result is accepted for committed preservation; final delivery owns completed-plan relocation and inbound-link reconciliation. No live RTL acceptance or unexecuted product test is inferred.

# Verification and handoff

- Run the repository wiki/document integrity validation on the final changed scope. For docs-only changes do not repeat product full suites; if locale/code changes occur, run only affected focus and analyzer using FVM.
- Preserve exact commands, exit codes, durations and bounded logs outside the repository.
- Return changed/new paths, triage, exact Arabic key/value acceptance, tests, limits and any uncertainty in the external report. No commit/push/PR/merge/deploy by this worker; principal reviews and preserves the result.
- Do not relocate the entire parent plan before coordinated delivery; final delivery owns completed-plan relocation and inbound-link reconciliation.
