import '../../core/provider_runtime/provider_protocol_constants.dart';

/// An immutable **provider template** (Plan 29 §7.1).
///
/// A template describes the wire protocol, supported authentication methods,
/// default endpoint, fallback models, and model-fetch capabilities of a
/// provider *kind*. It never holds a secret, a selected model, or any
/// user-specific state. `ProviderRegistry` is the catalog of official
/// templates; the reserved `custom` template lets the user build an
/// OpenAI-compatible or Anthropic-compatible instance without a hardcoded
/// gateway name.
///
/// A user-created [`ProviderInstance`]"(../../core/provider_runtime/provider_instance.dart)
/// references a template by `templateId` and adds its own UUID, display name,
/// credential, and default model.
class ProviderProfile {
  final String name;
  final String displayName;
  final String description;
  final String? defaultBaseUrl;
  final String? envApiKeyName;
  final String? envModelName;
  final String? envBaseUrlName;
  final Map<String, String> defaultHeaders;
  final String authType; // 'api_key' | 'oauth_external' | 'oauth_device_code'
  final String
  apiMode; // 'chat_completions' | 'anthropic_messages' | 'codex_responses' | 'ollama'
  final List<String> aliases;
  final List<String> fallbackModels;

  /// Flow used to authenticate: `api_key`, `device_code`, `loopback`,
  /// `external`, or `custom_endpoint`. Derived from authType when not set.
  final String? authFlow;

  /// Documentation or signup URL for obtaining credentials.
  final String? docsUrl;

  /// Whether the adapter can fetch a live model list from the provider API.
  final bool supportsModelFetch;

  /// Whether the user can disconnect/remove this provider from the UI.
  /// Subscription-based providers may set this to false to hide remove actions.
  final bool disconnectable;

  /// High-level wire protocol (Plan 29 §7.1). One of [ProviderProtocol].
  /// When omitted it is derived from [apiMode]: `anthropic_messages` →
  /// `anthropic_compatible`, everything else → `openai_compatible`.
  final String? protocol;

  /// Whether an API key is mandatory for this template (Plan 29 §7.1).
  /// Official cloud templates use [ApiKeyRequirement.required]; local engines,
  /// the `custom` template, and OAuth-only templates use
  /// [ApiKeyRequirement.optional]. Defaults to `required`.
  final String apiKeyRequirement;

  /// Explicit authentication methods this template advertises (Plan 29 §7.1).
  /// Drives the `Account` vs `API Key` badge and the auth picker. When empty
  /// it is derived from [authType]/[authFlow].
  final List<String> authMethods;

  /// Whether the user may create more than one instance from this template
  /// (Plan 29 §7.1). All templates default to true; a template may opt out to
  /// model a singleton-only provider.
  final bool supportsMultipleInstances;

  /// Default per-instance rate limit in requests per minute (Plan 30 §6.2).
  /// Applied to a new instance only when the client does not send an explicit
  /// value. `0` means unlimited. NVIDIA NIM advertises `38` to avoid strict
  /// `429` limits; all other templates default to `0`.
  final int defaultRequestsPerMinute;

  /// Optional thinking policy id (Task 43). When omitted, [effectiveThinkingPolicyId]
  /// derives from [apiMode].
  final String? thinkingPolicyId;

  const ProviderProfile({
    required this.name,
    this.displayName = '',
    this.description = '',
    this.defaultBaseUrl,
    this.envApiKeyName,
    this.envModelName,
    this.envBaseUrlName,
    this.defaultHeaders = const {},
    this.authType = 'api_key',
    this.apiMode = 'chat_completions',
    this.aliases = const [],
    this.fallbackModels = const [],
    this.authFlow,
    this.docsUrl,
    this.supportsModelFetch = true,
    this.disconnectable = true,
    this.protocol,
    this.apiKeyRequirement = ApiKeyRequirement.required,
    this.authMethods = const [],
    this.supportsMultipleInstances = true,
    this.defaultRequestsPerMinute = 0,
    this.thinkingPolicyId,
  });

  /// Resolves the effective auth flow, deriving from authType when authFlow
  /// is not explicitly set.
  String get effectiveAuthFlow {
    if (authFlow != null) {
      return authFlow!;
    }
    switch (authType) {
      case 'oauth_external':
      case 'oauth_device_code':
        return 'device_code';
      case 'api_key':
      default:
        return 'api_key';
    }
  }

  /// Whether this provider uses an OAuth-style flow instead of a static key.
  bool get isOAuth =>
      authType == 'oauth_external' || authType == 'oauth_device_code';

  /// Effective wire protocol, deriving from [apiMode] when [protocol] is null.
  String get effectiveProtocol {
    if (protocol != null) return protocol!;
    return apiMode == 'anthropic_messages'
        ? ProviderProtocol.anthropicCompatible
        : ProviderProtocol.openaiCompatible;
  }

  /// Whether an API key is mandatory for this template.
  bool get requiresApiKey => apiKeyRequirement == ApiKeyRequirement.required;

  /// Effective advertised auth methods, deriving from [effectiveAuthFlow] when
  /// [authMethods] is empty.
  List<String> get effectiveAuthMethods =>
      authMethods.isNotEmpty ? authMethods : [effectiveAuthFlow];

  /// Whether this is the reserved Custom template.
  bool get isCustom => name == kCustomProviderTemplateId;

  /// Effective thinking policy id for capability resolution (Task 43).
  ///
  /// Explicit [thinkingPolicyId] wins. Otherwise only proven apiMode seams map
  /// to a first-release policy; generic `chat_completions` fails closed to
  /// `unknown` so OpenAI Chat effort is opted in per template, not assumed.
  String get effectiveThinkingPolicyId {
    if (thinkingPolicyId != null && thinkingPolicyId!.isNotEmpty) {
      return thinkingPolicyId!;
    }
    if (isCustom) {
      return 'unknown';
    }
    return switch (apiMode) {
      'codex_responses' => 'codex_responses_effort',
      'anthropic_messages' => 'anthropic_thinking',
      'ollama' => 'ollama_live',
      _ => 'unknown',
    };
  }

  /// Serializes the template into a transport-safe map for socket commands.
  /// Secrets are never included here.
  Map<String, dynamic> toPublicMap() => {
    'id': name,
    'name': name,
    'display_name': displayName,
    'description': description,
    if (defaultBaseUrl != null) 'default_base_url': defaultBaseUrl,
    if (envApiKeyName != null) 'key_env': envApiKeyName,
    if (envModelName != null) 'env_model_name': envModelName,
    if (envBaseUrlName != null) 'env_base_url_name': envBaseUrlName,
    'auth_type': authType,
    'auth_flow': effectiveAuthFlow,
    'api_mode': apiMode,
    'protocol': effectiveProtocol,
    'api_key_requirement': apiKeyRequirement,
    'auth_methods': effectiveAuthMethods,
    'supports_multiple_instances': supportsMultipleInstances,
    if (docsUrl != null) 'docs_url': docsUrl,
    'supports_model_fetch': supportsModelFetch,
    'disconnectable': disconnectable,
    'fallback_models': fallbackModels,
    'aliases': aliases,
    'default_requests_per_minute': defaultRequestsPerMinute,
  };
}
