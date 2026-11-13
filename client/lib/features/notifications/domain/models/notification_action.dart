import 'package:equatable/equatable.dart';

/// What answering a notification action means.
///
/// The wire token of an action is an Agent-owned label identity; this enum is
/// the Client's translation of it into an intent the existing
/// `tool_permission_response` command can express.
enum NotificationActionIntent {
  /// Open the session that produced the notification.
  open,

  /// Approve this one execution (`scope: once`).
  allowOnce,

  /// Approve every matching execution for the session (`scope: session`).
  allowSession,

  /// Refuse the execution.
  deny,
}

/// One interactive action offered by a notification.
///
/// [label] is copy the Agent already localized. When it is absent the Client
/// resolves its own localized fallback through [NotificationActionCopy], so an
/// action is never presented with an empty button.
class NotificationAction extends Equatable {
  const NotificationAction({
    required this.id,
    required this.intent,
    this.label,
  });

  /// The wire id returned when the user picks this action.
  final String id;

  final NotificationActionIntent intent;

  /// Agent-rendered label; `null` when the Client must supply its own.
  final String? label;

  /// Wire ids the Agent and the Client agree on.
  static const String openId = 'open';
  static const String allowOnceId = 'allow_once';
  static const String allowSessionId = 'allow_session';
  static const String denyId = 'deny';

  /// The action a plain click performs.
  static const NotificationAction open = NotificationAction(
    id: openId,
    intent: NotificationActionIntent.open,
  );

  /// The approval set offered for a permission request, strongest first.
  static const List<NotificationAction> approvalActions = <NotificationAction>[
    NotificationAction(id: allowOnceId, intent: NotificationActionIntent.allowOnce),
    NotificationAction(id: allowSessionId, intent: NotificationActionIntent.allowSession),
    NotificationAction(id: denyId, intent: NotificationActionIntent.deny),
  ];

  /// Maps a wire id to its intent, or `null` for an unknown action.
  ///
  /// An action this build cannot name is dropped instead of being forwarded:
  /// an unmapped id must never reach the daemon as an execution decision.
  static NotificationActionIntent? intentForWireId(Object? value) {
    if (value is! String) return null;
    return switch (value.trim()) {
      openId => NotificationActionIntent.open,
      allowOnceId => NotificationActionIntent.allowOnce,
      allowSessionId => NotificationActionIntent.allowSession,
      denyId => NotificationActionIntent.deny,
      _ => null,
    };
  }

  /// True when the action answers an ask rather than only opening a surface.
  bool get isApproval => intent != NotificationActionIntent.open;

  @override
  List<Object?> get props => [id, intent, label];
}
