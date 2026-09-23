---
id: 101
title: Client Appearance Customization (Background, Theme, Font, and Scaling)
status: completed
gate: G5
created: 2026-09-23
completed: 2026-09-23
branch: feature/95-client-multilanguage
---

# Task 101 — Client Appearance Customization

## Goal
Empower users to personalize the Sanad desktop client appearance through settings by providing four color themes (Light, Dark, Midnight, Sepia), font family selection (featuring Cairo for Arabic, alongside Inter, Roboto, and System Default), font size scaling (Small, Normal, Large, Extra Large), and six background options (Default, two solid colors, and three nature wallpapers) equipped with an adaptive semi-transparent overlay to ensure contrast and legibility.

## Locked Decisions & Scope
- **Scope Boundary:** Client presentation layer only (`client/`). Local agent daemon contracts and behavior are unchanged.
- **Theme Modes & Palettes:**
  - 4 theme styles: `light`, `dark`, `midnight` (deep OLED dark), and `sepia` (warm paper/reading).
  - Appearance state managed via `AppearanceCubit` and persisted via `SharedPreferences`.
- **Primary / Accent Color Customization:**
  - 6 curated accent colors: `teal` (default), `blue`, `green`, `purple`, `orange`, `rose`.
  - Injected dynamically into `ThemeData.colorScheme.primary`, `secondaryContainer`, and `segmentedButtonThemeData` so all selectors and active controls match the chosen accent color.
- **Font Customization:**
  - Font families: `Cairo` (ideal for Arabic and multilingual typography), `Inter`, `Roboto`, and `Default` (System).
  - Font size scale factor: `small` (0.85x), `normal` (1.0x), `large` (1.15x), `extraLarge` (1.30x), applied dynamically via `MediaQuery.textScaler`.
- **Background Customization:**
  - 6 options:
    1. `default`: Standard theme scaffold background.
    2. `solidSlate`: Elegant Slate / Neutral tint.
    3. `solidMidnightNavy`: Deep navy blue tint.
    4. `natureForest`: Serene lush forest wallpaper.
    5. `natureMountain`: Majestic mountain sunset horizon wallpaper.
    6. `natureLake`: Tranquil alpine lake reflection wallpaper.
  - **Adaptive Protective Barrier (Overlay Scrim):**
    - High-quality wallpaper rendering includes a theme-adaptive semi-transparent scrim (`scrimColor` with calculated opacity: light/white tint in light/sepia themes, dark/black tint in dark/midnight themes) preventing chat bubbles, code blocks, and UI controls from getting lost in photo details.
- **Settings UI & Spacing:**
  - Integrated into `Settings > General` (Appearance section) with visual cards, previews, and responsive layouts.
  - Symmetrical spacing of 30px on both sides of the settings content frame.
  - Translucent frosted glass effect on sidebar navigation and settings cards for custom backgrounds.
  - UI labels and strings in English, with corresponding localized keys in `app_en.arb` and `app_ar.arb` conforming to the branch's localization contract.

## Gates

### G0 — Discovery & Design Audit
- [x] Audit existing `ThemeCubit`, `AppThemes`, `AppColorScheme`, and settings UI in `95-client-multilanguage`.
- [x] Prepare asset directory structure for nature wallpapers in `client/assets/wallpapers/`.
- [x] Define data models/cubit for `AppearanceSettings` and `AppearanceCubit`.

### G1 — Data Layer & Persistence
- [x] Implement `AppearanceCubit` to manage and persist:
  - Theme mode / palette: `light`, `dark`, `midnight`, `sepia`.
  - Font family: `cairo`, `inter`, `roboto`, `system`.
  - Font size scale: `small`, `normal`, `large`, `extraLarge`.
  - Wallpaper background type & custom color/asset.
- [x] Write unit tests for cubit state transitions and `SharedPreferences` persistence (`test/core/appearance_cubit_test.dart`).

### G2 — Themes & Typography Engine
- [x] Implement `midnight` and `sepia` themes in `AppThemes` / `AppColorScheme`.
- [x] Configure `GoogleFonts.cairoTextTheme()`, `GoogleFonts.interTextTheme()`, `GoogleFonts.robotoTextTheme()` dynamically.
- [x] Wire text scaler and theme into `MaterialApp` builder in `app_shell.dart`.

### G3 — Background Wallpaper & Adaptive Scrim Layer
- [x] Bundle nature wallpapers (`nature_forest.jpg`, `nature_mountain.jpg`, `nature_lake.jpg`) and register in `pubspec.yaml`.
- [x] Create `AppBackgroundWrapper` providing wallpaper rendering, solid color fallback, theme-adaptive semi-transparent scrim layer, and `_AppBackgroundScope` to prevent redundant nested rendering.
- [x] Integrate background wrapper into `AppShell` and update `HomeScreen` / `SettingsScreen` scaffolds to be transparent with frosted glass surfaces.

### G4 — Settings Appearance UI & Localization
- [x] Build visual selection widgets in `client/lib/features/settings/presentation/widgets/settings_pages.dart`:
  - Theme selector (4 options with visual badges).
  - Font family picker (including Cairo).
  - Font size scale selector with live preview box.
  - Background wallpaper grid (6 visual cards with active indicator in a 3-column responsive layout).
- [x] Add translation strings to `app_en.arb` and `app_ar.arb`.
- [x] Format symmetrical margins (30px) across the settings content layout.

### G5 — Verification & Live Testing
- [x] Run `fvm flutter analyze` (0 issues found).
- [x] Targeted unit and widget tests pass (22/22 tests).
- [x] Launch daemon and client with `sanad-dev run --driver --home ~/.sanad-test --no-cloud`.
- [x] Visual verification via FlutterDriver screenshots (`screenshot_1790157410978.png`).

## Acceptance Criteria
- [x] Changing theme to `midnight` or `sepia` updates the entire UI palette immediately and persists across restarts.
- [x] Changing font family to `Cairo` applies Cairo typography cleanly across the client (especially in Arabic & English).
- [x] Adjusting font size scales text proportionally and without UI overflows.
- [x] Selecting a nature wallpaper displays the image behind the conversation workspace with an adaptive semi-transparent scrim that preserves readability.
- [x] Selecting a solid color or default restores the clean background without photo artifacts.
- [x] Symmetrical and balanced spacing in Settings Screen matching design review.
- [x] No regression on existing RTL / localization behavior in `95-client-multilanguage`.

## Definition of Done
- [x] Static analysis passes (`fvm flutter analyze`).
- [x] Targeted tests pass (`fvm flutter test`).
- [x] Live UI verification via driver screenshot using `home = ~/.sanad-test`.
- [x] All code conforms to DRY and repository contracts.

## Current Status
- Gate: G5 (Completed)
- All automated tests, static analysis, and visual layout verifications passed.
