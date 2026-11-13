import 'notification_kind.dart';

/// The identity that decides whether a new notification replaces an existing
/// one or stacks beside it.
///
/// Collapse is derived from `session_id + kind`, so a replayed or re-escalated
/// ask about the same session and kind lands on the same OS notification
/// instead of producing a second banner. Two different requests in one session
/// therefore share a banner by design: the newest ask is the one worth showing,
/// and the older one stays reachable in the session surface.
class NotificationCollapseKey {
  NotificationCollapseKey._();

  /// The canonical collapse key for one ask.
  ///
  /// The separator is a character that cannot appear in an Agent identifier, so
  /// two different `(sessionId, kind)` pairs can never build the same key.
  static String forAsk({
    required String sessionId,
    required NotificationKind kind,
  }) {
    return 'ask\u0000$sessionId\u0000${kind.wire}';
  }

  /// True when an Agent-supplied collapse key agrees with the canonical one.
  ///
  /// The Agent derives the same value from `session_id + kind`; a disagreeing
  /// key is ignored rather than trusted, because replacement must stay
  /// deterministic even if a producer changes its own derivation.
  static bool agreesWith({
    required String? candidate,
    required String sessionId,
    required NotificationKind kind,
  }) {
    if (candidate == null || candidate.isEmpty) return false;
    return candidate == forAsk(sessionId: sessionId, kind: kind);
  }

  /// A stable positive 31-bit notification id for [collapseKey].
  ///
  /// Every desktop implementation identifies a notification by a numeric id
  /// (macOS `UNNotificationRequest` identifier, the Linux `replaces_id`
  /// lookup, the Windows toast tag), so the same key must always produce the
  /// same number across launches and transports. FNV-1a is used because it is
  /// stable across Dart versions and platforms; `hashCode` is not.
  static int notificationId(String collapseKey) {
    var hash = 0x811c9dc5;
    for (final unit in collapseKey.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }
}
