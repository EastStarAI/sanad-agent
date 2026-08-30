import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';

import '../compaction/compaction_enums.dart';
import '../compaction/compaction_pressure.dart';

/// Components included in the next provider request estimate (Plan 53c C0).
@immutable
class RequestPressureComponents {
  final int historyTokens;
  final int systemPromptTokens;
  final int runtimeContextTokens;
  final int toolSchemaTokens;
  final int mediaTokens;

  const RequestPressureComponents({
    required this.historyTokens,
    required this.systemPromptTokens,
    required this.runtimeContextTokens,
    required this.toolSchemaTokens,
    required this.mediaTokens,
  }) : assert(
         historyTokens >= 0 &&
             systemPromptTokens >= 0 &&
             runtimeContextTokens >= 0 &&
             toolSchemaTokens >= 0 &&
             mediaTokens >= 0,
       );

  int get total =>
      historyTokens +
      systemPromptTokens +
      runtimeContextTokens +
      toolSchemaTokens +
      mediaTokens;
}

/// Full prospective request pressure snapshot (Plan 53c Gate C0).
@immutable
class RequestPressureSnapshot {
  final RouteSignature routeSignature;
  final int contextWindowTokens;
  final int? inputLimitTokens;
  final int outputReservationTokens;
  final int safetyBufferTokens;
  final RequestPressureComponents components;
  final int estimatedRequestTokens;
  final int? confirmedInputTokens;
  final CompactionMeasurementKind measurementKind;

  const RequestPressureSnapshot({
    required this.routeSignature,
    required this.contextWindowTokens,
    this.inputLimitTokens,
    required this.outputReservationTokens,
    required this.safetyBufferTokens,
    required this.components,
    required this.estimatedRequestTokens,
    this.confirmedInputTokens,
    required this.measurementKind,
  });

  int get effectiveInputBudget {
    final window = inputLimitTokens ?? contextWindowTokens;
    return window - outputReservationTokens - safetyBufferTokens;
  }

  bool get exceedsThreshold => estimatedRequestTokens > effectiveInputBudget;

  CompactionPressure toCompactionPressure() {
    return CompactionPressure(
      routeSignature: routeSignature,
      contextWindowTokens: contextWindowTokens,
      outputReservationTokens: outputReservationTokens,
      safetyBufferTokens: safetyBufferTokens,
      estimatedRequestTokens: estimatedRequestTokens,
      confirmedInputTokens: confirmedInputTokens,
      measurementKind: measurementKind,
    );
  }
}
