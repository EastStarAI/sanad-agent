---
title: "Brand Asset Generation and Platform Handoff"
description: "Canonical Sanad identity sources, generated platform assets, review-ready community deliverables, and live-surface ownership."
---

# Brand Asset Generation and Platform Handoff

## Approved Identity

SANAD-10 accepted the owner-supplied Sanad artwork and closed the local design-intake gate. The approved decisions are:

- primary brand color: `#60A5FA`;
- content on the primary color uses near-black `#0A0A0A` where contrast is required;
- application icon: white Sanad mark on the approved near-black `#0A0A0A` background;
- canonical mark source: `docs/assets/brand/sanad-mark.svg`;
- canonical application composition: `docs/assets/brand/sanad-app-icon-source.svg`;
- canonical generated master: `docs/assets/brand/sanad-app-icon-1024.png`;
- original wordmarks preserved without redrawing at `docs/assets/brand/sanad-wordmark-horizontal.svg` and `docs/assets/brand/sanad-wordmark-stacked.svg`.

The supplied legacy dark, light, and purple PNG compositions are retained unchanged under `docs/assets/brand/source/` only as provenance and proportion references. They are not active identity or launcher sources. In particular, the supplied dark reference uses `#252525`, while the owner-approved application background is `#0A0A0A`.

The English and Arabic README heroes use the same light/dark horizontal wordmark variants rendered by the client's New Chat view from `client/assets/brand/`, so GitHub follows the viewer's color scheme without maintaining a separate README identity export. The owner later approved a real cross-platform product screenshot beneath the introduction. Its public copy lives at `docs/assets/screenshots/sanad-desktop-and-ios-simulator.png`; the left sidebar uses a light privacy blur that keeps the underlying list structure visible while making private workspace, conversation, and account labels unreadable, preserving the macOS and iPhone Simulator product view.

## Reproducible Generation

`scripts/brand/generate_brand_assets.sh` derives every square icon from the canonical SVG, calls the repository's existing `flutter_launcher_icons` dependency for Android, iOS, legacy macOS, Windows, and Web, and then completes surfaces the package does not fully own. The complete generation path is macOS-oriented because it requires Apple's `sips` utility; it also requires Ruby, FFmpeg, and FVM, and fails before writing outputs when any prerequisite is missing:

- Android adaptive safe-area foreground and Android 13 monochrome declaration;
- a flat macOS asset catalog generated from the same opaque canonical composition
  as iOS, avoiding the Xcode 26 layered Icon Composer enclosure that adds a
  visible light rim around dark icons;
- a seven-frame Windows ICO (`16`, `24`, `32`, `48`, `64`, `128`, `256`) through `client/tool/generate_windows_icon.dart`;
- independently padded Web maskable icons and `16`/`32`/ICO favicons;
- Linux hicolor icons and desktop-entry packaging;
- Discord, GitHub repository, and product-page handoff files.

The standard app icon uses the approved 80% width proportion. Adaptive and maskable artwork uses a smaller 62.5% width composition so the mark remains inside platform safe areas rather than being clipped by circles, squircles, or Android masks.

## Applied Platform Matrix

| Surface | Applied output | Result / rule | Remaining live owner |
|---|---|---|---|
| Flutter title bar | `client/assets/app-logo.png` | `1024x1024`, white mark, opaque `#0A0A0A` background | Included in SANAD-10 |
| Flutter splash | `client/assets/sanad_mark.png` | Transparent square with approved blue mark; Dart reference and tests use the canonical name | Included in SANAD-10 |
| Android legacy launcher | `client/android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` | Complete `48`, `72`, `96`, `144`, `192` matrix | Device smoke in SANAD-12 |
| Android adaptive / monochrome | `client/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` and generated foreground densities | White safe-area foreground, `#0A0A0A` background, monochrome layer declared | Android 13 launcher smoke in SANAD-12 |
| iOS / iPadOS | `client/ios/Runner/Assets.xcassets/AppIcon.appiconset/` | Every `Contents.json` slot generated; App Store `1024` output is opaque | Xcode/device archive in SANAD-12 |
| macOS | `client/macos/Runner/Assets.xcassets/AppIcon.appiconset/` | The complete `16` through `1024` matrix uses the same opaque pixels as the corrected iOS icon; no competing `AppIcon.icon` layered source may reintroduce Xcode 26's light enclosure rim | Archive/notarization smoke in SANAD-12 |
| Windows app | `client/windows/runner/resources/app_icon.ico` | Seven-frame ICO generated from the same master | Windows executable/taskbar smoke in SANAD-12 |
| Windows installer | `client/release/windows/sanad_client_installer.iss` | `SetupIconFile` consumes the canonical generated ICO, not a PNG | Installer smoke in SANAD-12 |
| Linux package | `client/linux/assets/icons/hicolor/` and `client/linux/com.eaststarai.sanad.desktop` | `16`, `24`, `32`, `48`, `64`, `128`, `256`, `512`; CMake installs the desktop entry and icon tree | Linux package smoke in SANAD-12 |
| Flutter Web / PWA | `client/web/icons/` and `client/web/manifest.json` | Standard `192/512`, separately padded maskable `192/512`, near-black background, blue theme | Browser install smoke in SANAD-12 |
| Web favicon | `client/web/favicon.svg` | The approved blue SVG mark is the only favicon linked by `client/web/index.html`; its content-derived query key invalidates previously cached legacy PNG/ICO selections | Browser/cache smoke in SANAD-12 |

## Community and Product Deliverables

The review-ready export pack is tracked under `docs/assets/brand/deliverables/`:

| Surface | File | Application boundary |
|---|---|---|
| Discord server icon | `discord-server-icon-512.png` | Apply to the live `Sanad Agent` server after owner circular-crop review |
| Discord server banner | `discord-server-banner-960x540.png` | Separate landscape composition; do not stretch the square icon |
| GitHub repository social preview | `github-repository-social-preview-1280x640.png` | SANAD-11 applies after creating `EastStarAI/sanad-agent` |
| Product-page social card | `sanad-product-social-card-1200x630.png` | SANAD-13 applies to the Sanad product page and sharing metadata |
| Product icon | `sanad-product-icon-512.png` | SANAD-13 product/download surfaces |
| Apple touch icon | `sanad-apple-touch-icon-180.png` | SANAD-13 product Web shell |
| Product favicon PNG / ICO | `sanad-favicon-32.png`, `sanad-favicon.ico` | SANAD-13 Sanad-specific pages only |

The `EastStarAI` organization avatar remains an EastStar identity decision; SANAD-10 does not replace it with a Sanad app icon by inference. Product-site deployment must not overwrite EastStar-wide favicons on organization-level pages.

## Verification and Live Handoff

Local acceptance requires:

1. the canonical SVG and original wordmarks remain tracked;
2. generated icon dimensions, near-black corner pixels, iOS opacity, exact
   iOS/macOS flat-icon pixel parity, absence of a layered macOS icon source, adaptive
   monochrome, maskable padding, Web metadata, Windows ICO frames, and Linux
   matrix pass `client/test/brand/brand_assets_test.dart`;
3. no active client source, `pubspec.yaml`, or test refers to the removed legacy splash filename;
4. Flutter analysis, the focused brand test, the full client fast suite, and locally available builds pass;
5. the approved README screenshot exists at its canonical path, retains its
   `1773x1025` dimensions, and exposes no private sidebar labels under OCR;
6. `git diff --check`, governance checks, public-snapshot scans, and Graphify update complete.

Live application remains intentionally split by owner:

- SANAD-11: repository social preview, GitHub↔Discord links/feed, and any explicitly approved GitHub avatar;
- SANAD-12: icons embedded in Android, Apple, Windows, Linux, Web, installers, packages, and release artifacts;
- SANAD-13: Sanad product-page favicons, touch icon, social card, cache refresh, and reciprocal links;
- server owner: upload Discord icon/banner after circular and desktop/mobile visual review.
