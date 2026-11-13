import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Maps the notification taxonomy to localized copy.
///
/// The Agent renders the copy that ships in a payload and it always wins. This
/// exists for the two cases where the Client must speak for itself: a payload
/// whose copy was emptied, and the labels the macOS notification category fixes
/// when it is registered at startup.
class NotificationCopySource {
  const NotificationCopySource(this._localizations);

  final AppLocalizations _localizations;

  /// Neutral stand-in for the ask sentence when a payload arrives without copy.
  String get _askFallback => _localizations.notificationsAskFallback;

  /// Buttons offered with an approval ask, in the order the OS shows them.
  Map<NotificationActionIntent, String> get approvalActionLabels =>
      <NotificationActionIntent, String>{
        NotificationActionIntent.allowOnce: _localizations.notificationActionAllowOnce,
        NotificationActionIntent.allowSession: _localizations.notificationActionAllowSession,
        NotificationActionIntent.deny: _localizations.notificationActionDeny,
        NotificationActionIntent.open: _localizations.notificationActionOpen,
      };

  NotificationCopy copyFor(NotificationKind kind) => NotificationCopy(
        title: _title(kind),
        body: _body(kind),
        actionLabels: approvalActionLabels,
      );

  /// Copy for the user-pressed test notification.
  ///
  /// It says what it is, so a probe can never be mistaken for an Agent decision,
  /// and it offers no buttons because there is nothing to answer.
  NotificationCopy get testNotificationCopy => NotificationCopy(
        title: _localizations.notificationsTestNotificationTitle,
        body: _localizations.notificationsTestNotificationBody,
        actionLabels: const <NotificationActionIntent, String>{},
      );

  String _title(NotificationKind kind) => switch (kind) {
        NotificationKind.permissionRequest => _localizations.notificationPermissionRequestTitle,
        NotificationKind.userQuestion => _localizations.notificationUserQuestionTitle,
        NotificationKind.blocked => _localizations.notificationBlockedTitle,
        NotificationKind.failed => _localizations.notificationFailedTitle,
        NotificationKind.completed => _localizations.notificationCompletedTitle,
        NotificationKind.backgroundTaskDone => _localizations.notificationBackgroundTaskDoneTitle,
        NotificationKind.scheduledResult => _localizations.notificationScheduledResultTitle,
        NotificationKind.providerQuota => _localizations.notificationProviderQuotaTitle,
        NotificationKind.connectionLost => _localizations.notificationConnectionLostTitle,
        NotificationKind.authRequired => _localizations.notificationAuthRequiredTitle,
      };

  String _body(NotificationKind kind) => switch (kind) {
        NotificationKind.permissionRequest => _localizations
            .notificationPermissionRequestBody(_askFallback),
        NotificationKind.userQuestion =>
          _localizations.notificationUserQuestionBody(_askFallback),
        NotificationKind.blocked => _localizations.notificationBlockedBody,
        NotificationKind.failed =>
          _localizations.notificationFailedBody(_askFallback),
        NotificationKind.completed =>
          _localizations.notificationCompletedBody(_askFallback),
        NotificationKind.backgroundTaskDone =>
          _localizations.notificationBackgroundTaskDoneBody(_askFallback),
        NotificationKind.scheduledResult =>
          _localizations.notificationScheduledResultBody(_askFallback),
        NotificationKind.providerQuota =>
          _localizations.notificationProviderQuotaBody(_askFallback),
        NotificationKind.connectionLost => _localizations.notificationConnectionLostBody,
        NotificationKind.authRequired => _localizations.notificationAuthRequiredBody,
      };

  /// The localized label for one kind, used by the per-kind Settings switches.
  String labelFor(NotificationKind kind) => switch (kind) {
        NotificationKind.permissionRequest => _localizations.notificationsKindPermissionRequest,
        NotificationKind.userQuestion => _localizations.notificationsKindUserQuestion,
        NotificationKind.blocked => _localizations.notificationsKindBlocked,
        NotificationKind.failed => _localizations.notificationsKindFailed,
        NotificationKind.completed => _localizations.notificationsKindCompleted,
        NotificationKind.backgroundTaskDone => _localizations.notificationsKindBackgroundTaskDone,
        NotificationKind.scheduledResult => _localizations.notificationsKindScheduledResult,
        NotificationKind.providerQuota => _localizations.notificationsKindProviderQuota,
        NotificationKind.connectionLost => _localizations.notificationsKindConnectionLost,
        NotificationKind.authRequired => _localizations.notificationsKindAuthRequired,
      };
}
