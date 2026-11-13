import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_navigation.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/notifications_page.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements NotificationPlatformAdapter {
  _FakeAdapter({this.supported = true, this.canOpenSettings = true});

  NotificationPermissionStatus permission = NotificationPermissionStatus.unknown;
  final bool supported;
  final bool canOpenSettings;
  int permissionRequests = 0;

  @override
  bool get isSupported => supported;

  @override
  bool get supportsApprovalActions => supported;

  @override
  bool get canOpenSystemSettings => canOpenSettings;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
    Map<NotificationKind, String> kindLabels = const <NotificationKind, String>{},
  }) async {}

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    permissionRequests++;
    permission = NotificationPermissionStatus.granted;
    return permission;
  }

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async => null;

  @override
  Future<void> show(NotificationPresentationRequest request) async {}

  @override
  Future<bool> cancel(int notificationId) async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => true;

  @override
  Future<void> dispose() async {}
}

Widget _wrap(NotificationSettingsCubit cubit, Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    home: BlocProvider<NotificationSettingsCubit>.value(
      value: cubit,
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  Future<NotificationSettingsCubit> makeCubit(
    WidgetTester tester,
    _FakeAdapter adapter, {
    Map<String, Object> stored = const <String, Object>{},
    NotificationPreferencesPublisher? publishPreferences,
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    final preferences = await SharedPreferences.getInstance();
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(preferences),
      adapter: adapter,
      publishPreferences: publishPreferences,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  testWidgets('offers the OS permission ask only before the OS was asked', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notification_permission_request_btn')));
    await tester.pumpAndSettle();

    expect(adapter.permissionRequests, 1);
    expect(cubit.state.permission, NotificationPermissionStatus.granted);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
  });

  testWidgets('explains a refusal and offers the system pane instead of asking again',
      (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(
      tester,
      adapter,
      stored: <String, Object>{NotificationPreferencesStore.permissionRequestedKey: true},
    );
    adapter.permission = NotificationPermissionStatus.denied;

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.notificationsPermissionDeniedBody), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
    expect(find.byKey(const ValueKey('notification_open_settings_btn')), findsOneWidget);
  });

  testWidgets('offers no pane button on a platform that cannot open one', (tester) async {
    final adapter = _FakeAdapter(canOpenSettings: false);
    final cubit = await makeCubit(
      tester,
      adapter,
      stored: <String, Object>{NotificationPreferencesStore.permissionRequestedKey: true},
    );
    adapter.permission = NotificationPermissionStatus.denied;

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    // The refusal is still explained; a button that could not open the pane is
    // not offered.
    expect(find.byKey(const ValueKey('notification_open_settings_btn')), findsNothing);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
  });

  testWidgets('keeps every kind enabled by default', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    for (final kind in NotificationKind.values) {
      expect(
        find.byKey(ValueKey('notification_kind_${kind.wire}_toggle')),
        findsOneWidget,
        reason: 'every kind has its own switch',
      );
      expect(cubit.state.isKindEnabled(kind), isTrue);
    }
  });

  testWidgets('persists a per-kind choice without touching the others', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final completedToggle =
        find.byKey(ValueKey('notification_kind_${NotificationKind.completed.wire}_toggle'));
    await tester.ensureVisible(completedToggle);
    await tester.pumpAndSettle();
    await tester.tap(completedToggle);
    await tester.pumpAndSettle();

    expect(cubit.state.isKindEnabled(NotificationKind.completed), isFalse);
    expect(cubit.state.isKindEnabled(NotificationKind.permissionRequest), isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getStringList(NotificationPreferencesStore.disabledKindsKey),
      <String>[NotificationKind.completed.wire],
    );
  });

  testWidgets('the global switch stops every kind switch', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notification_global_toggle')));
    await tester.pumpAndSettle();

    expect(cubit.state.preferences.enabled, isFalse);
    final tile = tester.widget<SwitchListTile>(
      find.byKey(ValueKey('notification_kind_${NotificationKind.blocked.wire}_toggle')),
    );
    expect(tile.onChanged, isNull, reason: 'a disabled global switch cannot be bypassed');
  });

  testWidgets('states that notifications are unavailable without a platform surface',
      (tester) async {
    final adapter = _FakeAdapter(supported: false);
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.notificationsUnsupportedBody), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
  });

  testWidgets('shows each kind with its current urgency and lowers one', (tester) async {
    final adapter = _FakeAdapter();
    // The urgency hint is a delivery claim, so this test states the OS answer it
    // describes: permission granted.
    adapter.permission = NotificationPermissionStatus.granted;
    final published = <NotificationPreferences>[];
    final cubit = await makeCubit(tester, adapter, publishPreferences: published.add);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.notificationsUrgencyAlertHint), findsWidgets,
        reason: 'every enabled kind states the product default urgency');
    expect(find.text(l10n.notificationsPerDeviceScope), findsOneWidget);

    final completedUrgency = find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency'),
    );
    await tester.ensureVisible(completedUrgency);
    await tester.pumpAndSettle();
    await tester.tap(completedUrgency);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency_normal'),
    ));
    await tester.pumpAndSettle();

    expect(cubit.state.ceilingFor(NotificationKind.completed), NotificationUrgency.normal);
    expect(cubit.state.ceilingFor(NotificationKind.failed), NotificationUrgency.defaultUrgency,
        reason: 'lowering one kind leaves the others at the default');
    expect(find.text(l10n.notificationsUrgencyBannerOnlyHint), findsOneWidget);
    expect(published.single.ceilingFor(NotificationKind.completed), NotificationUrgency.normal);

    final stored = await SharedPreferences.getInstance();
    expect(
      stored.getStringList(NotificationPreferencesStore.kindUrgencyKey),
      <String>['completed:normal'],
    );
  });

  testWidgets('the urgency control states its value and changes with it', (tester) async {
    // Plan 174g (M3): the affordance used to be an unlabeled glyph, so `Alert`
    // and `Banner only` rendered identically and the control did not read as a
    // control at rest.
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.granted;
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    final valueKey = ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency_value');
    await tester.ensureVisible(find.byKey(valueKey));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(valueKey)).data,
      l10n.notificationsUrgencyAlert,
      reason: 'the control names the ceiling it will apply',
    );

    final urgency = find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency'),
    );
    final pill = tester.widget<Container>(
      find.descendant(of: urgency, matching: find.byType(Container)).first,
    );
    expect(
      (pill.decoration as BoxDecoration?)?.border,
      isNotNull,
      reason: 'the affordance needs a surface to read as a control, not as an icon',
    );

    await tester.tap(urgency);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency_normal'),
    ));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(valueKey)).data,
      l10n.notificationsUrgencyBannerOnly,
      reason: 'the control shows the state instead of only being able to change it',
    );
    expect(
      tester.widget<Icon>(
        find.descendant(of: urgency, matching: find.byIcon(Icons.volume_off_outlined)),
      ).icon,
      Icons.volume_off_outlined,
      reason: 'the glyph changes with the ceiling',
    );
  });

  testWidgets('the urgency control is exposed as a button to a screen reader', (tester) async {
    // Plan 174g (S4): `PopupMenuButton.child` drops the `button: true` role the
    // icon form emitted through `IconButton`, so the pill states it itself.
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.granted;
    final cubit = await makeCubit(tester, adapter);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency'),
    ));
    // The row merges its children, so the role lands on the pill's own node
    // inside the merged tile rather than on the tile's outer node.
    final button = _firstButtonNode(node);

    expect(button, isNotNull,
        reason: 'a pill a screen reader cannot identify as a control is not a control');
    expect(button!.getSemanticsData().hasAction(SemanticsAction.tap), isTrue,
        reason: 'the pill is activated by the same tap the menu opens with');

    // The framework verifies handles before tear-downs run, so it is released
    // here rather than from a tear-down.
    semantics.dispose();
  });

  testWidgets('the urgency menu uses the vocabulary the row states', (tester) async {
    // Plan 174g (L4): the menu said `Alert` / `Banner only` while the rows said
    // `Banner and sound` / `Banner without sound`, so the user had to translate
    // between two names for one setting.
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.granted;
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    final urgency = find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency'),
    );
    await tester.ensureVisible(urgency);
    await tester.pumpAndSettle();
    await tester.tap(urgency);
    await tester.pumpAndSettle();

    final high = find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency_high'),
    );
    final normal = find.byKey(
      ValueKey('notification_kind_${NotificationKind.completed.wire}_urgency_normal'),
    );

    expect(find.descendant(of: high, matching: find.text(l10n.notificationsUrgencyAlert)), findsOneWidget);
    expect(
      find.descendant(of: high, matching: find.text(l10n.notificationsUrgencyAlertHint)),
      findsOneWidget,
      reason: 'the menu states the delivery in the words the row uses',
    );
    expect(find.descendant(of: normal, matching: find.text(l10n.notificationsUrgencyBannerOnly)), findsOneWidget);
    expect(
      find.descendant(of: normal, matching: find.text(l10n.notificationsUrgencyBannerOnlyHint)),
      findsOneWidget,
      reason: 'the same vocabulary, with the delivery that makes it meaningful',
    );

    // Plan 174g (L5): the unselected item starts where the selected one starts.
    final highOffset = tester.getTopLeft(
      find.descendant(of: high, matching: find.text(l10n.notificationsUrgencyAlert)),
    ).dx;
    final normalOffset = tester.getTopLeft(
      find.descendant(of: normal, matching: find.text(l10n.notificationsUrgencyBannerOnly)),
    ).dx;
    expect(normalOffset, highOffset,
        reason: 'the check slot is reserved, so nothing shifts when the selection moves');
  });

  testWidgets('the test card names the kind the probe follows', (tester) async {
    // Plan 174g (L6): the probe borrows a real kind, so a quietened row produced
    // a quieter test with no explanation of why.
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.granted;
    final cubit = await makeCubit(tester, adapter);
    cubit.attachTestSender(
      () async => NotificationDisplayOutcome.display,
      kind: NotificationKind.completed,
    );

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    final kindLabel = NotificationCopySource(l10n).labelFor(NotificationKind.completed);
    final notice = find.byKey(const ValueKey('notification_test_kind_notice'));
    await tester.ensureVisible(notice);
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsTestKindNotice(kindLabel)), findsOneWidget);
  });

  testWidgets('reports a revoked OS permission while the in-app switch stays on', (tester) async {
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.denied;
    final cubit = await makeCubit(
      tester,
      adapter,
      stored: <String, Object>{NotificationPreferencesStore.permissionRequestedKey: true},
    );

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(cubit.state.permissionDeniedWhileEnabled, isTrue);
    expect(find.byKey(const ValueKey('notification_permission_conflict')), findsOneWidget);
    expect(find.text(l10n.notificationsPermissionDeniedWhileEnabled), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_open_settings_btn')), findsOneWidget);
  });

  testWidgets('the rows state the OS block instead of a delivery claim', (tester) async {
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.denied;
    final cubit = await makeCubit(
      tester,
      adapter,
      stored: <String, Object>{NotificationPreferencesStore.permissionRequestedKey: true},
    );

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.notificationsUrgencyBlockedByPermission), findsWidgets,
        reason: 'a revoked permission means nothing is delivered, so no row may claim a banner');
    expect(find.text(l10n.notificationsUrgencyAlertHint), findsNothing);
    expect(find.text(l10n.notificationsUrgencyBannerOnlyHint), findsNothing);
  });

  testWidgets('the test action reports the pipeline outcome in the page', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);
    cubit.attachTestSender(() async => NotificationDisplayOutcome.display);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    final button = find.byKey(const ValueKey('notification_test_btn'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notification_test_outcome')), findsOneWidget);
    expect(find.text(l10n.notificationsTestShown), findsOneWidget);
  });

  testWidgets('a refused platform call is reported as a failure, not as sent', (tester) async {
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.granted;
    final cubit = await makeCubit(tester, adapter);
    cubit.attachTestSender(() async => NotificationDisplayOutcome.presentationFailed);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    final button = find.byKey(const ValueKey('notification_test_btn'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsTestFailed), findsOneWidget);
    expect(find.text(l10n.notificationsTestShown), findsNothing,
        reason: 'a call the platform refused must never be presented as success');
  });

  testWidgets('the test action stays unavailable without the running pipeline', (tester) async {
    final adapter = _FakeAdapter();
    adapter.permission = NotificationPermissionStatus.granted;
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('notification_test_btn')),
    );
    expect(button.onPressed, isNull,
        reason: 'Settings cannot raise a notification without the pipeline that owns the action');
  });

  testWidgets('a suppressed test explains the setting that stopped it', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);
    cubit.attachTestSender(() async => NotificationDisplayOutcome.suppressedPermission);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.ensureVisible(find.byKey(const ValueKey('notification_test_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notification_test_btn')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsTestPermissionDenied), findsOneWidget);
  });

  testWidgets('states that OS settings always win', (tester) async {
    final adapter = _FakeAdapter();
    final cubit = await makeCubit(tester, adapter);

    await tester.pumpWidget(_wrap(cubit, const NotificationsPage()));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.ensureVisible(find.byKey(const ValueKey('notification_limits_card')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsLimitsTitle), findsOneWidget);
    expect(find.text(l10n.notificationsLimitsOsWins), findsOneWidget);
  });

  testWidgets('the Settings navigation offers a notifications entry', (tester) async {
    final selected = <SettingsDestination>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Scaffold(
          body: SettingsNavigation(
            devices: const [],
            activeDeviceId: null,
            selectedDevice: null,
            selectedDestination: SettingsDestination.general,
            workspaces: const [],
            selectedWorkspaceId: null,
            showAllWorkspaces: false,
            onSelectPersonal: selected.add,
            onSelectDevice: (_) {},
            onSelectDeviceSection: (_) {},
            onSelectWorkspace: (_) {},
            onToggleWorkspaces: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('nav_tile_notifications')));
    await tester.pump();

    expect(selected, <SettingsDestination>[SettingsDestination.notifications]);
  });
}

/// The first node in [root]'s subtree that is a button, including [root].
SemanticsNode? _firstButtonNode(SemanticsNode root) {
  if (root.getSemanticsData().flagsCollection.isButton) return root;
  SemanticsNode? found;
  root.visitChildren((SemanticsNode child) {
    found = found ?? _firstButtonNode(child);
    return found != null;
  });
  return found;
}
