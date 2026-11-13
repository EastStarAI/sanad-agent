import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_bundle.dart';
import 'package:sanad_client/features/notifications/infrastructure/web_push_client_unsupported.dart';

/// A total no-op adapter for targets with no OS notification surface.
///
/// Reporting [isSupported] as `false` is what keeps the rest of the feature
/// honest: the display policy drops every notification, and Settings states
/// that notifications are unavailable instead of offering a permission button
/// that cannot work.
class UnsupportedNotificationAdapter implements NotificationPlatformAdapter {
  const UnsupportedNotificationAdapter();

  @override
  bool get isSupported => false;

  @override
  bool get supportsApprovalActions => false;

  @override
  bool get canOpenSystemSettings => false;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
    Map<NotificationKind, String> kindLabels = const <NotificationKind, String>{},
  }) async {}

  @override
  Future<NotificationPermissionStatus> checkPermission() async =>
      NotificationPermissionStatus.unsupported;

  @override
  Future<NotificationPermissionStatus> requestPermission() async =>
      NotificationPermissionStatus.unsupported;

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async => null;

  @override
  Future<void> show(NotificationPresentationRequest request) async {}

  @override
  Future<bool> cancel(int notificationId) async => false;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> dispose() async {}
}

NotificationPlatformBundle createNotificationBundle() => NotificationPlatformBundle(
      adapter: const UnsupportedNotificationAdapter(),
      webPush: const UnsupportedWebPushClient(),
      dispose: () async {},
    );
