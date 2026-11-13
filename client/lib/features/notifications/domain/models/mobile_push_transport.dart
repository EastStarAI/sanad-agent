import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';

/// The platform wake-up channel for mobile push.
///
/// This boundary knows three things and nothing else: whether a push provider is
/// wired into this build, the messages the provider handed to the app, and the
/// device token the provider issued. It never decides whether a notification is
/// shown, never renders copy, and never answers an ask; those stay in the
/// domain and application layers that desktop already uses.
///
/// Both implementations are compile-time selections, so nothing above this
/// boundary branches on the platform, and a build without a provider resolves a
/// total no-op instead of a channel that throws.
abstract class MobilePushTransport {
  /// Whether this build has a push provider that can issue a token.
  ///
  /// A build without one still shows the in-app pipeline: the socket path and
  /// the foreground rules are platform-neutral, and only the wake-up is missing.
  bool get isSupported;

  /// Notifications the provider delivered while the app was running.
  Stream<MobilePushMessage> get displays;

  /// Interactions with a notification the operating system presented,
  /// including one that launched the app.
  Stream<MobilePushMessage> get interactions;

  /// The message that launched the process, consumed once.
  ///
  /// A terminated Client is started by the tap, not by a socket, so this is the
  /// only way the tapped notification is handled at all.
  Future<MobilePushMessage?> takeInitialMessage();

  /// The token the provider issued, or `null` when the provider has not finished
  /// registering. The value is sensitive and is never logged.
  Future<MobilePushToken?> currentToken();

  /// Token rotations. A rotation must reach the relay, because the previous
  /// token stops delivering.
  Stream<MobilePushToken> get tokenRefreshes;

  /// Asks the platform to (re)start provider registration.
  ///
  /// Registration is idempotent; calling it after every authentication is what
  /// makes a token available on a device that signed in after the process
  /// started.
  Future<void> ensureRegistration();

  /// Mirrors the session that is on screen to the native foreground hook.
  ///
  /// iOS decides whether to present a remote notification while the app is in
  /// the foreground before any Dart code sees it. Publishing the exact visible
  /// session keeps that decision per-event instead of making the whole
  /// foreground silent.
  Future<void> reportVisibleSession(String? sessionId);

  Future<void> dispose();
}
