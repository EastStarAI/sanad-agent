import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';

/// The platform pair the notification pipeline composes.
///
/// One bundle exists per build: a native build pairs its OS adapter with a
/// no-op web push client, and the web build pairs its browser adapter with the
/// real push client. Both are created from the same runtime on web, so the
/// worker registration, the permission read, and the presented notification
/// have exactly one owner.
class NotificationPlatformBundle {
  NotificationPlatformBundle({
    required this.adapter,
    required this.webPush,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  final NotificationPlatformAdapter adapter;
  final WebPushClient webPush;
  final Future<void> Function() _dispose;

  Future<void> dispose() async {
    await adapter.dispose();
    await webPush.dispose();
    await _dispose();
  }
}
