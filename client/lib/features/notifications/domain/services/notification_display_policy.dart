import 'package:equatable/equatable.dart';

import '../models/notification_kind.dart';
import '../models/notification_payload.dart';
import '../models/notification_permission_status.dart';
import '../models/notification_preferences.dart';
import '../models/notification_presence.dart';

/// Why the display pipeline did or did not raise an OS notification.
///
/// The outcome is a closed set so the decision matrix can be tested as data
/// instead of inferred from side effects.
enum NotificationDisplayOutcome {
  /// Raise (or replace) the OS notification.
  display,

  /// The ask is already in front of the user; no banner, in-app state unchanged.
  suppressedOnScreen,

  /// A socket connect just replayed parked state.
  suppressedQuietWindow,

  /// The user turned this kind, or notifications globally, off.
  suppressedDisabled,

  /// The OS does not (or may not yet) accept notifications from this app.
  suppressedPermission,

  /// The notification outlived its expiry.
  dropExpired,

  /// The canonical event was already processed.
  dropDuplicate,

  /// This build has no OS notification surface for the current platform.
  dropUnsupported,

  /// The decision was to display, but the platform refused the call.
  ///
  /// This is the only outcome that is not a policy choice: the policy said
  /// `display`, and the adapter threw before a notification existed. It exists
  /// so a caller — in practice the Settings test action — can report the real
  /// result instead of claiming a notification that was never shown.
  presentationFailed,
}

/// One decision plus the reason token used by logs and tests.
class NotificationDisplayDecision extends Equatable {
  const NotificationDisplayDecision(this.outcome, {this.kind, this.sessionId});

  final NotificationDisplayOutcome outcome;
  final NotificationKind? kind;
  final String? sessionId;

  bool get shouldDisplay => outcome == NotificationDisplayOutcome.display;

  /// A compact, content-free reason for a log line.
  String get reason => [
        outcome.name,
        if (kind != null) 'kind=${kind!.wire}',
        if (sessionId != null) 'session=$sessionId',
      ].join(' ');

  @override
  List<Object?> get props => [outcome, kind, sessionId];
}

/// The single owner of "does this notification reach the operating system?".
///
/// The checks run in a fixed order, and each one exists for a different reason:
/// an unsupported platform can never show anything, an expired or already
/// processed notification is not news, a replay is not an interruption, a
/// disabled kind is the user's decision, an ungranted permission means the OS
/// would silently drop it anyway, and presence means the user is already
/// looking at the ask.
class NotificationDisplayPolicy {
  NotificationDisplayPolicy._();

  static NotificationDisplayDecision decide({
    required NotificationPayload payload,
    required bool alreadyProcessed,
    required NotificationPreferences preferences,
    required NotificationPermissionStatus permission,
    required bool quietWindowOpen,
    required NotificationPresence presence,
    required DateTime now,
    bool platformSupported = true,
  }) {
    NotificationDisplayDecision outcome(NotificationDisplayOutcome value) =>
        NotificationDisplayDecision(
          value,
          kind: payload.kind,
          sessionId: payload.sessionId,
        );

    if (!platformSupported) {
      return outcome(NotificationDisplayOutcome.dropUnsupported);
    }
    if (payload.isExpiredAt(now)) {
      return outcome(NotificationDisplayOutcome.dropExpired);
    }
    if (alreadyProcessed) {
      return outcome(NotificationDisplayOutcome.dropDuplicate);
    }
    if (quietWindowOpen) {
      return outcome(NotificationDisplayOutcome.suppressedQuietWindow);
    }
    if (!preferences.allows(payload.kind)) {
      return outcome(NotificationDisplayOutcome.suppressedDisabled);
    }
    if (!permission.canDisplay) {
      return outcome(NotificationDisplayOutcome.suppressedPermission);
    }
    if (presence.showsAsk(sessionId: payload.sessionId, requestId: payload.requestId)) {
      return outcome(NotificationDisplayOutcome.suppressedOnScreen);
    }
    return outcome(NotificationDisplayOutcome.display);
  }
}
