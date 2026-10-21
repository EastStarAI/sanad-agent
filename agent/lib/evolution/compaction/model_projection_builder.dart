import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import '../db/compaction_boundary_repository.dart';
import '../db/session_db.dart';
import '../models/compaction_operation_record.dart';
import 'compaction_summary_projection.dart';
import 'model_context_projection.dart';

/// Builds ephemeral model projections from canonical history and the latest
/// eligible completed compaction boundary (Plan 53b Gate B2).
class ModelProjectionBuilder {
  static final Logger _logger = Logger('ModelProjectionBuilder');
  static final Set<String> _loggedInvalidations = <String>{};

  @visibleForTesting
  static void resetLoggedInvalidations() => _loggedInvalidations.clear();

  final SessionDB _sessions;
  final CompactionBoundaryRepository _boundaries;

  ModelProjectionBuilder({
    required SessionDB sessions,
    required CompactionBoundaryRepository boundaries,
  }) : _sessions = sessions,
       _boundaries = boundaries;

  static void _logInvalidation(String compactionId, String reason) {
    if (_loggedInvalidations.add('$compactionId:$reason')) {
      _logger.warning(
        'Compaction boundary invalidated: compaction_id=$compactionId, reason=$reason',
      );
    }
  }

  CanonicalConversationTimeline loadCanonicalTimeline(String sessionId) {
    return CanonicalConversationTimeline(
      sessionId: sessionId,
      messages: _sessions.getPersistedMessages(sessionId),
    );
  }

  ModelContextProjection buildForSession(String sessionId) {
    final timeline = loadCanonicalTimeline(sessionId);
    final boundary = _findLatestEligibleBoundary(sessionId, timeline.messages);
    if (boundary == null) {
      return ModelContextProjection(
        sessionId: sessionId,
        conversationMessages: timeline.messages
            .map((entry) => entry.message)
            .toList(growable: false),
      );
    }

    final retainedTailEndPresent = timeline.messages.any(
      (entry) => entry.rowId == boundary.retainedTailRange.end.rowId,
    );
    final tailMessages = _messagesForRange(
      timeline.messages,
      boundary.retainedTailRange,
      includeReplacementSuffix: !retainedTailEndPresent,
    );
    final postBoundaryMessages = retainedTailEndPresent
        ? timeline.messages
              .where(
                (entry) => entry.rowId > boundary.retainedTailRange.end.rowId,
              )
              .map((entry) => entry.message)
              .toList(growable: false)
        : const <Message>[];

    // Guaranteed non-null by CompactionBoundaryValidity.isAuthoritativeProjection.
    final summary = boundary.internalSummary!;

    final projected = <Message>[
      Message(
        role: MessageRole.user,
        content: CompactionSummaryProjection.format(summary),
        metadata: const {
          CompactionSummaryProjection.projectionMetadataKey: true,
        },
      ),
      ...tailMessages,
      ...postBoundaryMessages,
    ];

    return ModelContextProjection(
      sessionId: sessionId,
      activeBoundary: boundary,
      conversationMessages: projected,
    );
  }

  CompactionOperationRecord? _findLatestEligibleBoundary(
    String sessionId,
    List<PersistedMessage> timeline,
  ) {
    final rowIds = timeline.map((entry) => entry.rowId).toSet();
    final currentRevision = _boundaries.historyRevisionForSession(sessionId);
    if (currentRevision == null) {
      return null;
    }

    final completed = _boundaries.listCompletedForSession(sessionId);
    for (final boundary in completed) {
      final ineligibilityReason =
          CompactionBoundaryValidity.ineligibilityReason(
            boundary: boundary,
            existingMessageRowIds: rowIds,
            currentRevision: currentRevision,
          );
      if (ineligibilityReason != null) {
        _logInvalidation(boundary.compactionId, ineligibilityReason);
        continue;
      }
      if (!_retainedTailPreservesToolPairs(boundary, timeline)) {
        _logInvalidation(boundary.compactionId, 'orphaned_tool_calls');
        continue;
      }
      return boundary;
    }
    return null;
  }

  bool _retainedTailPreservesToolPairs(
    CompactionOperationRecord boundary,
    List<PersistedMessage> timeline,
  ) {
    final retainedTailEndPresent = timeline.any(
      (entry) => entry.rowId == boundary.retainedTailRange.end.rowId,
    );
    final retainedCallIds = <String>{};
    for (final entry in timeline) {
      if (entry.rowId < boundary.retainedTailRange.start.rowId ||
          (retainedTailEndPresent &&
              entry.rowId > boundary.retainedTailRange.end.rowId)) {
        continue;
      }
      final message = entry.message;
      if (message.role == MessageRole.assistant) {
        for (final call in message.toolCalls ?? const []) {
          retainedCallIds.add(call.id);
        }
      } else if (message.role == MessageRole.tool) {
        final toolCallId = message.toolCallId?.trim();
        if (toolCallId == null ||
            toolCallId.isEmpty ||
            !retainedCallIds.contains(toolCallId)) {
          return false;
        }
      }
    }
    return true;
  }

  List<Message> _messagesForRange(
    List<PersistedMessage> timeline,
    CompactionMessageRange range, {
    bool includeReplacementSuffix = false,
  }) {
    return timeline
        .where(
          (entry) =>
              entry.rowId >= range.start.rowId &&
              (includeReplacementSuffix || entry.rowId <= range.end.rowId),
        )
        .map((entry) => entry.message)
        .toList(growable: false);
  }
}
