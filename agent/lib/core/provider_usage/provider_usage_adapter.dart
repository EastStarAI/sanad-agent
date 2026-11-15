/// Provider usage adapter interface and registry (Task 55 §3.1, §3.3, Gate A).
///
/// The adapter contract is **independent of auth method** (OAuth vs API Key).
/// Each adapter decides whether the credential it receives is capable of
/// fetching usage. The daemon is the sole authority for usage state; the
/// client never reads credentials or contacts provider endpoints.
///
/// Capability is bound to the **template/instance**, not to a Flutter-side
/// catalog. `ProviderUsageRegistry.supportsTemplate` is the single place that
/// decides whether an instance has a usage adapter — clients must not
/// hardcode a provider list.
library;

import 'provider_usage_models.dart';
import '../provider_runtime/secret_record.dart';

/// Context handed to a usage adapter for a single fetch.
///
/// The adapter receives the instance's resolved [SecretRecord] (which carries
/// the bearer token / API key) plus its effective base URL. Adapters must not
/// log the record, the token, or any raw provider response.
class ProviderUsageContext {
  /// Owning instance UUID.
  final String instanceId;

  /// Template id (e.g. `openai-codex`).
  final String templateId;

  /// Effective base URL for the provider (template default or instance
  /// override), already normalised (no trailing slash unless it is a root).
  final String baseUrl;

  /// Resolved credential for this instance. May be null when no credential is
  /// stored; adapters decide whether usage is supported without one.
  final SecretRecord? credential;

  /// Optional account id extracted from the credential/OAuth state, used as the
  /// `ChatGPT-Account-Id` header by the ChatGPT adapter when present.
  final String? accountId;

  /// Injectable HTTP client factory (for tests). Produces a fresh client per
  /// fetch; the adapter owns closing it.
  final HttpClientFactory httpClientFactory;

  const ProviderUsageContext({
    required this.instanceId,
    required this.templateId,
    required this.baseUrl,
    required this.httpClientFactory,
    this.credential,
    this.accountId,
  });
}

/// Minimal, injectable HTTP client surface used by usage adapters. The
/// concrete implementation wraps `package:http` in production and a fake in
/// tests. Adapters depend on this abstraction so tests never touch the network.
abstract class ProviderUsageHttpClient {
  Future<ProviderUsageHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  });

  Future<ProviderUsageHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  });

  void close();
}

class ProviderUsageHttpResponse {
  final int statusCode;
  final String body;

  const ProviderUsageHttpResponse(this.statusCode, this.body);

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Factory that produces a fresh [ProviderUsageHttpClient] per fetch.
typedef HttpClientFactory = ProviderUsageHttpClient Function();

/// Contract for a per-provider usage adapter (Task 55 §3.3).
///
/// Adapters are stateless: one instance per daemon, shared across all fetches.
/// They own wire translation only and must never retain session state,
/// credentials, or snapshots.
abstract class ProviderUsageAdapter {
  /// Template id this adapter handles (e.g. `openai-codex`).
  String get templateId;

  /// Human-readable source label embedded in the snapshot
  /// (e.g. `chatgpt_usage_api`).
  String get sourceLabel;

  /// Whether this adapter can attempt a usage fetch for [context].
  ///
  /// Adapters return `false` when the credential shape is insufficient (e.g.
  /// an API-key-only credential where usage requires an OAuth token). This is
  /// a cheap synchronous check; it must not perform network I/O.
  bool canFetch(ProviderUsageContext context);

  /// Fetches a fresh usage snapshot from the provider.
  ///
  /// Returns a [ProviderUsageSnapshot] on success. Throws
  /// [ProviderUsageAuthException] when the credential is missing/expired,
  /// [ProviderUsageUnavailableException] for transient network/parse failures,
  /// or [ProviderUsageException] for any other failure. Adapters must never
  /// throw a raw provider error or include credential/response details in the
  /// message.
  Future<ProviderUsageSnapshot> fetch(ProviderUsageContext context);
}

/// Optional mutation capability implemented only by adapters that support
/// provider-owned reset credits.
abstract class ProviderUsageResetAdapter implements ProviderUsageAdapter {
  /// Consumes at most one credit.
  ///
  /// [creditId] targets one specific credit when the provider supports it and
  /// the Client supplied one; a null id keeps the legacy behaviour where the
  /// provider chooses the credit. The id is an opaque provider value: it is
  /// never displayed and never logged.
  Future<ProviderUsageResetAdapterResult> reset(
    ProviderUsageContext context, {
    required String idempotencyKey,
    String? creditId,
  });
}

class ProviderUsageResetAdapterResult {
  final String status;
  final int? availableResets;
  const ProviderUsageResetAdapterResult(this.status, {this.availableResets});
}

/// Typed exceptions raised by usage adapters. The caller maps these to
/// [ProviderUsageResult] statuses; the message must be display-safe and must
/// never leak the raw response body, headers, or credential.
class ProviderUsageException implements Exception {
  final String message;
  const ProviderUsageException(this.message);
  @override
  String toString() => message;
}

/// Credential resolution failure (missing, expired, relogin required).
class ProviderUsageAuthException extends ProviderUsageException {
  const ProviderUsageAuthException([
    super.message = 'Authentication required.',
  ]);
}

/// Transient or unexpected provider/network failure.
class ProviderUsageUnavailableException extends ProviderUsageException {
  const ProviderUsageUnavailableException([
    super.message = 'Usage information is temporarily unavailable.',
  ]);
}

/// Registry of per-template usage adapters. This is the **single** place that
/// decides whether an instance supports usage queries — clients must not
/// hardcode a provider list (Task 55 §3.1).
///
/// Registering a new adapter for a future API-key provider requires no changes
/// to the model surface or the protocol: implement [ProviderUsageAdapter],
/// register it here, and the daemon advertises support automatically.
class ProviderUsageRegistry {
  final Map<String, ProviderUsageAdapter> _byTemplate = {};

  ProviderUsageRegistry();

  /// Registers [adapter] under its `templateId`. Replaces an existing adapter
  /// for the same template.
  void register(ProviderUsageAdapter adapter) {
    _byTemplate[adapter.templateId] = adapter;
  }

  /// Returns the adapter for [templateId], or null when no usage adapter is
  /// registered. Callers surface `unsupported` to the client in that case.
  ProviderUsageAdapter? adapterFor(String templateId) =>
      _byTemplate[templateId];

  /// Whether any usage adapter is registered for [templateId]. This is the
  /// capability signal consumed by the daemon and exposed to clients.
  bool supportsTemplate(String templateId) =>
      _byTemplate.containsKey(templateId);

  /// All registered template ids (for diagnostics/tests only).
  List<String> get registeredTemplates =>
      _byTemplate.keys.toList(growable: false);
}
