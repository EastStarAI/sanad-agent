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
  final ConfirmedInputUsageBaseline? confirmedInputUsage;
  final RequestPressureSnapshot? preflightPressure;
  final List<IndexedConversationMessage> timeline;
  final String systemPrompt;
  final String runtimeContext;
  final List<Map<String, dynamic>> toolSchemas;
  final CompactionInternalSummary? previousSummary;
  final CompactionMessageRange? previousSourceRange;
  final int targetRequestTokens;
  final double thresholdRatio;

  const CompactionEngineRequest({
    required this.compactionId,
    required this.sessionId,
    required this.trigger,
    required this.sourceRevision,
    required this.routeSignature,
    required this.contextWindowTokens,
    this.inputLimitTokens,
    this.confirmedInputUsage,
    this.preflightPressure,
    required this.timeline,
    required this.systemPrompt,
    required this.runtimeContext,
    required this.toolSchemas,
    this.previousSummary,
    this.previousSourceRange,
    required this.targetRequestTokens,
    this.thresholdRatio = 0.80,
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
  }) : _pressureEvaluator = pressureEvaluator ?? RequestPressureEvaluator(),
       _tailSelector = tailSelector ?? const CompactionTailSelector(),
       _toolPruner = toolPruner ?? const CompactionToolPruner(),
       _continuityValidator =
           continuityValidator ?? CompactionContinuityValidator(),
       _summarizer = summarizer ?? StructuredCompactionSummarizer();

  RequestPressureSnapshot measurePressure(CompactionEngineRequest request) {
    final preflight = request.preflightPressure;
    if (preflight != null) return preflight;
    return _pressureEvaluator.evaluate(
      routeSignature: request.routeSignature,
      contextWindowTokens: request.contextWindowTokens,
      inputLimitTokens: request.inputLimitTokens,
      conversationMessages: request.timeline.map((e) => e.message).toList(),
      systemPrompt: request.systemPrompt,
      runtimeContext: request.runtimeContext,
      toolSchemas: request.toolSchemas,
      confirmedInputUsage: request.confirmedInputUsage,
      thresholdRatio: request.thresholdRatio,
    );
  }

  CompactionRangeSelection? prepareSelection(
    CompactionEngineRequest request, {
    bool force = false,
  }) {
    final pressure = measurePressure(request);
    if (!force && !pressure.exceedsThreshold) {
      return null;
    }
    final progressCap = (pressure.components.historyTokens * 0.50).floor();
    final tailBudget =
        progressCap > 0 && progressCap < request.targetRequestTokens
        ? progressCap
        : request.targetRequestTokens;
    return _tailSelector.select(
      timeline: request.timeline,
      tailTokenBudget: tailBudget,
      previousSourceEnd: request.previousSourceRange,
    );
  }

  Future<CompactionCandidate?> buildCandidate(
    CompactionEngineRequest request, {
    bool force = false,
    CompactionRangeSelection? preparedSelection,
  }) async {
    final pressure = measurePressure(request);
    final selection =
        preparedSelection ?? prepareSelection(request, force: force);
    if (selection == null) return null;
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
        previousSummaryAnchor: CompactionSummaryPrompt.formatSummary(
          request.previousSummary!,
        ),
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
    var afterTokens = _pressureEvaluator
        .evaluate(
          routeSignature: request.routeSignature,
          contextWindowTokens: request.contextWindowTokens,
          inputLimitTokens: request.inputLimitTokens,
          conversationMessages: projectedMessages,
          systemPrompt: request.systemPrompt,
          runtimeContext: request.runtimeContext,
          toolSchemas: request.toolSchemas,
          confirmedInputUsage: request.confirmedInputUsage,
        )
        .estimatedRequestTokens;

    // C1: a single oversized recent tool/media payload must still produce a
    // measurable candidate via projection-only pruning (canonical rows untouched).
    final effectiveInputBudget = pressure.effectiveInputBudget;
    var retainedTailTokens = CompactionTokenEstimator.estimateMessages(
      projectedTail.map((entry) => entry.message),
    );
    if (afterTokens > effectiveInputBudget ||
        retainedTailTokens > request.targetRequestTokens) {
      projectedTail = _toolPruner.pruneOversizedForProjection(projectedTail);
      projectedMessages = <Message>[
        projectedSummary,
        ...projectedTail.map((entry) => entry.message),
      ];
      afterTokens = _pressureEvaluator
          .evaluate(
            routeSignature: request.routeSignature,
            contextWindowTokens: request.contextWindowTokens,
            inputLimitTokens: request.inputLimitTokens,
            conversationMessages: projectedMessages,
            systemPrompt: request.systemPrompt,
            runtimeContext: request.runtimeContext,
            toolSchemas: request.toolSchemas,
            confirmedInputUsage: request.confirmedInputUsage,
          )
          .estimatedRequestTokens;
      retainedTailTokens = CompactionTokenEstimator.estimateMessages(
        projectedTail.map((entry) => entry.message),
      );
    }

    if (afterTokens > effectiveInputBudget ||
        retainedTailTokens > request.targetRequestTokens) {
      throw CompactionEngineFailure(
        CompactionFailureReason.projectionStillOverBudget,
        estimatedAfterTokens: afterTokens,
      );
    }

    var beforeTokens = pressure.estimatedRequestTokens;
    if (request.trigger == CompactionTrigger.overflow &&
        beforeTokens <= effectiveInputBudget) {
      // A provider overflow is authoritative evidence that the request crossed
      // the usable input budget even when the fallback estimate was low.
      beforeTokens = effectiveInputBudget + 1;
    }
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
        beforeMeasurementKind: pressure.measurementKind,
        retainedTailTokens: retainedTailTokens,
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
