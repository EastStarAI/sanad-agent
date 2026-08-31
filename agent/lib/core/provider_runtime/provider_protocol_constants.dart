/// Centralized vocabulary for the Provider Template/Instance model (Plan 29).
///
/// These constants replace magic strings across the catalog, repository,
/// runtime, and protocol layers. They MUST be used instead of raw literals.
library;

/// High-level wire protocol a provider speaks. Drives `ProviderEndpointResolver`
/// and adapter selection. `ProviderTemplate.protocol` is one of these.
class ProviderProtocol {
  ProviderProtocol._();

  /// OpenAI-compatible REST shape (`/models`, `/v1/chat/completions`,
  /// `/responses`). Covers OpenAI, OpenRouter, Gemini OSS proxy, DeepSeek,
  /// Kimi, xAI, NVIDIA NIM, Ollama, LM Studio, llama.cpp and Custom gateways.
  static const openaiCompatible = 'openai_compatible';

  /// Anthropic-native message shape (`/v1/models`, `/v1/messages` with
  /// `x-api-key` + `anthropic-version`).
  static const anthropicCompatible = 'anthropic_compatible';

  static const all = <String>[openaiCompatible, anthropicCompatible];

  static bool isValid(String value) => all.contains(value);
}

/// Whether an API key is required to make a template usable.
class ApiKeyRequirement {
  ApiKeyRequirement._();

  /// Official cloud templates that mandate a key (OpenAI, Anthropic, ...).
  static const required = 'required';

  /// Local engines, Custom Provider, and OAuth-only templates: a key is
  /// accepted but not mandatory. An optional instance saved without a key
  /// surfaces `No API key` inside the API Keys category, never as a missing
  /// credential failure.
  static const optional = 'optional';

  static const all = <String>[required, optional];

  static bool isValid(String value) => all.contains(value);
}

/// Explicit authentication methods a template advertises. The instance stores
/// the method the user actually chose. Badge mapping (Plan 29 §6.1):
/// `Account` ← `deviceCode`/`loopback`/`external`; `API Key` ← `apiKey`/
/// `customEndpoint`.
class ProviderAuthMethod {
  ProviderAuthMethod._();

  static const apiKey = 'api_key';
  static const deviceCode = 'device_code';
  static const loopback = 'loopback';
  static const external = 'external';

  /// Methods that classify under the "Account" badge.
  static const accountMethods = <String>[deviceCode, loopback, external];

  /// Methods that classify under the "API Key" badge. Custom/local providers
  /// use `apiKey` with `ApiKeyRequirement.optional`; `customEndpoint` is NOT a
  /// valid `auth_method` value (it is a legacy `authFlow` string only).
  static const apiKeyMethods = <String>[apiKey];

  static bool isAccountMethod(String method) => accountMethods.contains(method);

  static bool isApiKeyMethod(String method) => apiKeyMethods.contains(method);
}

/// Lifecycle status of a `ProviderInstance` (Plan 29 §7.2).
class InstanceStatus {
  InstanceStatus._();

  /// Created but not yet validated/credentialled; cannot become default.
  static const draft = 'draft';

  /// Fully usable: credential + endpoint + model resolve cleanly.
  static const ready = 'ready';

  /// Credential missing or expired (OAuth re-login / key removed).
  static const needsAuth = 'needs_auth';

  /// Endpoint test failed or configuration is invalid.
  static const error = 'error';

  static const all = <String>[draft, ready, needsAuth, error];

  static bool isValid(String value) => all.contains(value);
}

/// Credential edit actions for `provider.credential.update` (Plan 29 §7.5).
/// `keep` is the default; an empty field never implies `remove`.
class CredentialAction {
  CredentialAction._();

  static const keep = 'keep';
  static const replace = 'replace';
  static const remove = 'remove';

  static const all = <String>[keep, replace, remove];

  static bool isValid(String value) => all.contains(value);
}

/// Reserved template id for a user-defined provider that is neither officially
/// registered nor a hardcoded gateway name (Plan 29 §7.1). Custom instances
/// must declare an explicit protocol + base URL at creation time.
const kCustomProviderTemplateId = 'custom';

/// Canonical GitHub Copilot subscription template id.
const kGithubCopilotTemplateId = 'github-copilot';

/// Central, non-secret GitHub Copilot OAuth and Copilot API constants.
///
/// The Client ID is the public VS Code GitHub App identity used for the
/// Copilot-internal token exchange. It is not a secret. Classic personal
/// access tokens (`ghp_*`) are rejected because Copilot's API does not
/// accept them.
class GithubCopilotProtocol {
  GithubCopilotProtocol._();

  static const templateId = kGithubCopilotTemplateId;

  /// Public GitHub App Client ID used by the Copilot device-code exchange.
  static const clientId = 'Iv1.b507a08c87ecfe98';

  /// Minimum OAuth scope required for Copilot token exchange.
  static const oauthScope = 'read:user';

  static const deviceCodeUrl = 'https://github.com/login/device/code';
  static const accessTokenUrl = 'https://github.com/login/oauth/access_token';
  static const verificationUri = 'https://github.com/login/device';
  static const tokenExchangeUrl =
      'https://api.github.com/copilot_internal/v2/token';
  static const defaultApiBaseUrl = 'https://api.githubcopilot.com';

  static const editorVersion = 'vscode/1.104.1';
  static const exchangeUserAgent = 'GitHubCopilotChat/0.26.7';
  static const integrationId = 'vscode-chat';
  static const openaiIntent = 'conversation-edits';

  static const integrationIdHeader = 'Copilot-Integration-Id';
  static const openaiIntentHeader = 'Openai-Intent';
  static const editorVersionHeader = 'Editor-Version';
  static const initiatorHeader = 'x-initiator';
  static const visionRequestHeader = 'Copilot-Vision-Request';
  static const initiatorUser = 'user';
  static const initiatorAgent = 'agent';

  /// Static headers required on Copilot API requests (dynamic initiator and
  /// vision headers are applied per request).
  static const staticRequestHeaders = {
    integrationIdHeader: integrationId,
    openaiIntentHeader: openaiIntent,
    editorVersionHeader: editorVersion,
  };

  /// Proactive refresh margin: exchange before the Copilot API token expires.
  static const refreshSafetyMargin = Duration(seconds: 120);

  /// RFC 8628 `slow_down` increment applied to the device-code poll interval.
  static const slowDownIncrement = Duration(seconds: 5);

  static const defaultPollInterval = Duration(seconds: 5);

  /// RFC 8628 device-code grant type.
  static const deviceCodeGrantType =
      'urn:ietf:params:oauth:grant-type:device_code';

  static const githubAccept = 'application/json';
  static const githubUserAgent = 'sanad-agent';

  /// Fallback when the exchange omits `expires_at`.
  static const defaultTokenTtl = Duration(seconds: 1800);

  static const classicPatPrefix = 'ghp_';

  static const allowedExactHosts = {
    'api.githubcopilot.com',
    'githubcopilot.com',
    'copilot-proxy.githubusercontent.com',
  };

  static const allowedHostSuffix = '.githubcopilot.com';

  static const classicPatRejectionMessage =
      'Classic GitHub personal access tokens (ghp_*) are not supported by '
      'the Copilot API. Sign in with the GitHub device-code flow instead.';

  static bool isClassicPersonalAccessToken(String token) =>
      token.trim().startsWith(classicPatPrefix);

  /// Per-request Copilot headers layered on [staticRequestHeaders].
  ///
  /// `x-initiator` is `user` for the first model call of a turn and `agent`
  /// after tool results. `Copilot-Vision-Request` is omitted unless [vision]
  /// is true.
  static Map<String, String> dynamicRequestHeaders({
    required bool afterToolResults,
    required bool vision,
  }) {
    return {
      initiatorHeader: afterToolResults ? initiatorAgent : initiatorUser,
      if (vision) visionRequestHeader: 'true',
    };
  }

  /// True when [modelId] must use the OpenAI Responses API (`/responses`).
  ///
  /// Chat Completions is the default Copilot transport. A model is routed to
  /// Responses only when its id explicitly names that protocol.
  static bool usesResponsesApi(String modelId) {
    final id = modelId.trim().toLowerCase();
    if (id.isEmpty) return false;
    return id.split(RegExp(r'[-_./]')).contains('responses');
  }
}
