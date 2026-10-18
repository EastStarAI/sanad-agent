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
