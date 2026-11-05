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
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';

/// State of the optional generation probe inside one verification.
class ProbeState {
  ProbeState._();

  /// The selected model answered the probe.
  static const passed = 'passed';

  /// No model is selected yet, so there is nothing to probe.
  static const skipped = 'skipped';

  /// The probe failed for a reason that does not prove the credential is wrong.
  static const warning = 'warning';

  /// The probe was rejected with `401`/`403`: the credential is wrong.
  static const failed = 'failed';

  /// Discovery-only verification; the probe was not requested.
  static const notRun = 'not_run';

  static const all = <String>[passed, skipped, warning, failed, notRun];

  static bool isValid(String value) => all.contains(value);
}

/// A non-blocking probe warning: the credential listed models but the optional
/// generation check did not prove the route.
class ProbeWarning {
  const ProbeWarning({required this.kind, this.model, required this.cause});

  /// The model or its request parameters were rejected.
  static const modelRejected = 'model_rejected';

  /// The account may list models but is not allowed to run the probed one.
  static const forbidden = 'forbidden';

  /// The probe exceeded its time budget.
  static const timeout = 'timeout';

  /// The probe could not reach the endpoint.
  static const network = 'network';

  /// The endpoint rate limited the probe.
  static const rateLimited = 'rate_limited';

  /// A probe failure the runtime could not classify.
  static const unknown = 'unknown';

  final String kind;
  final String? model;
  final ProviderDiscoveryError cause;

  Map<String, dynamic> toMap() => {
    'kind': kind,
    if (model != null) 'model': model,
    'cause': cause.toMap(),
  };
}

/// Outcome of one connection verification.
///
/// [failure] is set only for a definitive cause — a discovery failure that
/// proves the credential or the endpoint is wrong, or a `401`/`403` from the
/// generation probe. A [warning] describes a probe that did not prove the route
/// without proving anything is misconfigured, so it never changes the instance
/// status on its own.
class InstanceVerification {
  const InstanceVerification({
    required this.success,
    required this.modelsCount,
    required this.probeState,
    this.model,
    this.probeLatency,
    this.failure,
    this.warning,
  });

  final bool success;
  final int modelsCount;
  final String probeState;
  final String? model;
  final Duration? probeLatency;
  final ProviderDiscoveryError? failure;
  final ProbeWarning? warning;

  /// Wire payload of `provider.instance.test_result`.
  ///
  /// `error`/`message` remain for older clients that read the failure text;
  /// `failure` is the typed sanitized cause every current surface renders,
  /// `warning` is its non-blocking counterpart, and `probe_state` tells the
  /// client which of the pass/partial/warning shapes to show.
  Map<String, dynamic> toMap() => {
    'success': success,
    'models_count': modelsCount,
    'probe_state': probeState,
    if (model != null) 'model': model,
    if (probeLatency != null) 'latency_ms': probeLatency!.inMilliseconds,
    if (warning != null) 'warning': warning!.toMap(),
    if (failure != null) ...{
      'failure': failure!.toMap(),
      'error': failure!.summary,
      'message': failure!.summary,
    },
  };
}

/// The single owner of "does this provider instance actually work?".
///
/// Verification has two independently-useful stages:
///
/// 1. **Discovery** (always): a live model listing for the current credential
///    revisions. A definitive discovery failure is the only thing that may block
///    setup, because it proves the credential or the endpoint is wrong.
/// 2. **Generation probe** (opt-in, `probe: true`): one minimal request against
///    the instance's *selected* model. It proves the route end to end for the
///    Test action, but it must never block setup: an unselected model, a
///    non-chat entry in `/models`, a model that rejects the output bound, or a
///    cold-loading local engine would otherwise reject a valid credential.
///
/// The probe is never retried, never streamed into a session, and never
/// persisted as conversation history.
class ProviderInstanceVerifier {
  ProviderInstanceVerifier({
    required ProviderModelCacheService cache,
    required ProviderInstanceRepository repository,
    required ProviderInstanceService instances,
    required ProviderCredentialService credentials,
    AgentRuntimeService? runtime,
    this.probeEnabled = true,
    this.probeTimeout = defaultProbeTimeout,
    this.localProbeTimeout = defaultLocalProbeTimeout,
  }) : _cache = cache,
       _repo = repository,
       _instances = instances,
       _credentials = credentials,
       _runtime = runtime;

  /// Time budget for a hosted provider, whose models answer immediately.
  static const Duration defaultProbeTimeout = Duration(seconds: 12);

  /// Time budget for a local engine, which may cold-load a model on first use.
  static const Duration defaultLocalProbeTimeout = Duration(seconds: 90);

  /// Prompt is deliberately tiny: the probe proves credential + wire reach the
  /// model, not answer quality.
  static const String _probeSystemPrompt =
      'You are a connection check. Answer with a single word.';
  static const String _probeUserPrompt = 'Reply with OK.';

  /// Output bound for the probe. Adapters translate it onto their own wire
  /// field (`max_completion_tokens`, `max_tokens`, `max_output_tokens`).
  static const int _probeMaxOutputTokens = 1;

  final _logger = Logger('ProviderInstanceVerifier');
  final ProviderModelCacheService _cache;
  final ProviderInstanceRepository _repo;
  final ProviderInstanceService _instances;
  final ProviderCredentialService _credentials;
  final AgentRuntimeService? _runtime;

  /// Whether a probe is possible at all (a runtime must be available).
  final bool probeEnabled;

  /// Probe budget for hosted providers.
  final Duration probeTimeout;

  /// Probe budget for local engines, which can cold-load a model.
  final Duration localProbeTimeout;

  /// Verifies [instanceId] and applies the resulting lifecycle status.
  ///
  /// Set [probe] to false for a setup gate: discovery alone decides whether the
  /// credential or endpoint is wrong, and no generation request is made.
  Future<InstanceVerification> verify(
    String instanceId, {
    bool probe = true,
  }) async {
    final instance = _repo.findById(instanceId);
    if (instance == null) {
      return const InstanceVerification(
        success: false,
        modelsCount: 0,
        probeState: ProbeState.notRun,
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
    // The failure a setup gate may act on is the one discovery proved.
    final discoveryFailure = _discoveryFailure(
      row,
      modelsEndpoint,
      models.length,
    );
    if (discoveryFailure != null) {
      return _fail(instance, discoveryFailure, models.length);
    }

    final selected = instance.defaultModel;
    final probeModel = selected == null || selected.isEmpty ? null : selected;
    final canProbe = probe && probeEnabled && _runtime != null;
    if (!canProbe || probeModel == null) {
      // Discovery alone is a valid outcome: the credential listed models.
      _applyVerified(instance);
      return InstanceVerification(
        success: true,
        modelsCount: models.length,
        probeState: canProbe ? ProbeState.skipped : ProbeState.notRun,
        model: probeModel,
      );
    }

    // Stage two — minimal generation probe against the selected model only.
    final budget = _probeBudget(instance);
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
              timeout: budget,
              maxOutputTokens: _probeMaxOutputTokens,
            ),
          )
          .timeout(budget);
      stopwatch.stop();
      // A pass clears a previous warning from the stored row.
      _cache.recordVerificationCause(instanceId, null);
      _applyVerified(instance);
      return InstanceVerification(
        success: true,
        modelsCount: models.length,
        probeState: ProbeState.passed,
        model: probeModel,
        probeLatency: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      _logger.fine('Generation probe failed during verification: $error');
      final cause = ProviderDiscoveryError.capture(
        error,
        endpoint: _chatEndpoint(instance),
      );
      if (cause.kind == ProviderFailureCategory.invalidCredential) {
        // Only a probe 401 proves the credential is rejected. The cause is
        // persisted so the demotion survives a restart (issue 339 review 2).
        _cache.recordVerificationCause(instanceId, cause);
        return _fail(
          instance,
          cause,
          models.length,
          model: probeModel,
          latency: stopwatch.elapsed,
        );
      }
      // A probe 403, a model/parameter rejection, a timeout, a transport
      // failure, a rate limit, or a 5xx proves nothing about the credential:
      // warn, keep the status discovery decided, and persist the warning so the
      // card still explains itself after a restart. The verified discovery is
      // applied first — the warning must never block the readiness it did not
      // disprove (issue 339 review 2).
      final warningCause = cause.asWarning();
      _applyVerified(instance);
      _cache.recordVerificationCause(instanceId, warningCause);
      return InstanceVerification(
        success: true,
        modelsCount: models.length,
        probeState: ProbeState.warning,
        model: probeModel,
        probeLatency: stopwatch.elapsed,
        warning: ProbeWarning(
          kind: _warningKindFor(cause),
          model: probeModel,
          cause: warningCause,
        ),
      );
    }
  }

  /// Probe warning class for a non-definitive probe cause.
  static String _warningKindFor(ProviderDiscoveryError cause) {
    switch (cause.kind) {
      case ProviderFailureCategory.timeout:
        return ProbeWarning.timeout;
      case ProviderFailureCategory.network:
        return ProbeWarning.network;
      case ProviderFailureCategory.rateLimited:
        return ProbeWarning.rateLimited;
      case ProviderFailureCategory.forbidden:
        // The account may list models but not run this one: a policy warning.
        return ProbeWarning.forbidden;
      case ProviderFailureCategory.invalidCredential:
        // Only reachable when a caller downgraded it; keep the model wording.
        return ProbeWarning.modelRejected;
      case ProviderFailureCategory.endpointNotFound:
      case ProviderFailureCategory.http:
        return ProbeWarning.modelRejected;
      default:
        return ProbeWarning.unknown;
    }
  }

  /// The discovery failure a setup gate may block on, or null when the current
  /// revisions discovered a usable live list.
  ProviderDiscoveryError? _discoveryFailure(
    Map<String, dynamic>? row,
    Uri? modelsEndpoint,
    int modelsCount,
  ) {
    final stored = ProviderDiscoveryError.tryRestore(
      detailJson: row?['last_error_detail'],
      legacyText: row?['last_error'],
    );
    if (stored != null) return stored;
    if (row == null || row['source'] != 'live') {
      return ProviderDiscoveryError.fallbackPresets(endpoint: modelsEndpoint);
    }
    if (modelsCount == 0) {
      return ProviderDiscoveryError.noModels(endpoint: modelsEndpoint);
    }
    return null;
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
      probeState: model == null ? ProbeState.notRun : ProbeState.failed,
      model: model,
      probeLatency: latency,
      failure: failure,
    );
  }

  /// Records a verified discovery, which is what returns an instance to `ready`.
  void _applyVerified(ProviderInstance instance) {
    _instances.applyConnectionOutcome(
      instance.id,
      null,
      credentialConfigured: _credentialConfigured(instance.id),
    );
  }

  bool _credentialConfigured(String instanceId) =>
      _credentials.summary(instanceId).configured;

  /// A local engine may cold-load a model, so it gets a longer budget. Optional
  /// key templates are the local engines and user-defined endpoints.
  Duration _probeBudget(ProviderInstance instance) {
    final template = instance.template;
    final isLocal = template != null &&
        template.apiKeyRequirement == ApiKeyRequirement.optional;
    return isLocal ? localProbeTimeout : probeTimeout;
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
