import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';

import 'notification_backend_unsupported.dart'
    if (dart.library.io) 'notification_backend_native.dart'
    as backend;

/// The single local notification path, selected at compile time.
///
/// A native target gets the platform adapter; a target without `dart:io`
/// (Web) resolves a total no-op, so nothing above this boundary needs a web
/// branch. The adapter itself reports whether its platform can raise an OS
/// notification, which keeps mobile honest until the push task supplies its own
/// adapter.
NotificationPlatformAdapter createPlatformNotificationAdapter() {
  return backend.createNotificationAdapter();
}
