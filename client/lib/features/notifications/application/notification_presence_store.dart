import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';

/// The app-wide answer to "what is the user looking at right now?".
///
/// Two surfaces write it: the window lifecycle reports visibility, and the
/// mounted conversation surface reports the session (and the pending ask) it is
/// presenting. Nothing else reads conversation state for notifications, so a
/// background or other-session window stays notifyable no matter what the
/// conversation cache holds.
class NotificationPresenceStore {
  NotificationPresence _presence = NotificationPresence.none;

  NotificationPresence get presence => _presence;

  /// Records window visibility. Hiding the window clears presence, because a
  /// hidden window keeps the widget tree alive but shows the user nothing.
  void setWindowVisible(bool visible) {
    if (_presence.windowVisible == visible) return;
    _presence = _presence.copyWith(windowVisible: visible);
  }

  /// Records the conversation surface currently on screen.
  void reportConversationSurface({
    required String deviceId,
    String? sessionId,
    String? requestId,
  }) {
    _presence = NotificationPresence(
      windowVisible: _presence.windowVisible,
      deviceId: deviceId,
      sessionId: sessionId,
      requestId: requestId,
    );
  }

  /// Records the pending ask of the session already on screen.
  void reportPendingRequest(String? requestId) {
    final sessionId = _presence.sessionId;
    if (sessionId == null) return;
    if (_presence.requestId == requestId) return;
    _presence = NotificationPresence(
      windowVisible: _presence.windowVisible,
      deviceId: _presence.deviceId,
      sessionId: sessionId,
      requestId: requestId,
    );
  }

  /// Clears the conversation surface, leaving window visibility intact.
  void clearConversationSurface() {
    _presence = _presence.copyWith(clearSurface: true);
  }

  /// Clears everything. Used when the app tears the surface down entirely.
  void reset() {
    _presence = NotificationPresence.none;
  }
}
