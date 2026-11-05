import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';

/// Category of one provider connection failure.
///
/// One vocabulary is shared by model discovery, the connection test, and setup
/// verification so every surface (Client, CLI, readiness) names the same cause
/// (issue 339).
class ProviderFailureCategory {
  ProviderFailureCategory._();

  /// The endpoint rejected the credential (`401`).
  static const invalidCredential = 'invalid_credential';

  /// The credential is valid but not allowed (`403`).
  static const forbidden = 'forbidden';

  /// The endpoint does not serve the probed path (`404`).
  static const endpointNotFound = 'endpoint_not_found';

  /// The account is rate limited or out of quota (`429`).
  static const rateLimited = 'rate_limited';

  /// The endpoint did not answer in time (`408`, or a client-side timeout).
  static const timeout = 'timeout';

  /// The endpoint could not be reached at all (socket, TLS, DNS).
  static const network = 'network';

  /// The provider failed on its own side (`5xx`).
  static const serverError = 'server_error';

  /// The endpoint answered with no usable model list.
  static const noModels = 'no_models';

  /// A non-2xx answer the runtime could not classify further.
  static const http = 'http';

  /// A failure the runtime could not classify.
  static const unknown = 'unknown';

  static const all = <String>[
    invalidCredential,
    forbidden,
    endpointNotFound,
    rateLimited,
    timeout,
    network,
    serverError,
    noModels,
    http,
    unknown,
  ];

  static bool isValid(String value) => all.contains(value);
}

/// Sanitized, user-safe cause of the last failed provider connection.
///
/// This is the single owner of what may leave the daemon about a provider
/// failure: a category, the HTTP status, a short canonical reason, and the
/// endpoint origin plus path. It never carries a credential, a header, the
/// request payload, or the provider's raw response body.
class ProviderDiscoveryError {
  const ProviderDiscoveryError({
    required this.kind,
    this.statusCode,
    required this.message,
    this.endpoint,
  });

  final String kind;
  final int? statusCode;

  /// Short English reason. Canonical per [kind] and [statusCode]; never
  /// provider-authored text.
  final String message;

  /// `scheme://host[:port]/path` of the endpoint that was probed. Query,
  /// fragment, and user info are stripped because they can carry a secret.
  final String? endpoint;

  /// Whether the endpoint rejected the credential itself.
  bool get isAuthFailure =>
      kind == ProviderFailureCategory.invalidCredential ||
      kind == ProviderFailureCategory.forbidden;

  /// One-line form used by the CLI, the readiness reason, and every legacy
  /// string consumer of `provider_model_cache.last_error`.
  String get summary => endpoint == null ? message : '$message from $endpoint';

  /// Bound on any free text that reaches a user surface.
  static const int maxMessageLength = 160;

  static const _redactor = SecretsRedactor();

  /// Classifies [error] into a sanitized provider failure.
  ///
  /// [endpoint] is the probed endpoint; it is sanitized here so no caller can
  /// leak a query string or user info.
  static ProviderDiscoveryError capture(Object? error, {Uri? endpoint}) {
    final target = sanitizeEndpoint(endpoint);
    if (error is LlmHttpException) {
      final status = error.statusCode;
      return ProviderDiscoveryError(
        kind: categoryForStatus(status),
        statusCode: status,
        message: reasonForStatus(status),
        endpoint: target,
      );
    }
    if (error is TimeoutException) {
      return ProviderDiscoveryError(
        kind: ProviderFailureCategory.timeout,
        message: 'The provider endpoint timed out',
        endpoint: target,
      );
    }
    if (error is SocketException ||
        error is HttpException ||
        error is HandshakeException ||
        error is IOException) {
      return ProviderDiscoveryError(
        kind: ProviderFailureCategory.network,
        message: 'Could not reach the provider endpoint',
        endpoint: target,
      );
    }
    if (error is FormatException) {
      return ProviderDiscoveryError(
        kind: ProviderFailureCategory.noModels,
        message: 'The provider returned an unexpected model list',
        endpoint: target,
      );
    }
    if (error is StateError) {
      final text = error.message.toString().toLowerCase();
      if (text.contains('empty model list')) {
        return ProviderDiscoveryError(
          kind: ProviderFailureCategory.noModels,
          message: 'The provider returned an empty model list',
          endpoint: target,
        );
      }
      if (text.contains('not a list of models') ||
          text.contains('response data is empty')) {
        return ProviderDiscoveryError(
          kind: ProviderFailureCategory.noModels,
          message: 'The provider returned an unexpected model list',
          endpoint: target,
        );
      }
    }
    return ProviderDiscoveryError(
      kind: ProviderFailureCategory.unknown,
      message: 'The provider request failed',
      endpoint: target,
    );
  }

  /// The sanitized failure describing a discovery that silently fell back to
  /// the built-in model presets without a classified transport failure.
  static ProviderDiscoveryError fallbackPresets({Uri? endpoint}) =>
      ProviderDiscoveryError(
        kind: ProviderFailureCategory.unknown,
        message: 'Model discovery fell back to the built-in model presets',
        endpoint: sanitizeEndpoint(endpoint),
      );

  /// The sanitized failure for an endpoint that answered without any model.
  static ProviderDiscoveryError noModels({Uri? endpoint}) =>
      ProviderDiscoveryError(
        kind: ProviderFailureCategory.noModels,
        message: 'The provider returned no models',
        endpoint: sanitizeEndpoint(endpoint),
      );

  /// Category for one HTTP status.
  static String categoryForStatus(int? status) {
    if (status == 401) return ProviderFailureCategory.invalidCredential;
    if (status == 403) return ProviderFailureCategory.forbidden;
    if (status == 404) return ProviderFailureCategory.endpointNotFound;
    if (status == 408) return ProviderFailureCategory.timeout;
    if (status == 429) return ProviderFailureCategory.rateLimited;
    if (status != null && status >= 500 && status <= 599) {
      return ProviderFailureCategory.serverError;
    }
    return ProviderFailureCategory.http;
  }

  /// Canonical short reason for one HTTP status.
  static String reasonForStatus(int? status) {
    if (status == null) return 'The provider request failed';
    if (status == 401) return 'Invalid credential (HTTP 401)';
    if (status == 403) return 'Access denied (HTTP 403)';
    if (status == 404) return 'Models endpoint not found (HTTP 404)';
    if (status == 408) return 'The provider endpoint timed out (HTTP 408)';
    if (status == 429) return 'Rate limited (HTTP 429)';
    if (status >= 500 && status <= 599) {
      return 'Provider server error (HTTP $status)';
    }
    return 'Provider rejected the request (HTTP $status)';
  }

  /// Reduces [uri] to `scheme://host[:port]/path`.
  static String? sanitizeEndpoint(Uri? uri) {
    if (uri == null || uri.host.isEmpty) return null;
    final path = uri.path.isEmpty ? '' : uri.path;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final sanitized = '${uri.scheme}://${uri.host}$port$path';
    return sanitized.isEmpty ? null : sanitized;
  }

  /// Rebuilds the projection from stored columns.
  ///
  /// [detailJson] is the structured column written by this version. Rows
  /// written by an older daemon only carry [legacyText]; those are re-derived
  /// from the `LlmHttpException(<status> ...)` prefix our own
  /// `toString()` produced, so a raw provider body is never replayed.
  static ProviderDiscoveryError? tryRestore({
    Object? detailJson,
    Object? legacyText,
  }) {
    final structured = _decodeMap(detailJson);
    if (structured != null) {
      final restored = fromMap(structured);
      if (restored != null) return restored;
    }
    final legacy = legacyText?.toString().trim();
    if (legacy == null || legacy.isEmpty) return null;
    final inline = _decodeMap(legacy);
    if (inline != null) {
      final restored = fromMap(inline);
      if (restored != null) return restored;
    }
    final status = _legacyStatus(legacy);
    if (status != null) {
      return ProviderDiscoveryError(
        kind: categoryForStatus(status),
        statusCode: status,
        message: reasonForStatus(status),
      );
    }
    final lowered = legacy.toLowerCase();
    if (lowered.contains('empty model list') ||
        lowered.contains('not a list of models') ||
        lowered.contains('response data is empty')) {
      return const ProviderDiscoveryError(
        kind: ProviderFailureCategory.noModels,
        message: 'The provider returned an unexpected model list',
      );
    }
    return const ProviderDiscoveryError(
      kind: ProviderFailureCategory.unknown,
      message: 'Model discovery failed',
    );
  }

  static final RegExp _legacyStatusPattern = RegExp(
    r'^LlmHttpException\((\d{3})\b',
  );

  static int? _legacyStatus(String legacy) {
    final match = _legacyStatusPattern.firstMatch(legacy);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static Map<String, dynamic>? _decodeMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is! String || value.trim().isEmpty) return null;
    final trimmed = value.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  static ProviderDiscoveryError? fromMap(Map<String, dynamic> map) {
    final kind = map['kind']?.toString() ?? '';
    final message = map['message']?.toString() ?? '';
    if (!ProviderFailureCategory.isValid(kind) || message.isEmpty) return null;
    final rawStatus = map['status_code'];
    final endpoint = map['endpoint']?.toString();
    return ProviderDiscoveryError(
      kind: kind,
      statusCode: rawStatus is num ? rawStatus.toInt() : null,
      message: _bound(_redactor.redact(message)),
      endpoint: endpoint == null || endpoint.isEmpty ? null : endpoint,
    );
  }

  Map<String, dynamic> toMap() => {
    'kind': kind,
    if (statusCode != null) 'status_code': statusCode,
    'message': message,
    if (endpoint != null) 'endpoint': endpoint,
  };

  /// Encodes this failure into the `provider_model_cache.last_error_detail`
  /// column read back by [tryRestore].
  String toJson() => jsonEncode(toMap());

  static String _bound(String value) =>
      value.length <= maxMessageLength
      ? value
      : '${value.substring(0, maxMessageLength - 3)}...';

  @override
  String toString() => 'ProviderDiscoveryError($kind, $summary)';
}
