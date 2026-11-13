import 'dart:async';

import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';

/// The app-wide answer to "what is the user looking at right now?".
///
/// Two surfaces write it: the window lifecycle reports visibility, and the
/// mounted conversation surface reports the session (and the pending ask) it is
/// presenting. Nothing else reads conversation state for notifications, so a
/// background or other-session window stays notifyable no matter what the
/// conversation cache holds.
///
/// Every change is published on [changes], because a platform hook that runs
/// outside Dart (the iOS foreground delegate) needs the session that is on
/// screen mirrored to it, not polled.
class NotificationPresenceStore {
  NotificationPresence _presence = NotificationPresence.none;

  final StreamController<NotificationPresence> _changes =
      StreamController<NotificationPresence>.broadcast();

  NotificationPresence get presence => _presence;

  /// Presence changes, in order.
  Stream<NotificationPresence> get changes => _changes.stream;

  /// Records window visibility. Hiding the window clears presence, because a
  /// hidden window keeps the widget tree alive but shows the user nothing.
  void setWindowVisible(bool visible) {
    if (_presence.windowVisible == visible) return;
    _publish(_presence.copyWith(windowVisible: visible));
  }

  /// Records the conversation surface currently on screen.
  void reportConversationSurface({
    required String deviceId,
    String? sessionId,
    String? requestId,
  }) {
    _publish(NotificationPresence(
      windowVisible: _presence.windowVisible,
      deviceId: deviceId,
      sessionId: sessionId,
      requestId: requestId,
    ));
  }

  /// Records the pending ask of the session already on screen.
  void reportPendingRequest(String? requestId) {
    final sessionId = _presence.sessionId;
    if (sessionId == null) return;
    if (_presence.requestId == requestId) return;
    _publish(NotificationPresence(
      windowVisible: _presence.windowVisible,
      deviceId: _presence.deviceId,
      sessionId: sessionId,
      requestId: requestId,
    ));
  }

  /// Clears the conversation surface, leaving window visibility intact.
  void clearConversationSurface() {
    _publish(_presence.copyWith(clearSurface: true));
  }

  /// Clears everything. Used when the app tears the surface down entirely.
  void reset() {
    _publish(NotificationPresence.none);
  }

  void _publish(NotificationPresence next) {
    _presence = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
