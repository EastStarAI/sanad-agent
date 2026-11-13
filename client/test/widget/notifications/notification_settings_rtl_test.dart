// Plan 174f — Arabic layout and right-to-left rendering of the notification
// settings surface.
//
// The page is the one place a user controls notifications, so it has to read as
// Arabic rather than as translated English: every string comes from the `ar`
// locale, the column flows right to left, and no English notification label
// leaks through.

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
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/notifications_page.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements NotificationPlatformAdapter {
  @override
  bool get isSupported => true;

  @override
  bool get supportsApprovalActions => true;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
  }) async {}

  @override
  Future<NotificationPermissionStatus> checkPermission() async => NotificationPermissionStatus.granted;

  @override
  Future<NotificationPermissionStatus> requestPermission() async => NotificationPermissionStatus.granted;

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

final RegExp _arabicScript = RegExp(r'[\u0600-\u06FF]');

void main() {
  testWidgets('the notifications page renders right to left in Arabic', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
      adapter: _FakeAdapter(),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: BlocProvider<NotificationSettingsCubit>.value(
          value: cubit,
          child: const Scaffold(body: NotificationsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final arabic = lookupAppLocalizations(const Locale('ar'));
    final english = lookupAppLocalizations(const Locale('en'));

    expect(find.text(arabic.notifications), findsOneWidget);
    expect(find.text(arabic.notificationsAllow), findsOneWidget);
    expect(find.text(arabic.notificationsPerDeviceScope), findsOneWidget);
    expect(find.text(arabic.notificationsTestTitle), findsOneWidget);
    expect(find.text(arabic.notificationsUrgencyAlertHint), findsWidgets);

    // Nothing English reaches the page.
    expect(find.text(english.notificationsAllow), findsNothing);
    expect(find.text(english.notificationsTestTitle), findsNothing);
    expect(find.text(english.notificationsLimitsOsWins), findsNothing);

    // The whole column is laid out right to left, not just translated.
    final directionality = Directionality.of(
      tester.element(find.byKey(const ValueKey('notification_global_toggle'))),
    );
    expect(directionality, TextDirection.rtl);

    final pageDirection = Directionality.of(
      tester.element(find.byKey(const ValueKey('notification_per_device_scope'))),
    );
    expect(pageDirection, TextDirection.rtl,
        reason: 'every notification row inherits the Arabic direction');
  });

  test('every kind label and urgency label is authored in Arabic', () {
    final arabic = NotificationCopySource(lookupAppLocalizations(const Locale('ar')));
    final english = NotificationCopySource(lookupAppLocalizations(const Locale('en')));

    for (final kind in NotificationKind.values) {
      final label = arabic.labelFor(kind);
      expect(_arabicScript.hasMatch(label), isTrue, reason: '${kind.wire} has no Arabic label');
      expect(label, isNot(english.labelFor(kind)), reason: '${kind.wire} label is not translated');
    }

    final l10n = lookupAppLocalizations(const Locale('ar'));
    for (final value in <String>[
      l10n.notificationsUrgencyAlert,
      l10n.notificationsUrgencyAlertHint,
      l10n.notificationsUrgencyBannerOnly,
      l10n.notificationsUrgencyBannerOnlyHint,
      l10n.notificationsUrgencyOff,
      l10n.notificationsUrgencyChange,
      l10n.notificationsLimitsTitle,
      l10n.notificationsLimitsOsWins,
      l10n.notificationsLimitsIosWebApp,
      l10n.notificationsTestButton,
      l10n.notificationsTestShown,
      l10n.notificationsTestKindDisabled,
      l10n.notificationsTestPermissionDenied,
      l10n.notificationsTestUnsupported,
      l10n.notificationsTestFailed,
      l10n.notificationsPermissionDeniedWhileEnabled,
    ]) {
      expect(_arabicScript.hasMatch(value), isTrue, reason: 'missing Arabic copy: $value');
    }
  });
}
