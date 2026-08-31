import 'dart:convert';

import 'provider_protocol_constants.dart';

/// A credential payload for a `ProviderInstance` (Plan 29 §7.4).
///
/// Holds either an API key (`apiKey`) or an OAuth token bundle
/// (`accessToken`/`refreshToken`/`expiresAt`/`scope`). It does NOT merge Sanad
/// device identity. The raw record lives only inside the `SecretStore` and the
/// runtime resolver; it MUST never appear in DTOs, cache keys, equality/debug
/// strings, events, or logs.
class SecretRecord {
  /// Owning instance UUID.
  final String instanceId;

  /// Static API key. Both required and optional API-key templates (including
  /// Custom and local engines) use `auth_method = api_key`.
  final String? apiKey;

  /// OAuth access token used as the runtime bearer credential.
  final String? accessToken;

  /// Optional refresh token for renewing the access token.
  final String? refreshToken;

  /// Optional id-token returned by some providers.
  final String? idToken;

  /// Epoch milliseconds when the access token expires.
  final int? expiresAt;

  /// OAuth scope string (space-delimited) if returned by the provider.
  final String? scope;

  /// Token type (typically `Bearer`).
  final String tokenType;

  /// Last refresh attempt epoch milliseconds.
  final int? lastRefreshAt;

  /// Soft status hint persisted alongside the record.
  /// One of: `authenticated`, `expired`, `relogin_required`.
  final String status;

  /// OAuth account label (e.g. email) for display only.
  final String? accountLabel;

  /// OAuth account name (e.g. user's full name) for display only.
  final String? accountName;

  /// The auth method this credential was obtained through (one of
  /// [ProviderAuthMethod]). Drives the `Account` vs `API Key` badge.
  final String authMethod;

  const SecretRecord({
    required this.instanceId,
    this.apiKey,
    this.accessToken,
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.scope,
    this.tokenType = 'Bearer',
    this.lastRefreshAt,
    this.status = 'authenticated',
    this.accountLabel,
    this.accountName,
    required this.authMethod,
  });

  bool get isOAuth =>
      authMethod == ProviderAuthMethod.deviceCode ||
      authMethod == ProviderAuthMethod.loopback ||
      authMethod == ProviderAuthMethod.external;

  bool get isExpired {
    if (expiresAt == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Treat tokens as expired slightly before the real expiry to allow refresh.
    return now >= (expiresAt! - 60_000);
  }

  /// Whether the access token will expire within [margin].
  bool isExpiringWithin(Duration margin, {DateTime? now}) {
    if (expiresAt == null) return false;
    final epoch = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return epoch >= (expiresAt! - margin.inMilliseconds);
  }

  SecretRecord copyWith({
    String? apiKey,
    String? accessToken,
    String? refreshToken,
    String? idToken,
    int? expiresAt,
    String? scope,
    String? tokenType,
    int? lastRefreshAt,
    String? status,
    String? accountLabel,
    String? accountName,
    String? authMethod,
  }) {
    return SecretRecord(
      instanceId: instanceId,
      apiKey: apiKey ?? this.apiKey,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      idToken: idToken ?? this.idToken,
      expiresAt: expiresAt ?? this.expiresAt,
      scope: scope ?? this.scope,
      tokenType: tokenType ?? this.tokenType,
      lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
      status: status ?? this.status,
      accountLabel: accountLabel ?? this.accountLabel,
      accountName: accountName ?? this.accountName,
      authMethod: authMethod ?? this.authMethod,
    );
  }

  Map<String, dynamic> toJson() => {
    'instance_id': instanceId,
    if (apiKey != null) 'api_key': apiKey,
    if (accessToken != null) 'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (idToken != null) 'id_token': idToken,
    if (expiresAt != null) 'expires_at': expiresAt,
    if (scope != null) 'scope': scope,
    'token_type': tokenType,
    if (lastRefreshAt != null) 'last_refresh_at': lastRefreshAt,
    'status': status,
    if (accountLabel != null) 'account_label': accountLabel,
    if (accountName != null) 'account_name': accountName,
    'auth_method': authMethod,
  };

  factory SecretRecord.fromJson(Map<String, dynamic> json) {
    var accountLabel = json['account_label'] as String?;
    var accountName = json['account_name'] as String?;
    final authMethod =
        json['auth_method'] as String? ?? ProviderAuthMethod.apiKey;
    final isOAuth =
        authMethod == ProviderAuthMethod.deviceCode ||
        authMethod == ProviderAuthMethod.loopback ||
        authMethod == ProviderAuthMethod.external;
    if ((accountLabel == null || accountName == null) && isOAuth) {
      final token =
          (json['id_token'] as String?) ?? (json['access_token'] as String?);
      if (token != null) {
        final identity = extractOAuthAccountIdentity(token);
        accountLabel ??= identity.accountLabel;
        accountName ??= identity.accountName;
      }
    }
    return SecretRecord(
      instanceId: json['instance_id'] as String,
      apiKey: json['api_key'] as String?,
      accessToken: json['access_token'] as String?,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
      expiresAt: _parseInt(json['expires_at']),
      scope: json['scope'] as String?,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      lastRefreshAt: _parseInt(json['last_refresh_at']),
      status: json['status'] as String? ?? 'authenticated',
      accountLabel: accountLabel,
      accountName: accountName,
      authMethod: authMethod,
    );
  }

  static int? _parseInt(Object? v) {
    if (v is int) return v;
    if (v == null) return null;
    return int.tryParse('$v');
  }

  /// A debug representation that NEVER includes the secret payload.
  @override
  String toString() =>
      'SecretRecord(instance=$instanceId, method=$authMethod, '
      'status=$status, hasKey=${apiKey != null}, '
      'hasAccess=${accessToken != null}, expired=$isExpired)';
}

/// A secret-free summary of a stored credential (Plan 29 §7.4).
///
/// This is the ONLY shape ever returned to the client or CLI. It carries just
/// enough to render a card: whether a credential is configured, the auth
/// method/status, a masked key hint, the OAuth account label, expiry, and a
/// `reloginRequired` flag.
class SecretSummary {
  final String instanceId;

  /// Whether any credential is stored for this instance.
  final bool configured;

  /// Auth method actually used (one of [ProviderAuthMethod]).
  final String authMethod;

  /// `authenticated` | `expired` | `relogin_required` | `missing`.
  final String status;

  /// Masked API key hint (e.g. `sk-p****9X2A`), or null for OAuth / no key.
  final String? maskedKeyHint;

  /// OAuth account label (e.g. email), or null.
  final String? accountLabel;

  /// OAuth account name (e.g. user's full name), or null.
  final String? accountName;

  /// Access token expiry (epoch ms) when applicable.
  final int? expiresAt;

  /// Whether the user must re-authenticate (OAuth expired/revoked).
  final bool reloginRequired;

  const SecretSummary({
    required this.instanceId,
    required this.configured,
    required this.authMethod,
    required this.status,
    this.maskedKeyHint,
    this.accountLabel,
    this.accountName,
    this.expiresAt,
    required this.reloginRequired,
  });

  Map<String, dynamic> toMap() => {
    'instance_id': instanceId,
    'configured': configured,
    'auth_method': authMethod,
    'status': status,
    if (maskedKeyHint != null) 'masked_key_hint': maskedKeyHint,
    if (accountLabel != null) 'account_label': accountLabel,
    if (accountName != null) 'account_name': accountName,
    if (expiresAt != null) 'expires_at': expiresAt,
    'relogin_required': reloginRequired,
  };

  /// Builds a summary from a raw record, masking the API key and deriving
  /// status/relogin flags without exposing any secret.
  factory SecretSummary.fromRecord(SecretRecord? record, String instanceId) {
    if (record == null) {
      return SecretSummary(
        instanceId: instanceId,
        configured: false,
        authMethod: ProviderAuthMethod.apiKey,
        status: 'missing',
        reloginRequired: false,
      );
    }
    final expired = record.isOAuth && record.isExpired;
    final relogin = record.status == 'relogin_required';
    return SecretSummary(
      instanceId: instanceId,
      configured: true,
      authMethod: record.authMethod,
      status: relogin
          ? 'relogin_required'
          : (expired ? 'expired' : record.status),
      maskedKeyHint: record.apiKey != null ? maskApiKey(record.apiKey!) : null,
      accountLabel: record.accountLabel,
      accountName: record.accountName,
      expiresAt: record.expiresAt,
      reloginRequired: relogin,
    );
  }
}

/// Masks an API key for display as `prefix****suffix` (e.g. `sk-p****9X2A`).
///
/// - Keys with <= 8 chars show the first 2 and last 2 with the middle masked.
/// - Longer keys show the first 4 and last 4.
/// - Very short keys (<= 4 chars) are fully masked except the last char.
String maskApiKey(String key) {
  if (key.length <= 4) {
    return '${'•' * (key.length - 1)}${key.isNotEmpty ? key[key.length - 1] : ''}';
  }
  if (key.length <= 8) {
    final prefix = key.substring(0, 2);
    final suffix = key.substring(key.length - 2);
    return '$prefix${'•' * 4}$suffix';
  }
  final prefix = key.substring(0, 4);
  final suffix = key.substring(key.length - 4);
  return '$prefix${'•' * 4}$suffix';
}

/// Decodes the payload of a JWT token without verifying its signature.
/// Returns a map of claims, or an empty map if decoding fails.
Map<String, dynamic> decodeJwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return const {};

  var payload = parts[1];
  final remainder = payload.length % 4;
  if (remainder > 0) {
    payload += '=' * (4 - remainder);
  }

  try {
    final decodedBytes = base64Url.decode(payload);
    final decodedString = utf8.decode(decodedBytes);
    final dynamic json = jsonDecode(decodedString);
    if (json is Map<String, dynamic>) {
      return json;
    }
  } catch (_) {
    // Display metadata is optional; malformed or opaque tokens are ignored.
  }
  return const {};
}

/// Extracts optional display-only account identity from unverified JWT claims.
///
/// Signature verification remains the OAuth flow's responsibility. This helper
/// never treats claims as authorization state and ignores non-string or blank
/// values. The label preference is email, username, UPN, then display name.
({String? accountLabel, String? accountName}) extractOAuthAccountIdentity(
  String token,
) {
  final claims = decodeJwtClaims(token);
  String? firstNonEmpty(Iterable<String> keys) {
    for (final key in keys) {
      final value = claims[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  return (
    accountLabel: firstNonEmpty(const [
      'email',
      'preferred_username',
      'upn',
      'name',
    ]),
    accountName: firstNonEmpty(const ['name']),
  );
}
