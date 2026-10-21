import '../../core/models/message.dart';
import 'message_history_identity.dart';

/// Session-scoped authority for "is this active assistant row the terminal
/// result of its turn".
///
/// A candidate is an assistant row with no tool calls that a steer did not
/// supersede. It is terminal when it carries the durable terminal stamp
/// written by the terminal commit, or when the next active row of the same
/// session is absent or a root user input. A fetched history page boundary
/// never decides terminality.
class TerminalAssistantClassifier {
  const TerminalAssistantClassifier._();

  static const String workItemIdKey = 'terminal_work_item_id';
  static const String generationKey = 'terminal_generation';

  static bool isCandidate(Message message) =>
      message.role == MessageRole.assistant &&
      message.metadata?['superseded_by_steer'] != true &&
      (message.toolCalls == null || message.toolCalls!.isEmpty);

  static bool hasStamp(Message message) =>
      message.metadata?[workItemIdKey] != null;

  /// [next] is the next active row of the same session, or null when
  /// [message] is the newest active row.
  static bool isTerminal(Message message, {required Message? next}) {
    if (!isCandidate(message)) return false;
    if (hasStamp(message)) return true;
    return next == null || MessageHistoryIdentity.isRootUser(next);
  }

  /// Keeps the durable terminal stamp of [stored] when an identity-aligned
  /// history rewrite supplies a [replacement] that does not carry one. Only
  /// the terminal commit writes the stamp; a rewrite from an in-memory or
  /// cached copy taken before that commit must not erase it.
  static Message carryForwardStamp({
    required Message stored,
    required Message replacement,
  }) {
    if (replacement.role != MessageRole.assistant ||
        !hasStamp(stored) ||
        hasStamp(replacement)) {
      return replacement;
    }
    final storedMetadata = stored.metadata!;
    return replacement.copyWith(
      metadata: {
        ...?replacement.metadata,
        workItemIdKey: storedMetadata[workItemIdKey],
        if (storedMetadata[generationKey] != null)
          generationKey: storedMetadata[generationKey],
      },
    );
  }

  /// SQL boolean expression equivalent to [isTerminal] for the `messages`
  /// row aliased as [alias]; the next row is resolved inside the same
  /// session's active history.
  static String sqlIsTerminal(String alias) =>
      '''
(json_extract($alias.data, '\$.role') = 'assistant'
 AND COALESCE(json_array_length(json_extract($alias.data, '\$.toolCalls')), 0) = 0
 AND COALESCE(json_extract($alias.data, '\$.metadata.superseded_by_steer'), 0) != 1
 AND (
   json_extract($alias.data, '\$.metadata.$workItemIdKey') IS NOT NULL
   OR COALESCE((
     SELECT CASE
       WHEN json_extract(nx.data, '\$.role') = 'user'
            AND COALESCE(nx.input_kind, json_extract(nx.data, '\$.metadata.input_kind'), '') != '${MessageHistoryIdentity.steer}'
            AND COALESCE(json_extract(nx.data, '\$.metadata.steer'), 0) != 1
       THEN 1 ELSE 0 END
     FROM messages nx
     WHERE nx.session_id = $alias.session_id
       AND nx.id > $alias.id
       AND (nx.history_status = '${MessageHistoryIdentity.active}' OR nx.history_status IS NULL)
     ORDER BY nx.id ASC
     LIMIT 1
   ), 1) = 1
 ))''';
}
