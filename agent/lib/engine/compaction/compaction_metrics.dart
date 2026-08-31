import 'package:meta/meta.dart';

import 'compaction_enums.dart';

/// Token and timing metrics for one compaction operation.
@immutable
class CompactionMetrics {
  final int contextWindowTokens;
  final int estimatedRequestTokensBefore;
  final int estimatedRequestTokensAfter;
  final CompactionMeasurementKind beforeMeasurementKind;
  final int? providerConfirmedRequestTokensAfter;
  final int reclaimedTokens;
  final int retainedTailTokens;
  final Duration? duration;

  CompactionMetrics({
    required this.contextWindowTokens,
    required this.estimatedRequestTokensBefore,
    required this.estimatedRequestTokensAfter,
    this.beforeMeasurementKind = CompactionMeasurementKind.estimated,
    this.providerConfirmedRequestTokensAfter,
    required this.retainedTailTokens,
    this.duration,
  }) : reclaimedTokens =
           estimatedRequestTokensBefore - estimatedRequestTokensAfter,
       assert(contextWindowTokens > 0, 'contextWindowTokens must be positive'),
       assert(
         estimatedRequestTokensBefore >= 0 &&
             estimatedRequestTokensAfter >= 0 &&
             (providerConfirmedRequestTokensAfter == null ||
                 providerConfirmedRequestTokensAfter >= 0) &&
             retainedTailTokens >= 0,
         'token counts must be non-negative',
       ),
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
          estimatedRequestTokensBefore == other.estimatedRequestTokensBefore &&
          estimatedRequestTokensAfter == other.estimatedRequestTokensAfter &&
          beforeMeasurementKind == other.beforeMeasurementKind &&
          providerConfirmedRequestTokensAfter ==
              other.providerConfirmedRequestTokensAfter &&
          reclaimedTokens == other.reclaimedTokens &&
          retainedTailTokens == other.retainedTailTokens &&
          duration == other.duration;

  @override
  int get hashCode => Object.hash(
    contextWindowTokens,
    estimatedRequestTokensBefore,
    estimatedRequestTokensAfter,
    beforeMeasurementKind,
    providerConfirmedRequestTokensAfter,
    reclaimedTokens,
    retainedTailTokens,
    duration,
  );
}
