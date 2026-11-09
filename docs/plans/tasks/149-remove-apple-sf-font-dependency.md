---
title: "Remove the Apple SF Font Dependency"
description: "Task 149: drop flutter_sficon, draw the composer send arrow with CupertinoIcons, and guard the Client against bundling any Apple-provided font (ITMS-91182)."
---

# Task 149 — Remove the Apple SF Font Dependency

## Goal

The Client bundles no Apple-provided font, so the iOS build stops tripping
App Store validation `ITMS-91182` (blocked from 2027-10-01) while the composer
send control keeps its size, color, and behavior.

## Locked decisions and scope

- `flutter_sficon` exists for exactly one icon. Swift proof: the package's only
  asset is `packages/flutter_sficon/lib/fonts/sficons.ttf`, whose embedded
  `SFProText-Regular` is what Apple rejects.
- The send arrow becomes `CupertinoIcons.arrow_up` from `cupertino_icons`, a
  Flutter-authored icon font already in the dependency graph. The glyph keeps
  the original `16` size and `colorScheme.onPrimary` color, and the widget gains
  no new semantics.
- Dependency removal is complete: `pubspec.yaml`, `pubspec.lock`, and every
  source import, iOS/macOS asset list, documentation, and license/NOTICE
  reference.
- `client/test/guards/no_apple_font_bundle_guard_test.dart` fails closed on
  three surfaces: a declared dependency, a resolved `pubspec.lock` entry (which
  also catches a transitive pull), and an Apple font in `assets/` names or in a
  refreshed `build/**` `AssetManifest`/`FontManifest`. A self-test proves the
  guard recognizes a smuggled font and ignores Flutter-authored ones.
- Out of scope: the dictation work owned by pull request 337, any other package
  upgrade, and any visual redesign of the composer.

## Gates

### G0 — Discovery

- [x] Confirm `flutter_sficon` has one call site (`MessageBarButton`) and one
      unused import (`FloatingGlassView`).
- [x] Confirm the built iOS asset list carries
      `packages/flutter_sficon/lib/fonts/sficons.ttf`, and that no other tracked
      file references the package.
- [x] Confirm `cupertino_icons` is already a direct dependency.

### G1 — Icon and dependency removal

- [x] Replace `sf.SFIcon(sf.SFIcons.sf_arrow_up)` with
      `Icon(CupertinoIcons.arrow_up)` keeping `size: 16` and the original color.
- [x] Remove the unused `flutter_sficon` import from `FloatingGlassView`.
- [x] Remove the dependency from `client/pubspec.yaml` and regenerate
      `client/pubspec.lock`.

### G2 — Guard

- [x] Add the dependency, lockfile, asset, and build-manifest guard.
- [x] Add a focused widget test pinning the icon identity, size, color, and the
      enabled/disabled send behavior.

### G3 — Documentation

- [x] Record the invariant — no Apple-provided font may be bundled
      (`ITMS-91182`) — in `docs/technical/design_system.md` and the typography
      section of `client/AGENTS.md`.

### G4 — Verification and delivery

- [x] `fvm flutter analyze`: `No issues found!`.
- [x] `fvm flutter test test/widget/message_bar_test.dart
      test/guards/no_apple_font_bundle_guard_test.dart`: 8 tests pass, and
      `test/guards/` passes as a suite.
- [x] Negative proof: re-declaring `flutter_sficon` in `pubspec.yaml` fails the
      guard on both the dependency and the generated build-manifest surface.
- [x] Pull request opened against `main`; no merge.

## Acceptance Criteria

- [x] `git grep flutter_sficon` finds no reference in tracked source, assets,
      docs, or license lists after the change resolves.
- [x] The composer send affordance still renders a `16`-pixel arrow in
      `colorScheme.onPrimary`, and a disabled composer still drops the tap.
- [x] The guard fails when `flutter_sficon` returns to `pubspec.yaml` or
      `pubspec.lock`, when an `assets/` path names an Apple font, or when a build
      manifest lists one, and passes for `Cairo-*.ttf` and
      `CupertinoIcons.ttf`.
- [x] `fvm flutter analyze` is clean and the two focused test files pass.

## Definition of Done

- [x] Evidence recorded with bounded command output.
- [x] `graphify update .` run after the code change.
- [x] Pull request opened with `type/*` and `comp/*` labels; no merge, no branch
      deletion.

## Delivered evidence (pull request 367)

- All required checks pass; `Verify protected review labels` passes with no
  protected label requested, so the merge remains a maintainer decision.
- `fvm flutter analyze`: clean. Focused widget and guard tests: 8 pass.
  `test/guards/`: passes.

## Discovery correction

The brief described the import in `client/lib/shared/widgets/floating_glass.dart`
as unused. It was not: `FloatingGlassButton` rendered `sf.SFIcon` twice. The
dependency removal therefore converts that widget to a standard `Icon` with the
same `20` pixel size and colour, and renames its `sfIcon` field to `icon` so no
stale package name survives. The widget has no call sites in `lib/` or `test/`,
so the rename changes no behaviour.
