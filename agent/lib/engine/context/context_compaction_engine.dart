import 'dart:async';
import 'dart:convert';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/llm_usage_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';

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
  final List<Message>? providerProjection;
  final List<ToolSchema> providerTools;
  final LLMRequestOptions providerRequestOptions;
  final int projectionRevision;
  final CompactionInternalSummary? previousSummary;
  final CompactionMessageRange? previousSourceRange;
  final int targetRequestTokens;
  final double thresholdRatio;
  final double? targetRatio;

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
    this.providerProjection,
    this.providerTools = const [],
    this.providerRequestOptions = const LLMRequestOptions(),
    this.projectionRevision = 0,
    this.previousSummary,
    this.previousSourceRange,
    required this.targetRequestTokens,
    this.thresholdRatio = 0.90,
    this.targetRatio,
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
    if (!_tailSelector.hasCompressibleHead(
      timeline: request.timeline,
      previousSourceEnd: request.previousSourceRange,
    )) {
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
    final List<IndexedConversationMessage> prunedSource;
    try {
      prunedSource = _toolPruner.pruneSourceMessages(
        selection.sourceMessages,
        protectedTailStartRowId: selection.retainedTailRange.start.rowId,
      );
    } catch (_) {
      throw CompactionEngineFailure(
        CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.pruning,
        cause: CompactionFailureCause.toolResultMalformed,
      );
    }
    final anchors = _continuityValidator.extractAnchors(prunedSource);
    final generated =
        await _generateSummary(request, prunedSource, anchors, pressure);
    final candidateDiagnostics = CompactionDurableDiagnostics(
      relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
        compactionId: request.compactionId,
        requestId: generated.ledger.isNotEmpty
            ? generated.ledger.last.requestId
            : null,
      ),
      attempts: generated.ledger,
      aggregateUsage: {
        if (generated.aggregateUsage.inputTokens != null)
          'input_tokens': generated.aggregateUsage.inputTokens,
        if (generated.aggregateUsage.cachedInputTokens != null)
          'cached_input_tokens': generated.aggregateUsage.cachedInputTokens,
        if (generated.aggregateUsage.cacheWriteTokens != null)
          'cache_write_tokens': generated.aggregateUsage.cacheWriteTokens,
        if (generated.aggregateUsage.outputTokens != null)
          'output_tokens': generated.aggregateUsage.outputTokens,
        if (generated.aggregateUsage.reasoningTokens != null)
          'reasoning_tokens': generated.aggregateUsage.reasoningTokens,
        if (generated.duration != null)
          'duration_ms': generated.duration!.inMilliseconds,
      },
      decisionSnapshot: {
        'context_window': request.contextWindowTokens,
        'effective_input_budget': pressure.effectiveInputBudget,
        'auto_threshold_tokens': pressure.thresholdTokens,
        'target_request_tokens': request.targetRequestTokens,
        if (request.targetRatio != null) 'target_ratio': request.targetRatio,
        'target_scope': 'usable_budget',
        if (request.thresholdRatio > 0)
          'threshold_ratio': request.thresholdRatio,
      },
      postBoundary: const CompactionPostBoundaryStatus(
        status: 'pending',
        targetOutcome: TargetOutcome.unknown,
      ),
    );

    var summary = generated.summary;
    var continuity = generated.continuity;
    if (!continuity.passed) {
      throw CompactionEngineFailure(
        CompactionFailureReason.continuityValidationFailed,
        stage: CompactionFailureStage.validation,
        cause: CompactionFailureCause.continuityValidationFailed,
        missingAnchors: continuity.missingAnchors,
        antiThrashing: CompactionAntiThrashingHints(
          repairAttempts: continuity.repairAttempts,
          noProgress: true,
        ),
        diagnostics: candidateDiagnostics,
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
      try {
        projectedTail = _toolPruner.pruneOversizedForProjection(projectedTail);
      } catch (_) {
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          stage: CompactionFailureStage.pruning,
          cause: CompactionFailureCause.pruningFailed,
          diagnostics: candidateDiagnostics,
        );
      }
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
        stage: CompactionFailureStage.pruning,
        cause: CompactionFailureCause.projectionStillOverBudget,
        estimatedAfterTokens: afterTokens,
        diagnostics: candidateDiagnostics,
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
        stage: CompactionFailureStage.pruning,
        cause: CompactionFailureCause.projectionStillOverBudget,
        estimatedAfterTokens: afterTokens,
        diagnostics: candidateDiagnostics,
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
        effectiveInputBudgetTokens: pressure.effectiveInputBudget,
        autoThresholdTokens: pressure.thresholdTokens,
        estimatedRequestTokensBefore: beforeTokens,
        estimatedRequestTokensAfter: afterTokens,
        beforeMeasurementKind: pressure.measurementKind,
        retainedTailTokens: retainedTailTokens,
        summarizationInputTokens: generated.aggregateUsage.inputTokens,
        summarizationCachedInputTokens:
            generated.aggregateUsage.cachedInputTokens,
        summarizationCacheWriteTokens:
            generated.aggregateUsage.cacheWriteTokens,
        summarizationOutputTokens: generated.aggregateUsage.outputTokens,
        summarizationReasoningTokens:
            generated.aggregateUsage.reasoningTokens,
        summarizationAttempts: generated.attempts,
        duration: generated.duration,
      ),
      routeSignature: request.routeSignature,
      diagnostics: candidateDiagnostics,
    );
  }

  Future<_GeneratedSummary> _generateSummary(
    CompactionEngineRequest request,
    List<IndexedConversationMessage> prunedSource,
    List<CompactionContinuityAnchor> anchors,
    RequestPressureSnapshot pressure,
  ) async {
    final ledger = <CompactionSummarizationAttemptRecord>[];
    CompactionDurableDiagnostics failureDiagnostics({
      _CompactionUsage? usage,
    }) {
      final effUsage = usage ?? const _CompactionUsage();
      return CompactionDurableDiagnostics(
        relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
          compactionId: request.compactionId,
          requestId: ledger.isNotEmpty ? ledger.last.requestId : null,
        ),
        attempts: List.unmodifiable(ledger),
        aggregateUsage: {
          if (effUsage.inputTokens != null) 'input_tokens': effUsage.inputTokens,
          if (effUsage.cachedInputTokens != null)
            'cached_input_tokens': effUsage.cachedInputTokens,
          if (effUsage.cacheWriteTokens != null)
            'cache_write_tokens': effUsage.cacheWriteTokens,
          if (effUsage.outputTokens != null)
            'output_tokens': effUsage.outputTokens,
          if (effUsage.reasoningTokens != null)
            'reasoning_tokens': effUsage.reasoningTokens,
        },
        decisionSnapshot: {
          'context_window': request.contextWindowTokens,
          'effective_input_budget': pressure.effectiveInputBudget,
          'auto_threshold_tokens': pressure.thresholdTokens,
          'target_request_tokens': request.targetRequestTokens,
          if (request.targetRatio != null) 'target_ratio': request.targetRatio,
          'target_scope': 'usable_budget',
          if (request.thresholdRatio > 0)
            'threshold_ratio': request.thresholdRatio,
        },
      );
    }

    final providerSummarizer = _summarizer;
    if (providerSummarizer is ProviderProjectionCompactionSummarizer) {
      final provider =
          providerSummarizer as ProviderProjectionCompactionSummarizer;
      final base = request.providerProjection;
      if (base == null || base.isEmpty) {
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          diagnostics: failureDiagnostics(),
        );
      }
      final immutableBase = List<Message>.unmodifiable(base);
      var instruction = CompactionSummaryPrompt.buildJsonInstruction();
      var attempts = 0;
      var totalDuration = Duration.zero;
      _CompactionUsage aggregateUsage = const _CompactionUsage();
      _CompactionUsage acceptedUsage = const _CompactionUsage();
      CompactionContinuityResult? lastContinuity;
      for (; attempts < 2; attempts++) {
        final passKind = attempts == 0 ? 'full' : 'repair';
        final attemptRequestId = _buildAttemptRequestId(
          request: request,
          passKind: passKind,
          attempt: attempts,
        );
        final attemptOptions = request.providerRequestOptions.copyWith(
          requestId: attemptRequestId,
        );
        CompactionProviderResult result;
        try {
          result = await provider.summarizeProvider(
            CompactionProviderRequest(
              baseProjection: immutableBase,
              tools: request.providerTools,
              routeSignature: request.routeSignature,
              options: attemptOptions,
              instruction: instruction,
            ),
          );
        } on CompactionRouteChanged {
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: Duration.zero,
            outcome: 'error',
            failureReason: 'route_changed',
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          throw CompactionEngineFailure(
            CompactionFailureReason.sourceRevisionStale,
            stage: CompactionFailureStage.persistence,
            cause: CompactionFailureCause.sourceRevisionStale,
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        } on CompactionProviderOverflow {
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: Duration.zero,
            outcome: 'overflow',
            failureReason: 'context_overflow',
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          if (attempts == 0) {
            return _generateRecoverySummary(
              request: request,
              provider: provider,
              source: prunedSource,
              anchors: anchors,
              initialLedger: ledger,
              pressure: pressure,
            );
          }
          throw CompactionEngineFailure(
            CompactionFailureReason.summarizationFailed,
            stage: CompactionFailureStage.provider,
            cause: CompactionFailureCause.overflow,
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        } on CompactionInvalidProviderResponse catch (error) {
          final errorUsage = _CompactionUsage.fromProvider(error.usage);
          aggregateUsage = aggregateUsage + errorUsage;
          final attemptDuration = error.duration ?? Duration.zero;
          totalDuration += attemptDuration;
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: attemptDuration,
            inputTokens: errorUsage.inputTokens,
            cachedInputTokens: errorUsage.cachedInputTokens,
            cacheWriteTokens: errorUsage.cacheWriteTokens,
            outputTokens: errorUsage.outputTokens,
            reasoningTokens: errorUsage.reasoningTokens,
            outcome: 'invalid_response',
            failureReason: error.reason,
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          if (attempts == 0) {
            instruction = CompactionSummaryPrompt.buildJsonInstruction(
              missingFields: ['valid JSON only; ${error.reason}'],
            );
            continue;
          }
          throw CompactionEngineFailure(
            CompactionFailureReason.summarizationFailed,
            stage: CompactionFailureStage.provider,
            cause: CompactionFailureCause.invalidResponse,
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        } on TimeoutException {
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: Duration.zero,
            outcome: 'error',
            failureReason: CompactionFailureCause.timeout,
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          throw CompactionEngineFailure(
            CompactionFailureReason.summarizationFailed,
            stage: CompactionFailureStage.provider,
            cause: CompactionFailureCause.timeout,
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        } on LlmHttpException catch (error) {
          final isRateLimit = error.statusCode == 429;
          final cause = isRateLimit
              ? CompactionFailureCause.rateLimited
              : CompactionFailureCause.providerError;
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: Duration.zero,
            outcome: 'error',
            failureReason: cause,
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          throw CompactionEngineFailure(
            CompactionFailureReason.summarizationFailed,
            stage: CompactionFailureStage.provider,
            cause: cause,
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        } catch (error) {
          if (error is CompactionEngineFailure) rethrow;
          final classified = CompactionDiagnostics.classify(error);
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: Duration.zero,
            outcome: 'error',
            failureReason: classified.cause,
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          throw CompactionEngineFailure(
            classified.failureReason,
            stage: classified.stage,
            cause: classified.cause,
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        }

        final passUsage = _CompactionUsage.fromProvider(result.usage);
        aggregateUsage = aggregateUsage + passUsage;
        totalDuration += result.duration;

        try {
          final parsed = _continuityValidator.redactSummary(
            CompactionSummaryParser.parse(result.content),
          );
          final continuity = _continuityValidator.validate(
            summary: parsed,
            anchors: anchors,
            repairAttempts: attempts,
          );
          lastContinuity = continuity;
          if (continuity.passed) {
            acceptedUsage = passUsage;
            ledger.add(CompactionSummarizationAttemptRecord(
              passKind: passKind,
              requestId: attemptRequestId,
              duration: result.duration,
              inputTokens: passUsage.inputTokens,
              cachedInputTokens: passUsage.cachedInputTokens,
              cacheWriteTokens: passUsage.cacheWriteTokens,
              outputTokens: passUsage.outputTokens,
              reasoningTokens: passUsage.reasoningTokens,
              outcome: 'success',
              relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
                compactionId: request.compactionId,
                requestId: attemptRequestId,
              ),
            ));
            return _GeneratedSummary(
              summary: parsed,
              continuity: continuity,
              acceptedUsage: acceptedUsage,
              aggregateUsage: aggregateUsage,
              attempts: attempts + 1,
              duration: totalDuration,
              ledger: ledger,
            );
          }
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: result.duration,
            inputTokens: passUsage.inputTokens,
            cachedInputTokens: passUsage.cachedInputTokens,
            cacheWriteTokens: passUsage.cacheWriteTokens,
            outputTokens: passUsage.outputTokens,
            reasoningTokens: passUsage.reasoningTokens,
            outcome: 'validation_failed',
            failureReason: continuity.missingAnchors.join(', '),
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          instruction = CompactionSummaryPrompt.buildJsonInstruction(
            missingFields: continuity.missingAnchors,
          );
        } on FormatException catch (e) {
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: result.duration,
            inputTokens: passUsage.inputTokens,
            cachedInputTokens: passUsage.cachedInputTokens,
            cacheWriteTokens: passUsage.cacheWriteTokens,
            outputTokens: passUsage.outputTokens,
            reasoningTokens: passUsage.reasoningTokens,
            outcome: 'invalid_response',
            failureReason: 'format_error: $e',
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          instruction = CompactionSummaryPrompt.buildJsonInstruction(
            missingFields: CompactionInternalSummary.requiredSectionKeys,
          );
        }
      }
      throw CompactionEngineFailure(
        CompactionFailureReason.continuityValidationFailed,
        missingAnchors:
            lastContinuity?.missingAnchors ??
            CompactionInternalSummary.requiredSectionKeys,
        antiThrashing: const CompactionAntiThrashingHints(
          repairAttempts: 1,
          noProgress: true,
        ),
        diagnostics: failureDiagnostics(usage: aggregateUsage),
      );
    }

    final promptPasses = CompactionSummaryPrompt.buildPasses(
      sourceMessages: prunedSource,
      previousSummary: request.previousSummary,
    );
    final rawParts = <String>[];
    for (final prompt in promptPasses) {
      rawParts.add(await _summarizer.summarize(prompt: prompt));
    }
    var summary = _continuityValidator.redactSummary(
      CompactionSummaryParser.parseLegacy(rawParts.join('\n')),
    );
    var continuity = _continuityValidator.validate(
      summary: summary,
      anchors: anchors,
    );
    final fullRequestId = _buildAttemptRequestId(
      request: request,
      passKind: 'full',
      attempt: 0,
    );
    ledger.add(CompactionSummarizationAttemptRecord(
      passKind: 'full',
      requestId: fullRequestId,
      duration: Duration.zero,
      outcome: continuity.passed ? 'success' : 'validation_failed',
      failureReason: continuity.passed ? null : continuity.missingAnchors.join(', '),
      relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
        compactionId: request.compactionId,
        requestId: fullRequestId,
      ),
    ));
    if (!continuity.passed) {
      final repaired = _continuityValidator.redactSummary(
        CompactionSummaryParser.parseLegacy(
          await _summarizer.summarize(
            prompt:
                '${promptPasses.last}\nRepair missing: ${continuity.missingAnchors.join(', ')}',
          ),
        ),
      );
      continuity = _continuityValidator.validate(
        summary: repaired,
        anchors: anchors,
        repairAttempts: 1,
      );
      final repairRequestId = _buildAttemptRequestId(
        request: request,
        passKind: 'repair',
        attempt: 1,
      );
      ledger.add(CompactionSummarizationAttemptRecord(
        passKind: 'repair',
        requestId: repairRequestId,
        duration: Duration.zero,
        outcome: continuity.passed ? 'success' : 'validation_failed',
        failureReason: continuity.passed ? null : continuity.missingAnchors.join(', '),
        relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
          compactionId: request.compactionId,
          requestId: repairRequestId,
        ),
      ));
      if (continuity.passed) summary = repaired;
    }
    return _GeneratedSummary(
      summary: summary,
      continuity: continuity,
      acceptedUsage: const _CompactionUsage(),
      aggregateUsage: const _CompactionUsage(),
      attempts: continuity.repairAttempts + 1,
      duration: null,
      ledger: ledger,
    );
  }

  Future<_GeneratedSummary> _generateRecoverySummary({
    required CompactionEngineRequest request,
    required ProviderProjectionCompactionSummarizer provider,
    required List<IndexedConversationMessage> source,
    required List<CompactionContinuityAnchor> anchors,
    List<CompactionSummarizationAttemptRecord> initialLedger = const [],
    required RequestPressureSnapshot pressure,
  }) async {
    final ledger = List<CompactionSummarizationAttemptRecord>.from(initialLedger);
    CompactionDurableDiagnostics failureDiagnostics({
      _CompactionUsage? usage,
    }) {
      final effUsage = usage ?? const _CompactionUsage();
      return CompactionDurableDiagnostics(
        relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
          compactionId: request.compactionId,
        ),
        attempts: List.unmodifiable(ledger),
        aggregateUsage: {
          if (effUsage.inputTokens != null) 'input_tokens': effUsage.inputTokens,
          if (effUsage.cachedInputTokens != null)
            'cached_input_tokens': effUsage.cachedInputTokens,
          if (effUsage.cacheWriteTokens != null)
            'cache_write_tokens': effUsage.cacheWriteTokens,
          if (effUsage.outputTokens != null)
            'output_tokens': effUsage.outputTokens,
          if (effUsage.reasoningTokens != null)
            'reasoning_tokens': effUsage.reasoningTokens,
        },
        decisionSnapshot: {
          'context_window': request.contextWindowTokens,
          'effective_input_budget': pressure.effectiveInputBudget,
          'auto_threshold_tokens': pressure.thresholdTokens,
          'target_request_tokens': request.targetRequestTokens,
          if (request.targetRatio != null) 'target_ratio': request.targetRatio,
          'target_scope': 'usable_budget',
          if (request.thresholdRatio > 0)
            'threshold_ratio': request.thresholdRatio,
        },
      );
    }

    final chunks = _boundedSafeChunks(source, maximumChunks: 4);
    if (chunks.isEmpty) {
      throw CompactionEngineFailure(
        CompactionFailureReason.summarizationFailed,
        diagnostics: failureDiagnostics(),
      );
    }
    final stableSystem = request.providerProjection!
        .where((message) => message.role == MessageRole.system)
        .toList(growable: false);
    final partials = <CompactionInternalSummary>[];
    var aggregateUsage = const _CompactionUsage();
    var duration = Duration.zero;
    var attempts = 0;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final generated = await _recoveryPass(
        request: request,
        provider: provider,
        baseProjection: [
          ...stableSystem,
          ...chunk.map((entry) => entry.message),
        ],
        instruction: CompactionSummaryPrompt.buildJsonInstruction(
          partial: true,
        ),
        passKind: 'chunk',
        chunkIndex: i,
        ledger: ledger,
        failureDiagnostics: failureDiagnostics,
      );
      partials.add(generated.summary);
      aggregateUsage = aggregateUsage + generated.aggregateUsage;
      duration += generated.duration ?? Duration.zero;
      attempts += generated.attempts;
    }

    final reduceBase = <Message>[
      ...stableSystem,
      Message(
        role: MessageRole.user,
        content: jsonEncode([
          for (final summary in partials)
            CompactionSummaryPrompt.toJsonMap(summary),
        ]),
      ),
    ];
    final reduced = await _recoveryPass(
      request: request,
      provider: provider,
      baseProjection: reduceBase,
      instruction: CompactionSummaryPrompt.buildJsonInstruction(),
      anchors: anchors,
      passKind: 'reduce',
      ledger: ledger,
      failureDiagnostics: failureDiagnostics,
    );
    return _GeneratedSummary(
      summary: reduced.summary,
      continuity: reduced.continuity,
      acceptedUsage: reduced.acceptedUsage,
      aggregateUsage: aggregateUsage + reduced.aggregateUsage,
      attempts: attempts + reduced.attempts,
      duration: duration + (reduced.duration ?? Duration.zero),
      ledger: ledger,
    );
  }

  Future<_GeneratedSummary> _recoveryPass({
    required CompactionEngineRequest request,
    required ProviderProjectionCompactionSummarizer provider,
    required List<Message> baseProjection,
    required String instruction,
    List<CompactionContinuityAnchor> anchors = const [],
    required String passKind,
    int? chunkIndex,
    required List<CompactionSummarizationAttemptRecord> ledger,
    required CompactionDurableDiagnostics Function({_CompactionUsage? usage})
        failureDiagnostics,
  }) async {
    final immutableBase = List<Message>.unmodifiable(baseProjection);
    CompactionContinuityResult? lastContinuity;
    var aggregateUsage = const _CompactionUsage();
    var duration = Duration.zero;
    for (var attempt = 0; attempt < 2; attempt++) {
      final effectivePassKind = attempt == 0 ? passKind : 'repair';
      final attemptRequestId = _buildAttemptRequestId(
        request: request,
        passKind: effectivePassKind,
        attempt: attempt,
        chunkIndex: chunkIndex,
      );
      final attemptOptions = request.providerRequestOptions.copyWith(
        requestId: attemptRequestId,
      );
      try {
        final result = await provider.summarizeProvider(
          CompactionProviderRequest(
            baseProjection: immutableBase,
            tools: request.providerTools,
            routeSignature: request.routeSignature,
            options: attemptOptions,
            instruction: instruction,
          ),
        );
        final passUsage = _CompactionUsage.fromProvider(result.usage);
        aggregateUsage = aggregateUsage + passUsage;
        duration += result.duration;
        final summary = _continuityValidator.redactSummary(
          CompactionSummaryParser.parse(result.content),
        );
        final continuity = _continuityValidator.validate(
          summary: summary,
          anchors: anchors,
          repairAttempts: attempt,
        );
        lastContinuity = continuity;
        if (continuity.passed) {
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: effectivePassKind,
            requestId: attemptRequestId,
            duration: result.duration,
            inputTokens: passUsage.inputTokens,
            cachedInputTokens: passUsage.cachedInputTokens,
            cacheWriteTokens: passUsage.cacheWriteTokens,
            outputTokens: passUsage.outputTokens,
            reasoningTokens: passUsage.reasoningTokens,
            outcome: 'success',
            relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
              compactionId: request.compactionId,
              requestId: attemptRequestId,
            ),
          ));
          return _GeneratedSummary(
            summary: summary,
            continuity: continuity,
            acceptedUsage: passUsage,
            aggregateUsage: aggregateUsage,
            attempts: attempt + 1,
            duration: duration,
            ledger: ledger,
          );
        }
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: result.duration,
          inputTokens: passUsage.inputTokens,
          cachedInputTokens: passUsage.cachedInputTokens,
          cacheWriteTokens: passUsage.cacheWriteTokens,
          outputTokens: passUsage.outputTokens,
          reasoningTokens: passUsage.reasoningTokens,
          outcome: 'validation_failed',
          failureReason: continuity.missingAnchors.join(', '),
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: continuity.missingAnchors,
          partial: anchors.isEmpty,
        );
      } on CompactionRouteChanged {
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: Duration.zero,
          outcome: 'error',
          failureReason: 'route_changed',
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        throw CompactionEngineFailure(
          CompactionFailureReason.sourceRevisionStale,
          diagnostics: failureDiagnostics(usage: aggregateUsage),
        );
      } on CompactionProviderOverflow {
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: Duration.zero,
          outcome: 'overflow',
          failureReason: 'context_overflow',
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          diagnostics: failureDiagnostics(usage: aggregateUsage),
        );
      } on CompactionInvalidProviderResponse catch (error) {
        final errorUsage = _CompactionUsage.fromProvider(error.usage);
        aggregateUsage = aggregateUsage + errorUsage;
        final attemptDuration = error.duration ?? Duration.zero;
        duration += attemptDuration;
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: attemptDuration,
          inputTokens: errorUsage.inputTokens,
          cachedInputTokens: errorUsage.cachedInputTokens,
          cacheWriteTokens: errorUsage.cacheWriteTokens,
          outputTokens: errorUsage.outputTokens,
          reasoningTokens: errorUsage.reasoningTokens,
          outcome: 'invalid_response',
          failureReason: error.reason,
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: ['valid JSON only; ${error.reason}'],
          partial: anchors.isEmpty,
        );
      } on TimeoutException {
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: Duration.zero,
          outcome: 'error',
          failureReason: CompactionFailureCause.timeout,
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          stage: CompactionFailureStage.provider,
          cause: CompactionFailureCause.timeout,
          diagnostics: failureDiagnostics(usage: aggregateUsage),
        );
      } on LlmHttpException catch (error) {
        final isRateLimit = error.statusCode == 429;
        final cause = isRateLimit
            ? CompactionFailureCause.rateLimited
            : CompactionFailureCause.providerError;
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: Duration.zero,
          outcome: 'error',
          failureReason: cause,
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          stage: CompactionFailureStage.provider,
          cause: cause,
          diagnostics: failureDiagnostics(usage: aggregateUsage),
        );
      } on FormatException catch (e) {
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: Duration.zero,
          outcome: 'invalid_response',
          failureReason: 'format_error: $e',
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: CompactionInternalSummary.requiredSectionKeys,
          partial: anchors.isEmpty,
        );
      } catch (error) {
        if (error is CompactionEngineFailure) rethrow;
        final classified = CompactionDiagnostics.classify(error);
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: Duration.zero,
          outcome: 'error',
          failureReason: classified.cause,
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        throw CompactionEngineFailure(
          classified.failureReason,
          stage: classified.stage,
          cause: classified.cause,
          diagnostics: failureDiagnostics(usage: aggregateUsage),
        );
      }
    }
    throw CompactionEngineFailure(
      CompactionFailureReason.continuityValidationFailed,
      missingAnchors:
          lastContinuity?.missingAnchors ??
          CompactionInternalSummary.requiredSectionKeys,
      diagnostics: failureDiagnostics(usage: aggregateUsage),
    );
  }

  static List<List<IndexedConversationMessage>> _boundedSafeChunks(
    List<IndexedConversationMessage> source, {
    required int maximumChunks,
  }) {
    if (source.isEmpty) return const [];
    final groups = <List<IndexedConversationMessage>>[];
    for (var index = 0; index < source.length; index++) {
      final current = source[index];
      final group = <IndexedConversationMessage>[current];
      if (current.message.role == MessageRole.assistant &&
          (current.message.toolCalls?.isNotEmpty ?? false)) {
        final ids = current.message.toolCalls!.map((call) => call.id).toSet();
        while (index + 1 < source.length &&
            source[index + 1].message.role == MessageRole.tool &&
            ids.contains(source[index + 1].message.toolCallId)) {
          group.add(source[++index]);
        }
      }
      groups.add(group);
    }
    final chunkCount = groups.length.clamp(1, maximumChunks);
    final groupsPerChunk = (groups.length / chunkCount).ceil();
    final chunks = <List<IndexedConversationMessage>>[];
    for (var index = 0; index < groups.length; index += groupsPerChunk) {
      chunks.add([
        for (final group in groups.skip(index).take(groupsPerChunk)) ...group,
      ]);
    }
    return chunks;
  }

  static String _buildAttemptRequestId({
    required CompactionEngineRequest request,
    required String passKind,
    required int attempt,
    int? chunkIndex,
  }) {
    final rawBase = request.providerRequestOptions.requestId?.trim();
    String? baseId = rawBase;
    if (baseId != null && baseId.isNotEmpty) {
      baseId = baseId.replaceAll(
        RegExp(r':(full|repair|chunk|reduce):\d+(_\d+)?$'),
        '',
      );
    }
    final String prefix;
    if (baseId != null && baseId.isNotEmpty) {
      prefix = baseId.startsWith('compaction:') ? baseId : 'compaction:$baseId';
    } else {
      final compId = request.compactionId.trim();
      prefix = compId.startsWith('compaction:')
          ? compId
          : 'compaction:$compId';
    }
    if (chunkIndex != null) {
      return '$prefix:$passKind:${chunkIndex}_$attempt';
    }
    return '$prefix:$passKind:$attempt';
  }
}

class _GeneratedSummary {
  final CompactionInternalSummary summary;
  final CompactionContinuityResult continuity;
  final _CompactionUsage acceptedUsage;
  final _CompactionUsage aggregateUsage;
  final int attempts;
  final Duration? duration;
  final List<CompactionSummarizationAttemptRecord> ledger;

  const _GeneratedSummary({
    required this.summary,
    required this.continuity,
    required this.acceptedUsage,
    required this.aggregateUsage,
    required this.attempts,
    required this.duration,
    this.ledger = const [],
  });
}

class _CompactionUsage {
  final int? inputTokens;
  final int? cachedInputTokens;
  final int? cacheWriteTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  const _CompactionUsage({
    this.inputTokens,
    this.cachedInputTokens,
    this.cacheWriteTokens,
    this.outputTokens,
    this.reasoningTokens,
  });

  factory _CompactionUsage.fromProvider(Map<String, dynamic>? usage) {
    if (usage == null) return const _CompactionUsage();
    final snapshot = LlmUsageSnapshot.fromProviderUsage(usage);

    return _CompactionUsage(
      inputTokens: snapshot.inputTokens,
      cachedInputTokens: snapshot.cachedTokens,
      cacheWriteTokens: snapshot.cacheWriteTokens,
      outputTokens: snapshot.outputTokens,
      reasoningTokens: snapshot.reasoningTokens,
    );
  }

  _CompactionUsage operator +(_CompactionUsage other) => _CompactionUsage(
    inputTokens: _sum(inputTokens, other.inputTokens),
    cachedInputTokens: _sum(cachedInputTokens, other.cachedInputTokens),
    cacheWriteTokens: _sum(cacheWriteTokens, other.cacheWriteTokens),
    outputTokens: _sum(outputTokens, other.outputTokens),
    reasoningTokens: _sum(reasoningTokens, other.reasoningTokens),
  );

  static int? _sum(int? a, int? b) => a == null
      ? b
      : b == null
      ? a
      : a + b;
}

class CompactionEngineFailure implements Exception {
  final CompactionFailureReason reason;
  final String? stage;
  final String? cause;
  final List<String> missingAnchors;
  final int? estimatedAfterTokens;
  final CompactionAntiThrashingHints? antiThrashing;
  final CompactionDurableDiagnostics? diagnostics;

  CompactionEngineFailure(
    this.reason, {
    this.stage,
    this.cause,
    this.missingAnchors = const [],
    this.estimatedAfterTokens,
    this.antiThrashing,
    this.diagnostics,
  });

  @override
  String toString() =>
      'CompactionEngineFailure($reason, stage: $stage, cause: $cause)';
}
