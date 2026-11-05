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
  /// Longest label value that may stay a critical anchor.
  ///
  /// A label whose value runs longer than this is prose (a brief line, a pasted
  /// paragraph), not a continuity anchor: no summary can be required to
  /// reproduce it verbatim. The anchor is still reported, so extraction stays
  /// observable, but it never blocks a boundary.
  static const int maxCriticalAnchorChars = 160;

  /// The line grammar for one labelled anchor.
  ///
  /// The label owns its line: optional indentation, markdown list or quote
  /// markers, an optional ATX heading prefix, optional emphasis markers, the
  /// label, a colon, and a non-empty value. Anchoring at the line start is what
  /// keeps `Task:` and `mask:` from arming an `ask` anchor, and requiring the
  /// colon directly after the label is what keeps `asked about:` from arming it.
  /// A label used mid-paragraph is prose rather than an anchor: that is the
  /// price of a grammar that cannot match inside another word.
  static RegExp labelPattern(String label) => RegExp(
    r'^[ \t]*(?:[-*+>][ \t]*)*(?:#{1,6}[ \t]*)?(?:\*\*|__)?' +
        RegExp.escape(label) +
        r'(?:\*\*|__)?[ \t]*:[ \t]*(\S.*)$',
    multiLine: true,
    caseSensitive: false,
  );

  final SecretsRedactor _redactor;

  CompactionContinuityValidator({SecretsRedactor? redactor})
    : _redactor = redactor ?? const SecretsRedactor();

  List<CompactionContinuityAnchor> extractAnchors(
    List<IndexedConversationMessage> sourceMessages,
  ) {
    final anchors = <CompactionContinuityAnchor>[];
    // One anchor per label key: a restated goal or a second blocker must not
    // multiply the verbatim coverage a summary owes, and the first occurrence
    // is the stable one across successive summarized ranges.
    final labeledKeys = <String>{};
    for (final entry in sourceMessages) {
      final content = entry.message.content ?? '';
      void addLabeled(String label, {bool critical = true}) {
        final match = labelPattern(label).firstMatch(content);
        if (match == null || !labeledKeys.add(label)) return;
        final value = match.group(1)!.trim();
        anchors.add(
          CompactionContinuityAnchor(
            key: label,
            value: value,
            critical: critical && value.length <= maxCriticalAnchorChars,
          ),
        );
      }

      // Only user-authored text may establish semantic continuity anchors.
      // Tool output and assistant content commonly quote source files, logs,
      // and JSON containing labels such as `goal:` or `blocker:`; treating
      // those incidental strings as user intent makes valid compactions fail.
      if (entry.message.role == MessageRole.user) {
        addLabeled('goal');
        addLabeled('constraints', critical: false);
        addLabeled('pending ask');
        addLabeled('pending_ask');
        addLabeled('ask');
        addLabeled('path', critical: false);
        addLabeled('blocker');
        addLabeled('decision', critical: false);
      }
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
    final redacted = redactSummary(summary);
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

  CompactionInternalSummary redactSummary(CompactionInternalSummary summary) {
    String redact(String? value) =>
        value == null ? '' : _redactor.redact(value);
    return CompactionInternalSummary(
      previousSummaryAnchor: summary.previousSummaryAnchor,
      currentGoal: redact(summary.currentGoal),
      latestUserRequest: redact(summary.latestUserRequest),
      successCriteria: redact(summary.successCriteria),
      constraints: redact(summary.constraints),
      completedWork: redact(summary.completedWork),
      activeState: redact(summary.activeState),
      criticalContext: redact(summary.criticalContext),
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
      summary.latestUserRequest,
      summary.activeState,
      summary.criticalContext,
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
