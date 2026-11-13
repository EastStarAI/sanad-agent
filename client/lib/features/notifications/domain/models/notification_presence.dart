import 'package:equatable/equatable.dart';

/// What the Client is currently putting in front of the user.
///
/// Presence is the only reason a notification is ever withheld from the
/// operating system: an ask the user is already looking at does not need a
/// banner, while an open window on another session is not evidence that a human
/// is watching this one.
///
/// A hidden window is never presence, even when the same session is still the
/// selected one, because tray background mode keeps the whole widget tree
/// alive.
class NotificationPresence extends Equatable {
  const NotificationPresence({
    this.windowVisible = false,
    this.deviceId,
    this.sessionId,
    this.requestId,
  });

  /// The window is on screen (not hidden behind tray background mode).
  final bool windowVisible;

  /// The conversation surface currently mounted, when there is one.
  final String? deviceId;
  final String? sessionId;

  /// The pending ask projected by that surface, when one is pending.
  final String? requestId;

  /// Nothing is on screen.
  static const NotificationPresence none = NotificationPresence();

  /// Whether this presence already shows the ask a notification would carry.
  ///
  /// The session must match, and the window must be visible. The request only
  /// refines that: a session on screen with no projected request yet still
  /// counts, because the in-app prompt for the arriving ask is exactly what the
  /// user is about to see, and a second banner would duplicate it. A session
  /// that is showing a *different* pending request does not count, because the
  /// ask in the notification is not the one in front of the user.
  bool showsAsk({required String sessionId, String? requestId}) {
    if (!windowVisible) return false;
    if (this.sessionId == null || this.sessionId != sessionId) return false;
    if (requestId == null || requestId.isEmpty) return true;
    final projected = this.requestId;
    if (projected == null || projected.isEmpty) return true;
    return projected == requestId;
  }

  NotificationPresence copyWith({
    bool? windowVisible,
    String? deviceId,
    String? sessionId,
    String? requestId,
    bool clearSurface = false,
  }) {
    if (clearSurface) {
      return NotificationPresence(windowVisible: windowVisible ?? this.windowVisible);
    }
    return NotificationPresence(
      windowVisible: windowVisible ?? this.windowVisible,
      deviceId: deviceId ?? this.deviceId,
      sessionId: sessionId ?? this.sessionId,
      requestId: requestId ?? this.requestId,
    );
  }

  @override
  List<Object?> get props => [windowVisible, deviceId, sessionId, requestId];
}
