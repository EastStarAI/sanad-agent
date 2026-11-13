/// The short window after a socket connect during which no OS notification is
/// raised.
///
/// A reconnect (or a profile switch) replays the parked state of every session,
/// including an ask the user never answered. Those replays are authoritative
/// in-app state and must reach the conversation surfaces, but they are not new
/// interruptions: the user already saw the ask, and re-raising the banner is
/// the exact noise this window prevents.
///
/// The window suppresses only the OS notification. In-app state is projected by
/// the existing event path, which never consults this class.
class NotificationQuietWindow {
  NotificationQuietWindow({
    this.duration = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long a connect keeps the OS quiet.
  final Duration duration;

  final DateTime Function() _clock;
  DateTime? _openedAt;

  /// Starts (or restarts) the window. Every connect arms it, so a flapping
  /// transport cannot deliver a replay after the first window closed.
  void arm() {
    _openedAt = _clock();
  }

  bool get isOpen {
    final openedAt = _openedAt;
    if (openedAt == null) return false;
    final elapsed = _clock().difference(openedAt);
    if (elapsed.isNegative) return true;
    if (elapsed >= duration) {
      _openedAt = null;
      return false;
    }
    return true;
  }

  /// How much of the window is left; [Duration.zero] when closed.
  Duration get remaining {
    final openedAt = _openedAt;
    if (openedAt == null || !isOpen) return Duration.zero;
    final left = duration - _clock().difference(openedAt);
    return left.isNegative ? Duration.zero : left;
  }

  void clear() {
    _openedAt = null;
  }
}
