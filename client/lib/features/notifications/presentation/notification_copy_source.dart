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

  String _title(NotificationKind kind) => switch (kind) {
        NotificationKind.permissionRequest => _localizations.notificationTitlePermissionRequest,
        NotificationKind.userQuestion => _localizations.notificationTitleUserQuestion,
        NotificationKind.blocked => _localizations.notificationTitleBlocked,
        NotificationKind.failed => _localizations.notificationTitleFailed,
        NotificationKind.completed => _localizations.notificationTitleCompleted,
        NotificationKind.backgroundTaskDone => _localizations.notificationTitleBackgroundTaskDone,
        NotificationKind.scheduledResult => _localizations.notificationTitleScheduledResult,
        NotificationKind.providerQuota => _localizations.notificationTitleProviderQuota,
        NotificationKind.connectionLost => _localizations.notificationTitleConnectionLost,
        NotificationKind.authRequired => _localizations.notificationTitleAuthRequired,
      };

  String _body(NotificationKind kind) => switch (kind) {
        NotificationKind.permissionRequest => _localizations.notificationBodyPermissionRequest,
        NotificationKind.userQuestion => _localizations.notificationBodyUserQuestion,
        NotificationKind.blocked => _localizations.notificationBodyBlocked,
        NotificationKind.failed => _localizations.notificationBodyFailed,
        NotificationKind.completed => _localizations.notificationBodyCompleted,
        NotificationKind.backgroundTaskDone => _localizations.notificationBodyBackgroundTaskDone,
        NotificationKind.scheduledResult => _localizations.notificationBodyScheduledResult,
        NotificationKind.providerQuota => _localizations.notificationBodyProviderQuota,
        NotificationKind.connectionLost => _localizations.notificationBodyConnectionLost,
        NotificationKind.authRequired => _localizations.notificationBodyAuthRequired,
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
