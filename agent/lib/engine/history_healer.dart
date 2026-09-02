import 'package:logging/logging.dart';
import '../core/models/message.dart';
import '../evolution/db/persisted_runtime_state_repository.dart';
import '../evolution/session_manager.dart';
import 'runtime/deferred_tool_result.dart';

class HistoryHealer {
  static final Logger _logger = Logger('HistoryHealer');

  static Set<String> deferredToolCallIds({
    required Iterable<SessionWorkItem> workItems,
    required String sessionId,
  }) {
    final protectedIds = <String>{};
    for (final item in workItems) {
      if (item.sessionId != sessionId ||
          item.state == SessionWorkState.completed ||
          item.state == SessionWorkState.cancelled) {
        continue;
      }
      final deferredResults = Map<String, dynamic>.from(
        item.continuationMetadata['deferred_tool_results'] as Map? ?? const {},
      );
      for (final entry in deferredResults.entries) {
        final descriptor = DeferredToolResultDescriptor.tryParseMetadata(
          entry.value,
        );
        if (descriptor != null &&
            descriptor.requesterSessionId == sessionId &&
            descriptor.requesterToolCallId == entry.key) {
          protectedIds.add(entry.key);
        }
      }
    }
    return protectedIds;
  }

  /// Scans loaded history for unanswered `toolCalls` in assistant messages and
  /// automatically appends dummy cancellation tool results.
  static void healHistory({
    required List<Message> history,
    required SessionManager sessionManager,
    required String sessionId,
    Set<String> suspendedToolCallIds = const {},
    Set<String> deferredToolCallIds = const {},
    Set<String> activeToolCallIds = const {},
  }) {
    if (history.isEmpty) return;
    bool modified = false;

    for (int i = 0; i < history.length; i++) {
      final msg = history[i];
      if (msg.role == MessageRole.assistant &&
          msg.toolCalls != null &&
          msg.toolCalls!.isNotEmpty) {
        final pendingToolCallIds = msg.toolCalls!.map((tc) => tc.id).toSet();

        // Search for matching tool result messages that follow this assistant message
        for (int j = i + 1; j < history.length; j++) {
          final nextMsg = history[j];
          if (nextMsg.role == MessageRole.tool && nextMsg.toolCallId != null) {
            pendingToolCallIds.remove(nextMsg.toolCallId);
          }
          if (nextMsg.role == MessageRole.user ||
              nextMsg.role == MessageRole.assistant) {
            break;
          }
        }

        // Suspended and deferred tools have authoritative result owners. They
        // must survive restart without a synthetic cancellation being inserted
        // before the user decision or launcher transaction resolves.
        pendingToolCallIds
          ..removeAll(suspendedToolCallIds)
          ..removeAll(deferredToolCallIds)
          ..removeAll(activeToolCallIds);

        // A call without a remaining durable owner was interrupted by a
        // previous daemon lifetime. Only an explicit Stop is user-cancelled.
        if (pendingToolCallIds.isNotEmpty) {
          _logger.warning(
            'Healing session history: found unanswered tool calls $pendingToolCallIds in session $sessionId.',
          );

          int insertIndex = i + 1;
          while (insertIndex < history.length &&
              history[insertIndex].role == MessageRole.tool) {
            insertIndex++;
          }

          final healMessages = pendingToolCallIds
              .map(
                (id) => Message(
                  role: MessageRole.tool,
                  content:
                      'The tool execution was interrupted because the agent stopped unexpectedly. Its outcome is unknown.',
                  toolCallId: id,
                  metadata: const {
                    'status': 'interrupted',
                    'reason': 'daemon_interrupted',
                    'is_error': true,
                  },
                ),
              )
              .toList();

          history.insertAll(insertIndex, healMessages);
          i += healMessages.length;
          modified = true;
        }
      }
    }

    if (modified) {
      sessionManager.saveSessionHistory(sessionId, history);
    }
  }
}
