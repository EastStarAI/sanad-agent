import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_endpoint_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/missing_provider_adapter.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/rate_limited_llm_adapter.dart';

/// Immutable identity of a routed LLM request: which provider instance, which
/// template, which protocol, which normalized base URL, which model, and revision.
/// Two turns with the same [RouteSignature] reuse the same cached [LLMAdapter];
/// different signatures build (and cache) distinct adapters, enabling concurrent
/// sessions with different providers (Plan 29 §9.1).
class RouteSignature {
  final String providerInstanceId;
  final String templateId;
  final String protocol;
  final String normalizedBaseUrl;
  final String modelId;
  final int configRevision;
  final int credentialRevision;

  const RouteSignature({
    required this.providerInstanceId,
    required this.templateId,
    required this.protocol,
    required this.normalizedBaseUrl,
    required this.modelId,
    required this.configRevision,
    required this.credentialRevision,
  });

  /// Composite cache key used by [AgentRuntimeService]. Deliberately excludes
  /// credentials so secrets never appear in cache keys or logs.
  String get cacheKey => '$providerInstanceId/$modelId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RouteSignature &&
          runtimeType == other.runtimeType &&
          providerInstanceId == other.providerInstanceId &&
          templateId == other.templateId &&
          protocol == other.protocol &&
          normalizedBaseUrl == other.normalizedBaseUrl &&
          modelId == other.modelId &&
          configRevision == other.configRevision &&
          credentialRevision == other.credentialRevision;

  @override
  int get hashCode => Object.hash(
    providerInstanceId,
    templateId,
    protocol,
    normalizedBaseUrl,
    modelId,
    configRevision,
    credentialRevision,
  );

  @override
  String toString() =>
      'RouteSignature($cacheKey, template=$templateId, protocol=$protocol, configRev=$configRevision, credRev=$credentialRevision)';
}

/// Owns the composite-keyed [LLMAdapter] cache, replacing the previous
/// process-global singleton adapter. Switching provider/model is a cache
/// lookup/insert — no eviction, no restart, no global mutation — so multiple
/// sessions can use different providers concurrently with full isolation.
///
/// Adapters are built lazily from [RouteSignature] using the same factory
/// logic that lived in `di.dart`, but credentials are now resolved per-profile
/// via [Config.apiKeyFor]/[Config.baseUrlFor] and [ProviderCredentialResolver],
/// so a non-active provider gets its own key.
class AgentRuntimeService {
  final Map<RouteSignature, LLMAdapter> _adapters = {};
  final Map<String, RouteSignature> _sessionSignatures = {};
  final Config _config;
  final ModelsDevService? _modelsDevService;
  final ProviderCredentialResolver? _credentialResolver;
  final ProviderInstanceRepository _instanceRepo;
  final ProviderCredentialService? _credService;
  final ProviderRateLimiter? _rateLimiter;
  final RuntimeRecoveryService? _recoveryService;

  AgentRuntimeService(
    this._config,
    this._instanceRepo, {
    ModelsDevService? modelsDevService,
    ProviderCredentialResolver? credentialResolver,
    ProviderCredentialService? credService,
    ProviderRateLimiter? rateLimiter,
    RuntimeRecoveryService? recoveryService,
  }) : _modelsDevService = modelsDevService,
       _credentialResolver = credentialResolver,
       _credService = credService,
       _rateLimiter = rateLimiter,
       _recoveryService = recoveryService;
  ProviderCredentialService? get credentialService => _credService;

  /// Resolves the signature for a given provider instance (by UUID) and model.
  /// Fails closed with a clear error — no fallback to legacy env vars (Plan 29 §3.10).
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    ProviderInstance? instance;
    if (providerId != null && providerId.isNotEmpty) {
      instance = _instanceRepo.findById(providerId);
      if (instance == null) {
        throw StateError(
          'Provider instance not found for UUID: $providerId. '
          'Use a valid instance UUID or configure a default provider instance.',
        );
      }
    } else {
      // Fail closed: only an explicitly-set default instance is used for
      // implicit routing. We NEVER silently fall back to the first row —
      // that could route a request through an unrelated account (Plan 29
      // §3.10, criterion 13/24).
      instance = _instanceRepo.findDefault();
      if (instance == null) {
        throw StateError(
          'No default provider instance is set. '
          'Create a provider instance and mark one as default.',
        );
      }
    }

    final effModel = (modelId != null && modelId.isNotEmpty)
        ? modelId
        : instance.defaultModel;
    if (effModel == null || effModel.isEmpty) {
      throw StateError(
        'No model selected for provider instance "${instance.displayName}" (${instance.id}). '
        'Set a default model for the instance.',
      );
    }

    final normalizedModel = ProviderModelId.normalize(
      templateId: instance.templateId,
      protocol: instance.protocol,
      rawModelId: effModel,
    );

    final effBaseUrl = instance.effectiveBaseUrl ?? '';
    final normalizedUrl = ProviderEndpointResolver.normalizeBaseUrl(effBaseUrl);

    return RouteSignature(
      providerInstanceId: instance.id,
      templateId: instance.templateId,
      protocol: instance.protocol,
      normalizedBaseUrl: normalizedUrl,
      modelId: normalizedModel,
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );
  }

  /// Returns the cached adapter for [signature], building and caching it on
  /// miss. Throws on build failure without disturbing existing cache entries.
  LLMAdapter adapterFor(RouteSignature signature) {
    final cached = _adapters[signature];
    if (cached != null) {
      return cached;
    }
    final built = _buildAdapter(signature);
    _adapters[signature] = built;
    return built;
  }

  /// Plan 30: returns a turn-scoped adapter that wraps the cached adapter with
  /// a [RateLimitedLLMAdapter] when the instance has a rate limit > 0. The
  /// wrapper is wired to the [RuntimeRecoveryService] so a rate-limit wait
  /// broadcasts a `session.runtime_notice`, and to the session's cancel token
  /// so `session.runtime_stop` / provider change aborts the wait.
  ///
  /// When no rate limiter or recovery service is configured (e.g. isolated
  /// unit tests), this returns the raw cached adapter unchanged.
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) {
    final inner = adapterFor(signature);
    final limiter = _rateLimiter;
    final recovery = _recoveryService;
    if (limiter == null || recovery == null) {
      return inner;
    }
    // Resolve the instance to read its configured rate limit.
    final instance = _instanceRepo.findById(signature.providerInstanceId);
    final rpm = instance?.requestsPerMinute ?? 0;
    if (rpm <= 0) {
      return inner;
    }
    return RateLimitedLLMAdapter(
      inner,
      providerInstanceId: signature.providerInstanceId,
      requestsPerMinute: rpm,
      limiter: limiter,
      cancelToken: recovery.cancelToken(sessionId, runId: runId),
      onRateLimited:
          ({
            required providerInstanceId,
            required retryAfter,
            int? limit,
          }) async {
            await recovery.reportRateLimitWait(
              sessionId: sessionId,
              providerInstanceId: providerInstanceId,
              retryAfter: retryAfter,
              limit: limit,
              requestId: requestId,
              runId: runId,
            );
          },
    );
  }

  /// Returns the default adapter derived from the current default instance.
  LLMAdapter defaultAdapter() {
    try {
      return adapterFor(resolveSignature());
    } catch (error) {
      return missingProviderAdapter(error);
    }
  }

  /// Returns an adapter that fails lazily with a user-facing provider error
  /// instead of crashing dependency resolution or daemon startup.
  LLMAdapter missingProviderAdapter([Object? error]) {
    return MissingProviderAdapter(message: _missingProviderMessage(error));
  }

  /// Records the last signature used for a session (for metrics/observability
  /// only; routing is always derived from the message, not from this map).
  void rememberSessionSignature(String sessionId, RouteSignature signature) {
    _sessionSignatures[sessionId] = signature;
  }

  /// The last signature recorded for [sessionId], or null.
  RouteSignature? sessionSignature(String sessionId) =>
      _sessionSignatures[sessionId];

  /// Clears the entire adapter cache.
  void invalidate() {
    _adapters.clear();
  }

  /// Clears only the adapters whose provider instance matches [providerInstanceId].
  void invalidateProvider(String providerInstanceId) {
    _adapters.removeWhere(
      (sig, _) => sig.providerInstanceId == providerInstanceId,
    );
  }

  LLMAdapter _buildAdapter(RouteSignature signature) {
    String? resolvedApiKey;
    if (_credService != null &&
        !signature.providerInstanceId.startsWith('fallback-')) {
      final rawSecret = _credService.rawForResolver(
        signature.providerInstanceId,
      );
      if (rawSecret != null) {
        resolvedApiKey = rawSecret.apiKey ?? rawSecret.accessToken;
      }
    }

    final profile = _profileForSignature(signature);
    int? modelContextLimitLookup(String modelId) =>
        _catalogContextLimit(signature, modelId);

    if (_credentialResolver != null) {
      _credentialResolver.resolve(profile.name);
    }

    if (signature.protocol == ProviderProtocol.anthropicCompatible) {
      return BaseAnthropicAdapter(
        _config,
        profile,
        modelContextLimitLookup: modelContextLimitLookup,
        baseUrlOverride: signature.normalizedBaseUrl,
        apiKeyOverride: resolvedApiKey,
        defaultModelOverride: signature.modelId,
      );
    } else {
      if (profile.apiMode == 'codex_responses') {
        return CodexResponsesAdapter(
          _config,
          profile,
          modelContextLimitLookup: modelContextLimitLookup,
          baseUrlOverride: signature.normalizedBaseUrl,
          apiKeyOverride: resolvedApiKey,
          defaultModelOverride: signature.modelId,
        );
      } else if (profile.apiMode == 'ollama') {
        return OllamaAdapter(
          _config,
          profile,
          modelContextLimitLookup: modelContextLimitLookup,
          baseUrlOverride: signature.normalizedBaseUrl,
        );
      } else {
        return BaseOpenAIAdapter(
          _config,
          profile,
          modelsDevService: _modelsDevService,
          modelContextLimitLookup: modelContextLimitLookup,
          baseUrlOverride: signature.normalizedBaseUrl,
          apiKeyOverride: resolvedApiKey,
          defaultModelOverride: signature.modelId,
        );
      }
    }
  }

  int? _catalogContextLimit(RouteSignature signature, String rawModelId) {
    final cached = _instanceRepo.readModelCache(
      signature.providerInstanceId,
      'models',
    );
    if (cached == null ||
        cached['config_revision'] != signature.configRevision ||
        cached['credential_revision'] != signature.credentialRevision) {
      return null;
    }

    final requestedModel = ProviderModelId.normalize(
      templateId: signature.templateId,
      protocol: signature.protocol,
      rawModelId: rawModelId,
    ).toLowerCase();
    final models = cached['models'];
    if (requestedModel.isEmpty || models is! List) return null;

    for (final entry in models) {
      if (entry is! Map) continue;
      final cachedModel = ProviderModelId.normalize(
        templateId: signature.templateId,
        protocol: signature.protocol,
        rawModelId: entry['value']?.toString() ?? '',
      ).toLowerCase();
      if (cachedModel != requestedModel) continue;

      final contextWindow = entry['context_window'];
      if (contextWindow is num && contextWindow > 0) {
        return contextWindow.toInt();
      }
      return null;
    }
    return null;
  }

  ProviderProfile _profileForSignature(RouteSignature signature) {
    final registered = ProviderRegistry.findByNameOrAlias(signature.templateId);
    if (registered == null) {
      return ProviderProfile(
        name: signature.templateId,
        displayName: 'Custom Provider',
        authType: 'api_key',
        authFlow: 'custom_endpoint',
        apiMode: signature.protocol == ProviderProtocol.anthropicCompatible
            ? 'anthropic_messages'
            : 'chat_completions',
        protocol: signature.protocol,
        fallbackModels:
            signature.protocol == ProviderProtocol.anthropicCompatible
            ? (ProviderRegistry.findByNameOrAlias(
                    'anthropic',
                  )?.fallbackModels ??
                  const [])
            : const [],
      );
    }

    if (!registered.isCustom) {
      return registered;
    }

    return ProviderProfile(
      name: registered.name,
      displayName: registered.displayName,
      description: registered.description,
      defaultBaseUrl: registered.defaultBaseUrl,
      envApiKeyName: registered.envApiKeyName,
      envModelName: registered.envModelName,
      envBaseUrlName: registered.envBaseUrlName,
      defaultHeaders: registered.defaultHeaders,
      authType: registered.authType,
      authFlow: registered.authFlow,
      apiMode: signature.protocol == ProviderProtocol.anthropicCompatible
          ? 'anthropic_messages'
          : 'chat_completions',
      aliases: registered.aliases,
      fallbackModels: signature.protocol == ProviderProtocol.anthropicCompatible
          ? (ProviderRegistry.findByNameOrAlias('anthropic')?.fallbackModels ??
                const [])
          : registered.fallbackModels,
      docsUrl: registered.docsUrl,
      supportsModelFetch: registered.supportsModelFetch,
      disconnectable: registered.disconnectable,
      protocol: signature.protocol,
      apiKeyRequirement: registered.apiKeyRequirement,
      authMethods: registered.authMethods,
      supportsMultipleInstances: registered.supportsMultipleInstances,
      defaultRequestsPerMinute: registered.defaultRequestsPerMinute,
    );
  }

  String _missingProviderMessage(Object? error) {
    if (error == null) {
      return 'No ready provider is configured for this device. Open Provider Setup or skip setup for now.';
    }
    final message = error.toString().trim();
    if (message.isEmpty) {
      return 'No ready provider is configured for this device. Open Provider Setup or skip setup for now.';
    }
    return message;
  }
}
