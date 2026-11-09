import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';

/// The outcome of attempting to resolve runtime credentials for a provider.
enum CredentialResolutionStatus { ready, reloginRequired, missing, refreshing }

class CredentialResolutionResult {
  final CredentialResolutionStatus status;

  /// Resolved access token / API key when status is `ready`, otherwise null.
  final String? credential;

  /// Human-readable reason for non-ready statuses.
  final String? reason;

  /// The provider profile that was resolved.
  final ProviderProfile profile;

  CredentialResolutionResult({
    required this.status,
    required this.profile,
    this.credential,
    this.reason,
  });

  bool get isReady => status == CredentialResolutionStatus.ready;
}

/// The reason a credential read reports while the Agent vault is still opening.
///
/// A daemon opens its vault without waiting for the operating-system store, so a
/// synchronous resolver cannot tell "this provider has no key" from "the store
/// has not answered yet". Reporting the second answer as the first would tell a
/// person their credential is gone.
const vaultNotReadyReason =
    'The Agent vault is still opening (vault_not_ready), so this provider '
    'credential is unknown rather than missing. It becomes readable when the '
    'operating-system credential store answers.';

/// Resolves a usable credential at runtime for a given provider.
///
/// - For api_key providers: reads the env key (provider-specific or generic
///   `LLM_API_KEY`).
/// - For OAuth providers: reads `ProviderCredentialStore`, refreshes the token
///   when a refresh token is available and the access token is near expiry,
///   and surfaces `relogin_required` when no refresh is possible.
///
/// This replaces the legacy behaviour of reading `CHATGPT_SESSION_TOKEN`
/// directly from `.env` for `openai-codex`.
class ProviderCredentialResolver {
  final _logger = Logger('ProviderCredentialResolver');

  final EnvFileService _env;
  final ProviderCredentialStore _credStore;
  final http.Client Function() _clientFactory;

  /// The Agent vault's readiness, when this process opens one.
  ///
  /// It is a lookup rather than an instance, because the vault may be created
  /// after this resolver is composed. `null` means the resolver has no vault to
  /// wait for, which is the case for every store that answers synchronously.
  final SecretVaultReadiness? Function()? _vaultReadiness;

  ProviderCredentialResolver(
    this._env,
    this._credStore, {
    http.Client Function()? clientFactory,
    SecretVaultReadiness? Function()? vaultReadiness,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _vaultReadiness = vaultReadiness;

  /// Whether this process's Agent vault has finished opening.
  bool get _vaultIsReady => _vaultReadiness?.call()?.isReady ?? true;

  /// Resolves credentials for [providerId] after waiting, at most [deadline],
  /// for the Agent vault to finish opening.
  ///
  /// A caller that can wait uses this entry point so a first turn is not refused
  /// with `vault_not_ready` for a vault that is merely still opening. The wait is
  /// bounded and never throws, so a store that never answers cannot turn a turn
  /// into an unbounded pause.
  Future<CredentialResolutionResult> resolveAwaitingVault(
    String providerId, {
    Duration deadline = secretVaultStartupReadyDeadline,
  }) async {
    await _vaultReadiness?.call()?.readyWithin(deadline);
    return resolve(providerId);
  }

  /// Resolves credentials for [providerId] (name or alias).
  CredentialResolutionResult resolve(String providerId) {
    final profile =
        ProviderRegistry.findByNameOrAlias(providerId) ??
        _customProfile(providerId);
    return resolveProfile(profile);
  }

  /// Resolves credentials for the currently active provider.
  CredentialResolutionResult resolveActive() {
    final active = _env.get('ACTIVE_PROVIDER').trim().toLowerCase();
    if (active.isEmpty) {
      // Fall back to auto-detection using env values.
      final baseUrl = _env.get('LLM_BASE_URL').toLowerCase();
      final genericKey = _env.get('LLM_API_KEY');
      if (baseUrl.isEmpty && genericKey.isEmpty) {
        return CredentialResolutionResult(
          status: CredentialResolutionStatus.missing,
          profile: ProviderRegistry.profiles.first,
          reason: 'No provider configured.',
        );
      }
    }
    return resolve(active.isEmpty ? 'openai' : active);
  }

  CredentialResolutionResult resolveProfile(ProviderProfile profile) {
    if (profile.isOAuth) {
      return _resolveOAuth(profile);
    }
    return _resolveApiKey(profile);
  }

  CredentialResolutionResult _resolveApiKey(ProviderProfile profile) {
    String key = '';
    if (profile.envApiKeyName != null) {
      key = _env.get(profile.envApiKeyName!);
    }
    if (key.trim().isEmpty) {
      key = _env.get('LLM_API_KEY');
    }
    if (key.trim().isEmpty &&
        (profile.name == 'ollama' ||
            profile.name == 'lm-studio' ||
            profile.name == 'llama-cpp')) {
      // Local engines do not require a key.
      return CredentialResolutionResult(
        status: CredentialResolutionStatus.ready,
        profile: profile,
        credential: '',
      );
    }
    if (key.trim().isEmpty) {
      if (!_vaultIsReady) {
        return CredentialResolutionResult(
          status: CredentialResolutionStatus.missing,
          profile: profile,
          reason: vaultNotReadyReason,
        );
      }
      return CredentialResolutionResult(
        status: CredentialResolutionStatus.missing,
        profile: profile,
        reason: 'No API key configured for ${profile.displayName}.',
      );
    }
    return CredentialResolutionResult(
      status: CredentialResolutionStatus.ready,
      profile: profile,
      credential: key,
    );
  }

  CredentialResolutionResult _resolveOAuth(ProviderProfile profile) {
    final record = _credStore.read(profile.name);
    if (record == null) {
      // Legacy fallback: a raw session token in .env is not a complete OAuth
      // session. Surface relogin_required instead of trusting it.
      final legacy = profile.envApiKeyName != null
          ? _env.get(profile.envApiKeyName!)
          : '';
      if (legacy.trim().isNotEmpty) {
        return CredentialResolutionResult(
          status: CredentialResolutionStatus.reloginRequired,
          profile: profile,
          reason:
              'A legacy token exists in .env but no OAuth session is stored. '
              'Please sign in again.',
        );
      }
      return CredentialResolutionResult(
        status: CredentialResolutionStatus.missing,
        profile: profile,
        reason: 'No OAuth session for ${profile.displayName}.',
      );
    }

    if (!record.isExpired) {
      return CredentialResolutionResult(
        status: CredentialResolutionStatus.ready,
        profile: profile,
        credential: record.accessToken,
      );
    }

    if (record.refreshToken == null || record.refreshToken!.isEmpty) {
      _credStore.updateStatus(profile.name, 'relogin_required');
      return CredentialResolutionResult(
        status: CredentialResolutionStatus.reloginRequired,
        profile: profile,
        reason: 'OAuth token expired and no refresh token is available.',
      );
    }

    // Attempt a synchronous best-effort refresh. Most refresh flows are async,
    // but the resolver is called synchronously during turn construction. When
    // a refresh is needed we mark relogin_required and let a higher layer
    // call [refreshAsync] before the next turn.
    _credStore.updateStatus(profile.name, 'expired');
    return CredentialResolutionResult(
      status: CredentialResolutionStatus.reloginRequired,
      profile: profile,
      reason: 'OAuth token expired. Refresh required.',
    );
  }

  /// Asynchronously refreshes the OAuth token for [providerId] when a refresh
  /// token is available. Returns the refreshed record, or null when refresh
  /// failed or is not supported for this provider.
  Future<ProviderAuthRecord?> refreshAsync(String providerId) async {
    final profile = ProviderRegistry.findByNameOrAlias(providerId);
    if (profile == null || !profile.isOAuth) return null;
    final record = _credStore.read(profile.name);
    if (record == null ||
        record.refreshToken == null ||
        record.refreshToken!.isEmpty) {
      return null;
    }

    final refreshTokenUrl = _refreshTokenUrl(profile);
    final clientId = _clientId(profile);
    if (refreshTokenUrl == null || clientId == null) {
      _logger.warning(
        'No refresh endpoint configured for ${profile.name}; '
        'relogin required.',
      );
      await _credStore.updateStatus(profile.name, 'relogin_required');
      return null;
    }

    final client = _clientFactory();
    try {
      final resp = await client.post(
        Uri.parse(refreshTokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': record.refreshToken,
          'client_id': clientId,
        },
      );
      if (resp.statusCode != 200) {
        _logger.warning(
          'Token refresh failed for ${profile.name}: HTTP ${resp.statusCode}',
        );
        await _credStore.updateStatus(profile.name, 'relogin_required');
        return null;
      }
      final tokens = jsonDecode(resp.body) as Map<String, dynamic>;
      final accessToken = tokens['access_token']?.toString();
      if (accessToken == null || accessToken.isEmpty) {
        await _credStore.updateStatus(profile.name, 'relogin_required');
        return null;
      }
      final expiresIn = tokens['expires_in'];
      final expiresAt = expiresIn is num
          ? DateTime.now()
                .add(Duration(seconds: expiresIn.toInt()))
                .millisecondsSinceEpoch
          : null;
      final newRefresh = tokens['refresh_token']?.toString();

      final updated = record.copyWith(
        accessToken: accessToken,
        refreshToken: newRefresh ?? record.refreshToken,
        expiresAt: expiresAt,
        lastRefreshAt: DateTime.now().millisecondsSinceEpoch,
        status: 'authenticated',
      );
      await _credStore.write(updated);
      return updated;
    } catch (e) {
      _logger.warning('Token refresh error for ${profile.name}: $e');
      await _credStore.updateStatus(profile.name, 'relogin_required');
      return null;
    } finally {
      client.close();
    }
  }

  String? _refreshTokenUrl(ProviderProfile profile) {
    switch (profile.name) {
      case 'openai-codex':
        return 'https://auth.openai.com/oauth/token';
      default:
        return null;
    }
  }

  String? _clientId(ProviderProfile profile) {
    switch (profile.name) {
      case 'openai-codex':
        return 'app_EMoamEEZ73f0CkXaXp7hrann';
      default:
        return null;
    }
  }

  ProviderProfile _customProfile(String id) {
    // An unknown provider id is treated as a custom endpoint using the generic
    // LLM_* env values.
    return ProviderProfile(
      name: id,
      displayName: id,
      authType: 'api_key',
      authFlow: 'custom_endpoint',
      apiMode: 'chat_completions',
      fallbackModels: const [],
    );
  }
}
