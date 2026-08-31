import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';

import '../compaction/compaction_enums.dart';
import '../compaction/compaction_pressure.dart';
import '../adapters/llm_adapter.dart';

/// Provider-confirmed input usage tied to the exact request material it measured.
///
/// The baseline is intentionally in-memory only. Consumers may extend it with a
/// newly appended message suffix, but must discard it when route, prompt,
/// schemas, or any measured message changes.
@immutable
class ConfirmedInputUsageBaseline {
  final RouteSignature routeSignature;
  final int inputTokens;
  final List<Message> conversationMessages;
  final String systemPrompt;
  final String runtimeContext;
  final List<Map<String, dynamic>> toolSchemas;
  final WireInputMeasurement? wireMeasurement;

  ConfirmedInputUsageBaseline({
    required this.routeSignature,
    required this.inputTokens,
    required List<Message> conversationMessages,
    required this.systemPrompt,
    required this.runtimeContext,
    required List<Map<String, dynamic>> toolSchemas,
    this.wireMeasurement,
  }) : assert(inputTokens >= 0),
       conversationMessages = List.unmodifiable(conversationMessages),
       toolSchemas = List.unmodifiable(toolSchemas);

  ConfirmedInputUsageBaseline copyWithInputTokens(int value) {
    return ConfirmedInputUsageBaseline(
      routeSignature: routeSignature,
      inputTokens: value,
      conversationMessages: conversationMessages,
      systemPrompt: systemPrompt,
      runtimeContext: runtimeContext,
      toolSchemas: toolSchemas,
      wireMeasurement: wireMeasurement,
    );
  }
}

/// Components included in the next provider request estimate (Plan 53c C0).
@immutable
class RequestPressureComponents {
  final int historyTokens;
  final int systemPromptTokens;
  final int runtimeContextTokens;
  final int toolSchemaTokens;
  final int mediaTokens;
  final int reasoningTokens;
  final int providerReplayTokens;

  const RequestPressureComponents({
    required this.historyTokens,
    required this.systemPromptTokens,
    required this.runtimeContextTokens,
    required this.toolSchemaTokens,
    required this.mediaTokens,
    this.reasoningTokens = 0,
    this.providerReplayTokens = 0,
  }) : assert(
         historyTokens >= 0 &&
             systemPromptTokens >= 0 &&
             runtimeContextTokens >= 0 &&
             toolSchemaTokens >= 0 &&
             mediaTokens >= 0 &&
             reasoningTokens >= 0 &&
             providerReplayTokens >= 0,
       );

  int get total =>
      historyTokens +
      systemPromptTokens +
      runtimeContextTokens +
      toolSchemaTokens +
      mediaTokens +
      reasoningTokens +
      providerReplayTokens;
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
  final double thresholdRatio;

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
    this.thresholdRatio = 1.0,
  });

  int get effectiveInputBudget {
    final window = inputLimitTokens ?? contextWindowTokens;
    return calculateEffectiveInputWindow(
      window,
      outputReservationTokens: outputReservationTokens,
      safetyBufferTokens: safetyBufferTokens,
    );
  }

  int get thresholdTokens => (effectiveInputBudget * thresholdRatio).floor();

  bool get exceedsThreshold => estimatedRequestTokens > thresholdTokens;

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

int calculateEffectiveInputWindow(
  int window, {
  int outputReservationTokens = 4096,
  int safetyBufferTokens = 1024,
}) {
  final requestedReservation = outputReservationTokens + safetyBufferTokens;
  if (requestedReservation < window) {
    return window - requestedReservation;
  }
  return (window * 0.75).floor().clamp(1, window);
}
