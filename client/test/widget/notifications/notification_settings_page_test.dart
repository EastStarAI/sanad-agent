import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_navigation.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/notifications_page.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements NotificationPlatformAdapter {
  _FakeAdapter({this.supported = true});

  NotificationPermissionStatus permission = NotificationPermissionStatus.unknown;
  final bool supported;
  int permissionRequests = 0;

  @override
  bool get isSupported => supported;

  @override
  bool get supportsApprovalActions => supported;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
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
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    final preferences = await SharedPreferences.getInstance();
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(preferences),
      adapter: adapter,
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
