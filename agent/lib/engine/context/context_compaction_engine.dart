import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import 'compaction_continuity_validator.dart';
import 'compaction_summary_prompt.dart';
import 'compaction_summarizer.dart';
import 'compaction_tail_selector.dart';
import 'compaction_token_estimator.dart';
import 'compaction_tool_pruner.dart';
import 'request_pressure_evaluator.dart';
import 'request_pressure_snapshot.dart';

/// Engine input for one compaction attempt (Plan 53c).
class CompactionEngineRequest {
  final String compactionId;
  final String sessionId;
  final CompactionTrigger trigger;
  final CompactionHistoryRevision sourceRevision;
  final RouteSignature routeSignature;
  final int contextWindowTokens;
  final int? inputLimitTokens;
  final int? confirmedInputTokens;
  final List<IndexedConversationMessage> timeline;
  final String systemPrompt;
  final String runtimeContext;
  final List<Map<String, dynamic>> toolSchemas;
  final CompactionInternalSummary? previousSummary;
  final int targetRequestTokens;

  const CompactionEngineRequest({
    required this.compactionId,
    required this.sessionId,
    required this.trigger,
    required this.sourceRevision,
    required this.routeSignature,
    required this.contextWindowTokens,
    this.inputLimitTokens,
    this.confirmedInputTokens,
    required this.timeline,
    required this.systemPrompt,
    required this.runtimeContext,
    required this.toolSchemas,
    this.previousSummary,
    required this.targetRequestTokens,
  });
}

/// Provider-neutral compaction engine (Plan 53c).
class ContextCompactionEngine {
  final RequestPressureEvaluator _pressureEvaluator;
  final CompactionTailSelector _tailSelector;
  final CompactionToolPruner _toolPruner;
  final CompactionContinuityValidator _continuityValidator;
  final CompactionSummarizer _summarizer;

  ContextCompactionEngine({
    RequestPressureEvaluator? pressureEvaluator,
    CompactionTailSelector? tailSelector,
    CompactionToolPruner? toolPruner,
    CompactionContinuityValidator? continuityValidator,
    CompactionSummarizer? summarizer,
  })  : _pressureEvaluator = pressureEvaluator ?? RequestPressureEvaluator(),
        _tailSelector = tailSelector ?? const CompactionTailSelector(),
        _toolPruner = toolPruner ?? const CompactionToolPruner(),
        _continuityValidator =
            continuityValidator ?? CompactionContinuityValidator(),
        _summarizer = summarizer ?? StructuredCompactionSummarizer();

  RequestPressureSnapshot measurePressure(CompactionEngineRequest request) {
    return _pressureEvaluator.evaluate(
      routeSignature: request.routeSignature,
      contextWindowTokens: request.contextWindowTokens,
      inputLimitTokens: request.inputLimitTokens,
      conversationMessages: request.timeline.map((e) => e.message).toList(),
      systemPrompt: request.systemPrompt,
      runtimeContext: request.runtimeContext,
      toolSchemas: request.toolSchemas,
      confirmedInputTokens: request.confirmedInputTokens,
    );
  }

  Future<CompactionCandidate?> buildCandidate(
    CompactionEngineRequest request, {
    bool force = false,
  }) async {
    final pressure = measurePressure(request);
    if (!force &&
        !pressure.exceedsThreshold &&
        pressure.estimatedRequestTokens <= request.targetRequestTokens) {
      return null;
    }

    final tailBudget = (request.targetRequestTokens * 0.35).round();
    final selection = _tailSelector.select(
      timeline: request.timeline,
      tailTokenBudget: tailBudget,
    );
    final prunedSource = _toolPruner.pruneSourceMessages(
      selection.sourceMessages,
      protectedTailStartRowId: selection.retainedTailRange.start.rowId,
    );
    final anchors = _continuityValidator.extractAnchors(prunedSource);
    final promptPasses = CompactionSummaryPrompt.buildPasses(
      sourceMessages: prunedSource,
      previousSummary: request.previousSummary,
    );
    final rawParts = <String>[];
    for (final prompt in promptPasses) {
      rawParts.add(await _summarizer.summarize(prompt: prompt));
    }
    final rawSummary = rawParts.join('\n');
    var summary = CompactionSummaryParser.parse(rawSummary);
    if (summary.currentGoal.trim().isEmpty ||
        (summary.remainingWork ?? '').trim().isEmpty) {
      throw CompactionEngineFailure(
        CompactionFailureReason.summarizationFailed,
      );
    }
    if (request.previousSummary != null) {
      summary = CompactionInternalSummary(
        previousSummaryAnchor:
            CompactionSummaryPrompt.formatSummary(request.previousSummary!),
        currentGoal: summary.currentGoal,
        successCriteria: summary.successCriteria,
        constraints: summary.constraints,
        completedWork: summary.completedWork,
        activeState: summary.activeState,
        decisions: summary.decisions,
        blockers: summary.blockers,
        filesAndPaths: summary.filesAndPaths,
        pendingAsks: summary.pendingAsks,
        remainingWork: summary.remainingWork,
      );
    }

    var continuity = _continuityValidator.validate(
      summary: summary,
      anchors: anchors,
    );
    if (!continuity.passed && continuity.repairAttempts == 0) {
      final repairPrompt =
          '${promptPasses.last}\n\nRepair the summary. Missing anchors: ${continuity.missingAnchors.join(', ')}';
      final repaired = CompactionSummaryParser.parse(
        await _summarizer.summarize(prompt: repairPrompt),
      );
      continuity = _continuityValidator.validate(
        summary: repaired,
        anchors: anchors,
        repairAttempts: 1,
      );
      if (continuity.passed) {
        summary = repaired;
      }
    }
    if (!continuity.passed) {
      throw CompactionEngineFailure(
        CompactionFailureReason.continuityValidationFailed,
        missingAnchors: continuity.missingAnchors,
        antiThrashing: CompactionAntiThrashingHints(
          repairAttempts: continuity.repairAttempts,
          noProgress: true,
        ),
      );
    }

    final projectedSummary = Message(
      role: MessageRole.user,
      content: CompactionSummaryPrompt.formatSummary(summary),
    );
    var projectedTail = selection.tailMessages;
    var projectedMessages = <Message>[
      projectedSummary,
      ...projectedTail.map((entry) => entry.message),
    ];
    var afterTokens = _pressureEvaluator.evaluate(
      routeSignature: request.routeSignature,
      contextWindowTokens: request.contextWindowTokens,
      inputLimitTokens: request.inputLimitTokens,
      conversationMessages: projectedMessages,
      systemPrompt: request.systemPrompt,
      runtimeContext: request.runtimeContext,
      toolSchemas: request.toolSchemas,
      confirmedInputTokens: request.confirmedInputTokens,
    ).estimatedRequestTokens;

    // C1: a single oversized recent tool/media payload must still produce a
    // measurable candidate via projection-only pruning (canonical rows untouched).
    if (afterTokens > request.targetRequestTokens) {
      projectedTail = _toolPruner.pruneOversizedForProjection(projectedTail);
      projectedMessages = <Message>[
        projectedSummary,
        ...projectedTail.map((entry) => entry.message),
      ];
      afterTokens = _pressureEvaluator.evaluate(
        routeSignature: request.routeSignature,
        contextWindowTokens: request.contextWindowTokens,
        inputLimitTokens: request.inputLimitTokens,
        conversationMessages: projectedMessages,
        systemPrompt: request.systemPrompt,
        runtimeContext: request.runtimeContext,
        toolSchemas: request.toolSchemas,
        confirmedInputTokens: request.confirmedInputTokens,
      ).estimatedRequestTokens;
    }

    if (afterTokens > request.targetRequestTokens) {
      throw CompactionEngineFailure(
        CompactionFailureReason.projectionStillOverBudget,
        estimatedAfterTokens: afterTokens,
      );
    }

    final beforeTokens = pressure.estimatedRequestTokens;
    if (afterTokens >= beforeTokens) {
      throw CompactionEngineFailure(
        CompactionFailureReason.projectionStillOverBudget,
        estimatedAfterTokens: afterTokens,
      );
    }

    return CompactionCandidate(
      compactionId: request.compactionId,
      sessionId: request.sessionId,
      trigger: request.trigger,
      sourceRevision: request.sourceRevision,
      sourceRange: selection.sourceRange,
      retainedTailRange: selection.retainedTailRange,
      internalSummary: summary,
      continuityResult: continuity,
      metrics: CompactionMetrics(
        contextWindowTokens: request.contextWindowTokens,
        estimatedRequestTokensBefore: beforeTokens,
        estimatedRequestTokensAfter: afterTokens,
        retainedTailTokens: CompactionTokenEstimator.estimateMessages(
          projectedTail.map((entry) => entry.message),
        ),
      ),
      routeSignature: request.routeSignature,
    );
  }
}

class CompactionEngineFailure implements Exception {
  final CompactionFailureReason reason;
  final List<String> missingAnchors;
  final int? estimatedAfterTokens;
  final CompactionAntiThrashingHints? antiThrashing;

  CompactionEngineFailure(
    this.reason, {
    this.missingAnchors = const [],
    this.estimatedAfterTokens,
    this.antiThrashing,
  });

  @override
  String toString() => 'CompactionEngineFailure($reason)';
}
