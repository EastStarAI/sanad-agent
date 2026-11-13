import '../models/notification_permission_status.dart';
import '../models/web_push_capability.dart';
import '../models/web_push_display_policy.dart';
import '../models/web_push_subscription.dart';

/// One interaction the browser reported for a notification it presented.
///
/// The payload is returned verbatim so the page feeds it to the same
/// `NotificationService` and `NotificationActionRouter` a socket event uses.
/// Exactly one of [envelope] and [presented] is normally set: a notification the
/// worker raised from a push carries the canonical envelope, and one the page
/// raised carries the presentation payload the page itself encoded.
class WebPushInteraction {
  const WebPushInteraction({this.envelope, this.presented, this.actionId});

  /// The canonical Agent envelope, when the worker raised the notification.
  final Map<String, dynamic>? envelope;

  /// The page-owned presentation payload, when the page raised it.
  final Map<String, dynamic>? presented;

  /// The action the user pressed, or `null` for a plain click.
  final String? actionId;

  bool get isEmpty => envelope == null && presented == null;
}

/// The browser boundary for web push.
///
/// Everything here is transport and permission. The decision to display, the
/// dedupe identity, the collapse key, and the action outcome belong to the
/// existing notification pipeline; this boundary only answers what the browser
/// did.
abstract class WebPushClient {
  /// Whether this build is the web Client. A native build reports `false` and
  /// every other member is a total no-op.
  bool get isWebPlatform;

  /// What this browser can do, decided synchronously from feature detection.
  /// It never prompts.
  WebPushAvailability get availability;

  /// Reads the browser's permission without prompting.
  Future<NotificationPermissionStatus> checkPermission();

  /// Prompts the browser. Called only from an explicit user action.
  Future<NotificationPermissionStatus> requestPermission();

  /// Registers the owned worker (idempotent) and waits for it to activate.
  Future<void> ensureServiceWorker();

  /// The subscription this browser already holds, if any.
  Future<WebPushSubscription?> currentSubscription();

  /// Creates or reuses a subscription for [applicationServerKey].
  Future<WebPushSubscription?> subscribe({required String applicationServerKey});

  /// Unsubscribes this browser and drops the registration it holds.
  Future<void> unsubscribe();

  /// Renders a notification through the owned worker, so a page-raised and a
  /// worker-raised notification share one tag and one click path.
  Future<void> show({
    required int notificationId,
    required String title,
    required String body,
    required String presentationPayload,
  });

  /// Removes the notification with [notificationId].
  Future<bool> cancel(int notificationId);

  /// Canonical envelopes the worker forwarded because a visible tab is
  /// authoritative for its own display decision.
  Stream<Map<String, dynamic>> get pushEnvelopes;

  /// Clicks and action presses on a notification the worker presented.
  Stream<WebPushInteraction> get interactions;

  /// Endpoint rotations reported by the worker.
  Stream<WebPushSubscription> get rotatedSubscriptions;

  /// Mirrors the user's display policy for the closed-tab path.
  Future<void> publishDisplayPolicy(WebPushDisplayPolicy policy);

  /// Consumes a launch URL that names the session a notification pointed at.
  /// Returns `null` when the page was not opened from a notification.
  Map<String, String>? takePendingOpen();

  Future<void> dispose();
}
