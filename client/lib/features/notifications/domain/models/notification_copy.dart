import 'package:equatable/equatable.dart';

import 'notification_action.dart';
import 'notification_kind.dart';

/// Localized copy for one notification kind.
///
/// The Agent normally renders the title and body, and its copy wins whenever it
/// is present. This is the Client's fallback for a notification that arrives
/// without copy (an older Agent, or a redaction that emptied a field): a
/// notification with no text is not useful, and a generic "you have a
/// notification" is explicitly rejected by the plan, so the Client names the
/// kind in the user's own language instead.
class NotificationCopy extends Equatable {
  const NotificationCopy({
    required this.title,
    required this.body,
    required this.actionLabels,
  });

  final String title;
  final String body;

  /// Localized label per action intent.
  final Map<NotificationActionIntent, String> actionLabels;

  String? labelFor(NotificationAction action) {
    final agentLabel = action.label;
    if (agentLabel != null && agentLabel.trim().isNotEmpty) return agentLabel.trim();
    final fallback = actionLabels[action.intent];
    if (fallback == null || fallback.trim().isEmpty) return null;
    return fallback.trim();
  }

  @override
  List<Object?> get props => [title, body, actionLabels];
}

/// Resolves localized fallback copy for a kind.
typedef NotificationCopyResolver = NotificationCopy Function(NotificationKind kind);
