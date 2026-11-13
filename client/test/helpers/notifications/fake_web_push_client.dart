import 'dart:async';

import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';

/// Records what the pipeline asked the platform to present.
class FakeNotificationAdapter implements NotificationPlatformAdapter {
  FakeNotificationAdapter({
    this.isSupported = true,
    this.permission = NotificationPermissionStatus.granted,
  });

  @override
  final bool isSupported;

  NotificationPermissionStatus permission;
  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];
  final List<int> cancelled = <int>[];
  int permissionRequests = 0;
  bool initialized = false;

  @override
  bool get supportsApprovalActions => false;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels = const <NotificationActionIntent, String>{},
  }) async {
    initialized = true;
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<void> show(NotificationPresentationRequest request) async => shown.add(request);

  @override
  Future<bool> cancel(int notificationId) async {
    cancelled.add(notificationId);
    return true;
  }

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> dispose() async {}
}

/// A browser boundary with no browser, so the lifecycle is proven by data.
class FakeWebPushClient implements WebPushClient {
  FakeWebPushClient({
    this.isWebPlatform = true,
    this.availability = WebPushAvailability.ready,
    this.permission = NotificationPermissionStatus.granted,
  });

  @override
  final bool isWebPlatform;

  @override
  WebPushAvailability availability;

  NotificationPermissionStatus permission;
  WebPushSubscription? subscription;
  int permissionRequests = 0;
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  int workerRegistrations = 0;
  String? lastApplicationServerKey;
  final List<WebPushDisplayPolicy> policies = <WebPushDisplayPolicy>[];
  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];
  final List<int> cancelled = <int>[];
  Map<String, String>? pendingOpen;
  bool failSubscribe = false;

  final StreamController<Map<String, dynamic>> _pushEnvelopes = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<WebPushInteraction> _interactions = StreamController<WebPushInteraction>.broadcast();
  final StreamController<WebPushSubscription> _rotations = StreamController<WebPushSubscription>.broadcast();

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    permissionRequests++;
    permission = NotificationPermissionStatus.granted;
    return permission;
  }

  @override
  Future<void> ensureServiceWorker() async => workerRegistrations++;

  @override
  Future<WebPushSubscription?> currentSubscription() async => subscription;

  @override
  Future<WebPushSubscription?> subscribe({required String applicationServerKey}) async {
    subscribeCalls++;
    lastApplicationServerKey = applicationServerKey;
    if (failSubscribe) return null;
    subscription = WebPushSubscription(
      endpoint: 'https://push.example/$subscribeCalls',
      p256dh: 'p256dh-key',
      auth: 'auth-key',
    );
    return subscription;
  }

  @override
  Future<void> unsubscribe() async {
    unsubscribeCalls++;
    subscription = null;
  }

  @override
  Future<void> show({
    required int notificationId,
    required String title,
    required String body,
    required String presentationPayload,
  }) async {
    shown.add(
      NotificationPresentationRequest(
        id: notificationId,
        title: title,
        body: body,
        urgency: NotificationUrgency.high,
        payload: presentationPayload,
      ),
    );
  }

  @override
  Future<bool> cancel(int notificationId) async {
    cancelled.add(notificationId);
    return true;
  }

  @override
  Stream<Map<String, dynamic>> get pushEnvelopes => _pushEnvelopes.stream;

  @override
  Stream<WebPushInteraction> get interactions => _interactions.stream;

  @override
  Stream<WebPushSubscription> get rotatedSubscriptions => _rotations.stream;

  @override
  Future<void> publishDisplayPolicy(WebPushDisplayPolicy policy) async => policies.add(policy);

  @override
  Map<String, String>? takePendingOpen() {
    final pending = pendingOpen;
    pendingOpen = null;
    return pending;
  }

  @override
  Future<void> dispose() async {
    await _pushEnvelopes.close();
    await _interactions.close();
    await _rotations.close();
  }
}
