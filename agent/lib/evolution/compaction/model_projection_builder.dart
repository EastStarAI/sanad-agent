import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import '../db/compaction_boundary_repository.dart';
import '../db/session_db.dart';
import '../models/compaction_operation_record.dart';
import 'compaction_summary_projection.dart';
import 'model_context_projection.dart';
import 'model_projection_exception.dart';

/// Builds ephemeral model projections from canonical history and the latest
/// eligible completed compaction boundary (Plan 53b Gate B2).
class ModelProjectionBuilder {
  final SessionDB _sessions;
  final CompactionBoundaryRepository _boundaries;

  ModelProjectionBuilder({
    required SessionDB sessions,
    required CompactionBoundaryRepository boundaries,
  }) : _sessions = sessions,
       _boundaries = boundaries;

  CanonicalConversationTimeline loadCanonicalTimeline(String sessionId) {
    return CanonicalConversationTimeline(
      sessionId: sessionId,
      messages: _sessions.getPersistedMessages(sessionId),
    );
  }

  ModelContextProjection buildForSession(String sessionId) {
    final timeline = loadCanonicalTimeline(sessionId);
    final rowIds = timeline.messages.map((entry) => entry.rowId).toSet();
    final boundary = _findLatestEligibleBoundary(sessionId, timeline.messages);
    if (boundary == null) {
      _rejectConflictingNewestBoundary(sessionId, rowIds);
      return ModelContextProjection(
        sessionId: sessionId,
        conversationMessages: timeline.messages
            .map((entry) => entry.message)
            .toList(growable: false),
      );
    }

    final byId = {
      for (final entry in timeline.messages) entry.rowId: entry.message,
    };
    _assertRangePresent(byId, boundary.retainedTailRange, 'retained tail');
    final tailMessages = _messagesForRange(
      timeline.messages,
      boundary.retainedTailRange,
    );
    final postBoundaryMessages = timeline.messages
        .where((entry) => entry.rowId > boundary.retainedTailRange.end.rowId)
        .map((entry) => entry.message)
        .toList(growable: false);

    final summary = boundary.internalSummary;
    if (summary == null) {
      throw const ModelProjectionException(
        'completed boundary is missing internal summary',
      );
    }

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
    final revision = _boundaries.historyRevisionForSession(sessionId);
    if (revision == null) {
      return null;
    }

    final completed = _boundaries.listCompletedForSession(sessionId);
    for (final boundary in completed) {
      if (CompactionBoundaryValidity.isProjectionEligible(
            boundary: boundary,
            existingMessageRowIds: rowIds,
            currentRevision: revision,
          ) &&
          _retainedTailPreservesToolPairs(boundary, timeline)) {
        return boundary;
      }
    }
    return null;
  }

  bool _retainedTailPreservesToolPairs(
    CompactionOperationRecord boundary,
    List<PersistedMessage> timeline,
  ) {
    final retainedCallIds = <String>{};
    for (final entry in timeline) {
      if (entry.rowId < boundary.retainedTailRange.start.rowId ||
          entry.rowId > boundary.retainedTailRange.end.rowId) {
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

  void _rejectConflictingNewestBoundary(String sessionId, Set<int> rowIds) {
    for (final boundary in _boundaries.listCompletedForSession(sessionId)) {
      if (!boundary.isAuthoritativeProjection) {
        continue;
      }
      if (CompactionBoundaryValidity.hasConflictingMessageRowIds(
        boundary: boundary,
        existingMessageRowIds: rowIds,
      )) {
        throw const ModelProjectionException(
          'newest completed boundary references conflicting message row ids',
        );
      }
      return;
    }
  }

  void _assertRangePresent(
    Map<int, Message> byId,
    CompactionMessageRange range,
    String label,
  ) {
    for (final id in {range.start.rowId, range.end.rowId}) {
      if (byId.containsKey(id)) continue;
      throw ModelProjectionException(
        'missing $label message row id $id for active boundary',
      );
    }
  }

  List<Message> _messagesForRange(
    List<PersistedMessage> timeline,
    CompactionMessageRange range,
  ) {
    return timeline
        .where(
          (entry) =>
              entry.rowId >= range.start.rowId &&
              entry.rowId <= range.end.rowId,
        )
        .map((entry) => entry.message)
        .toList(growable: false);
  }
}
