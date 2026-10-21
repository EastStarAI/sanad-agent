import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';

import '../compaction/compaction_enums.dart';
import '../adapters/llm_adapter.dart';
import 'compaction_token_estimator.dart';
import 'request_pressure_snapshot.dart';

/// Builds prospective request pressure for one route (Plan 53c Gate C0).
///
/// Tool-schema estimates are cached by route identity + schema fingerprint so
/// stable schemas are not re-encoded every preflight, while different routes
/// never share a cached value.
class RequestPressureEvaluator {
  static final Logger _logger = Logger('RequestPressureEvaluator');
  static const int defaultOutputReservationTokens = 4096;
  static const int defaultSafetyBufferTokens = 1024;
  final int outputReservationTokens;
  final int safetyBufferTokens;
  final Map<String, int> _toolSchemaTokenCache;

  RequestPressureEvaluator({
    this.outputReservationTokens = defaultOutputReservationTokens,
    this.safetyBufferTokens = defaultSafetyBufferTokens,
    Map<String, int>? toolSchemaTokenCache,
  }) : _toolSchemaTokenCache = toolSchemaTokenCache ?? <String, int>{};

  RequestPressureSnapshot evaluate({
    required RouteSignature routeSignature,
    required int contextWindowTokens,
    int? inputLimitTokens,
    required List<Message> conversationMessages,
    required String systemPrompt,
    required String runtimeContext,
    required List<Map<String, dynamic>> toolSchemas,
    ConfirmedInputUsageBaseline? confirmedInputUsage,
    int? wireEstimatedInputTokens,
    WireInputMeasurement? wireMeasurement,
    double thresholdRatio = 1.0,
  }) {
    final historyTokens = CompactionTokenEstimator.estimateMessages(
      conversationMessages,
    );
    final systemTokens = CompactionTokenEstimator.estimateText(systemPrompt);
    final runtimeTokens = CompactionTokenEstimator.estimateText(runtimeContext);
    final schemaTokens = _cachedToolSchemaTokens(
      routeSignature: routeSignature,
      toolSchemas: toolSchemas,
    );
    final mediaTokens = CompactionTokenEstimator.estimateMediaTokens(
      conversationMessages,
    );
    final components = RequestPressureComponents(
      historyTokens: historyTokens,
      systemPromptTokens: systemTokens,
      runtimeContextTokens: runtimeTokens,
      toolSchemaTokens: schemaTokens,
      mediaTokens: mediaTokens,
    );
    final explicitEstimate = wireEstimatedInputTokens ?? components.total;
    final baselineDelta = _baselineDeltaTokens(
      baseline: confirmedInputUsage,
      routeSignature: routeSignature,
      conversationMessages: conversationMessages,
      systemPrompt: systemPrompt,
      runtimeContext: runtimeContext,
      toolSchemas: toolSchemas,
      wireMeasurement: wireMeasurement,
    );
    final confirmedInputTokens = baselineDelta == null
        ? null
        : confirmedInputUsage!.inputTokens;
    final estimated = baselineDelta == null
        ? explicitEstimate
        : confirmedInputTokens! + baselineDelta;
    final measurementKind = confirmedInputTokens == null
        ? CompactionMeasurementKind.estimated
        : baselineDelta == 0
        ? CompactionMeasurementKind.confirmed
        : CompactionMeasurementKind.mixed;
    final snapshot = RequestPressureSnapshot(
      routeSignature: routeSignature,
      contextWindowTokens: contextWindowTokens,
      inputLimitTokens: inputLimitTokens,
      outputReservationTokens: outputReservationTokens,
      safetyBufferTokens: safetyBufferTokens,
      components: components,
      estimatedRequestTokens: estimated,
      confirmedInputTokens: confirmedInputTokens,
      measurementKind: measurementKind,
      thresholdRatio: thresholdRatio,
    );
    _logger.fine(
      'request_pressure route=${routeSignature.providerInstanceId}/'
      '${routeSignature.modelId}/${routeSignature.protocol} '
      'measurement=${measurementKind.wireValue} '
      'history=${components.historyTokens} system=${components.systemPromptTokens} '
      'runtime=${components.runtimeContextTokens} tools=${components.toolSchemaTokens} '
      'media=${components.mediaTokens} reasoning=${components.reasoningTokens} '
      'replay=${components.providerReplayTokens} total=${snapshot.estimatedRequestTokens}',
    );
    return snapshot;
  }

  int _cachedToolSchemaTokens({
    required RouteSignature routeSignature,
    required List<Map<String, dynamic>> toolSchemas,
  }) {
    final key = _toolSchemaCacheKey(routeSignature, toolSchemas);
    return _toolSchemaTokenCache.putIfAbsent(
      key,
      () => CompactionTokenEstimator.estimateToolSchemas(toolSchemas),
    );
  }

  /// Version tag for the compact non-content wire proof persisted with a
  /// provider-confirmed usage.
  static const String wireProofVersion = 'v1';

  /// Computes a compact versioned non-content proof binding [wireMeasurement]
  /// (its stable material and ordered wire items) to [routeSignature].
  ///
  /// The proof stores no raw content: the stable material and every ordered
  /// wire item are already content-addressed digests, and the payload below
  /// adds only the version and safe route identity. A changed prompt, tool
  /// schema, message, or route therefore yields a different proof, so a
  /// restore can verify a persisted binding by remeasuring the historical
  /// request prefix with the active adapter.
  static String wireProof({
    required WireInputMeasurement wireMeasurement,
    required RouteSignature routeSignature,
  }) {
    final payload = <String, Object>{
      'v': wireProofVersion,
      'provider_instance_id': routeSignature.providerInstanceId,
      'model_id': routeSignature.modelId,
      'protocol': routeSignature.protocol,
      'base_url': routeSignature.normalizedBaseUrl,
      // Additive (Task 120): unchanged routes keep their existing proof.
      'api_mode': ?routeSignature.apiMode,
      'stable': wireMeasurement.stableMaterialFingerprint,
      'items': wireMeasurement.inputItemFingerprints,
    };
    final digest = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return '$wireProofVersion:$digest';
  }

  /// Returns true if [proof] is a recognized versioned wire proof format.
  static bool isValidWireProof(String? proof) {
    if (proof == null || proof.isEmpty) return false;
    final prefix = '$wireProofVersion:';
    if (!proof.startsWith(prefix)) return false;
    final hash = proof.substring(prefix.length);
    return hash.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);
  }

  static String _toolSchemaCacheKey(
    RouteSignature route,
    List<Map<String, dynamic>> toolSchemas,
  ) {
    return Object.hash(
      route.providerInstanceId,
      route.modelId,
      route.protocol,
      route.normalizedBaseUrl,
      route.apiMode,
      route.configRevision,
      route.credentialRevision,
      jsonEncode(toolSchemas),
    ).toString();
  }

  int? _baselineDeltaTokens({
    required ConfirmedInputUsageBaseline? baseline,
    required RouteSignature routeSignature,
    required List<Message> conversationMessages,
    required String systemPrompt,
    required String runtimeContext,
    required List<Map<String, dynamic>> toolSchemas,
    required WireInputMeasurement? wireMeasurement,
  }) {
    if (baseline == null || baseline.routeSignature != routeSignature) {
      return null;
    }
    final baselineWire = baseline.wireMeasurement;
    if (baselineWire != null) {
      // A wire-measured baseline is consumed only through the live wire
      // extension proof: the current request must remeasure as an extension of
      // the exact material the provider measured. Anything else would reuse a
      // confirmed value against material that was never proven to match it, so
      // admission falls back to the explicit estimate instead.
      if (wireMeasurement == null ||
          !wireMeasurement.extendsMeasurement(baselineWire)) {
        return null;
      }
      final delta =
          wireMeasurement.estimatedTokens - baselineWire.estimatedTokens;
      return delta < 0 ? null : delta;
    }
    if (wireMeasurement != null ||
        baseline.systemPrompt != systemPrompt ||
        baseline.runtimeContext != runtimeContext ||
        jsonEncode(baseline.toolSchemas) != jsonEncode(toolSchemas) ||
        conversationMessages.length < baseline.conversationMessages.length) {
      return null;
    }
    for (var index = 0; index < baseline.conversationMessages.length; index++) {
      if (jsonEncode(baseline.conversationMessages[index].toJson()) !=
          jsonEncode(conversationMessages[index].toJson())) {
        return null;
      }
    }
    final suffix = conversationMessages.skip(
      baseline.conversationMessages.length,
    );
    return CompactionTokenEstimator.estimateMessages(suffix) +
        CompactionTokenEstimator.estimateMediaTokens(suffix);
  }
}
