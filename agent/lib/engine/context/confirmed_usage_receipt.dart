import 'package:meta/meta.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/llm_finish_reason.dart';
import 'package:sanad_agent/core/models/message.dart';

import '../adapters/llm_adapter.dart';
import 'request_pressure_evaluator.dart';

/// Provider-confirmed input usage recorded on one assistant row, bound to the
/// wire request that produced it (Task 106 G11 R4, reused by Task 118).
///
/// The confirmed value always comes from the timestamped per-step
/// `context_usage` snapshot when present, because the generic `usage` map on
/// the same assistant row is a mutable last-run value. A `context_usage`
/// provider/model identity is authoritative when present; the mutable legacy
/// `provider`/`model` value is consulted only when the snapshot carries none,
/// and an absent recorded identity never matches.
@immutable
class ConfirmedUsageReceipt {
  final int inputTokens;
  final String wireProof;

  const ConfirmedUsageReceipt({
    required this.inputTokens,
    required this.wireProof,
  });

  /// Reads a bound receipt from [message] for [routeSignature], or `null`
  /// for non-assistant rows, missing or non-positive usage, a mismatched or
  /// absent route identity, and a missing or unrecognized wire proof.
  static ConfirmedUsageReceipt? read(
    Message message, {
    required RouteSignature routeSignature,
    String? providerAlias,
  }) {
    if (message.role != MessageRole.assistant) return null;
    // Usage of a failed or cancelled response never anchors (Task 118b).
    if (message.finishReason == LLMFinishReason.failed ||
        message.finishReason == LLMFinishReason.cancelled) {
      return null;
    }
    final metadata = message.metadata;
    final contextUsage = metadata?['context_usage'];
    final usage = metadata?['usage'];
    final contextInputTokens = contextUsage is Map
        ? contextUsage['input_tokens']
        : null;
    final usageInputTokens = usage is Map ? usage['input_tokens'] : null;
    final inputTokens = contextInputTokens is num && contextInputTokens > 0
        ? contextInputTokens
        : usageInputTokens;
    if (inputTokens is! num || inputTokens <= 0) return null;

    final contextUsageProvider = contextUsage is Map
        ? contextUsage['provider_instance_id']?.toString()
        : null;
    final contextUsageModel = contextUsage is Map
        ? contextUsage['model_id']?.toString()
        : null;
    final legacyProvider = metadata?['provider']?.toString();
    final legacyModel = metadata?['model']?.toString();
    final recordedProvider =
        (contextUsageProvider == null || contextUsageProvider.isEmpty)
        ? legacyProvider
        : contextUsageProvider;
    final recordedModel =
        (contextUsageModel == null || contextUsageModel.isEmpty)
        ? legacyModel
        : contextUsageModel;
    // Candidate provider aliases exclude null and empty values: an absent
    // recorded identity must fail closed, not match via a null alias.
    final providerIds = <String>{
      routeSignature.providerInstanceId,
      routeSignature.templateId,
      ?providerAlias,
    }.where((value) => value.isNotEmpty).toSet();
    if (recordedProvider == null ||
        recordedProvider.isEmpty ||
        !providerIds.contains(recordedProvider) ||
        recordedModel == null ||
        recordedModel.isEmpty ||
        recordedModel != routeSignature.modelId) {
      return null;
    }

    final proof = contextUsage is Map
        ? contextUsage['wire_proof']?.toString()
        : null;
    if (proof == null ||
        proof.isEmpty ||
        !RequestPressureEvaluator.isValidWireProof(proof)) {
      // Missing, unbound legacy, or unknown-version proof fails closed.
      return null;
    }
    return ConfirmedUsageReceipt(
      inputTokens: inputTokens.round(),
      wireProof: proof,
    );
  }

  /// Whether [prefix], the active adapter's remeasurement of the request that
  /// produced this receipt, is the exact wire material the receipt measured.
  bool provenBy(WireInputMeasurement prefix, RouteSignature routeSignature) =>
      wireProof ==
      RequestPressureEvaluator.wireProof(
        wireMeasurement: prefix,
        routeSignature: routeSignature,
      );
}
