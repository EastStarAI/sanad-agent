import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';

/// Reusable localized explanation and safe next action for compaction failures.
class CompactionFailureExplanation extends Equatable {
  final String explanation;
  final String nextAction;
  final String? stage;
  final String? cause;
  final String? failureReason;

  const CompactionFailureExplanation({
    required this.explanation,
    required this.nextAction,
    this.stage,
    this.cause,
    this.failureReason,
  });

  /// Single-line combined representation for toast notifications.
  String toToastMessage() => '$explanation $nextAction';

  /// Multiline formatted lines for timeline event details / tooltips.
  ///
  /// Without an ambient [l10n] the lines fall back to the generated English
  /// localization, so the authored ARB remains the single copy authority.
  List<String> toDetailLines({AppLocalizations? l10n}) {
    final copy = l10n ?? AppLocalizationsEn();
    return [
      copy.compactionFailurePrefix(explanation),
      copy.compactionNextActionPrefix(nextAction),
    ];
  }

  /// Multiline text representation for timeline event details.
  String toDetailText({AppLocalizations? l10n}) => toDetailLines(l10n: l10n).join('\n');

  @override
  List<Object?> get props => [
    explanation,
    nextAction,
    stage,
    cause,
    failureReason,
  ];
}

/// Central formatter resolving safe stage/cause/failureReason into localized
/// explanatory feedback and appropriate safe next actions.
///
/// Every English fallback derives from the generated localization
/// (`app_en.arb` authority) instead of duplicating authored copy as literals.
abstract final class CompactionFailureFormatter {
  static CompactionFailureExplanation resolve({
    String? stage,
    String? cause,
    String? failureReason,
    String? outcome,
    AppLocalizations? l10n,
  }) {
    final normStage = _normalize(stage);
    final normCause = _normalize(cause) ?? _normalize(failureReason ?? outcome);
    final normReason = _normalize(failureReason) ?? _normalize(outcome);
    final effectiveStage = normStage ?? _inferStageFromCause(normCause);

    final (explanation, nextAction) = _resolveCopy(
      stage: effectiveStage,
      cause: normCause,
      l10n: l10n,
    );

    return CompactionFailureExplanation(
      explanation: explanation,
      nextAction: nextAction,
      stage: effectiveStage,
      cause: normCause,
      failureReason: normReason,
    );
  }

  static CompactionFailureExplanation resolveForSnapshot(
    CompactionEventSnapshot snapshot, {
    AppLocalizations? l10n,
  }) => resolve(
    stage: snapshot.failureStage,
    cause: snapshot.failureCause,
    failureReason: snapshot.failureReason,
    l10n: l10n,
  );

  static CompactionFailureExplanation resolveForResult(
    SessionCompactResult result, {
    AppLocalizations? l10n,
  }) => resolve(
    stage: result.failureStage,
    cause: result.failureCause,
    failureReason: result.failureReason,
    outcome: result.outcome,
    l10n: l10n,
  );

  static (String explanation, String nextAction) _resolveCopy({
    String? stage,
    String? cause,
    AppLocalizations? l10n,
  }) {
    final copy = l10n ?? AppLocalizationsEn();

    // The Agent's fallback cause defaults the stage to provider when no stage
    // hint existed. Presenting the provider explanation there would fabricate a
    // diagnosis, so an unclassified failure keeps the honest fallback copy. A
    // stage the Agent actually asserted keeps its specific explanation.
    if (cause == 'unexpected_error' && (stage == null || stage == 'provider')) {
      return (copy.compactionFailureUnexpected, copy.compactionActionRetry);
    }

    switch (cause) {
      // Thinking validation / pre-claim
      case 'thinking_capability_unsupported':
      case 'thinking_capability_unknown':
      case 'thinking_option_unavailable_for_route':
      case 'thinking_route_instance_not_found':
        return (
          copy.compactionFailureThinkingUnsupported,
          copy.compactionActionThinkingUnsupported,
        );

      case 'session_busy':
        return (copy.compactionFailureSessionBusy, copy.compactionActionSessionBusy);

      case 'compaction_in_progress':
        return (
          copy.compactionFailureCompactionInProgress,
          copy.compactionActionCompactionInProgress,
        );

      case 'session_not_found':
      case 'invalid_request':
      case 'unavailable':
      case 'route_resolution_failed':
      case 'preparation_failed':
        return (
          copy.compactionFailurePreparation,
          copy.compactionActionPreparation,
        );

      // Pruning
      case 'tool_result_malformed':
      case 'pruning_failed':
        return (copy.compactionFailurePruning, copy.compactionActionPruning);

      case 'projection_still_over_budget':
        return (copy.compactionFailureBudget, copy.compactionActionBudget);

      // Provider
      case 'timeout':
        return (copy.compactionFailureTimeout, copy.compactionActionTimeout);

      case 'rate_limited':
        return (
          copy.compactionFailureRateLimited,
          copy.compactionActionRateLimited,
        );

      case 'overflow':
        return (copy.compactionFailureOverflow, copy.compactionActionOverflow);

      case 'invalid_response':
        return (
          copy.compactionFailureInvalidResponse,
          copy.compactionActionInvalidResponse,
        );

      case 'network_error':
        return (copy.compactionFailureNetwork, copy.compactionActionNetwork);

      case 'provider_error':
      case 'summarization_failed':
        return (
          copy.compactionFailureSummarization,
          copy.compactionActionSummarization,
        );

      // Validation
      case 'continuity_validation_failed':
        return (
          copy.compactionFailureContinuity,
          copy.compactionActionContinuity,
        );

      // Persistence
      case 'source_revision_stale':
        return (
          copy.compactionFailureStaleRevision,
          copy.compactionActionStaleRevision,
        );

      case 'claim_lost':
      case 'stale_operation':
      case 'superseded':
        return (copy.compactionFailureClaimLost, copy.compactionActionClaimLost);

      case 'interrupted':
        return (
          copy.compactionFailureInterrupted,
          copy.compactionActionInterrupted,
        );

      case 'database_error':
      case 'persistence_failed':
      case 'missing_message_rows':
        return (
          copy.compactionFailurePersistence,
          copy.compactionActionPersistence,
        );

      default:
        break;
    }

    // Fall back to stage-based feedback if stage is known
    switch (stage) {
      case 'preparation':
        return (
          copy.compactionFailurePreparation,
          copy.compactionActionPreparation,
        );
      case 'pruning':
        return (copy.compactionFailurePruning, copy.compactionActionPruning);
      case 'provider':
        return (
          copy.compactionFailureSummarization,
          copy.compactionActionSummarization,
        );
      case 'validation':
        return (
          copy.compactionFailureContinuity,
          copy.compactionActionContinuity,
        );
      case 'persistence':
        return (
          copy.compactionFailurePersistence,
          copy.compactionActionPersistence,
        );
      default:
        return (copy.compactionFailureUnexpected, copy.compactionActionRetry);
    }
  }

  static String? _normalize(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)}_${match.group(2)!.toLowerCase()}',
        )
        .toLowerCase();
  }

  static String? _inferStageFromCause(String? cause) {
    if (cause == null) return null;
    return switch (cause) {
      'session_busy' ||
      'compaction_in_progress' ||
      'thinking_capability_unsupported' ||
      'thinking_capability_unknown' ||
      'thinking_option_unavailable_for_route' ||
      'thinking_route_instance_not_found' ||
      'session_not_found' ||
      'invalid_request' ||
      'unavailable' ||
      'route_resolution_failed' ||
      'preparation_failed' => 'preparation',

      'tool_result_malformed' || 'pruning_failed' || 'projection_still_over_budget' => 'pruning',

      'timeout' ||
      'rate_limited' ||
      'overflow' ||
      'invalid_response' ||
      'network_error' ||
      'provider_error' ||
      'summarization_failed' => 'provider',

      'continuity_validation_failed' => 'validation',

      'source_revision_stale' ||
      'claim_lost' ||
      'stale_operation' ||
      'superseded' ||
      'missing_message_rows' ||
      'database_error' ||
      'persistence_failed' ||
      'interrupted' => 'persistence',

      _ => null,
    };
  }
}
