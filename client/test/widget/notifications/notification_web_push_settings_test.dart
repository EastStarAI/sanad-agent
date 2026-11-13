import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/features/notifications/application/web_push_subscription_service.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/data/web_push_subscription_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/repositories/web_push_subscription_registrar.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/notifications_page.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/notifications/fake_web_push_client.dart';

class _AcceptingRegistrar implements WebPushSubscriptionRegistrar {
  @override
  Future<WebPushRegistrationOutcome> register(
    WebPushSubscription subscription, {
    required String accessToken,
    required String clientInstanceId,
    DateTime? createdAt,
  }) async => WebPushRegistrationOutcome.registered;

  @override
  Future<WebPushRegistrationOutcome> revoke(String endpoint, {required String accessToken}) async =>
      WebPushRegistrationOutcome.revoked;
}

Widget _wrap(NotificationSettingsCubit cubit) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    home: BlocProvider<NotificationSettingsCubit>.value(
      value: cubit,
      child: const Scaffold(body: NotificationsPage()),
    ),
  );
}

void main() {
  late FakeNotificationAdapter adapter;
  late FakeWebPushClient client;
  late WebPushSubscriptionService service;

  Future<NotificationSettingsCubit> makeCubit(
    WidgetTester tester, {
    WebPushAvailability availability = WebPushAvailability.ready,
    WebPushSubscription? subscription,
    NotificationPermissionStatus permission = NotificationPermissionStatus.unknown,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    adapter = FakeNotificationAdapter(permission: permission);
    client = FakeWebPushClient(availability: availability, permission: permission)..subscription = subscription;
    service = WebPushSubscriptionService(
      client: client,
      registrar: _AcceptingRegistrar(),
      store: WebPushSubscriptionStore(preferences),
      readAccessToken: () => 'token',
      readAccountId: () => 'account',
      readClientInstanceId: () => 'client-instance',
      readVapidPublicKey: () => 'BPublicKeyForTests',
    );
    addTearDown(service.dispose);
    addTearDown(client.dispose);
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(preferences),
      adapter: adapter,
      webPush: service,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  testWidgets('an uninstalled iOS session is told why it cannot work yet', (tester) async {
    final cubit = await makeCubit(tester, availability: WebPushAvailability.installRequired);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_wrap(cubit));
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsWebInstallRequiredBody), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
  });

  testWidgets('a build without a VAPID key explains instead of prompting', (tester) async {
    final cubit = await makeCubit(tester, availability: WebPushAvailability.unconfigured);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_wrap(cubit));
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsWebUnconfiguredBody), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
  });

  testWidgets('the enable action runs the browser lifecycle, not a bare prompt', (tester) async {
    final cubit = await makeCubit(tester);

    await tester.pumpWidget(_wrap(cubit));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notification_permission_request_btn')));
    await tester.pumpAndSettle();

    expect(client.permissionRequests, 1);
    expect(client.subscribeCalls, 1);
    expect(client.workerRegistrations, 1);
    expect(cubit.state.webPush.isSubscribed, isTrue);
    expect(find.byKey(const ValueKey('notification_web_push_disable_btn')), findsOneWidget);
  });

  testWidgets('a subscribed browser offers to turn delivery off', (tester) async {
    final cubit = await makeCubit(
      tester,
      subscription: const WebPushSubscription(
        endpoint: 'https://push.example/existing',
        p256dh: 'p',
        auth: 'a',
      ),
      permission: NotificationPermissionStatus.granted,
    );
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_wrap(cubit));
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsWebEnabledBody), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notification_web_push_disable_btn')));
    await tester.pumpAndSettle();

    expect(client.unsubscribeCalls, 1);
    expect(cubit.state.webPush.isSubscribed, isFalse);
  });

  testWidgets('a refused browser permission offers no dead system-settings button', (tester) async {
    final cubit = await makeCubit(tester, permission: NotificationPermissionStatus.denied);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_wrap(cubit));
    await tester.pumpAndSettle();

    expect(find.text(l10n.notificationsWebPermissionDeniedBody), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_permission_request_btn')), findsNothing);
    expect(find.byKey(const ValueKey('notification_open_settings_btn')), findsNothing);
  });
}
