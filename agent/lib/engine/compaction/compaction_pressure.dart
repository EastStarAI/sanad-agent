import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';

import 'compaction_enums.dart';

/// Prospective full-request pressure snapshot for one model route.
///
/// Produced by pressure evaluation only; does not own history or boundaries.
@immutable
class CompactionPressure {
  final RouteSignature routeSignature;
  final int contextWindowTokens;
  final int outputReservationTokens;
  final int safetyBufferTokens;
  final int estimatedRequestTokens;
  final int? confirmedInputTokens;
  final CompactionMeasurementKind measurementKind;

  CompactionPressure({
    required this.routeSignature,
    required this.contextWindowTokens,
    required this.outputReservationTokens,
    required this.safetyBufferTokens,
    required this.estimatedRequestTokens,
    this.confirmedInputTokens,
    required this.measurementKind,
  }) : assert(contextWindowTokens > 0, 'contextWindowTokens must be positive'),
       assert(
         outputReservationTokens >= 0 && safetyBufferTokens >= 0,
         'reservation and buffer must be non-negative',
       ),
       assert(
         estimatedRequestTokens >= 0,
         'estimatedRequestTokens must be non-negative',
       ),
       assert(
         confirmedInputTokens == null || confirmedInputTokens >= 0,
         'confirmedInputTokens must be non-negative when set',
       );

  int get effectiveInputBudget =>
      contextWindowTokens - outputReservationTokens - safetyBufferTokens;

  bool get exceedsThreshold => estimatedRequestTokens > effectiveInputBudget;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionPressure &&
          runtimeType == other.runtimeType &&
          routeSignature == other.routeSignature &&
          contextWindowTokens == other.contextWindowTokens &&
          outputReservationTokens == other.outputReservationTokens &&
          safetyBufferTokens == other.safetyBufferTokens &&
          estimatedRequestTokens == other.estimatedRequestTokens &&
          confirmedInputTokens == other.confirmedInputTokens &&
          measurementKind == other.measurementKind;

  @override
  int get hashCode => Object.hash(
    routeSignature,
    contextWindowTokens,
    outputReservationTokens,
    safetyBufferTokens,
    estimatedRequestTokens,
    confirmedInputTokens,
    measurementKind,
  );
}
