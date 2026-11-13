import 'package:equatable/equatable.dart';

import 'notification_action.dart';
import 'notification_kind.dart';
import 'notification_permission_status.dart';
import 'notification_urgency.dart';

/// One button on a presented notification, with its label already resolved.
class NotificationPresentationAction extends Equatable {
  const NotificationPresentationAction({required this.id, required this.label});

  final String id;
  final String label;

  @override
  List<Object?> get props => [id, label];
}

/// What the Client asks the platform to present.
///
/// The request is presentation-only: it carries no decision and no transport
/// identity. [payload] is returned verbatim when the user interacts, so the
/// platform layer never needs to understand a session, a request, or a kind.
class NotificationPresentationRequest extends Equatable {
  const NotificationPresentationRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.urgency,
    required this.payload,
    this.actions = const <NotificationPresentationAction>[],
    this.offersApprovalActions = false,
    this.threadId,
    this.androidChannelId,
    this.iosCategoryId,
  });

  /// Stable id derived from the collapse key; the platform replaces the banner
  /// that shares it.
  final int id;

  final String title;
  final String body;
  final NotificationUrgency urgency;

  /// Opaque string echoed back on a response (JSON, owned by the caller).
  final String payload;

  final List<NotificationPresentationAction> actions;

  /// Whether these actions answer an execution decision, so a platform that
  /// supports notification categories can attach its approval category.
  final bool offersApprovalActions;

  /// Groups related notifications on platforms that support threads (macOS,
  /// iOS).
  final String? threadId;

  /// The Android channel to post on, owned by the Client.
  final String? androidChannelId;

  /// The iOS category that fixes the buttons for this notification.
  final String? iosCategoryId;

  @override
  List<Object?> get props => [
        id,
        title,
        body,
        urgency,
        payload,
        actions,
        offersApprovalActions,
        threadId,
        androidChannelId,
        iosCategoryId,
      ];
}

/// A user interaction reported by the platform.
class NotificationPlatformResponse {
  const NotificationPlatformResponse({
    required this.payload,
    this.actionId,
    this.data = const <String, String>{},
  });

  final String payload;

  /// The action the user picked, when the platform reports one.
  final String? actionId;

  /// Platform-specific extras, used only to recover an action identity that a
  /// platform reports outside the action field.
  final Map<String, String> data;
}

typedef NotificationPlatformResponseCallback = void Function(
  NotificationPlatformResponse response,
);

/// The one local notification path the desktop Client uses.
///
/// Every platform that can raise an OS notification implements this contract,
/// and nothing above it branches on the platform. Mobile and web adapters plug
/// into the same boundary later; they are not implemented here.
abstract class NotificationPlatformAdapter {
  /// Whether this build has an OS notification surface to drive.
  bool get isSupported;

  /// Whether notifications of an approval kind can carry buttons on this
  /// platform. A platform that cannot name the button that was pressed must
  /// not show buttons at all, because the Client would have to guess a
  /// decision.
  bool get supportsApprovalActions;

  /// Whether [openSystemSettings] can actually open this application's
  /// notification pane. Where it cannot, Settings explains the refusal instead
  /// of offering a button that does nothing.
  bool get canOpenSystemSettings;

  /// Prepares the platform channel. [approvalActionLabels] are the localized
  /// labels used where the platform fixes button copy when the notification
  /// category is registered (macOS, iOS), and [kindLabels] names the Android
  /// channels the Client owns, because a channel name is user-visible and is
  /// fixed when the channel is created.
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
    Map<NotificationKind, String> kindLabels = const <NotificationKind, String>{},
  });

  /// Reads the current OS permission without ever prompting.
  Future<NotificationPermissionStatus> checkPermission();

  /// Asks the operating system, and only ever from an explicit user action.
  Future<NotificationPermissionStatus> requestPermission();

  Future<void> show(NotificationPresentationRequest request);

  /// Removes a presented notification. A platform without package identity may
  /// not be able to do this; the implementation reports whether it happened.
  Future<bool> cancel(int notificationId);

  Future<void> cancelAll();

  /// Opens the OS notification settings for this app, returning whether the
  /// pane could be opened. Only used after a refusal, where the OS offers no
  /// second prompt.
  Future<bool> openSystemSettings();

  Future<void> dispose();
}
