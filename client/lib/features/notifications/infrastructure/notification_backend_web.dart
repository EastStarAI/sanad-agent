import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_bundle.dart';
import 'package:sanad_client/features/notifications/infrastructure/web_notification_runtime.dart';

/// The browser OS surface: a notification the page decides on is presented by
/// the owned service worker, exactly as one the worker raises from a push.
///
/// Approval buttons are deliberately not offered. Browsers cap the number of
/// actions differently (Chrome two, Safari one, Firefox none), so a set of three
/// approval choices cannot be shown without silently hiding a decision. The
/// banner opens the exact session and request instead, where the user answers
/// through the existing in-app prompt and `tool_permission_response` path.
class WebNotificationAdapter implements NotificationPlatformAdapter {
  WebNotificationAdapter(this._runtime);

  final WebNotificationRuntime _runtime;

  static final Logger _logger = Logger('notifications.web');

  @override
  bool get isSupported => _runtime.hasNotifications;

  @override
  bool get supportsApprovalActions => false;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels = const <NotificationActionIntent, String>{},
  }) async {
    // Clicks arrive through the worker message channel, not this callback, so
    // the pipeline never has two owners for one interaction.
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() => _runtime.checkPermission();

  @override
  Future<NotificationPermissionStatus> requestPermission() => _runtime.requestPermission();

  @override
  Future<void> show(NotificationPresentationRequest request) {
    return _runtime.show(
      notificationId: request.id,
      title: request.title,
      body: request.body,
      presentationPayload: request.payload,
    );
  }

  @override
  Future<bool> cancel(int notificationId) async {
    try {
      return await _runtime.cancel(notificationId);
    } catch (error) {
      _logger.fine('could not withdraw a web notification: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> dispose() async {}
}

/// The browser push surface, delegating to the one runtime the adapter uses.
class WebPlatformPushClient implements WebPushClient {
  WebPlatformPushClient(this._runtime);

  final WebNotificationRuntime _runtime;

  @override
  bool get isWebPlatform => true;

  @override
  WebPushAvailability get availability => _runtime.availability;

  @override
  Future<NotificationPermissionStatus> checkPermission() => _runtime.checkPermission();

  @override
  Future<NotificationPermissionStatus> requestPermission() => _runtime.requestPermission();

  @override
  Future<void> ensureServiceWorker() => _runtime.register();

  @override
  Future<WebPushSubscription?> currentSubscription() => _runtime.currentSubscription();

  @override
  Future<WebPushSubscription?> subscribe({required String applicationServerKey}) =>
      _runtime.subscribe(applicationServerKey: applicationServerKey);

  @override
  Future<void> unsubscribe() => _runtime.unsubscribe();

  @override
  Future<void> show({
    required int notificationId,
    required String title,
    required String body,
    required String presentationPayload,
  }) {
    return _runtime.show(
      notificationId: notificationId,
      title: title,
      body: body,
      presentationPayload: presentationPayload,
    );
  }

  @override
  Future<bool> cancel(int notificationId) => _runtime.cancel(notificationId);

  @override
  Stream<Map<String, dynamic>> get pushEnvelopes => _runtime.pushEnvelopes;

  @override
  Stream<WebPushInteraction> get interactions => _runtime.interactions;

  @override
  Stream<WebPushSubscription> get rotatedSubscriptions => _runtime.rotations;

  @override
  Future<void> publishDisplayPolicy(WebPushDisplayPolicy policy) => _runtime.publishDisplayPolicy(policy);

  @override
  Map<String, String>? takePendingOpen() => _runtime.takePendingOpen();

  @override
  Future<void> dispose() async {}
}

NotificationPlatformBundle createNotificationBundle() {
  final runtime = WebNotificationRuntime();
  return NotificationPlatformBundle(
    adapter: WebNotificationAdapter(runtime),
    webPush: WebPlatformPushClient(runtime),
    dispose: runtime.dispose,
  );
}
