import 'provider_protocol_constants.dart';

/// Typed result of GitHub's Copilot-internal token exchange.
///
/// Holds the short-lived Copilot API token, its expiry in epoch milliseconds
/// (matching [SecretRecord.expiresAt]), and an optional per-account API
/// endpoint discovered from `endpoints.api` or the token's `proxy-ep`
/// hint. The endpoint is stored only after HTTPS host allowlisting so a
/// malicious or enterprise-mismatched host cannot become an SSRF target.
///
/// The raw token must never appear in logs, protocol payloads, or
/// [toString].
class CopilotTokenExchangeResult {
  /// Copilot API bearer token returned by the exchange.
  final String token;

  /// Epoch milliseconds when [token] expires.
  final int expiresAt;

  /// Validated account-specific API base URL, or `null` to use
  /// [GithubCopilotProtocol.defaultApiBaseUrl].
  final String? accountEndpoint;

  const CopilotTokenExchangeResult({
    required this.token,
    required this.expiresAt,
    this.accountEndpoint,
  });

  /// Parses a Copilot `/copilot_internal/v2/token` JSON body.
  ///
  /// [trustedEnterpriseDomain] is an optional data-residency GHE tenant
  /// (`tenant.ghe.com`). When omitted, only GitHub-owned Copilot hosts are
  /// accepted.
  factory CopilotTokenExchangeResult.fromExchangeResponse(
    Map<String, dynamic> json, {
    DateTime? now,
    String? trustedEnterpriseDomain,
  }) {
    final token = json['token']?.toString().trim() ?? '';
    if (token.isEmpty) {
      throw const FormatException(
        'Copilot token exchange returned an empty token.',
      );
    }
    final expiresAt = parseCopilotExpiresAt(
      json['expires_at'],
      now ?? DateTime.now(),
    );
    String? endpointsApi;
    final endpoints = json['endpoints'];
    if (endpoints is Map) {
      final raw = endpoints['api'];
      if (raw != null) {
        final text = raw.toString().trim();
        if (text.isNotEmpty) endpointsApi = text;
      }
    }
    return CopilotTokenExchangeResult(
      token: token,
      expiresAt: expiresAt,
      accountEndpoint: resolveCopilotAccountEndpoint(
        token: token,
        endpointsApi: endpointsApi,
        trustedEnterpriseDomain: trustedEnterpriseDomain,
      ),
    );
  }

  bool get isExpiringSoon {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now >=
        (expiresAt - GithubCopilotProtocol.refreshSafetyMargin.inMilliseconds);
  }

  /// Debug representation that never includes the token payload.
  @override
  String toString() =>
      'CopilotTokenExchangeResult(expiresAt=$expiresAt, '
      'hasEndpoint=${accountEndpoint != null})';
}

/// Converts a Copilot `expires_at` value to epoch milliseconds.
///
/// GitHub typically returns Unix seconds. Values already in milliseconds
/// (absolute magnitude ≥ 10^12) are kept as-is. Missing or zero values fall
/// back to [GithubCopilotProtocol.defaultTokenTtl] from [now].
int parseCopilotExpiresAt(Object? raw, DateTime now) {
  final fallback = now
      .add(GithubCopilotProtocol.defaultTokenTtl)
      .millisecondsSinceEpoch;
  if (raw == null) return fallback;

  num? numeric;
  if (raw is num) {
    numeric = raw;
  } else {
    final text = raw.toString().trim();
    if (text.isEmpty) return fallback;
    numeric = num.tryParse(text);
    if (numeric == null) {
      final parsed = DateTime.tryParse(text);
      if (parsed != null) return parsed.millisecondsSinceEpoch;
      return fallback;
    }
  }
  if (numeric == 0) return fallback;
  // Unix ms is ~1e12 in this century; Unix seconds is ~1e9.
  if (numeric.abs() >= 1000000000000) {
    return numeric.round();
  }
  return (numeric * 1000).round();
}

/// Whether [host] is a GitHub-owned Copilot API host, or a service host under
/// an optional trusted GHE data-residency tenant.
bool isAllowedCopilotApiHost(String host, {String? trustedEnterpriseDomain}) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  if (normalized.contains(':') ||
      normalized.contains('/') ||
      normalized.contains('@') ||
      normalized.startsWith('.')) {
    return false;
  }
  if (GithubCopilotProtocol.allowedExactHosts.contains(normalized)) {
    return true;
  }
  if (normalized.endsWith(GithubCopilotProtocol.allowedHostSuffix) &&
      normalized.length > GithubCopilotProtocol.allowedHostSuffix.length) {
    return true;
  }
  final tenant = trustedEnterpriseDomain?.trim().toLowerCase() ?? '';
  if (tenant.isNotEmpty && _isGheTenant(tenant)) {
    return normalized == tenant || normalized.endsWith('.$tenant');
  }
  return false;
}

/// Resolves a per-account Copilot API base URL from the exchange response.
///
/// Prefers `endpoints.api`. When that is absent, derives a host from the
/// token's `proxy-ep` field by replacing a leading `proxy.` with `api.`.
/// Invalid, non-HTTPS, or off-allowlist hosts return `null` so callers use
/// the default endpoint instead of following an SSRF target.
String? resolveCopilotAccountEndpoint({
  required String token,
  String? endpointsApi,
  String? trustedEnterpriseDomain,
}) {
  final fromEndpoints = _validatedHttpsBaseUrl(
    endpointsApi,
    trustedEnterpriseDomain: trustedEnterpriseDomain,
  );
  if (fromEndpoints != null) return fromEndpoints;
  if (endpointsApi != null && endpointsApi.trim().isNotEmpty) {
    // Advertised endpoint was present but rejected; do not follow proxy-ep.
    return null;
  }
  return _validatedHttpsBaseUrl(
    _proxyEpHint(token),
    trustedEnterpriseDomain: trustedEnterpriseDomain,
    rewriteProxyPrefix: true,
  );
}

String? _proxyEpHint(String token) {
  final match = RegExp(
    r'(?:^|;)\s*proxy-ep=([^;\s]+)',
    caseSensitive: false,
  ).firstMatch(token);
  return match?.group(1)?.trim();
}

String? _validatedHttpsBaseUrl(
  String? raw, {
  String? trustedEnterpriseDomain,
  bool rewriteProxyPrefix = false,
}) {
  if (raw == null) return null;
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.contains(RegExp(r'\s'))) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
    text = 'https://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return null;
  if (uri.scheme.toLowerCase() != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.hasPort && uri.port != 443) return null;
  var host = uri.host.trim().toLowerCase();
  if (host.isEmpty) return null;
  if (rewriteProxyPrefix && host.startsWith('proxy.')) {
    host = 'api.${host.substring('proxy.'.length)}';
  }
  if (!isAllowedCopilotApiHost(
    host,
    trustedEnterpriseDomain: trustedEnterpriseDomain,
  )) {
    return null;
  }
  return 'https://$host';
}

final _gheTenant = RegExp(r'^[a-z0-9-]+\.ghe\.com$');

bool _isGheTenant(String host) => _gheTenant.hasMatch(host);
