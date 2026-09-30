import 'package:meta/meta.dart';

import 'compaction_enums.dart';

/// Token and timing metrics for one compaction operation.
@immutable
class CompactionMetrics {
  final int contextWindowTokens;
  final int? effectiveInputBudgetTokens;
  final int? autoThresholdTokens;
  final int estimatedRequestTokensBefore;
  final int estimatedRequestTokensAfter;
  final CompactionMeasurementKind beforeMeasurementKind;
  final int? providerConfirmedRequestTokensAfter;
  final int reclaimedTokens;
  final int retainedTailTokens;
  final Duration? duration;
  final int? summarizationInputTokens;
  final int? summarizationCachedInputTokens;
  final int? summarizationCacheWriteTokens;
  final int? summarizationOutputTokens;
  final int? summarizationReasoningTokens;
  final int summarizationAttempts;

  CompactionMetrics({
    required this.contextWindowTokens,
    this.effectiveInputBudgetTokens,
    this.autoThresholdTokens,
    required this.estimatedRequestTokensBefore,
    required this.estimatedRequestTokensAfter,
    this.beforeMeasurementKind = CompactionMeasurementKind.estimated,
    this.providerConfirmedRequestTokensAfter,
    required this.retainedTailTokens,
    this.duration,
    this.summarizationInputTokens,
    this.summarizationCachedInputTokens,
    this.summarizationCacheWriteTokens,
    this.summarizationOutputTokens,
    this.summarizationReasoningTokens,
    this.summarizationAttempts = 0,
  }) : reclaimedTokens =
           estimatedRequestTokensBefore - estimatedRequestTokensAfter,
       assert(contextWindowTokens > 0, 'contextWindowTokens must be positive'),
       assert(
         estimatedRequestTokensBefore >= 0 &&
             estimatedRequestTokensAfter >= 0 &&
             (providerConfirmedRequestTokensAfter == null ||
                 providerConfirmedRequestTokensAfter >= 0) &&
             (effectiveInputBudgetTokens == null ||
                 effectiveInputBudgetTokens > 0) &&
             (autoThresholdTokens == null || autoThresholdTokens > 0) &&
             retainedTailTokens >= 0,
         'token counts must be non-negative',
       ),
       assert(summarizationAttempts >= 0),
       assert(
         estimatedRequestTokensAfter <= estimatedRequestTokensBefore,
         'after tokens must not exceed before tokens',
       );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionMetrics &&
          runtimeType == other.runtimeType &&
          contextWindowTokens == other.contextWindowTokens &&
          effectiveInputBudgetTokens == other.effectiveInputBudgetTokens &&
          autoThresholdTokens == other.autoThresholdTokens &&
          estimatedRequestTokensBefore == other.estimatedRequestTokensBefore &&
          estimatedRequestTokensAfter == other.estimatedRequestTokensAfter &&
          beforeMeasurementKind == other.beforeMeasurementKind &&
          providerConfirmedRequestTokensAfter ==
              other.providerConfirmedRequestTokensAfter &&
          reclaimedTokens == other.reclaimedTokens &&
          retainedTailTokens == other.retainedTailTokens &&
          duration == other.duration &&
          summarizationInputTokens == other.summarizationInputTokens &&
          summarizationCachedInputTokens ==
              other.summarizationCachedInputTokens &&
          summarizationCacheWriteTokens ==
              other.summarizationCacheWriteTokens &&
          summarizationOutputTokens == other.summarizationOutputTokens &&
          summarizationReasoningTokens == other.summarizationReasoningTokens &&
          summarizationAttempts == other.summarizationAttempts;

  @override
  int get hashCode => Object.hashAll([
    contextWindowTokens,
    effectiveInputBudgetTokens,
    autoThresholdTokens,
    estimatedRequestTokensBefore,
    estimatedRequestTokensAfter,
    beforeMeasurementKind,
    providerConfirmedRequestTokensAfter,
    reclaimedTokens,
    retainedTailTokens,
    duration,
    summarizationInputTokens,
    summarizationCachedInputTokens,
    summarizationCacheWriteTokens,
    summarizationOutputTokens,
    summarizationReasoningTokens,
    summarizationAttempts,
  ]);
}
