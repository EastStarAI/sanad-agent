import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/application/web_push_subscription_service.dart';
import 'package:sanad_client/features/notifications/data/web_push_subscription_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/repositories/web_push_subscription_registrar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/notifications/fake_web_push_client.dart';

class _RecordingRegistrar implements WebPushSubscriptionRegistrar {
  _RecordingRegistrar();

  WebPushRegistrationOutcome registerOutcome = WebPushRegistrationOutcome.registered;
  WebPushRegistrationOutcome revokeOutcome = WebPushRegistrationOutcome.revoked;
  bool unreachable = false;
  final List<WebPushSubscription> registered = <WebPushSubscription>[];
  final List<String> registeredTokens = <String>[];
  final List<String> revoked = <String>[];
  String? lastClientInstanceId;

  @override
  Future<WebPushRegistrationOutcome> register(
    WebPushSubscription subscription, {
    required String accessToken,
    required String clientInstanceId,
    DateTime? createdAt,
  }) async {
    registered.add(subscription);
    registeredTokens.add(accessToken);
    lastClientInstanceId = clientInstanceId;
    if (unreachable) throw const SocketException('relay is unreachable');
    return registerOutcome;
  }

  @override
  Future<WebPushRegistrationOutcome> revoke(String endpoint, {required String accessToken}) async {
    revoked.add(endpoint);
    return revokeOutcome;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebPushClient client;
  late _RecordingRegistrar registrar;
  late SharedPreferences preferences;
  late WebPushSubscriptionStore store;
  late String? accessToken;
  late String? accountId;
  late String? vapidKey;
  late WebPushSubscriptionService service;

  Future<void> harness({
    WebPushAvailability availability = WebPushAvailability.ready,
    NotificationPermissionStatus permission = NotificationPermissionStatus.unknown,
    String? token = 'token-1',
    String? account = 'account-1',
    String? vapid = 'BPublicKeyForTests',
    WebPushSubscription? subscription,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
    client = FakeWebPushClient(
      availability: availability,
      permission: permission,
    )..subscription = subscription;
    registrar = _RecordingRegistrar();
    store = WebPushSubscriptionStore(preferences);
    accessToken = token;
    accountId = account;
    vapidKey = vapid;
    service = WebPushSubscriptionService(
      client: client,
      registrar: registrar,
      store: store,
      readAccessToken: () => accessToken,
      readAccountId: () => accountId,
      readClientInstanceId: () => 'client-instance-1',
      readVapidPublicKey: () => vapidKey,
    );
    addTearDown(service.dispose);
    addTearDown(client.dispose);
  }

  group('web push availability', () {
    test('an uninstalled iOS Safari session is told to install', () async {
      await harness(availability: WebPushAvailability.installRequired);

      final settings = await service.refresh();

      expect(settings.availability, WebPushAvailability.installRequired);
      expect(settings.canSubscribe, isFalse);
      expect(client.permissionRequests, 0, reason: 'refresh never prompts');
    });

    test('a build without a VAPID public key reports unconfigured', () async {
      await harness(vapid: '');

      final settings = await service.refresh();

      expect(settings.availability, WebPushAvailability.unconfigured);
      expect(settings.canSubscribe, isFalse);
    });

    test('a native build never reports a web surface', () async {
      await harness();
      client = FakeWebPushClient(isWebPlatform: false);
      service = WebPushSubscriptionService(
        client: client,
        registrar: registrar,
        store: store,
        readAccessToken: () => accessToken,
        readAccountId: () => accountId,
        readClientInstanceId: () => 'client-instance-1',
        readVapidPublicKey: () => vapidKey,
      );

      final settings = await service.refresh();

      expect(settings.isWebPlatform, isFalse);
      expect(settings.availability, WebPushAvailability.unsupported);
    });
  });

  group('explicit enable', () {
    test('refuses without an authenticated account session', () async {
      await harness(token: null);

      final settings = await service.enable();

      expect(settings.failure, WebPushFailure.signInRequired);
      expect(client.permissionRequests, 0);
      expect(client.subscribeCalls, 0);
      expect(registrar.registered, isEmpty);
    });

    test('asks permission, subscribes with the public key, and registers the account', () async {
      await harness();

      final settings = await service.enable();

      expect(settings.status, WebPushSubscriptionStatus.subscribed);
      expect(settings.failure, WebPushFailure.none);
      expect(client.permissionRequests, 1, reason: 'the prompt runs only from this action');
      expect(client.subscribeCalls, 1);
      expect(client.lastApplicationServerKey, 'BPublicKeyForTests');
      expect(registrar.registered, hasLength(1));
      expect(registrar.registeredTokens.single, 'token-1');
      expect(registrar.lastClientInstanceId, 'client-instance-1');
      expect(store.read()?.endpoint, client.subscription!.endpoint);
      expect(store.read()?.accountId, 'account-1');
    });

    test('a refused permission creates no subscription', () async {
      await harness(permission: NotificationPermissionStatus.denied);

      final settings = await service.enable();

      expect(settings.failure, WebPushFailure.permissionDenied);
      expect(settings.status, WebPushSubscriptionStatus.notSubscribed);
      expect(client.subscribeCalls, 0);
      expect(registrar.registered, isEmpty);
    });

    test('a relay failure keeps the browser subscription for the next attempt', () async {
      await harness();
      registrar.registerOutcome = WebPushRegistrationOutcome.unavailable;

      final failed = await service.enable();

      expect(failed.failure, WebPushFailure.registrationFailed);
      expect(failed.status, WebPushSubscriptionStatus.notSubscribed);
      expect(client.subscription, isNotNull, reason: 'the permission must not be lost');
      expect(store.read(), isNull, reason: 'an unregistered endpoint is not account state');

      registrar.registerOutcome = WebPushRegistrationOutcome.registered;
      final retried = await service.enable();

      expect(retried.failure, WebPushFailure.none);
      expect(retried.status, WebPushSubscriptionStatus.subscribed);
      expect(client.permissionRequests, 1, reason: 'the second attempt reuses the permission');
      expect(client.subscribeCalls, 1, reason: 'the existing browser subscription is reused');
      expect(registrar.registered, hasLength(2));
    });
  });

  group('relay acknowledgement', () {
    const browserSubscription = WebPushSubscription(
      endpoint: 'https://push.example/existing',
      p256dh: 'p',
      auth: 'a',
    );

    test('a refused registration is reported as a failure, not as delivery', () async {
      await harness();
      registrar.registerOutcome = WebPushRegistrationOutcome.failed;

      final refused = await service.enable();

      expect(refused.status, WebPushSubscriptionStatus.notSubscribed);
      expect(refused.failure, WebPushFailure.registrationFailed);
      expect(client.subscription, isNotNull, reason: 'a refusal is not a permission reset');
    });

    test('an unreachable relay is reported as an unacknowledged registration', () async {
      await harness();
      registrar.unreachable = true;

      final refused = await service.enable();

      expect(refused.status, WebPushSubscriptionStatus.notSubscribed);
      expect(refused.failure, WebPushFailure.registrationFailed);
      expect(store.read(), isNull);
      expect(client.subscription, isNotNull);
    });

    test('reopening Settings cannot turn a refused registration into delivery', () async {
      await harness();
      registrar.registerOutcome = WebPushRegistrationOutcome.unavailable;
      await service.enable();

      final reloaded = await service.refresh();

      expect(reloaded.status, WebPushSubscriptionStatus.notSubscribed);
      expect(
        reloaded.failure,
        WebPushFailure.registrationFailed,
        reason: 'the status follows the relay acknowledgement, not the browser',
      );
    });

    test('a browser subscription the relay never saw is unacknowledged', () async {
      await harness(subscription: browserSubscription);

      final settings = await service.refresh();

      expect(settings.status, WebPushSubscriptionStatus.notSubscribed);
      expect(settings.failure, WebPushFailure.registrationFailed);
      expect(client.permissionRequests, 0, reason: 'a read never prompts');
    });

    test('a later acknowledgement clears the reported failure', () async {
      await harness();
      registrar.registerOutcome = WebPushRegistrationOutcome.unavailable;
      await service.enable();
      expect(service.settings.failure, WebPushFailure.registrationFailed);

      registrar.registerOutcome = WebPushRegistrationOutcome.registered;
      final retried = await service.enable();
      final reloaded = await service.refresh();

      expect(retried.status, WebPushSubscriptionStatus.subscribed);
      expect(retried.failure, WebPushFailure.none);
      expect(reloaded.status, WebPushSubscriptionStatus.subscribed);
      expect(reloaded.failure, WebPushFailure.none);
    });

    test('startup synchronization reports a refusal instead of delivery', () async {
      await harness(subscription: browserSubscription);
      registrar.registerOutcome = WebPushRegistrationOutcome.unauthorized;

      final refused = await service.synchronize();

      expect(refused.status, WebPushSubscriptionStatus.notSubscribed);
      expect(refused.failure, WebPushFailure.registrationFailed);
      expect(client.permissionRequests, 0);

      registrar.registerOutcome = WebPushRegistrationOutcome.registered;
      final repaired = await service.synchronize();

      expect(repaired.status, WebPushSubscriptionStatus.subscribed);
      expect(repaired.failure, WebPushFailure.none);
    });

    test('a request for this browser endpoint is not inherited by another account', () async {
      await harness(subscription: browserSubscription);
      await store.write(
        const WebPushSubscriptionRecord(
          endpoint: 'https://push.example/existing',
          accountId: 'account-0',
          clientInstanceId: 'client-instance-1',
        ),
      );

      final settings = await service.refresh();

      expect(settings.status, WebPushSubscriptionStatus.notSubscribed);
      expect(settings.failure, WebPushFailure.registrationFailed);
    });

    test('a signed-out browser reports that delivery needs a session', () async {
      await harness(token: null, subscription: browserSubscription);

      final settings = await service.refresh();

      expect(settings.status, WebPushSubscriptionStatus.notSubscribed);
      expect(settings.failure, WebPushFailure.signInRequired);
    });
  });

  group('startup synchronization', () {
    test('registers an existing browser subscription without prompting', () async {
      await harness(
        subscription: const WebPushSubscription(
          endpoint: 'https://push.example/existing',
          p256dh: 'p',
          auth: 'a',
        ),
      );

      final settings = await service.synchronize();

      expect(settings.status, WebPushSubscriptionStatus.subscribed);
      expect(client.permissionRequests, 0);
      expect(client.subscribeCalls, 0);
      expect(registrar.registered.single.endpoint, 'https://push.example/existing');
      expect(store.read()?.accountId, 'account-1');
    });

    test('re-registers an endpoint that belonged to another account', () async {
      await harness(
        subscription: const WebPushSubscription(
          endpoint: 'https://push.example/existing',
          p256dh: 'p',
          auth: 'a',
        ),
      );
      await store.write(
        const WebPushSubscriptionRecord(
          endpoint: 'https://push.example/existing',
          accountId: 'account-0',
          clientInstanceId: 'client-instance-1',
        ),
      );

      await service.synchronize();

      expect(registrar.registered, hasLength(1));
      expect(store.read()?.accountId, 'account-1');
    });

    test('a signed-out browser drops the subscription it kept', () async {
      await harness(
        token: null,
        subscription: const WebPushSubscription(
          endpoint: 'https://push.example/existing',
          p256dh: 'p',
          auth: 'a',
        ),
      );

      final settings = await service.synchronize();

      expect(settings.status, WebPushSubscriptionStatus.notSubscribed);
      expect(client.unsubscribeCalls, 1);
      expect(registrar.registered, isEmpty);
      expect(store.read(), isNull);
    });
  });

  group('revocation and rotation', () {
    test('logout revokes with the captured token and unsubscribes', () async {
      await harness();
      await service.enable();
      expect(store.read(), isNotNull);

      await service.revokeForLogout(accessToken: 'token-at-logout');

      expect(registrar.revoked.single, 'https://push.example/1');
      expect(client.unsubscribeCalls, 1);
      expect(store.read(), isNull);
      expect(service.settings.status, WebPushSubscriptionStatus.notSubscribed);
    });

    test('a rotated endpoint is registered again', () async {
      await harness();
      await service.enable();

      await service.onSubscriptionRotated(
        const WebPushSubscription(
          endpoint: 'https://push.example/rotated',
          p256dh: 'p2',
          auth: 'a2',
        ),
      );

      expect(registrar.registered.last.endpoint, 'https://push.example/rotated');
      expect(store.read()?.endpoint, 'https://push.example/rotated');
    });

    test('disabling revokes and unsubscribes', () async {
      await harness();
      await service.enable();

      final settings = await service.disable();

      expect(settings.status, WebPushSubscriptionStatus.notSubscribed);
      expect(registrar.revoked, hasLength(1));
      expect(client.unsubscribeCalls, 1);
      expect(store.read(), isNull);
    });
  });

  test('the display policy is mirrored for the closed-tab worker', () async {
    await harness();

    await service.publishDisplayPolicy(
      const WebPushDisplayPolicy(enabled: false, mutedKinds: <NotificationKind>{NotificationKind.failed}),
    );

    expect(client.policies.single.enabled, isFalse);
    expect(client.policies.single.mutedKinds, <NotificationKind>{NotificationKind.failed});
  });
}
