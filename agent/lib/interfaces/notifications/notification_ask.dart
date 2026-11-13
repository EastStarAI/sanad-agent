/// Plan 174 — the ask the Agent is willing to notify about.
///
/// A suspension payload carries far more than a notification may reveal: the
/// full tool arguments, the tool schema, the workspace path, the policy key.
/// [NotificationAsk.fromSuspension] is the only reader of that payload, and it
/// copies exactly three things out of it — the tool name, the command text of a
/// permission request, and the question (or form reason) of a user-input
/// request. Everything else stays behind.
///
/// The excerpt this file selects is NOT yet redacted: redaction and bounding
/// have one owner, [NotificationPayloadComposer], so every text field that
/// leaves the device crosses the same existing secret-redaction path.
library;

import 'notification_kind.dart';

/// One unresolved ask, reduced to what a notification is allowed to carry.
final class NotificationAsk {
  const NotificationAsk({
    required this.sessionId,
    required this.requestId,
    required this.eventId,
    required this.kind,
    required this.excerpt,
    this.sessionTitle,
    this.urgency,
  });

  final String sessionId;
  final String requestId;

  /// Canonical `event_id` of the `tool_permission_request` that raised the ask.
  ///
  /// It is the notification's identity across the local socket, the cloud
  /// socket, and push, so one ask produces one visible notification per device
  /// no matter how many dispatch steps the policy takes.
  final String eventId;

  final NotificationKind kind;

  /// The raw ask excerpt, never redacted here.
  final String excerpt;

  /// The session title, carried verbatim because it is never translated.
  final String? sessionTitle;

  /// Overrides the kind's default urgency when a caller has a reason to.
  final NotificationUrgency? urgency;

  /// The urgency this ask is dispatched with.
  NotificationUrgency get effectiveUrgency => urgency ?? kind.defaultUrgency;

  /// The same ask carrying a resolved session title.
  NotificationAsk withSessionTitle(String? sessionTitle) {
    final title = sessionTitle?.trim();
    if (title == null || title.isEmpty) return this;
    return NotificationAsk(
      sessionId: sessionId,
      requestId: requestId,
      eventId: eventId,
      kind: kind,
      excerpt: excerpt,
      sessionTitle: title,
      urgency: urgency,
    );
  }

  /// Reduces a live suspension payload to a notifiable ask.
  ///
  /// Only named keys are read; no list, map, or tool result is copied wholesale.
  factory NotificationAsk.fromSuspension({
    required String sessionId,
    required String requestId,
    required String eventId,
    required NotificationKind kind,
    required Map<String, dynamic> payload,
    String? sessionTitle,
  }) => NotificationAsk(
    sessionId: sessionId,
    requestId: requestId,
    eventId: eventId,
    kind: kind,
    excerpt: _selectExcerpt(kind, payload),
    sessionTitle: sessionTitle,
  );

  /// Longest raw excerpt selected from a payload, before redaction.
  static const int maxRawExcerpt = 512;

  static String _selectExcerpt(
    NotificationKind kind,
    Map<String, dynamic> payload,
  ) {
    if (kind == NotificationKind.userQuestion) {
      final question = _firstQuestion(payload);
      if (question != null) return question;
      // `system_request_secret` blocks on a form whose reason is authored for
      // the user; the field names and values never leave the device.
      final reason = _text(payload['reason']);
      if (reason != null) return reason;
    }
    final toolName = _text(payload['tool_name']);
    if (kind == NotificationKind.permissionRequest) {
      final command = _text(_mapValue(payload['tool_input'], 'command'));
      if (toolName != null && command != null) return '$toolName: $command';
      if (command != null) return command;
    }
    return toolName ?? '';
  }

  static String? _firstQuestion(Map<String, dynamic> payload) {
    final questions = payload['questions'];
    if (questions is List) {
      for (final entry in questions) {
        if (entry is Map) {
          final question = _text(entry['question']);
          if (question != null) return question;
        }
      }
    }
    return _text(payload['question']);
  }

  static Object? _mapValue(Object? source, String key) {
    if (source is Map) return source[key];
    return null;
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length <= maxRawExcerpt) return trimmed;
    return trimmed.substring(0, maxRawExcerpt);
  }
}

/// The reason a notification was withdrawn, carried so a Client can tell an
/// answered ask from a cancelled one without parsing anything else.
abstract final class NotificationWithdrawReason {
  static const resolved = 'resolved';
  static const alreadyResolved = 'already_resolved';
  static const sessionTerminal = 'session_terminal';
  static const disposed = 'disposed';
}
