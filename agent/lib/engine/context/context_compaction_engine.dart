import 'dart:async';
import 'dart:convert';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/llm_usage_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';
import 'package:sanad_agent/evolution/compaction/compaction_summary_projection.dart';

import 'compaction_continuity_validator.dart';
import 'compaction_request_budget.dart';
import 'compaction_summary_prompt.dart';
import 'compaction_summarizer.dart';
import 'compaction_tail_selector.dart';
import 'compaction_token_estimator.dart';
import 'compaction_tool_pruner.dart';
import 'confirmed_usage_receipt.dart';
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
  /// Complete post-compaction request target over the full window `W`
  /// (Task 118 Stage3A): `targetRatio × W`.
  final int targetRequestTokens;
  final double thresholdRatio;
  final double? targetRatio;

  /// The active route's wire measurement of a provider projection, when the
  /// route exposes one.
  final CompactionWireMeter? wireMeter;

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
    this.wireMeter,
  });
}

/// Provider-neutral compaction engine (Plan 53c).
class ContextCompactionEngine {
  final RequestPressureEvaluator _pressureEvaluator;
  final CompactionTailSelector _tailSelector;
  final CompactionToolPruner _toolPruner;
  final CompactionContinuityValidator _continuityValidator;
  final CompactionSummarizer _summarizer;
  final CompactionRecoveryPolicy _recoveryPolicy;

  ContextCompactionEngine({
    RequestPressureEvaluator? pressureEvaluator,
    CompactionTailSelector? tailSelector,
    CompactionToolPruner? toolPruner,
    CompactionContinuityValidator? continuityValidator,
    CompactionSummarizer? summarizer,
    CompactionRecoveryPolicy recoveryPolicy = CompactionRecoveryPolicy.defaults,
  }) : _recoveryPolicy = recoveryPolicy,
       _pressureEvaluator = pressureEvaluator ?? RequestPressureEvaluator(),
       _tailSelector = tailSelector ?? const CompactionTailSelector(),
       _toolPruner = toolPruner ?? const CompactionToolPruner(),
       _continuityValidator =
           continuityValidator ?? CompactionContinuityValidator(),
       _summarizer = summarizer ?? StructuredCompactionSummarizer();

  RequestPressureSnapshot measurePressure(CompactionEngineRequest request) {
    final preflight = request.preflightPressure;
    if (preflight != null) return preflight;
    // The request being replaced is the active projection: instructions,
    // tools, the previous summary and the rows after its source range, never
    // the canonical head hidden behind an eligible boundary.
    final startIndex = _tailSelector.sourceStartIndex(
      timeline: request.timeline,
      previousSourceEnd: request.previousSourceRange,
    );
    final previous = request.previousSummary;
    final conversation = <Message>[
      if (previous != null && request.previousSourceRange != null)
        Message(
          role: MessageRole.user,
          content: CompactionSummaryProjection.format(previous),
        ),
      for (final entry in request.timeline.skip(startIndex)) entry.message,
    ];
    final projection = request.providerProjection;
    final instructions = projection == null
        ? const <Message>[]
        : leadingSystemMessages(projection);
    return _pressureEvaluator.evaluate(
      routeSignature: request.routeSignature,
      contextWindowTokens: request.contextWindowTokens,
      inputLimitTokens: request.inputLimitTokens,
      conversationMessages: conversation,
      systemPrompt: instructions.isNotEmpty
          ? instructions.map((message) => message.content ?? '').join('\n')
          : request.systemPrompt,
      runtimeContext: instructions.isNotEmpty ? '' : request.runtimeContext,
      toolSchemas: _toolSchemas(request),
      confirmedInputUsage: request.confirmedInputUsage,
      thresholdRatio: request.thresholdRatio,
    );
  }

  /// Measures the complete-request inputs before selection (Task 118
  /// Stage3A): the fixed overhead the post-compaction request keeps intact
  /// and, on a route with wire measurement, the complete current request.
  Future<CompactionRequestMeasurement> measureRequest(
    CompactionEngineRequest request,
  ) async {
    final projection = request.providerProjection;
    final meter = request.wireMeter;
    if (meter != null && projection != null && projection.isNotEmpty) {
      try {
        final fixed = await meter(leadingSystemMessages(projection));
        final full = await meter(projection);
        if (fixed != null && full != null) {
          final tail = await _measureTailCosts(request, meter, projection, full);
          return CompactionRequestMeasurement(
            fixedOverheadTokens: fixed.estimatedTokens,
            wireMeasured: true,
            requestTokens: tail?.requestTokens ?? full.estimatedTokens,
            requestKind: tail?.requestKind ?? CompactionMeasurementKind.estimated,
            tailCosts: tail?.costs,
          );
        }
      } catch (_) {
        // Measurement is advisory; the provider-neutral estimate below keeps
        // compaction available when the wire codec cannot measure.
      }
    }
    return _estimatedMeasurement(request);
  }

  /// Prices every candidate retained tail as transmitted (Task 118 Stage3A
  /// replay-aware selection).
  ///
  /// The active provider projection must align row for row with the timeline
  /// after the previous source range; otherwise nothing is claimed and the
  /// selection falls back to the provider-neutral estimate. Each candidate
  /// start is priced by the route's wire estimate of the tail, and the span
  /// between two provider receipts that the active adapter proves against the
  /// current request carries the provider-confirmed input difference instead.
  /// That span includes replayed reasoning and tool framing at the cost the
  /// provider reported. Opaque replay outside a proven span stays unknown and
  /// is counted, never priced as zero or from its ciphertext.
  Future<_TailCostMeasurement?> _measureTailCosts(
    CompactionEngineRequest request,
    CompactionWireMeter meter,
    List<Message> projection,
    WireInputMeasurement full,
  ) async {
    final timeline = request.timeline;
    final startIndex = _tailSelector.sourceStartIndex(
      timeline: timeline,
      previousSourceEnd: request.previousSourceRange,
    );
    if (startIndex >= timeline.length - 1) return null;
    final rowCount = timeline.length - startIndex;
    final offset = projection.length - rowCount;
    final instructionCount = leadingSystemMessages(projection).length;
    final summaryOffset = request.previousSourceRange != null ? 1 : 0;
    if (offset != instructionCount && offset != instructionCount + summaryOffset) {
      return null;
    }
    for (var row = 0; row < rowCount; row++) {
      if (jsonEncode(projection[offset + row].toJson()) !=
          jsonEncode(timeline[startIndex + row].message.toJson())) {
        return null;
      }
    }

    final minimalStart = _tailSelector.minimalTailStart(
      timeline: timeline,
      previousSourceEnd: request.previousSourceRange,
    );
    final opaqueItems = [
      for (final entry in timeline) _opaqueReplayItems(entry.message),
    ];
    final costs = <int, CompactionTailCost>{};
    int? latestIndex;
    int? latestInput;
    int? latestDelta;
    int? nearestIndex;
    int? nearestInput;
    int? nearestDelta;
    var proven = 0;
    for (var index = timeline.length - 1; index > startIndex; index--) {
      final prefix = await meter(
        projection.sublist(0, offset + index - startIndex),
      );
      if (prefix == null) return null;
      final receipt = ConfirmedUsageReceipt.read(
        timeline[index].message,
        routeSignature: request.routeSignature,
        providerAlias: request.providerRequestOptions.providerInstanceId,
      );
      if (receipt != null &&
          receipt.provenBy(prefix, request.routeSignature) &&
          full.extendsMeasurement(prefix)) {
        final delta = receipt.inputTokens - prefix.estimatedTokens;
        latestIndex ??= index;
        latestInput ??= receipt.inputTokens;
        latestDelta ??= delta;
        nearestIndex = index;
        nearestInput = receipt.inputTokens;
        nearestDelta = delta;
        proven++;
      }
      final wireTail = full.estimatedTokens - prefix.estimatedTokens;
      final correction = latestDelta == null ? 0 : latestDelta - nearestDelta!;
      final tokens = wireTail + correction;
      var unproven = 0;
      for (var row = index; row < timeline.length; row++) {
        final covered =
            nearestIndex != null && row >= nearestIndex && row < latestIndex!;
        if (!covered) unproven += opaqueItems[row];
      }
      final hasConfirmedSpan =
          nearestIndex != null && nearestIndex != latestIndex;
      costs[index] = CompactionTailCost(
        tokens: tokens < 0 ? 0 : tokens,
        kind: hasConfirmedSpan
            ? CompactionMeasurementKind.mixed
            : CompactionMeasurementKind.estimated,
        confirmedTokens: hasConfirmedSpan ? latestInput! - nearestInput! : 0,
        unprovenReplayItems: unproven,
      );
      if (tokens > request.targetRequestTokens && index <= minimalStart) break;
    }
    return _TailCostMeasurement(
      costs: CompactionTailCosts(costs, provenReceipts: proven),
      requestTokens: latestDelta == null
          ? full.estimatedTokens
          : full.estimatedTokens + latestDelta,
      requestKind: latestDelta == null
          ? CompactionMeasurementKind.estimated
          : CompactionMeasurementKind.mixed,
    );
  }

  /// Opaque provider replay items a message carries on the wire, such as
  /// encrypted reasoning items: provider-priced state the text estimator
  /// cannot see.
  static int _opaqueReplayItems(Message message) {
    final state = message.providerState;
    if (state == null) return 0;
    int count(Object? value) {
      if (value is Map) {
        var total = 0;
        for (final entry in value.entries) {
          if (CompactionTokenEstimator.opaqueWireKeys.contains(entry.key) &&
              entry.value is String &&
              (entry.value as String).isNotEmpty) {
            total++;
          } else {
            total += count(entry.value);
          }
        }
        return total;
      }
      if (value is List) {
        return value.fold(0, (sum, item) => sum + count(item));
      }
      return 0;
    }

    return count(state.data);
  }

  CompactionRequestMeasurement _estimatedMeasurement(
    CompactionEngineRequest request,
  ) {
    final projection = request.providerProjection;
    final instructions = projection == null
        ? const <Message>[]
        : leadingSystemMessages(projection);
    final instructionTokens = instructions.isNotEmpty
        ? CompactionTokenEstimator.estimateMessages(instructions)
        : CompactionTokenEstimator.estimateText(request.systemPrompt) +
              CompactionTokenEstimator.estimateText(request.runtimeContext);
    return CompactionRequestMeasurement(
      fixedOverheadTokens:
          instructionTokens +
          CompactionTokenEstimator.estimateToolSchemas(_toolSchemas(request)),
      wireMeasured: false,
    );
  }

  /// Tool schemas the request carries: the explicit list, else the provider
  /// tools themselves (manual compaction passes only the latter).
  static List<Map<String, dynamic>> _toolSchemas(
    CompactionEngineRequest request,
  ) => request.toolSchemas.isNotEmpty
      ? request.toolSchemas
      : [for (final tool in request.providerTools) tool.toJson()];

  RequestPressureSnapshot _pressureFor(
    CompactionEngineRequest request,
    CompactionRequestMeasurement measurement,
  ) {
    final pressure = measurePressure(request);
    final measured = measurement.requestTokens;
    if (request.preflightPressure != null || measured == null) return pressure;
    return pressure.withRequestTokens(measured, measurement.requestKind);
  }

  /// Summary size reserved while the tail is selected: the previous summary
  /// as transmitted when one exists, otherwise the planning reservation.
  static int _summaryReservation(CompactionEngineRequest request) {
    final previous = request.previousSummary;
    if (previous == null) return CompactionTargetPolicy.summaryReservationTokens;
    return CompactionTokenEstimator.estimateText(
      CompactionSummaryProjection.format(previous),
    );
  }

  CompactionRangeSelection? prepareSelection(
    CompactionEngineRequest request, {
    bool force = false,
    CompactionRequestMeasurement? measurement,
  }) {
    final measured = measurement ?? _estimatedMeasurement(request);
    final pressure = _pressureFor(request, measured);
    if (!force && !pressure.exceedsThreshold) {
      return null;
    }
    if (!_tailSelector.hasCompressibleHead(
      timeline: request.timeline,
      previousSourceEnd: request.previousSourceRange,
    )) {
      return null;
    }
    // Task 118 Stage3A: the target covers the complete next request, so the
    // tail gets what remains after the intact instructions, tools and summary.
    final reservation = _summaryReservation(request);
    final remainder =
        request.targetRequestTokens - measured.fixedOverheadTokens - reservation;
    final targetTailBudget = remainder > 0 ? remainder : 0;
    final progressCap = (pressure.components.historyTokens * 0.50).floor();
    final tailBudget = progressCap > 0 && progressCap < targetTailBudget
        ? progressCap
        : targetTailBudget;
    final tailCosts = measured.tailCosts;
    return _tailSelector
        .select(
          timeline: request.timeline,
          tailTokenBudget: tailBudget,
          previousSourceEnd: request.previousSourceRange,
          tailCost: tailCosts == null
              ? null
              : (int start) => tailCosts[start]?.tokens,
        )
        .withBudget(
          CompactionSelectionBudget(
            measurement: measured,
            summaryReservationTokens: reservation,
            tailBudgetTokens: tailBudget,
          ),
        );
  }

  Future<CompactionCandidate?> buildCandidate(
    CompactionEngineRequest request, {
    bool force = false,
    CompactionRangeSelection? preparedSelection,
  }) async {
    final measurement =
        preparedSelection?.budget?.measurement ?? await measureRequest(request);
    final pressure = _pressureFor(request, measurement);
    final selection =
        preparedSelection ??
        prepareSelection(request, force: force, measurement: measurement);
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
    final decisionSnapshot = <String, dynamic>{
      ..._decisionSnapshot(request, pressure, selection.budget),
      ...generated.decisionSnapshot,
    };
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
      decisionSnapshot: decisionSnapshot,
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

    // Task 118 Stage3A: the post-compaction request is measured as it will be
    // transmitted: the intact instructions and tools, the summary in its
    // projection form, and the retained tail.
    final projectedSummary = Message(
      role: MessageRole.user,
      content: CompactionSummaryProjection.format(summary),
      metadata: const {CompactionSummaryProjection.projectionMetadataKey: true},
    );
    var projectedTail = selection.tailMessages;
    final post = await _measurePostRequest(
      request,
      measurement,
      projectedSummary,
      projectedTail.map((entry) => entry.message).toList(growable: false),
    );
    final fixedOverheadTokens = measurement.fixedOverheadTokens;
    final summaryTokens = post.summaryTokens;
    var retainedTailTokens = post.tailTokens;
    var afterTokens = fixedOverheadTokens + summaryTokens + retainedTailTokens;

    // C1: a single oversized recent tool/media payload that would not fit the
    // usable input budget at all is re-measured through projection-only
    // pruning (canonical rows untouched) before the request is rejected.
    final effectiveInputBudget = pressure.effectiveInputBudget;
    if (afterTokens > effectiveInputBudget) {
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
      retainedTailTokens = _estimatedTailTokens(
        projectedTail.map((entry) => entry.message),
      );
      afterTokens = fixedOverheadTokens + summaryTokens + retainedTailTokens;
    }

    if (afterTokens > effectiveInputBudget) {
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

    // The newest connected exchange is the shortest tail any selection keeps;
    // when even it cannot fit next to the intact overhead and summary the
    // target is unattainable for this request, which is reported, not forced.
    final minimalTailTokens = post.minimalTailTokens;
    final target = request.targetRequestTokens;
    final tailCost = post.tailCost;
    // Opaque replay outside a proven span has unknown cost, so a request that
    // looks within the target cannot be claimed as meeting it.
    final unprovenReplayItems =
        tailCost?.unprovenReplayItems ??
        projectedTail.fold<int>(
          0,
          (sum, entry) => sum + _opaqueReplayItems(entry.message),
        );
    decisionSnapshot.addAll({
      'summary_tokens': summaryTokens,
      'retained_tail_tokens': retainedTailTokens,
      'retained_tail_cost_kind':
          (tailCost?.kind ?? CompactionMeasurementKind.estimated).wireValue,
      'unproven_replay_items': unprovenReplayItems,
      if (tailCost != null) ...{
        'retained_tail_confirmed_tokens': tailCost.confirmedTokens,
        'proven_receipts': measurement.tailCosts!.provenReceipts,
      },
      'estimated_request_tokens_after': afterTokens,
      'target_feasibility':
          fixedOverheadTokens + summaryTokens + minimalTailTokens <= target
          ? 'feasible'
          : 'infeasible',
      'estimated_target_outcome': afterTokens > target
          ? TargetOutcome.notMet.wireValue
          : unprovenReplayItems > 0
          ? TargetOutcome.unknown.wireValue
          : TargetOutcome.met.wireValue,
    });

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
      diagnostics: candidateDiagnostics.copyWith(
        decisionSnapshot: decisionSnapshot,
      ),
    );
  }

  /// Provider-neutral cost of retained-tail rows: model-visible text plus
  /// model-facing media.
  static int _estimatedTailTokens(Iterable<Message> tail) =>
      CompactionTokenEstimator.estimateMessages(tail) +
      CompactionTokenEstimator.estimateMediaTokens(tail);

  /// Measures the summary and retained tail of the post-compaction request:
  /// on the route's wire when it can measure, otherwise by estimate.
  Future<_PostRequestMeasurement> _measurePostRequest(
    CompactionEngineRequest request,
    CompactionRequestMeasurement measurement,
    Message summary,
    List<Message> tail,
  ) async {
    final minimalStart = _tailSelector.minimalTailStart(
      timeline: request.timeline,
      previousSourceEnd: request.previousSourceRange,
    );
    final minimalTail = request.timeline
        .sublist(minimalStart)
        .map((entry) => entry.message)
        .toList(growable: false);
    final meter = request.wireMeter;
    final projection = request.providerProjection;
    if (measurement.wireMeasured && meter != null && projection != null) {
      try {
        final instructions = leadingSystemMessages(projection);
        final withSummary = await meter([...instructions, summary]);
        if (withSummary != null) {
          final summaryTokens =
              withSummary.estimatedTokens - measurement.fixedOverheadTokens;
          // The selection's own transmitted cost wins, so the measured tail
          // is exactly the tail that was selected (replay-aware, Task 118).
          final costs = measurement.tailCosts;
          final selected = costs?[request.timeline.length - tail.length];
          final minimal = costs?[minimalStart];
          Future<int?> wireTail(List<Message> rows) async {
            final measured = await meter([...instructions, summary, ...rows]);
            return measured == null
                ? null
                : measured.estimatedTokens - withSummary.estimatedTokens;
          }

          final tailTokens = selected?.tokens ?? await wireTail(tail);
          final minimalTokens = minimal?.tokens ?? await wireTail(minimalTail);
          if (tailTokens != null && minimalTokens != null) {
            return _PostRequestMeasurement(
              summaryTokens: summaryTokens < 0 ? 0 : summaryTokens,
              tailTokens: tailTokens,
              minimalTailTokens: minimalTokens,
              tailCost: selected,
            );
          }
        }
      } catch (_) {
        // Fall back to the provider-neutral estimate below.
      }
    }
    return _PostRequestMeasurement(
      summaryTokens: CompactionTokenEstimator.estimateMessage(summary),
      tailTokens: _estimatedTailTokens(tail),
      minimalTailTokens: _estimatedTailTokens(minimalTail),
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
        decisionSnapshot: _decisionSnapshot(request, pressure),
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
      // Safe shape code of the latest unusable response, or null when the
      // latest attempt was parsed (Task 118 Stage2).
      String? lastShape;
      for (; attempts < 2; attempts++) {
        final passKind = attempts == 0 ? 'full' : 'repair';
        final passWatch = Stopwatch()..start();
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
            duration: passWatch.elapsed,
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
            duration: passWatch.elapsed,
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
          final attemptDuration = error.duration ?? passWatch.elapsed;
          totalDuration += attemptDuration;
          lastShape = error.reason;
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
            cause: CompactionFailureCause.forSummaryShape(error.reason),
            diagnostics: failureDiagnostics(usage: aggregateUsage),
          );
        } on TimeoutException {
          ledger.add(CompactionSummarizationAttemptRecord(
            passKind: passKind,
            requestId: attemptRequestId,
            duration: passWatch.elapsed,
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
            duration: passWatch.elapsed,
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
            duration: passWatch.elapsed,
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
          lastShape = null;
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
        } on FormatException {
          lastShape = CompactionFailureCause.summaryInvalidJson;
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
            failureReason: CompactionFailureCause.summaryInvalidJson,
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
      if (lastShape != null) {
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          stage: CompactionFailureStage.provider,
          cause: CompactionFailureCause.forSummaryShape(lastShape),
          diagnostics: failureDiagnostics(usage: aggregateUsage),
        );
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

  /// Bounded recovery after the ordinary provider request overflowed
  /// (Task 117, 0P-F2).
  ///
  /// Atomic tool-call/result groups are packed into chunks against one
  /// per-pass token budget. An oversized single group is text-capped with an
  /// explicit truncation marker and never dropped. When the source needs more
  /// than [CompactionRecoveryPolicy.maxChunks] chunks, recovery fails before
  /// any recovery provider call. Partials (preceded by the eligible previous
  /// summary) are reduced in budget-packed batches until one summary remains.
  /// An overflowing chunk is split at most once.
  Future<_GeneratedSummary> _generateRecoverySummary({
    required CompactionEngineRequest request,
    required ProviderProjectionCompactionSummarizer provider,
    required List<IndexedConversationMessage> source,
    required List<CompactionContinuityAnchor> anchors,
    List<CompactionSummarizationAttemptRecord> initialLedger = const [],
    required RequestPressureSnapshot pressure,
  }) async {
    final policy = _recoveryPolicy;
    final ledger = List<CompactionSummarizationAttemptRecord>.from(initialLedger);
    final decision = <String, dynamic>{
      'recovery_max_chunks': policy.maxChunks,
      'recovery_safety_ratio': policy.passBudgetSafetyRatio,
    };
    var providerCalls = 0;
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
          ..._decisionSnapshot(request, pressure),
          ...decision,
          'recovery_provider_calls': providerCalls,
        },
      );
    }

    CompactionEngineFailure capacityExceeded() => CompactionEngineFailure(
      CompactionFailureReason.summarizationFailed,
      stage: CompactionFailureStage.pruning,
      cause: CompactionFailureCause.recoveryCapacityExceeded,
      diagnostics: failureDiagnostics(),
    );

    CompactionEngineFailure overflowed(_CompactionUsage usage) =>
        CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          stage: CompactionFailureStage.provider,
          cause: CompactionFailureCause.overflow,
          diagnostics: failureDiagnostics(usage: usage),
        );

    final groups = _atomicGroups(source);
    if (groups.isEmpty) {
      throw CompactionEngineFailure(
        CompactionFailureReason.summarizationFailed,
        diagnostics: failureDiagnostics(),
      );
    }
    final stableSystem = request.providerProjection!
        .where((message) => message.role == MessageRole.system)
        .toList(growable: false);
    final chunkInstruction = CompactionSummaryPrompt.buildJsonInstruction(
      partial: true,
    );
    final finalInstruction = CompactionSummaryPrompt.buildJsonInstruction();
    final instructionTokens = CompactionTokenEstimator.estimateText(
      chunkInstruction.length > finalInstruction.length
          ? chunkInstruction
          : finalInstruction,
    );
    final passBudget =
        (pressure.effectiveInputBudget * policy.passBudgetSafetyRatio)
            .floor() -
        _estimateRecoveryMessages(stableSystem) -
        CompactionTokenEstimator.estimateToolSchemas(request.toolSchemas) -
        instructionTokens;
    final sourceTokens = groups.fold<int>(
      0,
      (sum, group) => sum + _estimateRecoveryGroup(group),
    );
    decision['recovery_pass_budget_tokens'] = passBudget;
    decision['recovery_source_tokens'] = sourceTokens;
    if (passBudget < policy.minPassBudgetTokens) {
      throw capacityExceeded();
    }
    final chunks = _packRecoveryChunks(groups, passBudget);
    decision['recovery_chunk_count'] = chunks.length;
    if (chunks.length > policy.maxChunks) {
      throw capacityExceeded();
    }

    final partials = <CompactionInternalSummary>[];
    var aggregateUsage = const _CompactionUsage();
    var duration = Duration.zero;
    var attempts = 0;
    var passIndex = 0;
    var splits = 0;
    // A failing pass reports its own usage plus every earlier billed pass of
    // this recovery, so a late failure never understates the aggregate.
    CompactionDurableDiagnostics passFailureDiagnostics({
      _CompactionUsage? usage,
    }) => failureDiagnostics(
      usage: aggregateUsage + (usage ?? const _CompactionUsage()),
    );

    Future<void> summarizeChunk(
      List<List<IndexedConversationMessage>> chunk, {
      required bool mayHalve,
    }) async {
      final index = passIndex++;
      try {
        final generated = await _recoveryPass(
          request: request,
          provider: provider,
          baseProjection: [
            ...stableSystem,
            for (final group in chunk)
              for (final entry in group) entry.message,
          ],
          instruction: chunkInstruction,
          passKind: 'chunk',
          chunkIndex: index,
          ledger: ledger,
          failureDiagnostics: passFailureDiagnostics,
          onProviderCall: () => providerCalls++,
        );
        partials.add(generated.summary);
        aggregateUsage = aggregateUsage + generated.aggregateUsage;
        duration += generated.duration ?? Duration.zero;
        attempts += generated.attempts;
      } on _RecoveryPassOverflow catch (overflow) {
        aggregateUsage = aggregateUsage + overflow.usage;
        if (!mayHalve || chunk.length < 2) throw overflowed(aggregateUsage);
        splits++;
        decision['recovery_split_count'] = splits;
        final middle = chunk.length ~/ 2;
        await summarizeChunk(chunk.sublist(0, middle), mayHalve: false);
        await summarizeChunk(chunk.sublist(middle), mayHalve: false);
      }
    }

    for (final chunk in chunks) {
      await summarizeChunk(chunk, mayHalve: true);
    }

    // Bounded hierarchical reduce. The eligible previous summary precedes the
    // partials so earlier compacted history stays in the rolling checkpoint.
    var items = <Map<String, dynamic>>[
      if (request.previousSummary != null)
        CompactionSummaryPrompt.toJsonMap(request.previousSummary!),
      for (final summary in partials) CompactionSummaryPrompt.toJsonMap(summary),
    ];
    var reduceIndex = 0;
    while (true) {
      final batches = _packRecoveryItems(items, passBudget);
      if (batches.length == 1) break;
      if (batches.length >= items.length) {
        // No batch can merge two items within the pass budget.
        throw capacityExceeded();
      }
      final next = <Map<String, dynamic>>[];
      for (final batch in batches) {
        if (batch.length == 1) {
          next.add(batch.single);
          continue;
        }
        try {
          final generated = await _recoveryPass(
            request: request,
            provider: provider,
            baseProjection: [
              ...stableSystem,
              Message(role: MessageRole.user, content: jsonEncode(batch)),
            ],
            instruction: chunkInstruction,
            passKind: 'reduce',
            chunkIndex: reduceIndex++,
            ledger: ledger,
            failureDiagnostics: passFailureDiagnostics,
            onProviderCall: () => providerCalls++,
          );
          next.add(CompactionSummaryPrompt.toJsonMap(generated.summary));
          aggregateUsage = aggregateUsage + generated.aggregateUsage;
          duration += generated.duration ?? Duration.zero;
          attempts += generated.attempts;
        } on _RecoveryPassOverflow catch (overflow) {
          throw overflowed(aggregateUsage + overflow.usage);
        }
      }
      items = next;
    }
    decision['recovery_reduce_batches'] = reduceIndex;

    final _GeneratedSummary reduced;
    try {
      reduced = await _recoveryPass(
        request: request,
        provider: provider,
        baseProjection: [
          ...stableSystem,
          Message(role: MessageRole.user, content: jsonEncode(items)),
        ],
        instruction: finalInstruction,
        anchors: anchors,
        passKind: 'reduce',
        ledger: ledger,
        failureDiagnostics: passFailureDiagnostics,
        onProviderCall: () => providerCalls++,
      );
    } on _RecoveryPassOverflow catch (overflow) {
      throw overflowed(aggregateUsage + overflow.usage);
    }
    decision['recovery_provider_calls'] = providerCalls;
    return _GeneratedSummary(
      summary: reduced.summary,
      continuity: reduced.continuity,
      acceptedUsage: reduced.acceptedUsage,
      aggregateUsage: aggregateUsage + reduced.aggregateUsage,
      attempts: attempts + reduced.attempts,
      duration: duration + (reduced.duration ?? Duration.zero),
      ledger: ledger,
      decisionSnapshot: Map.unmodifiable(decision),
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
    void Function()? onProviderCall,
  }) async {
    final immutableBase = List<Message>.unmodifiable(baseProjection);
    CompactionContinuityResult? lastContinuity;
    var aggregateUsage = const _CompactionUsage();
    var duration = Duration.zero;
    String? lastShape;
    for (var attempt = 0; attempt < 2; attempt++) {
      final effectivePassKind = attempt == 0 ? passKind : 'repair';
      final passWatch = Stopwatch()..start();
      final attemptRequestId = _buildAttemptRequestId(
        request: request,
        passKind: effectivePassKind,
        attempt: attempt,
        chunkIndex: chunkIndex,
      );
      final attemptOptions = request.providerRequestOptions.copyWith(
        requestId: attemptRequestId,
      );
      // Usage of the billed response in this attempt, kept for every outcome
      // that follows a provider answer (Task 118 round 2).
      var passUsage = const _CompactionUsage();
      try {
        onProviderCall?.call();
        final result = await provider.summarizeProvider(
          CompactionProviderRequest(
            baseProjection: immutableBase,
            tools: request.providerTools,
            routeSignature: request.routeSignature,
            options: attemptOptions,
            instruction: instruction,
          ),
        );
        passUsage = _CompactionUsage.fromProvider(result.usage);
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
        lastShape = null;
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
          duration: passWatch.elapsed,
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
          duration: passWatch.elapsed,
          outcome: 'overflow',
          failureReason: 'context_overflow',
          relativeDumpPath: LLMRequestDumper.getRelativeDumpPath(
            compactionId: request.compactionId,
            requestId: attemptRequestId,
          ),
        ));
        // The caller owns the bounded split-or-fail decision.
        throw _RecoveryPassOverflow(aggregateUsage);
      } on CompactionInvalidProviderResponse catch (error) {
        final errorUsage = _CompactionUsage.fromProvider(error.usage);
        aggregateUsage = aggregateUsage + errorUsage;
        final attemptDuration = error.duration ?? passWatch.elapsed;
        duration += attemptDuration;
        lastShape = error.reason;
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
          duration: passWatch.elapsed,
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
          duration: passWatch.elapsed,
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
      } on FormatException {
        lastShape = CompactionFailureCause.summaryInvalidJson;
        ledger.add(CompactionSummarizationAttemptRecord(
          passKind: effectivePassKind,
          requestId: attemptRequestId,
          duration: passWatch.elapsed,
          inputTokens: passUsage.inputTokens,
          cachedInputTokens: passUsage.cachedInputTokens,
          cacheWriteTokens: passUsage.cacheWriteTokens,
          outputTokens: passUsage.outputTokens,
          reasoningTokens: passUsage.reasoningTokens,
          outcome: 'invalid_response',
          failureReason: CompactionFailureCause.summaryInvalidJson,
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
          duration: passWatch.elapsed,
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
    if (lastShape != null) {
      throw CompactionEngineFailure(
        CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.provider,
        cause: CompactionFailureCause.forSummaryShape(lastShape),
        diagnostics: failureDiagnostics(usage: aggregateUsage),
      );
    }
    throw CompactionEngineFailure(
      CompactionFailureReason.continuityValidationFailed,
      missingAnchors:
          lastContinuity?.missingAnchors ??
          CompactionInternalSummary.requiredSectionKeys,
      diagnostics: failureDiagnostics(usage: aggregateUsage),
    );
  }

  /// Groups each assistant tool-call batch with its results so recovery never
  /// splits a tool pair across chunks.
  static List<List<IndexedConversationMessage>> _atomicGroups(
    List<IndexedConversationMessage> source,
  ) {
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
    return groups;
  }

  static int _estimateRecoveryMessages(Iterable<Message> messages) =>
      CompactionTokenEstimator.estimateMessages(messages) +
      CompactionTokenEstimator.estimateMediaTokens(messages);

  static int _estimateRecoveryGroup(List<IndexedConversationMessage> group) =>
      _estimateRecoveryMessages(group.map((entry) => entry.message));

  /// Greedy, order-preserving packing of atomic groups into chunks whose
  /// estimate fits [passBudget]. An oversized group is text-capped first and
  /// still forms its own chunk if it remains over budget.
  static List<List<List<IndexedConversationMessage>>> _packRecoveryChunks(
    List<List<IndexedConversationMessage>> groups,
    int passBudget,
  ) {
    final chunks = <List<List<IndexedConversationMessage>>>[];
    var current = <List<IndexedConversationMessage>>[];
    var currentTokens = 0;
    for (final original in groups) {
      var group = original;
      var tokens = _estimateRecoveryGroup(group);
      if (tokens > passBudget) {
        group = _capRecoveryGroup(group, passBudget);
        tokens = _estimateRecoveryGroup(group);
      }
      if (current.isNotEmpty && currentTokens + tokens > passBudget) {
        chunks.add(current);
        current = [];
        currentTokens = 0;
      }
      current.add(group);
      currentTokens += tokens;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  /// Order-preserving packing of partial summaries into reduce batches.
  static List<List<Map<String, dynamic>>> _packRecoveryItems(
    List<Map<String, dynamic>> items,
    int passBudget,
  ) {
    final batches = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    var currentTokens = 0;
    for (final item in items) {
      final tokens = CompactionTokenEstimator.estimateText(jsonEncode(item));
      if (current.isNotEmpty && currentTokens + tokens > passBudget) {
        batches.add(current);
        current = [];
        currentTokens = 0;
      }
      current.add(item);
      currentTokens += tokens;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Deterministic head-and-tail text cap for one oversized atomic group,
  /// sharing [passBudget] evenly across its messages. Summary-input copies
  /// only; canonical history is never touched.
  static List<IndexedConversationMessage> _capRecoveryGroup(
    List<IndexedConversationMessage> group,
    int passBudget,
  ) {
    final perMessageChars =
        (passBudget ~/ group.length) * CompactionTokenEstimator.charsPerToken;
    return [
      for (final entry in group)
        IndexedConversationMessage(
          rowId: entry.rowId,
          message: _capRecoveryMessage(entry.message, perMessageChars),
        ),
    ];
  }

  static Message _capRecoveryMessage(Message message, int maxChars) {
    final result = message.toolResult;
    if (result != null) {
      final text = result.displayText;
      final capped = _capRecoveryText(text, maxChars);
      if (identical(capped, text)) return message;
      final derived = ToolExecutionResult(
        schemaVersion: result.schemaVersion,
        blocks: [ToolTextBlock(text: capped)],
        isError: result.isError,
        errorCode: result.errorCode,
      );
      return message.copyWith(content: capped, toolResult: derived);
    }
    final content = message.content;
    if (content == null) return message;
    final capped = _capRecoveryText(content, maxChars);
    return identical(capped, content)
        ? message
        : message.copyWith(content: capped);
  }

  static String _capRecoveryText(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    final omitted = text.length - maxChars;
    final marker = '\n[truncated $omitted chars for summary]\n';
    final keep = maxChars - marker.length;
    if (keep <= 0) return marker.trim();
    final head = (keep + 1) ~/ 2;
    final tail = keep - head;
    return '${text.substring(0, head)}$marker'
        '${text.substring(text.length - tail)}';
  }

  /// Durable decision fields shared by candidate and failure diagnostics.
  /// The threshold and the complete-request target are reported over the full
  /// window `W` (Task 118); when the usable-budget protection decided the
  /// trigger it is flagged explicitly.
  static Map<String, dynamic> _decisionSnapshot(
    CompactionEngineRequest request,
    RequestPressureSnapshot pressure, [
    CompactionSelectionBudget? budget,
  ]) => {
    'context_window': request.contextWindowTokens,
    'effective_input_budget': pressure.effectiveInputBudget,
    'auto_threshold_tokens': pressure.thresholdTokens,
    'nominal_threshold_tokens': pressure.nominalThresholdTokens,
    'threshold_scope': 'context_window',
    'threshold_capped_by_usable_budget': pressure.thresholdCappedByUsableBudget,
    'target_request_tokens': request.targetRequestTokens,
    if (request.targetRatio != null) 'target_ratio': request.targetRatio,
    'target_scope': 'context_window',
    if (request.thresholdRatio > 0) 'threshold_ratio': request.thresholdRatio,
    if (budget != null) ...{
      'fixed_overhead_tokens': budget.measurement.fixedOverheadTokens,
      'fixed_overhead_measurement': budget.measurement.wireMeasured
          ? 'wire_estimate'
          : 'estimate',
      'summary_reservation_tokens': budget.summaryReservationTokens,
      'tail_budget_tokens': budget.tailBudgetTokens,
    },
  };

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

class _PostRequestMeasurement {
  final int summaryTokens;
  final int tailTokens;
  final int minimalTailTokens;

  /// The selection's replay-aware cost of the retained tail, when measured.
  final CompactionTailCost? tailCost;

  const _PostRequestMeasurement({
    required this.summaryTokens,
    required this.tailTokens,
    required this.minimalTailTokens,
    this.tailCost,
  });
}

class _TailCostMeasurement {
  final CompactionTailCosts costs;
  final int requestTokens;
  final CompactionMeasurementKind requestKind;

  const _TailCostMeasurement({
    required this.costs,
    required this.requestTokens,
    required this.requestKind,
  });
}

class _GeneratedSummary {
  final CompactionInternalSummary summary;
  final CompactionContinuityResult continuity;
  final _CompactionUsage acceptedUsage;
  final _CompactionUsage aggregateUsage;
  final int attempts;
  final Duration? duration;
  final List<CompactionSummarizationAttemptRecord> ledger;

  /// Additive recovery decision fields for the durable decision snapshot.
  final Map<String, dynamic> decisionSnapshot;

  const _GeneratedSummary({
    required this.summary,
    required this.continuity,
    required this.acceptedUsage,
    required this.aggregateUsage,
    required this.attempts,
    required this.duration,
    this.ledger = const [],
    this.decisionSnapshot = const {},
  });
}

/// Internal signal: one recovery pass overflowed the provider context.
class _RecoveryPassOverflow implements Exception {
  final _CompactionUsage usage;

  const _RecoveryPassOverflow(this.usage);
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
