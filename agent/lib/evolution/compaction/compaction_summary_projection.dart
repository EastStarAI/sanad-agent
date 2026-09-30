import 'package:sanad_agent/engine/compaction/compaction.dart';

/// Formats internal summaries for ephemeral model projection only.
abstract final class CompactionSummaryProjection {
  CompactionSummaryProjection._();

  static const projectionMetadataKey = 'sanad_compaction_summary';

  static String format(CompactionInternalSummary summary) {
    final sections = <String>[
      'Internal conversation summary (projection only; not user input):',
      'Current goal: ${summary.currentGoal.trim()}',
    ];
    void add(String label, String? value) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        sections.add('$label: $trimmed');
      }
    }

    add('Success criteria', summary.successCriteria);
    add('Constraints', summary.constraints);
    add('Completed work', summary.completedWork);
    add('Active state', summary.activeState);
    add('Decisions', summary.decisions);
    add('Blockers', summary.blockers);
    add('Files and paths', summary.filesAndPaths);
    add('Pending asks', summary.pendingAsks);
    add('Remaining work', summary.remainingWork);
    if (summary.previousSummaryAnchor != null) {
      add('Previous summary anchor', summary.previousSummaryAnchor);
    }
    return sections.join('\n');
  }
}
