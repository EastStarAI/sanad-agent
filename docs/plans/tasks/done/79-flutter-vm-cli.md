# Task 79: Generalized Flutter VM Driver CLI Tool

## Goal
Provide a unified command-line interface (`flutter_driver_cli`) and core driver controller under `scripts/flutter_driver_cli/` that allows developers and AI agents to inspect, query, and interact with a driver-enabled Sanad Flutter Client via the Dart VM Service and Flutter Driver protocol without writing disposable scripts. The host CLI remains platform-neutral; the target must register the extensions in `client/lib/driver_main.dart`.

## Problem Statement
Previously, verifying UI behaviors or simulating user interactions in the Flutter client required writing dedicated Dart scripts (e.g. `client/test/interactive/test_ask_user_flow.dart`, `send_message_example.dart`, `take_screenshot.dart`). Furthermore, raw widget tree inspections were cluttered with state-management noise (`BlocBuilder`, framework keys, `InkWell` duplicates, icon glyphs) and coordinate-based taps were fragile against scrolled or occluded layouts.

## Locked Decisions & Boundaries
- **Standalone Host Architecture:** `flutter_driver_cli` resides in `scripts/flutter_driver_cli/` without importing `sanad_dev` runtime internals. It uses the Client package configuration for Flutter Driver and requires a target launched through `client/lib/driver_main.dart`.
- **One-Way Integration with `sanad-dev`:** `sanad-dev ui <command>` is the developer entry point that discovers the worktree-scoped VM port and executes `scripts/flutter_driver_cli.dart` with `--vm-url`.
- **Generic Framework-Level Tree Rules in `driver_main.dart`:**
  - **Leaf-Text Inheritance & Row Consolidation:** Any keyed or interactive widget automatically inherits its primary child text (`text: "..."`), eliminating duplicate sub-lines.
  - **Tooltip Ingestion:** Tooltips are ingested into the child widget's `tooltip` property rather than emitted as duplicate elements.
  - **State Noise & Private Glyph Suppression:** Automatically suppresses internal state-management wrappers (`BlocBuilder`, `StreamBuilder`, etc.), anonymous `InkWell` duplicates, framework global keys, and icon font glyphs.
  - **Auto-Scroll Before Tap (`Scrollable.ensureVisible`):** Automatically scrolls elements into view before tapping, preventing off-screen / occluded tap failures.
- **Supported Commands:**
  - `snapshot` / `inspect`: Extract clean UI hierarchy with `--only-keys`, `--interactive`, `--compact`, and `--within` filtering.
  - `find`: Locate widgets by key, text, or widget type with optional `--within` scoping.
  - `tap`: Click an element identified by key, text, or type with automatic centering and visibility scrolling.
  - `enter-text`: Input text into targeted input field or focused widget.
  - `scroll`: Scroll offset or scroll until target widget is visible.
  - `wait-for`: Wait for a widget with given key/text to appear or disappear with timeout.
  - `screenshot`: Capture visual viewport PNG and return file path.
  - `batch`: Execute an array of sequential interaction steps from JSON.
- **VM Endpoint Selection:** The standalone CLI accepts `--vm-url` or `VM_SERVICE_URL`. `sanad-dev ui` validates launcher ownership and injects the single managed Client endpoint for the current worktree. Arbitrary process-table selection is forbidden; multiple managed Clients require an explicit endpoint.

---

## Gates

### G0 — Setup & Task Tracking
- [x] Create branch `feature/flutter-vm-cli-plan-79` and Git worktree `.agent/worktrees/79-flutter-vm-cli`.
- [x] Create task contract `docs/plans/tasks/79-flutter-vm-cli.md`.

### G1 — Driver Engine & Primitives
- [x] Create standalone `scripts/flutter_driver_cli/flutter_vm_controller.dart` with VM Service WebSocket & FlutterDriver connection handling.
- [x] Implement robust primitives for `snapshot`, `find`, `tap`, `enterText`, `scroll`, `waitFor`, `screenshot`, and `batch`.

### G2 — CLI Interface & Subcommands
- [x] Create `scripts/flutter_driver_cli.dart` and `sanad-dev ui` integration with comprehensive CLI arguments and help text.
- [x] Implement formatted outputs (human-readable clean list, compact single-line mode, and JSON output modes).

### G3 — Generic Optimization & Live Verification
- [x] Implement generic leaf-text inheritance, tooltip ingestion, state wrapper suppression, and auto-scroll in `client/lib/driver_main.dart`.
- [x] Verify static analysis passes (`fvm flutter analyze` and `fvm dart analyze`).
- [x] Verify full test suite passes (`fvm flutter test` - 1,071 passed, 1 skipped).
- [x] Verify live interaction commands against an isolated macOS Client (clean scoped snapshot, strict scope failure, repeated Load more, scroll-until-visible, opening the `RTL` conversation with `selected: true`, text entry/readback, batch, and screenshot).
- [x] Update `.agents/skills/sanad-client-tester/SKILL.md` and task documentation.

### G4 — Review Hardening & PR Readiness
- [x] Move the final standalone implementation to `scripts/flutter_driver_cli/` and remove stale `client/tool` references.
- [x] Fail closed for missing scopes, invalid indexes, stale/unmanaged runtime records, and ambiguous managed Clients.
- [x] Select the Flutter isolate by advertised extension, preserve explicit VM URLs, and support Windows FVM shell resolution.
- [x] Fix tooltip inheritance, horizontal/keyed scrolling, scroll-until-visible routing, text-field value inspection, and non-blocking focus before text entry.
- [x] Add the nearest runtime contract at `scripts/flutter_driver_cli/AGENTS.md`, focused CLI/model tests, and technical/QA documentation.
- [x] Copy the primary `state.db` into the isolated runtime through a verified SQLite backup (`PRAGMA quick_check = ok`) with explicit user authorization.

### G5 — Flutter 3.47.0 Compatibility
- [x] Pin the root, Agent, and Client FVM configurations to Flutter `3.47.0` and resolve dependencies with only SDK-required transitive lockfile updates.
- [x] Pass formatting/static analysis and the full fast Client and Agent test suites on Flutter `3.47.0`.
- [x] Produce successful Android APK, unsigned iOS app, macOS app, and Web release builds using the Production client configuration.
- [x] Compile the Agent as a native macOS AOT executable with Flutter `3.47.0`'s Dart SDK.
- [x] Launch the isolated driver-enabled macOS runtime and verify `sanad-dev ui snapshot` plus one non-mutating lookup against the live Client.
- [x] Record the exact compatibility evidence and required migration changes in this task before PR delivery.

**Implementation remaining:** 0%. PR delivery is authorized; merge remains maintainer-controlled.

### Flutter 3.47.0 Compatibility Evidence
- SDK: Flutter `3.47.0`, Dart `3.13.0`, Xcode `26.4`, CocoaPods `1.16.2`, and Java `17.0.14`.
- Static verification: Client and Agent analyzers pass; the Flutter Android suggestion check reports Java/Gradle/AGP/KGP as compatible.
- Tests: Client `1071` passed with `1` skipped after clearing stale Flutter 3.41 shader artifacts; Agent `1128` passed with `10` skipped.
- Client builds: Android debug and release APKs, unsigned iOS release app, universal macOS release app, and Web release output all build successfully with `client/config/prod.json`.
- Agent build: `fvm dart compile exe bin/sanad_agent.dart -o build/sanad` produces a native arm64 macOS executable.
- Live runtime: isolated local-only managed runtime starts from this worktree; `sanad-dev ui snapshot --filter worktree_runtime_badge` reports `79-flutter-vm-cli`, and `sanad-dev ui find --key chat_input` finds the live composer field.
- Required migrations: FVM pins move to `3.47.0`; Android moves to Gradle `8.14`, AGP `8.11.1`, and Kotlin `2.2.20` with Flutter's transitional built-in Kotlin/new-DSL opt-outs; iOS moves to deployment target `15.0`; macOS moves to deployment target `12.0`; SDK-coupled lockfiles and analyzer exclusions refresh accordingly.
- Non-blocking follow-ups: Flutter warns that Gradle 8.x support will be dropped in a future release, iOS will eventually require UIScene lifecycle migration, and `mp_audio_stream` does not yet support Swift Package Manager.

---

## Acceptance Criteria
- [x] `sanad-dev ui inspect` (and `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart snapshot`) dumps clean widgets with keys and texts.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart find --key <key>` returns matching element details.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart tap --key <key>` successfully triggers tap on live client with auto-scroll.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart enter-text --key <key> --text <val>` types text into the specified field.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart scroll --key <key> --dy <val>` smoothly scrolls target scrollable.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart screenshot` captures viewport and writes PNG to disk.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart wait-for --key <key> --timeout <sec>` completes successfully.
- [x] `fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart batch --file <steps.json>` executes sequential commands.
- [x] Zero lint/analyzer errors across all modified and new files.

---

## Definition of Done
- [x] All acceptance criteria pass against the live client.
- [x] Code passes formatting and static analysis (`fvm dart analyze` / `fvm flutter analyze`).
- [x] Testing guidelines updated in `sanad-client-tester/SKILL.md`.
