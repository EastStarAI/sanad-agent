# 174g — Notification surface fixes from the enabled-state review

**Status:** implemented on `task/174g-ui-fixes`. Analyzer and focused unit/widget
coverage are green; the live re-capture is the orchestrator's, and the acceptance
steps it should follow are in §6.
**Owners:** `client/lib/features/notifications/` (pipeline, readiness, Settings
cubit, platform adapter), `client/lib/features/settings/…/notifications_page.dart`,
`client/lib/features/devices/` and
`client/lib/features/conversations/presentation/widgets/sidebar/` (the device
chrome the Arabic capture exposed), `client/lib/l10n/`.
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Evidence:** `.sanad` delegation record `delegation/174/results/enabled-state-review.md`
and `delegation/174/screenshots/enabled-*.png` (kept outside the repository, in
the operator's Sanad Home).

## 1. Goal

Close the defects the enabled-state live review found on the notification
surface, without changing the delivery contract: the settings page is the one
place a user controls notifications, and reviewing it while notifications were
actually enabled proved four things the disabled baseline could not — a cold-start
permission probe that lied, an OS action label that ignored the interface
language, an urgency control that did not read as a control, and copy that drifted
between the menu, the rows, and the interface language.

## 2. Items

| Id | Severity | Item | Outcome |
| :--- | :--- | :--- | :--- |
| H1 | high | Cold-start permission probe reports `unavailable` while a working service exists | Fixed |
| M2 | medium | A locale change does not reach the OS action label | Fixed for Linux; Darwin categories recorded as a limit |
| M3 | medium | The urgency control does not read as a control and shows no state | Fixed |
| L4 | low | Menu vocabulary diverges from the row vocabulary | Fixed |
| L5 | low | The unselected menu item loses the checkmark's indent | Fixed |
| L6 | low | The test probe silently inherits the `Completed runs` loudness | Fixed by naming the kind |
| L7 | low | The Arabic page still shows literal English `This device` and `local` | Fixed on the reviewed surfaces; remaining device-name copy recorded in §5 |

### H1 — cold-start permission ordering

`NotificationSettingsCubit.load()` is created and started unawaited at app scope
while `NotificationBridge` separately started the pipeline, so the first
`checkPermission()` could run before the Linux adapter's `initialize()` had built
the D-Bus object it answers with. The call threw, the adapter mapped it to
`unavailable`, and `NotificationDisplayPolicy` therefore refused every
Agent-raised notification until something else refreshed the permission.

The fix is ordering, not suppression:

- `NotificationService.start()` takes an `onPlatformReady` hook and awaits it
  between `initialize()` and stream subscription, so the first read is published
  before any Agent event can be decided against it.
- `NotificationPlatformReadiness` (`application/`) is the one release point,
  registered in the container and passed to the cubit. The bridge completes it
  inside that hook and then loads Settings from it (`NotificationSettingsCubit`
  no longer starts the read at creation), which is why the startup log now reports
  the permission the platform actually answered.
- `NotificationSettingsCubit._readPermission()` still awaits the signal, so a read
  that arrives before the pipeline has started (a page mounted early, a hot
  restart) waits instead of throwing. An adapter with no platform surface answers
  `unsupported` first, so an unsupported build cannot wait on a signal that never
  arrives.

An absent readiness instance means "no gate", which is what keeps a widget test
or a surface without a pipeline reading immediately, exactly as before.

### M2 — the OS action label follows the language

The freedesktop default action name was taken only from `initialize`, so
record 4 of the review raised an Arabic title and body with an English `Open`.
Linux builds the action array per notification, so the label now travels with the
presentation: `NotificationPresentationRequest.openActionLabel` carries
`NotificationCopySource.approvalActionLabels[open]` resolved from the live locale,
and `linuxDetailsFor` passes it as `defaultActionName`. An absent label keeps the
registered copy rather than presenting a blank button.

macOS fixes an approval category's buttons when the category is registered and the
plugin offers no per-notification override, so those buttons keep the language of
the launch they were registered in; the technical page states that limit.

### M3, L4, L5 — the urgency control

The per-kind affordance was an unlabeled `Icons.tune_rounded`, so `Alert` and
`Banner only` rendered identically and nothing at rest said it was a control.

- The control is now a labeled pill carrying the setting's value (`Alert` /
  `Banner only`) with a state glyph (alert, silent banner, permission block, no
  service), a border and a tonal surface, and a caret. It is still a
  `PopupMenuButton`, so hover, focus, and the tooltip come from the framework.
- The row keeps its subtitle for the delivery status (off, no notification
  service, blocked by system permission), so the control states the choice and the
  subtitle states whether that choice can be honoured.
- Both menu items reserve the check slot, so the selected and unselected labels
  share one text offset.
- One vocabulary: the pill and the menu item share the setting's name, and the
  menu states the delivery under that name (`Alert` / `Banner and sound`,
  `Banner only` / `Banner without sound`) instead of introducing a second name.

### L6 — the test probe names its kind

`NotificationService.testNotificationKind` is the one constant the probe borrows
(the kind is `completed`), `attachTestSender` carries it into state, and the test
card states `The test follows your <kind> alert style.` A quietened kind now
explains the quieter test instead of looking like a forgotten setting. A neutral
probe kind was rejected: a kind is a wire token shared with the Agent contract, and
adding one to make a probe quieter would change the payload vocabulary for a
cosmetic reason.

### L7 — the device chrome around the page

- The Client's synthesized local row now carries
  `DeviceConfig.localPlaceholderName`; `DeviceConfigUI.displayName` resolves it
  through `AppLocalizations`, and the sidebar header, the device menu, and the
  settings section title use it.
- The `local` badge reads from `AppLocalizations.devicesLocalBadge`.
- A name the Agent or the user wrote is shown exactly as stored, and the menu
  item's widget key still derives from the stored name, never the label.

## 3. Verification

Run from `client/` unless stated otherwise. Successful output was bounded to its
last lines while preserving exit status.

| Command | Result |
| :--- | :--- |
| `fvm flutter gen-l10n` | regenerated after the ARB edits |
| `fvm flutter analyze` | no issues |
| `fvm dart analyze` (from `agent/`) | no issues |
| `fvm flutter test test/unit/features/notifications/notification_cold_start_permission_test.dart` | pass (H1: 4 tests, including the startup log line) |
| `fvm flutter test test/unit/features/notifications/notification_action_label_locale_test.dart` | pass (M2) |
| `fvm flutter test test/widget/notifications/` | pass |
| `fvm flutter test test/unit/features/notifications/` | pass |
| `fvm flutter test test/guards/notifications_localization_guard_test.dart` | pass |
| `fvm flutter test test/widget/sidebar_device_header_localization_test.dart` | pass (L7) |
| `fvm flutter test test/guards/file_size_ratchet_guard_test.dart test/guards/locale_stable_widget_keys_guard_test.dart test/guards/no_hardcoded_font_guard_test.dart` | pass |
| `fvm flutter test test/unit/services/device_inventory_source_test.dart test/unit/services/device_manager_test.dart test/unit/services/device_command_client_test.dart test/widget/device_name_editor_test.dart test/unit/bloc/session_cubit_test.dart test/features/mcp/mcp_server_management_screen_test.dart` | pass (shared device surfaces) |

Fail-before evidence for the two behaviors a widget test can express directly:

- Removing `await _platformReadiness?.ready;` from the cubit makes the cold-start
  test fail (`permission` stays `unavailable` and the Agent notification is
  suppressed), and restoring it makes it pass.
- Restoring the old conditional check icon makes the menu-alignment assertion fail
  with a 24 px offset difference (`63.0` vs `87.0`).

No live runtime was started, restarted, or stopped for this task, and
`/home/ubuntu/.sanad-test` was not used: verification is the analyzer plus the
focused unit and widget tests above.

## 4. Deliberately not changed

- **N8 (popup elevation) and N9 (an off row keeps full title emphasis)** are nits
  outside this task's item list and were left for a follow-up so the re-capture
  can judge the new pill and menu surfaces first. The menu now carries a two-line
  item, which changes its height, so re-judging elevation with it is cheaper than
  guessing.
- **Darwin approval-button copy** cannot be corrected after registration with the
  plugin's current API; it keeps the launch language and is stated as a limit in
  `docs/technical/desktop_background_and_system_tray.md`.
- **Notification click routing, close/expiry, cross-device isolation, and narrow
  widths** remain unproven live; the enabled-state review already records them as
  open and nothing here changes those paths.

## 5. Open items and ownership

| Item | Owner | Note |
| :--- | :--- | :--- |
| Remaining device-chrome English copy around the settings rail (`Loading devices…`, `No devices`, `Device selector`, `Device Settings`) | devices / conversations features | Pre-existing and outside the notifications owner. The two strings the Arabic capture showed (`This device`, `local`) are fixed; localizing the rest of that widget is its own change. |
| Device-name copy on the devices settings pages (`providers_page.dart`, `skills_page.dart`, `workspace_page.dart`, `device_overview_page.dart` render `device.name` inside hard-coded English sentences) | devices + settings features | A localized `displayName` resolver now exists; those pages need their own copy pass before they can use it. |
| Live re-capture of the enabled page (dark/light, EN/AR, menu open, row off, banner-only) | orchestrator | See §6. |
| Agent-raised delivery end to end, click routing, and cross-device isolation | orchestrator live pass | Unchanged by this task. |

## 6. Acceptance for the live re-capture

1. Start the Client with a notification service present and **do not open
   Settings**. The first `notification service started` line must carry
   `permission=granted`, not `unavailable` (the pipeline publishes the read before
   it logs).
2. Raise an Agent notification (the run-completion kind) before opening Settings:
   it must reach the OS.
3. Open Settings → Notifications, switch the language to Arabic, then press
   `notification_test_btn`. The delivered payload's `actions` must be
   `["default", "فتح"]` in the same session, with no restart.
4. In the same session, read every kind row: each urgency pill states `Alert` or
   `Banner only`, differs by glyph, and has a visible surface. Open one menu: the
   checked and unchecked items share one text offset, and each item states the
   delivery it means.
5. Turn a kind off: the row subtitle says `Off`, the pill dims, and the menu is
   disabled. Turn it back on: the stored ceiling is retained.
6. Quiet `Completed runs` to `Banner only`, then press the test action: the test
   card names the borrowed kind, and the delivered urgency is `1`.
7. Read the Arabic rail: no English `This device` or `local`.
