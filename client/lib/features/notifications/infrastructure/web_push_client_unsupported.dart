import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';

/// A total no-op for builds that have no browser surface.
///
/// Reporting [isWebPlatform] as `false` is what keeps Settings honest: no web
/// card is rendered, no subscription is attempted, and the lifecycle service is
/// inert on desktop and mobile.
class UnsupportedWebPushClient implements WebPushClient {
  const UnsupportedWebPushClient();

  @override
  bool get isWebPlatform => false;

  @override
  WebPushAvailability get availability => WebPushAvailability.unsupported;

  @override
  Future<NotificationPermissionStatus> checkPermission() async => NotificationPermissionStatus.unsupported;

  @override
  Future<NotificationPermissionStatus> requestPermission() async => NotificationPermissionStatus.unsupported;

  @override
  Future<void> ensureServiceWorker() async {}

  @override
  Future<WebPushSubscription?> currentSubscription() async => null;

  @override
  Future<WebPushSubscription?> subscribe({required String applicationServerKey}) async => null;

  @override
  Future<void> unsubscribe() async {}

  @override
  Future<void> show({
    required int notificationId,
    required String title,
    required String body,
    required String presentationPayload,
  }) async {}

  @override
  Future<bool> cancel(int notificationId) async => false;

  @override
  Stream<Map<String, dynamic>> get pushEnvelopes => const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<WebPushInteraction> get interactions => const Stream<WebPushInteraction>.empty();

  @override
  Stream<WebPushSubscription> get rotatedSubscriptions => const Stream<WebPushSubscription>.empty();

  @override
  Future<void> publishDisplayPolicy(WebPushDisplayPolicy policy) async {}

  @override
  Map<String, String>? takePendingOpen() => null;

  @override
  Future<void> dispose() async {}
}
