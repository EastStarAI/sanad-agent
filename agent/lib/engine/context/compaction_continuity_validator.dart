import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import 'compaction_tail_selector.dart';

/// Continuity anchor extracted before summarization (Plan 53c Gate C4).
class CompactionContinuityAnchor {
  final String key;
  final String value;
  final bool critical;

  const CompactionContinuityAnchor({
    required this.key,
    required this.value,
    this.critical = true,
  });
}

/// Anti-thrashing hints produced by the engine for orchestrators (53d).
class CompactionAntiThrashingHints {
  final int repairAttempts;
  final bool noProgress;
  final Duration suggestedCooldown;

  const CompactionAntiThrashingHints({
    required this.repairAttempts,
    required this.noProgress,
    this.suggestedCooldown = const Duration(seconds: 30),
  });
}

/// Validates summary coverage and anti-degradation rules (Plan 53c Gate C4).
class CompactionContinuityValidator {
  final SecretsRedactor _redactor;

  CompactionContinuityValidator({SecretsRedactor? redactor})
      : _redactor = redactor ?? const SecretsRedactor();

  List<CompactionContinuityAnchor> extractAnchors(
    List<IndexedConversationMessage> sourceMessages,
  ) {
    final anchors = <CompactionContinuityAnchor>[];
    for (final entry in sourceMessages) {
      final content = entry.message.content ?? '';
      void addLabeled(String label, {bool critical = true}) {
        final pattern = RegExp(
          '$label:\\s*(.+)',
          caseSensitive: false,
        );
        final match = pattern.firstMatch(content);
        if (match != null) {
          anchors.add(
            CompactionContinuityAnchor(
              key: label,
              value: match.group(1)!.trim(),
              critical: critical,
            ),
          );
        }
      }

      if (entry.message.role == MessageRole.user) {
        addLabeled('goal');
        addLabeled('constraints', critical: false);
        addLabeled('pending ask');
        addLabeled('pending_ask');
        addLabeled('ask');
      }
      addLabeled('path', critical: false);
      addLabeled('blocker');
      addLabeled('decision', critical: false);
      if (entry.message.role == MessageRole.tool &&
          (entry.message.toolCallId ?? '').isNotEmpty) {
        anchors.add(
          CompactionContinuityAnchor(
            key: 'tool_side_effect',
            value: entry.message.toolCallId!,
            critical: false,
          ),
        );
      }
    }
    return anchors;
  }

  CompactionContinuityResult validate({
    required CompactionInternalSummary summary,
    required List<CompactionContinuityAnchor> anchors,
    int repairAttempts = 0,
  }) {
    final redacted = _redactSummary(summary);
    final missing = <String>[
      ...redacted.missingRequiredSections(),
      for (final anchor in anchors.where((a) => a.critical))
        if (!_coversAnchor(redacted, anchor)) anchor.key,
    ];
    return CompactionContinuityResult(
      passed: missing.isEmpty,
      missingAnchors: missing,
      repairAttempts: repairAttempts,
    );
  }

  CompactionInternalSummary _redactSummary(CompactionInternalSummary summary) {
    String redact(String? value) =>
        value == null ? '' : _redactor.redact(value);
    return CompactionInternalSummary(
      previousSummaryAnchor: summary.previousSummaryAnchor,
      currentGoal: redact(summary.currentGoal),
      successCriteria: redact(summary.successCriteria),
      constraints: redact(summary.constraints),
      completedWork: redact(summary.completedWork),
      activeState: redact(summary.activeState),
      decisions: redact(summary.decisions),
      blockers: redact(summary.blockers),
      filesAndPaths: redact(summary.filesAndPaths),
      pendingAsks: redact(summary.pendingAsks),
      remainingWork: redact(summary.remainingWork),
    );
  }

  bool _coversAnchor(
    CompactionInternalSummary summary,
    CompactionContinuityAnchor anchor,
  ) {
    final haystack = [
      summary.currentGoal,
      summary.remainingWork,
      summary.filesAndPaths,
      summary.pendingAsks,
      summary.blockers,
      summary.constraints,
      summary.decisions,
    ].whereType<String>().join('\n');
    return haystack.toLowerCase().contains(anchor.value.toLowerCase());
  }
}
