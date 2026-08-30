import 'dart:convert';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';

import '../compaction/compaction_enums.dart';
import 'compaction_token_estimator.dart';
import 'request_pressure_snapshot.dart';

/// Builds prospective request pressure for one route (Plan 53c Gate C0).
///
/// Tool-schema estimates are cached by route identity + schema fingerprint so
/// stable schemas are not re-encoded every preflight, while different routes
/// never share a cached value.
class RequestPressureEvaluator {
  final int outputReservationTokens;
  final int safetyBufferTokens;
  final Map<String, int> _toolSchemaTokenCache;

  RequestPressureEvaluator({
    this.outputReservationTokens = 4096,
    this.safetyBufferTokens = 1024,
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
    int? confirmedInputTokens,
  }) {
    final historyTokens =
        CompactionTokenEstimator.estimateMessages(conversationMessages);
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
    final estimated = components.total;
    final measurementKind = _measurementKind(
      estimated: estimated,
      confirmed: confirmedInputTokens,
    );
    return RequestPressureSnapshot(
      routeSignature: routeSignature,
      contextWindowTokens: contextWindowTokens,
      inputLimitTokens: inputLimitTokens,
      outputReservationTokens: outputReservationTokens,
      safetyBufferTokens: safetyBufferTokens,
      components: components,
      estimatedRequestTokens: estimated,
      confirmedInputTokens: confirmedInputTokens,
      measurementKind: measurementKind,
    );
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

  static String _toolSchemaCacheKey(
    RouteSignature route,
    List<Map<String, dynamic>> toolSchemas,
  ) {
    return Object.hash(
      route.providerInstanceId,
      route.modelId,
      route.protocol,
      route.normalizedBaseUrl,
      route.configRevision,
      route.credentialRevision,
      jsonEncode(toolSchemas),
    ).toString();
  }

  CompactionMeasurementKind _measurementKind({
    required int estimated,
    required int? confirmed,
  }) {
    if (confirmed == null) {
      return CompactionMeasurementKind.estimated;
    }
    if (confirmed == estimated) {
      return CompactionMeasurementKind.confirmed;
    }
    return CompactionMeasurementKind.mixed;
  }
}
