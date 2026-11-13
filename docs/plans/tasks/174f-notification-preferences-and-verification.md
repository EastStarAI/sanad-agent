# 174f — Notification preferences and cross-platform verification

**Status:** implemented — G0–G2 and G5 closed on this host; G3 partially
executed (Linux and build evidence recorded, every platform that cannot run here
is `[!]` with its owner); G4 closed for the boundaries this repository owns.
The review follow-up (B1 mute-versus-ceiling, W1 test-action honesty, W2/W3 copy
and accuracy corrections) is applied on the same branch.
**Owners:** `client/lib/features/notifications/` (model, store, service, settings
cubit, declaration), `client/lib/features/settings/…/notifications_page.dart`,
`agent/lib/interfaces/notifications/` (declaration, profiles, composer,
dispatcher), `client/lib/infrastructure/socket/` (registration envelope)
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Depends on:** `174b` (desktop delivery). `174c`, `174d`, and `174e` are still
unstarted; the obligations they inherit are listed in G0 and in the open items.

## Goal

Give the user one coherent place to control notifications across every device,
and prove the whole feature on each platform with recorded evidence rather than
per-platform assumptions.

## Locked decisions and scope

1. Preferences are global plus per kind. There is no silent kind by default, and
   a kind can only be lowered by the user.
2. Preferences are per device, not per account, because a phone and a desktop
   have different tolerances; the Agent applies the preference of the device it
   is dispatching to.
3. All notification copy and settings text is localized in `en` and `ar`.
4. Verification is per platform and recorded here; a platform without recorded
   evidence is not complete.
5. No digest, quiet hours, or batching in this task.

## Design decisions (G0)

### Preference model

`NotificationPreferences` (`client/lib/features/notifications/domain/models/`)
holds three things and nothing else:

- `enabled` — the global switch;
- `kindOverrides` — kinds the user turned off (a missing entry means enabled);
- `kindUrgencyOverrides` — kinds the user quietened, holding the **lowered
  ceiling only**.

The product default is `NotificationUrgency.high` (banner and sound) for every
kind. `withKindUrgency` stores a value only when it is strictly below that
default, so a corrupt file or a future build cannot raise a kind, and
`urgencyFor(kind, agentUrgency)` returns the lower of the Agent's decision and
the device's ceiling. The Settings surface exposes exactly two loudness choices
per kind — the default, and banner-only (no sound) — plus the row switch for
"off", because those are the states the platform adapters actually implement.

### Storage owner on each platform

The device's own preferences file, and nothing else:

| Platform | Storage |
| :--- | :--- |
| macOS, iOS | `NSUserDefaults` (through `SharedPreferences`) |
| Windows | the application's registry-backed preferences file |
| Linux | the XDG preferences file under the user's local share directory |
| Android | `SharedPreferences` |
| Web | `localStorage` |

Keys are `notifications_enabled`, `notifications_kinds_disabled`, and
`notifications_kinds_urgency` (`kind:urgency`). Nothing is account-scoped and
nothing is uploaded, which is what makes the choice per device rather than per
account. The Agent persists nothing: it holds the declaration in memory per
Client instance id and treats an unregistered device as the product default.

### How a change reaches the Agent, without the relay interpreting it

The Client declares its choice in its own authenticated registration envelope:

```json
"notifications": { "enabled": true, "kinds": { "completed": "off", "failed": "normal" } }
```

- Locally this is the top-level `notifications` field of `client.hello`
  (`SocketConnectionController.localHelloEnvelope`).
- On the cloud route it is the same field inside the `app_authenticate` client
  identity the hosted service already relays; the relay forwards it as one opaque
  value and reads no choice (plan 174, locked decision 2).
- A change re-sends the hello on the connected local socket
  (`publishNotificationPreferences`). While disconnected nothing is sent: the
  choice is already stored on this device and the next registration carries it.
- The Agent parses it in `ClientNotificationPreferences.tryParse`, stores it per
  instance in `ClientInstanceProfiles`, and applies it in
  `NotificationDispatcher`: a `client_instance` step for a kind that device muted
  is not published at all, and the payload's `urgency` and
  `platform_hints.android_channel_id` are composed with the device ceiling. The
  escalation timer still arms and the account step still reaches the other
  devices, which is what keeps one device's choice from affecting another.

Wire detail is owned by
[communication_protocols.md](../../technical/communication_protocols.md) §7.10.

### OS permission revoked while the in-app toggle is on

Nothing rewrites the switch. `NotificationSettingsCubit.refreshPermission` runs
on app resume and on page open, `NotificationSettingsState.permissionDeniedWhileEnabled`
reports the contradiction, the page shows it next to an "Open system settings"
action (macOS never shows a second prompt), and `NotificationDisplayPolicy`
refuses to raise anything until the permission is actually granted. The test
notification reports the same state instead of claiming success.

## Gates

### G0 — Preference model — closed

- [x] Define the preference model: global enable, per-kind urgency, per-device
      scope, and the storage owner on each platform.
- [x] Define how a preference change reaches the Agent for the device it applies
      to, without the relay interpreting it.
- [x] Define the behavior when permission is revoked at the OS level while the
      in-app toggle is still enabled.

### G1 — Settings surface — closed

- [x] Add a notifications section that shows the OS permission state, the global
      toggle, and one row per kind with its current urgency.
- [x] Provide a test notification action that exercises the real pipeline.
- [x] Explain platform limits in place: iOS installed-web-app requirement, and
      the fact that OS settings always win.

### G2 — Localization parity — closed

- [x] Ensure the Agent copy table and the Client localization keys share one
      key set, enforced by a test.
- [x] Ensure no user-facing string is hard-coded in widget code.
- [x] Verify Arabic layout and right-to-left rendering of the notification
      settings.

### G3 — Cross-platform verification matrix — partially closed, see the record

- [x] Linux: everything executable without a display or a notification daemon;
      the OS-level rows are `[!]` below.
- [ ] macOS: permission, hidden-window delivery, click, action, quit limitation.
      `[!]` — not executable here.
- [ ] Windows: permission, toast display, collapse behavior, cancellation
      limitation under NSIS. `[!]` — not executable here.
- [ ] Android: foreground same session, foreground other session, background,
      terminated, action, revoked token. `[!]` — `174c` unstarted.
- [ ] iOS: foreground suppression for the same session, background, terminated,
      action, installed web app path. `[!]` — `174c` unstarted.
- [ ] Web: closed tab, open tab same session, open tab other session, installed
      iOS web app. `[!]` — `174d` unstarted. The web release build and the
      settings surface it carries are verified.

### G4 — Failure and edge behavior — closed for this repository's boundaries

- [x] Agent offline at dispatch time: the ask waits, and the Client shows it on
      reconnect without a stale OS notification. Inherited from `174b`'s quiet
      window and covered by its unit test; the live socket case is `[!]` below.
- [x] Duplicate delivery across socket and push: one visible notification. The
      socket-to-socket pair is proven by dedupe tests; the push leg does not
      exist yet (`174c`/`174d`).
- [x] Escalation for an ask resolved on the first device: nothing arrives later.
      Agent `onAskResolved`/`onSessionTerminal` cancel the timer and withdraw;
      the Client drops a withdrawal it never showed.
- [ ] Relay unreachable: the dispatch fails closed with a recorded metric, and
      the in-app state remains correct. `[!]` — the relay is not in this
      repository; owner `174e` (hosted service). The Agent side already contains
      a throwing sink and records the failure without failing the ask.

### G5 — Documentation — closed

- [x] Record the final behavior, the platform limits, and the verification
      evidence in the owning technical documentation.
- [x] Document the local-only limitation for cross-device notifications.

## Acceptance Criteria

- [x] Given a user lowers one kind on one device, when that kind occurs, then
      only that device is affected and the other devices keep the default.
      Proven in `notification_dispatcher_test.dart` ("a declaration for another
      device does not change this one") and
      `client_instance_profiles_test.dart` ("a hello declaration is stored for
      that instance alone") and
      `notification_preferences_scope_test.dart` (the store and the declaration).
- [x] Given the OS permission is revoked while the in-app toggle is on, when the
      settings page opens, then it reports the real state and offers a fix path.
      Proven by the cubit and page tests bound to
      `notification_permission_conflict` and `notification_open_settings_btn`.
- [x] Given a kind is quietened and then muted — or muted and then quietened
      again — when this device declares its choices, then the declaration states
      `off` for that kind and never an urgency token, and the Agent reads it as
      muted with no ceiling. Proven in `notification_preferences_scope_test.dart`
      (both orders, the cubit, and a restart) and
      `notification_preferences_test.dart` / `client_instance_profiles_test.dart`
      (the Agent side of the same rule).
- [x] Given the platform refuses the presentation call, when the user presses the
      test action, then Settings reports a localized failure and never claims a
      notification was shown. Proven in `notification_display_matrix_test.dart`,
      `notification_preferences_scope_test.dart`, and
      `notification_settings_page_test.dart`.
- [x] Given the OS permission is revoked (or no notification service is
      reachable), when the page renders, then a kind row states that block instead
      of a banner-and-sound claim. Proven in
      `notification_settings_page_test.dart` (`the rows state the OS block instead
      of a delivery claim`).
- [~] Given any supported platform, when the verification matrix row is executed,
      then its evidence is recorded in this file with date and build identity.
      Every row is either executed and recorded below or explicitly `[!]`.
- [x] Given the Arabic locale, when the settings page and a notification are
      rendered, then all text is translated and correctly aligned. Proven by
      `notification_settings_rtl_test.dart` (page direction is RTL, no English
      label leaks) and the guard test (every key authored in both locales).
- [x] Given an ask resolved on the first device, when the escalation window
      passes, then no other device is notified. Proven in the dispatcher tests
      ("resolution 10 seconds in prevents the fan-out and withdraws").

## Implementation map

| Concern | Owner |
| :--- | :--- |
| Preference model, ceiling, declaration encoding | `client/lib/features/notifications/domain/models/notification_preferences.dart` |
| Per-device storage | `…/data/notification_preferences_store.dart` |
| Ceiling application and the test probe | `…/application/notification_service.dart` |
| Settings state and actions | `…/presentation/bloc/notification_settings_cubit.dart`, `notification_settings_state.dart` |
| Settings surface | `client/lib/features/settings/presentation/widgets/settings_pages/notifications_page.dart` |
| Registration envelope | `client/lib/infrastructure/socket/socket_connection_controller.dart` (`localHelloEnvelope`, `publishNotificationPreferences`) |
| Agent declaration | `agent/lib/interfaces/notifications/notification_preferences.dart` |
| Agent application | `…/client_instance_profiles.dart`, `…/notification_payload.dart` (`composeDispatch` ceiling), `…/notification_dispatcher.dart` |

## Review follow-up (blocker and warnings)

Applied on `task/174f-preferences` after the implementation review.

### B1 — a muted kind was declared as still on

`NotificationPreferences.toAgentDeclaration` built one map from two passes: the
off entries first and the urgency entries second. A kind present in both maps was
therefore emitted with its urgency token, and the Agent — which reads the
declaration as a ceiling — kept delivering it. The reachable order is
quieten-then-mute (the urgency menu is disabled while a row is off) and the state
survives a restart, so the defect was user-reachable.

Fix, in both codebases:

- `toAgentDeclaration` now emits one answer per kind: a muted kind is `off`,
  otherwise a stored ceiling, otherwise the kind is absent. Precedence is a rule,
  not map insertion order.
- `NotificationPreferences.ceilingFor` answers the product default for a muted
  kind, so no surface can describe a style for a kind that delivers nothing. The
  stored ceiling is kept so unmuting restores what the user chose.
- `ClientNotificationPreferences` (`agent/`) enforces the same rule: a muted kind
  has no ceiling (`ceilingFor` → `high`), `tryParse` drops a ceiling for a muted
  kind, and `toJson` emits only `off`.
- Protocol §7.10 states the precedence and the Agent's read of it.

Tests cover the two orders (`quietened-then-muted` and `muted-then-re-urgencied`),
their equality on the wire, the restart path, the cubit publishing path, and the
Agent's read of the same declaration.

### W1 — the test action reported success when presentation failed

`NotificationService._display` swallowed adapter failures while
`raiseTestNotification` returned the `display` decision, so Settings said "Test
notification sent" after a call the platform refused.

- `_display` now returns whether the platform accepted the call.
- The service returns `NotificationDisplayOutcome.presentationFailed` when the
  policy said `display` and the presentation failed — for an arrival and for the
  probe.
- The cubit maps that outcome to `NotificationTestOutcome.failed` (localized
  `notificationsTestFailed`), and a probe with no attached sender is `failed`
  rather than `unsupported`, so the copy never blames the system for a pipeline
  that is not there.

### W2 — the row copy claimed delivery while the OS refused it

A kind row described the alert style it would use. It now reports the block
first: `notificationsUrgencyBlockedByPermission` while permission is not
`granted`, and `notificationsUrgencyNoService` when the platform has no
notification surface or no reachable service. Both keys are authored in `en` and
`ar`.

### W3 — accuracy corrections

- `NotificationSettingsState.canSendTest` claimed a sender check it did not
  perform. It now requires `testSenderAttached`, set when the running pipeline
  attaches its sender, so Settings cannot offer a probe that can only fail.
- `client/lib/features/notifications/AGENTS.md`,
  `client/lib/features/settings/AGENTS.md`, protocol §7.10, and
  `docs/technical/desktop_background_and_system_tray.md` §8.1 now state the
  off-wins rule, the row-copy rule, the full test-outcome set including a failed
  presentation, and the sender requirement.
- The unit test that asserted a muted kind still advertises its ceiling was
  replaced: a muted kind has no effective ceiling, and unmuting restores it.

## Verification record

**Date:** 2026-11-13
**Host:** Linux 7.0.0-1016-oracle, Ubuntu 24.04, `arm64`
**Branch:** `task/174f-preferences` (base `e469dfe9`)
**Toolchain:** `fvm` 4.1.2 → Flutter 3.47.0 (stable, framework `4cf2416426`) /
Dart 3.13.0
**Build identity of the executed tree:** the working tree of the branch
described above; the branch head commit is reported with the hand-off.
**Host limits:** `DISPLAY` and `WAYLAND_DISPLAY` are unset, and
`org.freedesktop.Notifications` answers `ServiceUnknown` (`dbus-send`), so no OS
notification can be presented on this machine. `graphify` is not installed and no
`graphify-out/` exists in this worktree or the primary checkout.

### Commands executed

All commands ran inside `client/` or `agent/` with `fvm`, except where noted.

| Command | Result |
| :--- | :--- |
| `fvm flutter gen-l10n` (in `client/`) | Generated the localization Dart. Required first: `lib/l10n/app_localizations*.dart` is gitignored, so a fresh worktree cannot compile the Client without it. |
| `fvm flutter analyze` | `No issues found!` |
| `fvm dart analyze` (in `agent/`) | `No issues found!` |
| `fvm flutter test test/unit/features/notifications test/widget/notifications test/guards` | `All tests passed!` — 189 tests (177 before the review follow-up) |
| `fvm flutter test` (full fast suite) | `All tests passed!` — 2956 passed, 3 skipped (browser-only web guard) |
| `fvm dart test test/interfaces/notifications` | `All tests passed!` — 98 tests (93 before the review follow-up) |
| `fvm dart test` (full agent suite) | 4888 passed, 24 skipped, 7 failed — all 7 in `test/evolution/` and caused by `Failed to load dynamic library 'libsqlite3.so'` on this host (pre-existing, unrelated to this task; the notifications suite is green) |
| `fvm flutter build linux --release --dart-define-from-file=config/prod.json` | `✓ Built build/linux/arm64/release/bundle/sanad-client` |
| `fvm flutter build web --release --dart-define-from-file=config/prod.json` | `✓ Built build/web` |
| `dbus-send --session --print-reply --dest=org.freedesktop.Notifications … GetCapabilities` | `ServiceUnknown` — no notification daemon; no notification could be presented here |
| `fvm dart run scripts/lint_wiki.dart` (workspace root) | `FAILED: Found 2 documentation errors` — both pre-existing on the base branch (`docs/qa_maintenance/mobile_new_account_onboarding_qa.md` and `docs/technical/context_window_resolution.md`, missing frontmatter). Both notification pages this task edited resolve and link cleanly. |
| `graphify update .` | Not run — no `graphify` CLI and no `graphify-out/` index in this checkout |

New tests added by this task:

- `client/test/unit/features/notifications/notification_preferences_scope_test.dart`
  — the ceiling, the stored form, the declaration and its off-wins precedence in
  both orders, the restart path, and the test-action outcomes.
- `client/test/unit/features/notifications/notification_declaration_transport_test.dart`
  — the registration envelope the Agent reads.
- `client/test/widget/notifications/notification_settings_rtl_test.dart` — Arabic
  rendering and direction.
- `client/test/guards/notifications_localization_guard_test.dart` — no hard-coded
  string, no Arabic literal, and key parity across locales.
- Extensions to `notification_settings_page_test.dart` (row-copy honesty, a
  refused platform call, the sender gate) and
  `notification_display_matrix_test.dart` (a refused presentation for the probe
  and for an arrival); the pre-existing
  `notification_settings_cubit_test.dart` is unchanged and still green.
- `agent/test/interfaces/notifications/notification_preferences_test.dart`,
  extensions to `client_instance_profiles_test.dart` and
  `notification_dispatcher_test.dart`.

### Per-platform matrix

`PASS` means the row was executed on this host with the command quoted. `[!]`
means it was not executed here, with the reason and the owner.

| Platform | Row | Result | Evidence / reason | Owner |
| :--- | :--- | :--- | :--- | :--- |
| Linux | Settings surface: permission state, global switch, per-kind urgency, persistence | **PASS** | `fvm flutter test test/widget/notifications/notification_settings_page_test.dart` (12 tests) | client |
| Linux | OS permission revoked while the switch is on | **PASS** | page + cubit tests (`notification_permission_conflict`, `notification_open_settings_btn`) | client |
| Linux | Test notification through the real pipeline, including suppression | **PASS** | `notification_display_matrix_test.dart` (5 probe tests) + page test | client |
| Linux | Stated platform limits (OS wins, iOS web-app requirement) | **PASS** | page test (`notification_limits_card`, `notificationsLimitsOsWins`) | client |
| Linux | Arabic RTL rendering, no untranslated label | **PASS** | `notification_settings_rtl_test.dart` (2 tests, `TextDirection.rtl`) | client |
| Linux | No hard-coded string, no Arabic literal, key parity | **PASS** | `notifications_localization_guard_test.dart` (3 tests) | client |
| Linux | Agent applies the target device's preference (mute and ceiling) | **PASS** | `notification_dispatcher_test.dart` (4 new tests) | agent |
| Linux | One device's choice leaves the others at the default | **PASS** | profiles + dispatcher tests | agent |
| Linux | Lowered urgency reaches the adapter request | **PASS** | `notification_display_matrix_test.dart` ("a lowered kind reaches the platform at the ceiling") | client |
| Linux | Desktop build compiles with the plugin and the new surface | **PASS** | `fvm flutter build linux --release` | client |
| Linux | OS banner display, runtime urgency, click, action | `[!]` | No display (`DISPLAY` unset) and no notification daemon (`ServiceUnknown`); 174b recorded the same limit | release QA on a Linux desktop |
| macOS | Permission prompt, hidden-window delivery, click, action, quit limitation | `[!]` | No macOS host | macOS release QA (`174b` limitation 1) |
| Windows | Permission, toast display, collapse, cancellation under NSIS | `[!]` | No Windows host | Windows release QA (`174b` limitation 2) |
| Android | Foreground same session, foreground other session, background, terminated, action, revoked token | `[!]` | No Android SDK or device; `174c` unstarted | `174c` owner |
| iOS | Foreground suppression for the same session, background, terminated, action, installed web app | `[!]` | No Apple host; `174c` unstarted | `174c` owner |
| Web | Release build compiles with the new settings surface | **PASS** | `fvm flutter build web --release` | client |
| Web | Closed tab, open tab same session, open tab other session | `[!]` | No browser target here (the browser-only guard skips: 3 skipped) and `174d` unstarted | `174d` owner |
| Web | Installed iOS web app delivery | `[!]` | Requires an iPhone/iPad host and `174d` | `174d` owner |
| Any | Agent offline at dispatch time, then reconnect | `[!]` (live) | Needs a live Agent + Client pair with a display; the quiet-window behavior underneath is unit tested | `174b` owner |
| Any | Relay unreachable: fail closed with a metric | `[!]` | The relay is the hosted service (`174e`); this repository has no relay code | `174e` owner |
| Any | Duplicate delivery across socket and push | **PASS** for socket ↔ cloud socket; `[!]` for push | Dedupe tests; push does not exist yet | `174c`/`174d` owners |
| Any | An ask resolved on the first device notifies nobody later | **PASS** | `notification_dispatcher_test.dart` resolution tests + Client withdrawal test | agent + client |

## Open items

1. **Per-device preferences on an account-wide push step.** The Agent applies a
   device's declaration at the step that names that device. An `account` step
   names none, so filtering it per device needs either one instruction per
   registered instance or a recipient-side application of its own stored choice.
   `174c`, `174d`, and `174e` own that decision; the desktop route already
   applies the choice in the Client before display.
2. **Cloud registration of the declaration.** The Client writes `notifications`
   into the cloud `app_authenticate` identity, but the hosted service must carry
   it through to the Agent as part of the client identity it already relays.
   Until it does, a cloud-only Client re-declares on its next authentication and
   the Agent applies the product default in between. Owner: `174e`.
3. **Live per-platform passes.** macOS, Windows, Android, iOS, and browser rows
   remain `[!]` with the owners named in the matrix.
4. **`graphify update .` unexecuted.** No Graphify CLI and no index on this host,
   so the graph could not be refreshed.
5. **Pre-existing failures on this host.** Seven `test/evolution/` tests fail
   because `libsqlite3.so` is absent, and `scripts/lint_wiki.dart` reports two
   missing-frontmatter pages. Neither involves this task's files and both exist
   on the base branch.
6. **`docs/llms.txt` left unchanged.** The index already lists the three owning
   pages and this task added no new page, so there was nothing to add; the index
   is regenerated by `scripts/generate_llms_txt.dart` outside leaf tasks.

## Definition of Done

- [x] `fvm flutter analyze` and `fvm dart analyze` pass.
- [x] Focused tests pass; the platform matrix is complete with evidence, and
      every row that could not run here is `[!]` with a reason and an owner.
- [x] `docs/llms.txt` and the owning technical documents are updated. The index
      already lists the three owning pages
      (`client/lib/features/notifications/AGENTS.md`,
      `docs/technical/communication_protocols.md`,
      `docs/technical/desktop_background_and_system_tray.md`), and this task
      added no new page, so no index entry changed.
- [x] No hard-coded user-facing string and no Arabic literal in Dart source,
      enforced by `client/test/guards/notifications_localization_guard_test.dart`.
- [ ] Graph index refreshed with `graphify update .` — see open item 4.
