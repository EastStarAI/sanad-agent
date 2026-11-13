/// Plan 174 — the Agent-owned notification kinds and their default urgency.
///
/// The Agent owns every notification decision (plan 174, locked decision 1):
/// which session event notifies, its kind, its urgency, its copy, its
/// redaction, its target, its escalation window, and its cancellation. The
/// hosted relay transports a finished instruction and reads no content.
///
/// A kind is a typed, extensible value object rather than a closed enum, so a
/// future producer may declare a new kind without adding a semantic branch to
/// the dispatcher. Every Agent kind defaults to [NotificationUrgency.high]:
/// no kind ships silent, and a user lowers what they do not want.
library;

/// The delivery urgency of one notification.
///
/// Urgency is an attribute of a kind, not a second taxonomy. Every Agent kind
/// defaults to [high]; [normal] and [low] exist so a future per-user
/// preference can lower an individual kind without changing the model.
enum NotificationUrgency {
  high('high'),
  normal('normal'),
  low('low');

  const NotificationUrgency(this.wireName);

  /// Stable snake_case token used on the wire and in notification ids.
  final String wireName;

  /// Parses a wire token, falling back to [high] for anything unrecognized
  /// because a notification is never silently downgraded by bad input.
  static NotificationUrgency fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final urgency in NotificationUrgency.values) {
      if (urgency.wireName == normalized) return urgency;
    }
    return NotificationUrgency.high;
  }

  /// The quieter of two urgencies.
  ///
  /// The enum is declared from loudest to quietest, so the index is the rank and
  /// the larger index wins. A device preference can only lower a notification
  /// (plan 174, locked decision 7), which is why the dispatcher asks for the
  /// lower of the Agent's decision and the target device's ceiling.
  static NotificationUrgency lowerOf(
    NotificationUrgency first,
    NotificationUrgency second,
  ) =>
      first.index >= second.index ? first : second;
}

/// One Agent-owned notification kind.
final class NotificationKind {
  const NotificationKind._(this.value);

  /// Stable snake_case token used on the wire and as the copy-table key.
  final String value;

  /// The run is blocked on an execution decision.
  static const permissionRequest = NotificationKind._('permission_request');

  /// The run is blocked on an answer.
  static const userQuestion = NotificationKind._('user_question');

  /// The session cannot proceed without human intervention.
  static const blocked = NotificationKind._('blocked');

  /// The run ended in a final failure.
  static const failed = NotificationKind._('failed');

  /// The requested result exists.
  static const completed = NotificationKind._('completed');

  /// A background task or terminal command finished.
  static const backgroundTaskDone = NotificationKind._('background_task_done');

  /// A scheduled run produced a result.
  static const scheduledResult = NotificationKind._('scheduled_result');

  /// The selected provider is exhausted or rate-limited.
  static const providerQuota = NotificationKind._('provider_quota');

  /// Client-owned kind for a lost Agent connection.
  ///
  /// Declared here because the value vocabulary has one owner. The Agent never
  /// dispatches it: a Client raises it locally and it never traverses the
  /// relay (plan 174, locked decision 14).
  static const connectionLost = NotificationKind._('connection_lost');

  /// Client-owned kind for an expired account session.
  ///
  /// Declared for the same reason as [connectionLost]; never dispatched.
  static const authRequired = NotificationKind._('auth_required');

  /// Every kind the Agent may dispatch, in plan order.
  static const agentKinds = <NotificationKind>[
    permissionRequest,
    userQuestion,
    blocked,
    failed,
    completed,
    backgroundTaskDone,
    scheduledResult,
    providerQuota,
  ];

  /// Every kind this model declares, Agent-owned and Client-owned.
  static const knownKinds = <NotificationKind>[
    ...agentKinds,
    connectionLost,
    authRequired,
  ];

  static final RegExp _tokenPattern = RegExp(r'^[a-z][a-z0-9_]*$');

  /// Declares a custom kind. Rejects a token that cannot ride the wire.
  factory NotificationKind(String value) {
    final normalized = value.trim();
    if (!_tokenPattern.hasMatch(normalized)) {
      throw ArgumentError.value(
        value,
        'value',
        'A notification kind must be a lowercase snake_case token.',
      );
    }
    return NotificationKind._(normalized);
  }

  /// Parses a kind, returning `null` for an unknown or malformed token.
  static NotificationKind? tryParse(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    if (!_tokenPattern.hasMatch(normalized)) return null;
    return NotificationKind._(normalized);
  }

  /// Whether the Agent owns the dispatch decision for this kind.
  bool get isAgentOwned =>
      agentKinds.any((candidate) => candidate.value == value);

  /// What a notification of this kind is delivered with.
  ///
  /// Every kind defaults to high urgency (plan 174, locked decision 7).
  NotificationUrgency get defaultUrgency => NotificationUrgency.high;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotificationKind && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
