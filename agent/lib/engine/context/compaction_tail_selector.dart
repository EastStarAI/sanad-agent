import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import 'compaction_token_estimator.dart';

/// Indexed message row used by the compaction engine (Plan 53c C1).
class IndexedConversationMessage {
  final int rowId;
  final Message message;

  const IndexedConversationMessage({
    required this.rowId,
    required this.message,
  });
}

/// Result of head/tail partitioning for one compaction attempt.
class CompactionRangeSelection {
  final CompactionMessageRange sourceRange;
  final CompactionMessageRange retainedTailRange;
  final List<IndexedConversationMessage> sourceMessages;
  final List<IndexedConversationMessage> tailMessages;

  const CompactionRangeSelection({
    required this.sourceRange,
    required this.retainedTailRange,
    required this.sourceMessages,
    required this.tailMessages,
  });
}

/// Selects compressible head and tool-aware retained tail (Plan 53c Gate C1).
class CompactionTailSelector {
  final int minimumRecentMessages;

  const CompactionTailSelector({this.minimumRecentMessages = 2});

  CompactionRangeSelection select({
    required List<IndexedConversationMessage> timeline,
    required int tailTokenBudget,
    CompactionMessageRange? previousSourceEnd,
  }) {
    if (timeline.isEmpty) {
      throw ArgumentError('timeline must not be empty');
    }
    final startIndex = _sourceStartIndex(timeline, previousSourceEnd);
    if (startIndex >= timeline.length - 1) {
      throw ArgumentError('no compressible head remains');
    }

    var tailStart = (timeline.length - minimumRecentMessages)
        .clamp(startIndex + 1, timeline.length - 1);
    tailStart = _expandTailStart(timeline, tailStart)
        .clamp(startIndex + 1, timeline.length - 1);

    while (tailStart > startIndex + 1) {
      final expanded = _expandTailStart(timeline, tailStart - 1)
          .clamp(startIndex + 1, timeline.length - 1);
      final groupTokens = CompactionTokenEstimator.estimateMessages(
        timeline.sublist(expanded).map((entry) => entry.message),
      );
      if (groupTokens > tailTokenBudget) {
        break;
      }
      tailStart = expanded;
    }

    final sourceEndRow = timeline[tailStart - 1].rowId;
    final sourceStartRow = timeline[startIndex].rowId;
    final tailEndRow = timeline.last.rowId;
    final tailStartRow = timeline[tailStart].rowId;

    return CompactionRangeSelection(
      sourceRange: CompactionMessageRange(
        start: CompactionMessageIdentity(sourceStartRow),
        end: CompactionMessageIdentity(sourceEndRow),
      ),
      retainedTailRange: CompactionMessageRange(
        start: CompactionMessageIdentity(tailStartRow),
        end: CompactionMessageIdentity(tailEndRow),
      ),
      sourceMessages: timeline.sublist(startIndex, tailStart),
      tailMessages: timeline.sublist(tailStart),
    );
  }

  int _sourceStartIndex(
    List<IndexedConversationMessage> timeline,
    CompactionMessageRange? previousSourceEnd,
  ) {
    if (previousSourceEnd == null) {
      return 0;
    }
    final index = timeline.indexWhere(
      (entry) => entry.rowId > previousSourceEnd.end.rowId,
    );
    return index < 0 ? timeline.length : index;
  }

  int _expandTailStart(
    List<IndexedConversationMessage> timeline,
    int index,
  ) {
    var start = index;
    while (start > 0) {
      final current = timeline[start].message;
      final previous = timeline[start - 1].message;
      if (current.role == MessageRole.tool &&
          previous.role == MessageRole.assistant &&
          (previous.toolCalls?.isNotEmpty ?? false)) {
        start--;
        continue;
      }
      if (current.role == MessageRole.assistant &&
          previous.role == MessageRole.user) {
        start--;
        continue;
      }
      break;
    }
    return start;
  }
}
