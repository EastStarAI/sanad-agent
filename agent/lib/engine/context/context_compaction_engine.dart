import 'dart:convert';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/llm_usage_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
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
  final List<Message>? providerProjection;
  final List<ToolSchema> providerTools;
  final LLMRequestOptions providerRequestOptions;
  final int projectionRevision;
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
    this.providerProjection,
    this.providerTools = const [],
    this.providerRequestOptions = const LLMRequestOptions(),
    this.projectionRevision = 0,
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
    final prunedSource = _toolPruner.pruneSourceMessages(
      selection.sourceMessages,
      protectedTailStartRowId: selection.retainedTailRange.start.rowId,
    );
    final anchors = _continuityValidator.extractAnchors(prunedSource);
    final generated = await _generateSummary(request, prunedSource, anchors);
    var summary = generated.summary;
    var continuity = generated.continuity;
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
        effectiveInputBudgetTokens: pressure.effectiveInputBudget,
        autoThresholdTokens: pressure.thresholdTokens,
        estimatedRequestTokensBefore: beforeTokens,
        estimatedRequestTokensAfter: afterTokens,
        beforeMeasurementKind: pressure.measurementKind,
        retainedTailTokens: retainedTailTokens,
        summarizationInputTokens: generated.usage.inputTokens,
        summarizationCachedInputTokens: generated.usage.cachedInputTokens,
        summarizationCacheWriteTokens: generated.usage.cacheWriteTokens,
        summarizationOutputTokens: generated.usage.outputTokens,
        summarizationReasoningTokens: generated.usage.reasoningTokens,
        summarizationAttempts: generated.attempts,
        duration: generated.duration,
      ),
      routeSignature: request.routeSignature,
    );
  }

  Future<_GeneratedSummary> _generateSummary(
    CompactionEngineRequest request,
    List<IndexedConversationMessage> prunedSource,
    List<CompactionContinuityAnchor> anchors,
  ) async {
    final providerSummarizer = _summarizer;
    if (providerSummarizer is ProviderProjectionCompactionSummarizer) {
      final provider =
          providerSummarizer as ProviderProjectionCompactionSummarizer;
      final base = request.providerProjection;
      if (base == null || base.isEmpty) {
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
        );
      }
      final immutableBase = List<Message>.unmodifiable(base);
      var instruction = CompactionSummaryPrompt.buildJsonInstruction();
      var attempts = 0;
      var totalDuration = Duration.zero;
      _CompactionUsage usage = const _CompactionUsage();
      CompactionContinuityResult? lastContinuity;
      for (; attempts < 2; attempts++) {
        CompactionProviderResult result;
        try {
          result = await provider.summarizeProvider(
            CompactionProviderRequest(
              baseProjection: immutableBase,
              tools: request.providerTools,
              routeSignature: request.routeSignature,
              options: request.providerRequestOptions,
              instruction: instruction,
            ),
          );
        } on CompactionRouteChanged {
          throw CompactionEngineFailure(
            CompactionFailureReason.sourceRevisionStale,
          );
        } on CompactionProviderOverflow {
          if (attempts == 0) {
            return _generateRecoverySummary(
              request: request,
              provider: provider,
              source: prunedSource,
              anchors: anchors,
            );
          }
          throw CompactionEngineFailure(
            CompactionFailureReason.summarizationFailed,
          );
        } on CompactionInvalidProviderResponse catch (error) {
          totalDuration += error.duration ?? Duration.zero;
          usage = usage + _CompactionUsage.fromProvider(error.usage);
          if (attempts == 0) {
            instruction = CompactionSummaryPrompt.buildJsonInstruction(
              missingFields: ['valid JSON only; ${error.reason}'],
            );
            continue;
          }
          throw CompactionEngineFailure(
            CompactionFailureReason.summarizationFailed,
          );
        }
        totalDuration += result.duration;
        usage = usage + _CompactionUsage.fromProvider(result.usage);
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
            return _GeneratedSummary(
              summary: parsed,
              continuity: continuity,
              usage: usage,
              attempts: attempts + 1,
              duration: totalDuration,
            );
          }
          instruction = CompactionSummaryPrompt.buildJsonInstruction(
            missingFields: continuity.missingAnchors,
          );
        } on FormatException {
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
      if (continuity.passed) summary = repaired;
    }
    return _GeneratedSummary(
      summary: summary,
      continuity: continuity,
      usage: const _CompactionUsage(),
      attempts: continuity.repairAttempts + 1,
      duration: null,
    );
  }

  Future<_GeneratedSummary> _generateRecoverySummary({
    required CompactionEngineRequest request,
    required ProviderProjectionCompactionSummarizer provider,
    required List<IndexedConversationMessage> source,
    required List<CompactionContinuityAnchor> anchors,
  }) async {
    final chunks = _boundedSafeChunks(source, maximumChunks: 4);
    if (chunks.isEmpty) {
      throw CompactionEngineFailure(
        CompactionFailureReason.summarizationFailed,
      );
    }
    final stableSystem = request.providerProjection!
        .where((message) => message.role == MessageRole.system)
        .toList(growable: false);
    final partials = <CompactionInternalSummary>[];
    var usage = const _CompactionUsage();
    var duration = Duration.zero;
    var attempts = 0;
    for (final chunk in chunks) {
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
      );
      partials.add(generated.summary);
      usage = usage + generated.usage;
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
    );
    return _GeneratedSummary(
      summary: reduced.summary,
      continuity: reduced.continuity,
      usage: usage + reduced.usage,
      attempts: attempts + reduced.attempts,
      duration: duration + (reduced.duration ?? Duration.zero),
    );
  }

  Future<_GeneratedSummary> _recoveryPass({
    required CompactionEngineRequest request,
    required ProviderProjectionCompactionSummarizer provider,
    required List<Message> baseProjection,
    required String instruction,
    List<CompactionContinuityAnchor> anchors = const [],
  }) async {
    final immutableBase = List<Message>.unmodifiable(baseProjection);
    CompactionContinuityResult? lastContinuity;
    var usage = const _CompactionUsage();
    var duration = Duration.zero;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await provider.summarizeProvider(
          CompactionProviderRequest(
            baseProjection: immutableBase,
            tools: request.providerTools,
            routeSignature: request.routeSignature,
            options: request.providerRequestOptions,
            instruction: instruction,
          ),
        );
        usage = usage + _CompactionUsage.fromProvider(result.usage);
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
          return _GeneratedSummary(
            summary: summary,
            continuity: continuity,
            usage: usage,
            attempts: attempt + 1,
            duration: duration,
          );
        }
        instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: continuity.missingAnchors,
          partial: anchors.isEmpty,
        );
      } on CompactionRouteChanged {
        throw CompactionEngineFailure(
          CompactionFailureReason.sourceRevisionStale,
        );
      } on CompactionProviderOverflow {
        throw CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
        );
      } on CompactionInvalidProviderResponse catch (error) {
        usage = usage + _CompactionUsage.fromProvider(error.usage);
        duration += error.duration ?? Duration.zero;
        instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: ['valid JSON only; ${error.reason}'],
          partial: anchors.isEmpty,
        );
      } on FormatException {
        instruction = CompactionSummaryPrompt.buildJsonInstruction(
          missingFields: CompactionInternalSummary.requiredSectionKeys,
          partial: anchors.isEmpty,
        );
      }
    }
    throw CompactionEngineFailure(
      CompactionFailureReason.continuityValidationFailed,
      missingAnchors:
          lastContinuity?.missingAnchors ??
          CompactionInternalSummary.requiredSectionKeys,
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
}

class _GeneratedSummary {
  final CompactionInternalSummary summary;
  final CompactionContinuityResult continuity;
  final _CompactionUsage usage;
  final int attempts;
  final Duration? duration;
  const _GeneratedSummary({
    required this.summary,
    required this.continuity,
    required this.usage,
    required this.attempts,
    required this.duration,
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
