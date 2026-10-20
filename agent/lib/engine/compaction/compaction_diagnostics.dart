import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/context/compaction_summarizer.dart';
import 'package:sanad_agent/engine/context/context_compaction_engine.dart';
import 'compaction_enums.dart';

/// Allowlisted compaction failure stages (Plan 106 G8).
abstract final class CompactionFailureStage {
  static const preparation = 'preparation';
  static const pruning = 'pruning';
  static const provider = 'provider';
  static const validation = 'validation';
  static const persistence = 'persistence';
}

/// Allowlisted compaction failure causes (Plan 106 G8).
///
/// Raw exception messages, stack traces, paths, secrets, user text, and provider
/// response bodies must never be used as causes.
abstract final class CompactionFailureCause {
  // Preparation stage
  static const sessionBusy = 'session_busy';
  static const compactionInProgress = 'compaction_in_progress';
  static const invalidRequest = 'invalid_request';
  static const unavailable = 'unavailable';
  static const sessionNotFound = 'session_not_found';
  static const thinkingUnsupported = 'thinking_capability_unsupported';
  static const thinkingUnknown = 'thinking_capability_unknown';
  static const thinkingUnavailable = 'thinking_option_unavailable_for_route';
  static const thinkingInstanceNotFound = 'thinking_route_instance_not_found';
  static const routeResolutionFailed = 'route_resolution_failed';
  static const preparationFailed = 'preparation_failed';

  // Pruning stage
  static const toolResultMalformed = 'tool_result_malformed';
  static const pruningFailed = 'pruning_failed';
  static const projectionStillOverBudget = 'projection_still_over_budget';

  // Provider stage
  static const timeout = 'timeout';
  static const rateLimited = 'rate_limited';
  static const overflow = 'overflow';
  static const invalidResponse = 'invalid_response';
  static const networkError = 'network_error';
  static const providerError = 'provider_error';
  static const summarizationFailed = 'summarization_failed';

  // Validation stage
  static const continuityValidationFailed = 'continuity_validation_failed';

  // Persistence stage
  static const sourceRevisionStale = 'source_revision_stale';
  static const claimLost = 'claim_lost';
  static const staleOperation = 'stale_operation';
  static const superseded = 'superseded';
  static const missingMessageRows = 'missing_message_rows';
  static const databaseError = 'database_error';
  static const persistenceFailed = 'persistence_failed';
  static const interrupted = 'interrupted';

  // Fallback
  static const unexpectedError = 'unexpected_error';
}

/// Minimal stable diagnostics for contained compaction failures.
@immutable
class CompactionDiagnostics {
  final CompactionFailureReason failureReason;
  final String stage;
  final String cause;
  final Map<String, dynamic>? detail;

  const CompactionDiagnostics({
    required this.failureReason,
    required this.stage,
    required this.cause,
    this.detail,
  });

  Map<String, dynamic> toDetailMap() => {
    'stage': stage,
    'cause': cause,
    ...?detail,
  };

  /// Classifies any runtime failure into an allowlisted, redaction-safe
  /// [CompactionDiagnostics] representation.
  static CompactionDiagnostics classify(Object error, {String? stageHint}) {
    if (error is ThinkingSelectionException) {
      final safeCause = switch (error.code) {
        ThinkingSelectionErrorCode.capabilityUnsupported =>
          CompactionFailureCause.thinkingUnsupported,
        ThinkingSelectionErrorCode.capabilityUnknown =>
          CompactionFailureCause.thinkingUnknown,
        ThinkingSelectionErrorCode.optionUnavailable =>
          CompactionFailureCause.thinkingUnavailable,
        ThinkingSelectionErrorCode.instanceNotFound =>
          CompactionFailureCause.thinkingInstanceNotFound,
        _ => CompactionFailureCause.thinkingUnsupported,
      };
      return CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.preparation,
        cause: safeCause,
      );
    }

    if (error is TimeoutException) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.provider,
        cause: CompactionFailureCause.timeout,
      );
    }

    if (error is SocketException ||
        error is HttpException ||
        error is http.ClientException) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.provider,
        cause: CompactionFailureCause.networkError,
      );
    }

    if (error is LlmHttpException) {
      final cause = error.statusCode == 429
          ? CompactionFailureCause.rateLimited
          : CompactionFailureCause.providerError;
      return CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.provider,
        cause: cause,
      );
    }

    if (error is CompactionProviderOverflow) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.provider,
        cause: CompactionFailureCause.overflow,
      );
    }

    if (error is CompactionInvalidProviderResponse) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.provider,
        cause: CompactionFailureCause.invalidResponse,
      );
    }

    if (error is CompactionRouteChanged) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.sourceRevisionStale,
        stage: CompactionFailureStage.persistence,
        cause: CompactionFailureCause.sourceRevisionStale,
      );
    }

    if (error is SqliteException) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.persistenceFailed,
        stage: CompactionFailureStage.persistence,
        cause: CompactionFailureCause.databaseError,
      );
    }

    if (error is CompactionEngineFailure) {
      if (error.stage != null && error.cause != null) {
        return CompactionDiagnostics(
          failureReason: error.reason,
          stage: error.stage!,
          cause: error.cause!,
        );
      }
      final derivedStage = switch (error.reason) {
        CompactionFailureReason.continuityValidationFailed =>
          CompactionFailureStage.validation,
        CompactionFailureReason.projectionStillOverBudget =>
          CompactionFailureStage.pruning,
        CompactionFailureReason.sourceRevisionStale =>
          CompactionFailureStage.persistence,
        CompactionFailureReason.persistenceFailed =>
          CompactionFailureStage.persistence,
        CompactionFailureReason.sessionBusy =>
          CompactionFailureStage.preparation,
        CompactionFailureReason.compactionInProgress =>
          CompactionFailureStage.preparation,
        CompactionFailureReason.claimLost =>
          CompactionFailureStage.persistence,
        CompactionFailureReason.interrupted =>
          CompactionFailureStage.persistence,
        CompactionFailureReason.summarizationFailed =>
          stageHint ?? CompactionFailureStage.provider,
      };
      final derivedCause = switch (error.reason) {
        CompactionFailureReason.continuityValidationFailed =>
          CompactionFailureCause.continuityValidationFailed,
        CompactionFailureReason.projectionStillOverBudget =>
          CompactionFailureCause.projectionStillOverBudget,
        CompactionFailureReason.sourceRevisionStale =>
          CompactionFailureCause.sourceRevisionStale,
        CompactionFailureReason.persistenceFailed =>
          CompactionFailureCause.persistenceFailed,
        CompactionFailureReason.sessionBusy =>
          CompactionFailureCause.sessionBusy,
        CompactionFailureReason.compactionInProgress =>
          CompactionFailureCause.compactionInProgress,
        CompactionFailureReason.claimLost => CompactionFailureCause.claimLost,
        CompactionFailureReason.interrupted =>
          CompactionFailureCause.interrupted,
        CompactionFailureReason.summarizationFailed =>
          CompactionFailureCause.summarizationFailed,
      };
      return CompactionDiagnostics(
        failureReason: error.reason,
        stage: derivedStage,
        cause: derivedCause,
      );
    }

    if (stageHint == CompactionFailureStage.pruning ||
        (stageHint == null && error is ArgumentError)) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.pruning,
        cause: CompactionFailureCause.toolResultMalformed,
      );
    }

    if (stageHint == CompactionFailureStage.preparation) {
      return const CompactionDiagnostics(
        failureReason: CompactionFailureReason.summarizationFailed,
        stage: CompactionFailureStage.preparation,
        cause: CompactionFailureCause.preparationFailed,
      );
    }

    return CompactionDiagnostics(
      failureReason: CompactionFailureReason.summarizationFailed,
      stage: stageHint ?? CompactionFailureStage.provider,
      cause: CompactionFailureCause.unexpectedError,
    );
  }
}

/// Durable per-attempt summarization ledger entry (Task 106).
@immutable
class CompactionSummarizationAttemptRecord {
  final String passKind; // 'full', 'repair', 'chunk', 'reduce'
  final String requestId;
  final Duration duration;
  final int? inputTokens;
  final int? cachedInputTokens;
  final int? cacheWriteTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  final String outcome; // 'success', 'validation_failed', 'invalid_response', 'overflow', 'error'
  final String? failureReason;
  final String? relativeDumpPath;

  const CompactionSummarizationAttemptRecord({
    required this.passKind,
    required this.requestId,
    required this.duration,
    this.inputTokens,
    this.cachedInputTokens,
    this.cacheWriteTokens,
    this.outputTokens,
    this.reasoningTokens,
    required this.outcome,
    this.failureReason,
    this.relativeDumpPath,
  });

  Map<String, dynamic> toJson() => {
    'pass_kind': passKind,
    'request_id': requestId,
    'duration_ms': duration.inMilliseconds,
    'input_tokens': ?inputTokens,
    'cached_input_tokens': ?cachedInputTokens,
    'cache_write_tokens': ?cacheWriteTokens,
    'output_tokens': ?outputTokens,
    'reasoning_tokens': ?reasoningTokens,
    'outcome': outcome,
    'failure_reason': ?failureReason,
    'relative_dump_path': ?relativeDumpPath,
  };

  factory CompactionSummarizationAttemptRecord.fromJson(Map<String, dynamic> json) {
    return CompactionSummarizationAttemptRecord(
      passKind: json['pass_kind'] as String? ?? 'full',
      requestId: json['request_id'] as String? ?? '',
      duration: Duration(milliseconds: (json['duration_ms'] as num?)?.toInt() ?? 0),
      inputTokens: (json['input_tokens'] as num?)?.toInt(),
      cachedInputTokens: (json['cached_input_tokens'] as num?)?.toInt(),
      cacheWriteTokens: (json['cache_write_tokens'] as num?)?.toInt(),
      outputTokens: (json['output_tokens'] as num?)?.toInt(),
      reasoningTokens: (json['reasoning_tokens'] as num?)?.toInt(),
      outcome: json['outcome'] as String? ?? 'success',
      failureReason: json['failure_reason'] as String?,
      relativeDumpPath: json['relative_dump_path'] as String?,
    );
  }
}

/// Durable post-boundary confirmation status and target outcome (Task 106).
@immutable
class CompactionPostBoundaryStatus {
  final String status; // 'pending', 'confirmed', 'missing', 'rejected'
  final String? requestId;
  final DateTime? observedAt;
  final int? inputTokens;
  final int? cachedTokens;
  final String? missingReason;
  final TargetOutcome targetOutcome;
  final double? postInputRatio;

  const CompactionPostBoundaryStatus({
    required this.status,
    this.requestId,
    this.observedAt,
    this.inputTokens,
    this.cachedTokens,
    this.missingReason,
    this.targetOutcome = TargetOutcome.unknown,
    this.postInputRatio,
  });

  Map<String, dynamic> toJson() => {
    'status': status,
    'request_id': ?requestId,
    'observed_at': ?observedAt?.toUtc().toIso8601String(),
    'input_tokens': ?inputTokens,
    'cached_tokens': ?cachedTokens,
    'missing_reason': ?missingReason,
    'target_outcome': targetOutcome.wireValue,
    'post_input_ratio': ?postInputRatio,
  };

  factory CompactionPostBoundaryStatus.fromJson(Map<String, dynamic> json) {
    return CompactionPostBoundaryStatus(
      status: json['status'] as String? ?? 'pending',
      requestId: json['request_id'] as String?,
      observedAt: json['observed_at'] != null
          ? DateTime.tryParse(json['observed_at'] as String)
          : null,
      inputTokens: (json['input_tokens'] as num?)?.toInt(),
      cachedTokens: (json['cached_tokens'] as num?)?.toInt(),
      missingReason: json['missing_reason'] as String?,
      targetOutcome: TargetOutcome.fromWire(json['target_outcome'] as String?),
      postInputRatio: (json['post_input_ratio'] as num?)?.toDouble(),
    );
  }

  CompactionPostBoundaryStatus copyWithReserved({
    required String requestId,
    required DateTime observedAt,
  }) {
    return CompactionPostBoundaryStatus(
      status: 'reserved',
      requestId: requestId,
      observedAt: observedAt,
      targetOutcome: TargetOutcome.unknown,
    );
  }

  CompactionPostBoundaryStatus copyWithConfirmed({
    required String requestId,
    required DateTime observedAt,
    required int inputTokens,
    int? cachedTokens,
    required TargetOutcome targetOutcome,
    required double postInputRatio,
  }) {
    return CompactionPostBoundaryStatus(
      status: 'confirmed',
      requestId: requestId,
      observedAt: observedAt,
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      targetOutcome: targetOutcome,
      postInputRatio: postInputRatio,
    );
  }

  CompactionPostBoundaryStatus copyWithMissing({
    required String requestId,
    required DateTime observedAt,
    required String missingReason,
  }) {
    return CompactionPostBoundaryStatus(
      status: 'missing',
      requestId: requestId,
      observedAt: observedAt,
      missingReason: missingReason,
      targetOutcome: TargetOutcome.unknown,
    );
  }
}

/// Durable diagnostics record stored as JSON in session_compaction_operations (Task 106).
@immutable
class CompactionDurableDiagnostics {
  final String? relativeDumpPath;
  final List<CompactionSummarizationAttemptRecord> attempts;
  final Map<String, int?> aggregateUsage;
  final Map<String, dynamic>? decisionSnapshot;
  final Map<String, dynamic>? lastPreCompactionCall;
  final CompactionPostBoundaryStatus postBoundary;

  const CompactionDurableDiagnostics({
    this.relativeDumpPath,
    this.attempts = const [],
    this.aggregateUsage = const {},
    this.decisionSnapshot,
    this.lastPreCompactionCall,
    this.postBoundary = const CompactionPostBoundaryStatus(status: 'pending'),
  });

  Map<String, dynamic> toJson() => {
    'relative_dump_path': ?relativeDumpPath,
    'attempts': attempts.map((a) => a.toJson()).toList(),
    'aggregate_usage': aggregateUsage,
    'decision_snapshot': ?decisionSnapshot,
    'last_pre_compaction_call': ?lastPreCompactionCall,
    'post_boundary': postBoundary.toJson(),
  };

  factory CompactionDurableDiagnostics.fromJson(Map<String, dynamic> json) {
    return CompactionDurableDiagnostics(
      relativeDumpPath: json['relative_dump_path'] as String?,
      attempts: (json['attempts'] as List?)
              ?.map((a) => CompactionSummarizationAttemptRecord.fromJson(
                    Map<String, dynamic>.from(a as Map),
                  ))
              .toList() ??
          const [],
      aggregateUsage: (json['aggregate_usage'] as Map?)?.cast<String, int?>() ??
          const {},
      decisionSnapshot: json['decision_snapshot'] != null
          ? Map<String, dynamic>.from(json['decision_snapshot'] as Map)
          : null,
      lastPreCompactionCall: json['last_pre_compaction_call'] != null
          ? Map<String, dynamic>.from(json['last_pre_compaction_call'] as Map)
          : null,
      postBoundary: json['post_boundary'] != null
          ? CompactionPostBoundaryStatus.fromJson(
              Map<String, dynamic>.from(json['post_boundary'] as Map),
            )
          : const CompactionPostBoundaryStatus(status: 'pending'),
    );
  }

  CompactionDurableDiagnostics copyWith({
    String? relativeDumpPath,
    List<CompactionSummarizationAttemptRecord>? attempts,
    Map<String, int?>? aggregateUsage,
    Map<String, dynamic>? decisionSnapshot,
    Map<String, dynamic>? lastPreCompactionCall,
    CompactionPostBoundaryStatus? postBoundary,
  }) {
    return CompactionDurableDiagnostics(
      relativeDumpPath: relativeDumpPath ?? this.relativeDumpPath,
      attempts: attempts ?? this.attempts,
      aggregateUsage: aggregateUsage ?? this.aggregateUsage,
      decisionSnapshot: decisionSnapshot ?? this.decisionSnapshot,
      lastPreCompactionCall: lastPreCompactionCall ?? this.lastPreCompactionCall,
      postBoundary: postBoundary ?? this.postBoundary,
    );
  }

  CompactionDurableDiagnostics copyWithPostBoundary(
    CompactionPostBoundaryStatus postBoundary,
  ) {
    return CompactionDurableDiagnostics(
      relativeDumpPath: relativeDumpPath,
      attempts: attempts,
      aggregateUsage: aggregateUsage,
      decisionSnapshot: decisionSnapshot,
      lastPreCompactionCall: lastPreCompactionCall,
      postBoundary: postBoundary,
    );
  }
}
