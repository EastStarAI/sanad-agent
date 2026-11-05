import 'dart:async';

import 'package:logging/logging.dart';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_endpoint_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';

/// Outcome of one connection verification.
///
/// [failure] is null only when the endpoint answered with a verified live model
/// list **and** the minimal generation probe succeeded.
class InstanceVerification {
  const InstanceVerification({
    required this.success,
    required this.modelsCount,
    this.model,
    this.probeLatency,
    this.failure,
  });

  final bool success;
  final int modelsCount;
  final String? model;
  final Duration? probeLatency;
  final ProviderDiscoveryError? failure;

  /// Wire payload of `provider.instance.test_result`.
  ///
  /// `error`/`message` remain for older clients that read the failure text;
  /// `failure` is the typed sanitized cause every current surface renders.
  Map<String, dynamic> toMap() => {
    'success': success,
    'models_count': modelsCount,
    if (model != null) 'model': model,
    if (probeLatency != null) 'latency_ms': probeLatency!.inMilliseconds,
    if (failure != null) ...{
      'failure': failure!.toMap(),
      'error': failure!.summary,
      'message': failure!.summary,
    },
  };
}

/// The single owner of "does this provider instance actually work?".
///
/// Verification is two-stage because a `/models` listing alone does not prove
/// the credential: some providers serve the catalog unauthenticated. Stage one
/// is a live model discovery; stage two is one minimal generation request
/// against the instance's own model. The probe is never retried, never streamed
/// into a session, and never persisted as conversation history.
class ProviderInstanceVerifier {
  ProviderInstanceVerifier({
    required ProviderModelCacheService cache,
    required ProviderInstanceRepository repository,
    required ProviderInstanceService instances,
    required ProviderCredentialService credentials,
    AgentRuntimeService? runtime,
    this.probeEnabled = true,
    this.probeTimeout = defaultProbeTimeout,
  }) : _cache = cache,
       _repo = repository,
       _instances = instances,
       _credentials = credentials,
       _runtime = runtime;

  static const Duration defaultProbeTimeout = Duration(seconds: 12);

  /// Prompt is deliberately tiny: the probe proves credential + wire reach the
  /// model, not answer quality.
  static const String _probeSystemPrompt =
      'You are a connection check. Answer with a single word.';
  static const String _probeUserPrompt = 'Reply with OK.';

  final _logger = Logger('ProviderInstanceVerifier');
  final ProviderModelCacheService _cache;
  final ProviderInstanceRepository _repo;
  final ProviderInstanceService _instances;
  final ProviderCredentialService _credentials;
  final AgentRuntimeService? _runtime;

  /// Whether the generation probe runs after a verified discovery. Disabled
  /// only when no runtime is available to resolve an adapter.
  final bool probeEnabled;
  final Duration probeTimeout;

  /// Verifies [instanceId] and applies the resulting lifecycle status.
  Future<InstanceVerification> verify(String instanceId) async {
    final instance = _repo.findById(instanceId);
    if (instance == null) {
      return const InstanceVerification(
        success: false,
        modelsCount: 0,
        failure: ProviderDiscoveryError(
          kind: ProviderFailureCategory.unknown,
          message: 'Provider instance not found',
        ),
      );
    }
    final modelsEndpoint = _modelsEndpoint(instance);

    // Stage one — live discovery. A refresh that keeps a previous list writes a
    // stale source, so the row's own error decides the outcome rather than the
    // projection's revision filter.
    try {
      await _cache.refresh(instanceId, manual: true);
    } catch (error) {
      _logger.fine('Discovery failed during verification: $error');
    }
    final row = _repo.readModelCache(instanceId, 'models');
    final cachedModels = (row?['models'] as List?) ?? const <dynamic>[];
    final models = cachedModels
        .whereType<Map>()
        .map((entry) => entry['value']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final failure = ProviderDiscoveryError.tryRestore(
      detailJson: row?['last_error_detail'],
      legacyText: row?['last_error'],
    );
    if (failure != null) {
      return _fail(instance, failure, models.length);
    }
    if (row == null || row['source'] != 'live') {
      return _fail(
        instance,
        ProviderDiscoveryError.fallbackPresets(endpoint: modelsEndpoint),
        models.length,
      );
    }
    if (models.isEmpty) {
      return _fail(
        instance,
        ProviderDiscoveryError.noModels(endpoint: modelsEndpoint),
        0,
      );
    }

    // Stage two — minimal generation probe.
    final probeModel = _probeModel(instance, models);
    if (!probeEnabled || _runtime == null) {
      _instances.applyConnectionOutcome(
        instanceId,
        null,
        credentialConfigured: _credentialConfigured(instanceId),
      );
      return InstanceVerification(
        success: true,
        modelsCount: models.length,
        model: probeModel,
      );
    }
    final stopwatch = Stopwatch()..start();
    try {
      final signature = _runtime.resolveSignature(
        providerId: instanceId,
        modelId: probeModel,
      );
      final adapter = _runtime.adapterFor(signature);
      await adapter
          .generateResponse(
            [
              Message(role: MessageRole.system, content: _probeSystemPrompt),
              Message(role: MessageRole.user, content: _probeUserPrompt),
            ],
            modelOverride: probeModel,
            options: LLMRequestOptions(
              providerInstanceId: instanceId,
              timeout: probeTimeout,
              maxOutputTokens: 1,
            ),
          )
          .timeout(probeTimeout);
      stopwatch.stop();
      _instances.applyConnectionOutcome(
        instanceId,
        null,
        credentialConfigured: _credentialConfigured(instanceId),
      );
      return InstanceVerification(
        success: true,
        modelsCount: models.length,
        model: probeModel,
        probeLatency: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      _logger.fine('Generation probe failed during verification: $error');
      return _fail(
        instance,
        ProviderDiscoveryError.capture(
          error,
          endpoint: _chatEndpoint(instance),
        ),
        models.length,
        model: probeModel,
        latency: stopwatch.elapsed,
      );
    }
  }

  InstanceVerification _fail(
    ProviderInstance instance,
    ProviderDiscoveryError failure,
    int modelsCount, {
    String? model,
    Duration? latency,
  }) {
    _instances.applyConnectionOutcome(
      instance.id,
      failure,
      credentialConfigured: _credentialConfigured(instance.id),
    );
    return InstanceVerification(
      success: false,
      modelsCount: modelsCount,
      model: model,
      probeLatency: latency,
      failure: failure,
    );
  }

  bool _credentialConfigured(String instanceId) =>
      _credentials.summary(instanceId).configured;

  /// The instance's own default model when discovery advertised it, otherwise
  /// the first model the endpoint offered.
  String? _probeModel(ProviderInstance instance, List<String> models) {
    final selected = instance.defaultModel;
    if (selected != null && selected.isNotEmpty) {
      if (models.contains(selected)) return selected;
      // A selected model that discovery did not advertise is still the user's
      // choice; probing it reports the honest result for that route.
      return selected;
    }
    return models.first;
  }

  Uri? _modelsEndpoint(ProviderInstance instance) {
    final baseUrl = instance.effectiveBaseUrl;
    if (baseUrl == null || baseUrl.trim().isEmpty) return null;
    try {
      return ProviderEndpointResolver.resolveModelsEndpoint(
        baseUrl,
        instance.protocol,
      );
    } catch (_) {
      return null;
    }
  }

  Uri? _chatEndpoint(ProviderInstance instance) {
    final baseUrl = instance.effectiveBaseUrl;
    if (baseUrl == null || baseUrl.trim().isEmpty) return null;
    try {
      return ProviderEndpointResolver.resolveChatEndpoint(
        baseUrl,
        instance.protocol,
      );
    } catch (_) {
      return null;
    }
  }
}
