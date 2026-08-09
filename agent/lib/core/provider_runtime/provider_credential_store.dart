import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'secret_record.dart';

/// Represents the persisted auth session for an OAuth-based LLM provider.
///
/// This is stored in a dedicated `provider_auth.json` file, completely separate
/// from the Sanad Gateway `auth.json` owned by `AuthManager`. Mixing LLM provider
/// credentials with device identity tokens would risk breaking device binding or
/// leaking third-party scopes into Sanad auth.
class ProviderAuthRecord {
  final String providerId;

  /// OAuth access token used as the runtime bearer credential.
  final String accessToken;

  /// Optional refresh token for renewing the access token.
  final String? refreshToken;

  /// Optional id-token (some providers return it).
  final String? idToken;

  /// Epoch milliseconds when the access token expires.
  final int? expiresAt;

  /// OAuth scope string (space-delimited) if returned by the provider.
  final String? scope;

  /// Token type (typically "Bearer").
  final String tokenType;

  /// Last refresh attempt epoch milliseconds.
  final int? lastRefreshAt;

  /// Soft status hint persisted alongside the record.
  /// One of: `authenticated`, `expired`, `relogin_required`.
  final String status;

  /// OAuth account label (e.g. email) for display only.
  final String? accountLabel;

  /// OAuth account name (e.g. user's name) for display only.
  final String? accountName;

  ProviderAuthRecord({
    required this.providerId,
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.scope,
    this.tokenType = 'Bearer',
    this.lastRefreshAt,
    this.status = 'authenticated',
    this.accountLabel,
    this.accountName,
  });

  bool get isExpired {
    if (expiresAt == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Treat tokens as expired slightly before the real expiry to allow refresh.
    return now >= (expiresAt! - 60_000);
  }

  Map<String, dynamic> toJson() => {
    'provider_id': providerId,
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (idToken != null) 'id_token': idToken,
    if (expiresAt != null) 'expires_at': expiresAt,
    if (scope != null) 'scope': scope,
    'token_type': tokenType,
    if (lastRefreshAt != null) 'last_refresh_at': lastRefreshAt,
    'status': status,
    if (accountLabel != null) 'account_label': accountLabel,
    if (accountName != null) 'account_name': accountName,
  };

  factory ProviderAuthRecord.fromJson(Map<String, dynamic> json) {
    var accountLabel = json['account_label'] as String?;
    var accountName = json['account_name'] as String?;
    if (accountLabel == null || accountName == null) {
      final token =
          (json['id_token'] as String?) ?? (json['access_token'] as String?);
      if (token != null) {
        final identity = extractOAuthAccountIdentity(token);
        accountLabel ??= identity.accountLabel;
        accountName ??= identity.accountName;
      }
    }
    return ProviderAuthRecord(
      providerId: json['provider_id'] as String,
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
      expiresAt: (json['expires_at'] is int)
          ? json['expires_at'] as int
          : int.tryParse('${json['expires_at']}'),
      scope: json['scope'] as String?,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      lastRefreshAt: (json['last_refresh_at'] is int)
          ? json['last_refresh_at'] as int
          : int.tryParse('${json['last_refresh_at']}'),
      status: json['status'] as String? ?? 'authenticated',
      accountLabel: accountLabel,
      accountName: accountName,
    );
  }

  ProviderAuthRecord copyWith({
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
  }) {
    return ProviderAuthRecord(
      providerId: providerId,
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
    );
  }
}

/// A dedicated, file-backed store for LLM provider credentials that require
/// long-lived session state (OAuth access/refresh tokens, expiry, status).
///
/// Storage rules:
/// - Lives at `<sanad-home>/provider_auth.json`, separate from `auth.json`.
/// - Written with owner-only permissions on Unix-like systems.
/// - Never logs raw tokens.
/// - API keys for simple providers remain in `.env`; only OAuth session
///   metadata lives here.
class ProviderCredentialStore {
  final _logger = Logger('ProviderCredentialStore');

  late final String _storePath;
  late final bool _usesSanadHome;

  ProviderCredentialStore({String? storePath}) {
    _usesSanadHome = storePath == null;
    _storePath = storePath ?? p.join(getSanadHome(), 'provider_auth.json');
  }

  String get storePath => _storePath;

  Map<String, dynamic> _readRaw() {
    final boundary = SanadHomeBootstrap.identity();
    final file = File(_storePath);
    if (_usesSanadHome
        ? !boundary.fileExists('provider_auth.json')
        : !file.existsSync()) {
      return <String, dynamic>{};
    }
    try {
      final content = _usesSanadHome
          ? utf8.decode(boundary.readSecretBytes('provider_auth.json'))
          : file.readAsStringSync();
      if (content.trim().isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      _logger.warning('Failed to read provider credential store: $e');
    }
    return <String, dynamic>{};
  }

  Future<void> _writeRaw(Map<String, dynamic> data) async {
    if (_usesSanadHome) {
      await SanadHomeBootstrap.identity().writeSecretBytes(
        'provider_auth.json',
        utf8.encode(jsonEncode(data)),
      );
      return;
    }
    final file = File(_storePath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsString(jsonEncode(data));
    await _secureFile(file);
  }

  Future<void> _secureFile(File file) async {
    if (Platform.isWindows) return;
    try {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        _logger.warning(
          'Failed to set provider_auth.json permissions: ${result.stderr}',
        );
      }
    } catch (e) {
      _logger.warning('Failed to secure provider_auth.json: $e');
    }
  }

  /// Reads the auth record for [providerId], or null when none is stored.
  ProviderAuthRecord? read(String providerId) {
    final data = _readRaw();
    final entry = data['providers']?[providerId];
    if (entry is Map<String, dynamic>) {
      try {
        return ProviderAuthRecord.fromJson(entry);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Persists (or replaces) the auth record for its provider.
  Future<void> write(ProviderAuthRecord record) async {
    final data = _readRaw();
    final providers =
        (data['providers'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    providers[record.providerId] = record.toJson();
    data['providers'] = providers;
    await _writeRaw(data);
  }

  /// Marks a provider's session status without removing tokens.
  Future<void> updateStatus(String providerId, String status) async {
    final existing = read(providerId);
    if (existing == null) return;
    await write(existing.copyWith(status: status));
  }

  /// Removes a single provider's stored auth record.
  Future<void> remove(String providerId) async {
    final data = _readRaw();
    final providers =
        (data['providers'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    if (providers.containsKey(providerId)) {
      providers.remove(providerId);
      data['providers'] = providers;
      await _writeRaw(data);
    }
  }

  /// Lists every provider id that has a stored auth record.
  List<String> listConfiguredProviderIds() {
    final data = _readRaw();
    final providers = data['providers'];
    if (providers is Map) {
      return providers.keys.cast<String>().toList();
    }
    return const [];
  }

  /// Returns a public (secret-free) status map for all stored OAuth providers.
  List<Map<String, dynamic>> listPublicStatuses() {
    final ids = listConfiguredProviderIds();
    return ids.map((id) {
      final record = read(id);
      return {
        'provider_id': id,
        'status': record?.status ?? 'missing',
        if (record?.expiresAt != null) 'expires_at': record!.expiresAt,
        'is_expired': record?.isExpired ?? false,
        'token_type': record?.tokenType ?? 'Bearer',
      };
    }).toList();
  }
}
