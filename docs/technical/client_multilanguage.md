---
title: Client Multilingual Interface (English / Arabic)
area: technical
status: current
task: 95
---

# Client Multilingual Interface

## Overview
The Sanad Client renders its interface in the user's chosen language. Launch locales: `en` (default, LTR) and `ar` (RTL). The localization stays in the Flutter presentation layer only; agent daemon protocol strings and logs are untouched.

## Architecture
- **CodeGen:** `client/l10n.yaml` points `gen_l10n` at `client/lib/l10n/*.arb`. `app_localizations*.dart` under `lib/l10n/` is generated build output and git-ignored.
- **English source of truth:** every key is authored in `app_en.arb` first. `app_ar.arb` mirrors it 1:1. A test locks parity by inspecting the `.arb` files directly (see `client/test/core/locale_cubit_test.dart`).
- **Locale state:** `LocaleCubit` (`client/lib/core/presentation/bloc/locale/locale_cubit.dart`) owns the runtime locale.
  - Persistence key: SharedPreferences `app_locale` (inside the home-derived preference isolation boundary).
  - Unknown stored codes silently reset to `en` — one applicative crash may not come back from locale parsing (`settings_pages.dart` runs the same silent-fallback rule as the rest of the app).
  - `supportedLocales = [en, ar]`; `MaterialApp.router` receives `localizationsDelegates` + the cubit's locale and rebuilds on change (hot switch, no restart).
- **Language switch UI:** Settings → General → "Language" segmented button (`key: language_selector`). Arabic has a native label (العربية) so the option is readable in both directions; RTL flip comes free from `Directionality`.
- **Time strings:** `formatCompactRelativeTime` accepts `localeOverride` when a `BuildContext` is available (`Localizations.maybeLocaleOf(context)`); contextless callers resolve the app locale via the shared binding.

## RTL Behavior
- `Directionality` flips automatically from the locale; the workspace sidebar orders through `Row` (automatic mirror) plus explicit `left/right` selection only for `Positioned` overlays (hover drawer, button row).
- **Sidebar Resizing:** Drag-delta (`details.delta.dx`) is inverted in RTL so dragging left widens the right-docked sidebar, and the resize handle translate offset flips horizontally.
- **Toasts:** `ToastUtils` reads ambient `Directionality.of(context)` and flips alignment to `topLeft` on desktop with `TextDirection.rtl`.
- **Mobile Header:** `ConversationAppBar` mobile layout inherits ambient directionality, allowing header actions to place at the leading side naturally.
- **Message Footers & Activity:** Footers and activity labels flow with ambient directionality; thinking preview direction is resolved dynamically via `TextUtils.getTextDirection`.
- **Intentional LTR Preservations:** Code blocks (`_CodeBlockBuilder`), inline code (`_InlineCodeBuilder`), terminal logs (`InstallationTerminalView`), tabular elapsed seconds, and macOS window control insets remain strictly LTR for developer clarity and platform convention.
- Session timeline, composer, and dialogs render via Material's built-in RTL resolution.
- Details of the RTL regression found during Task 95 live in the task plan (`docs/plans/tasks/95-client-multilanguage.md`).

## Adding a New Locale
1. Copy `app_en.arb` to `app_<code>.arb`, translate every key (no extras/omissions — the parity test fails otherwise).
2. Add the locale to `kSupportedLocales` in `locale_cubit.dart`.
3. `fvm flutter gen-l10n && fvm flutter analyze && fvm flutter test test/core/locale_cubit_test.dart`.
4. If the locale is RTL, no layout changes should be required — flag any surface that hardcodes `left:` in a mirrored context.

## Remaining Coverage
~81 presentation files still contain unlocalized English literals (secondary screens: provider_setup, devices, parts of settings). The living inventory is `docs/qa_maintenance/task95-remaining-ui-strings.md`; it is the canonical follow-up checklist for incremental localization passes.
