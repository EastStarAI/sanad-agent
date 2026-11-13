import 'notification_backend_unsupported.dart'
    if (dart.library.io) 'notification_backend_native.dart'
    if (dart.library.js_interop) 'notification_backend_web.dart'
    as backend;
import 'notification_bundle.dart';

/// The single local notification path, selected at compile time.
///
/// A native target gets the platform adapter and an inert web push client; a
/// target without `dart:io` (Web) gets the browser runtime, which owns the
/// service worker, the permission gate, the push subscription, and the
/// presentation of a page-decided notification. Nothing above this boundary
/// branches on the platform.
NotificationPlatformBundle createNotificationPlatformBundle() {
  return backend.createNotificationBundle();
}
