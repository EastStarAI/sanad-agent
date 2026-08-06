import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';

/// The kind of auth flow a provider uses.
enum AuthFlowKind { deviceCode, loopback, external, apiKey, customEndpoint }

/// Information returned when an auth session is started.
class AuthSessionStart {
  final String sessionId;
  final AuthFlowKind flow;

  /// Human-readable verification URL the user must open.
  final String? verificationUri;

  /// URL that already embeds the user code (when the provider supports it).
  final String? verificationUriComplete;

  /// Short code the user enters at the verification page.
  final String? userCode;

  /// Polling interval in seconds (device code flows).
  final int? interval;

  /// Expiry epoch milliseconds for the device code itself.
  final int? expiresAt;

  /// Provider-specific opaque handle used for polling (e.g. device_auth_id).
  final Map<String, dynamic> handle;

  AuthSessionStart({
    required this.sessionId,
    required this.flow,
    this.verificationUri,
    this.verificationUriComplete,
    this.userCode,
    this.interval,
    this.expiresAt,
    required this.handle,
  });

  Map<String, dynamic> toMap() => {
    'session_id': sessionId,
    'flow': flow.name,
    if (verificationUri != null) 'verification_uri': verificationUri,
    if (verificationUriComplete != null)
      'verification_uri_complete': verificationUriComplete,
    if (userCode != null) 'user_code': userCode,
    if (interval != null) 'interval': interval,
    if (expiresAt != null) 'expires_at': expiresAt,
  };
}

/// The status of an in-flight auth session.
enum AuthSessionStatus { pending, approved, expired, error, cancelled }

class AuthSessionPoll {
  final AuthSessionStatus status;
  final String? errorMessage;
  final ProviderAuthRecord? record;

  AuthSessionPoll({required this.status, this.errorMessage, this.record});

  Map<String, dynamic> toMap() => {
    'status': status.name,
    if (errorMessage != null) 'error': errorMessage,
    if (record != null) 'authenticated': true,
  };
}

/// Manages device-code, loopback, and external OAuth flows for LLM providers.
///
/// This migrates the legacy `runCodexDeviceCodeFlow` terminal helper into a
/// reusable service that both the CLI wizard and the Flutter UI can drive. It
/// exposes a start/poll/cancel lifecycle and persists the resulting OAuth
/// tokens into `ProviderCredentialStore` (never `.env`).
///
/// Plan 29 multi-account support: `startForInstance` keys the pending session
/// and the resulting `SecretRecord` by `provider_instance_id` — not template
/// id — so two parallel flows for the same template run independently and a
/// failure in one never mutates the other's stored credential (exit gate C).
/// The legacy provider-keyed path (`start`/`statusFor`) is retained for
/// backward compatibility; the instance-keyed path is preferred by new
/// consumers and the protocol bridge.
class ProviderAuthSessionService {
  final ProviderCredentialStore _credStore;

  /// Optional Plan 29 instance-keyed credential sink. When non-null, OAuth
  /// bundles are written through it (to the SecretStore keyed by instance
  /// UUID) so multiple accounts of the same template never overwrite each
  /// other. When null, the legacy provider-keyed `_credStore` is used.
  final ProviderCredentialService? _credService;
  // Kept for future status transitions that require the instance service.
  // Currently OAuth approval writes the credential bundle via _credService;
  // instance readiness is promoted later during model selection.
  // ignore: unused_field
  final ProviderInstanceService? _instanceService;
  final http.Client Function() _clientFactory;

  final Map<String, _ActiveSession> _activeSessions = {};

  ProviderAuthSessionService(
    this._credStore, {
    ProviderCredentialService? credService,
    ProviderInstanceService? instanceService,
    http.Client Function()? clientFactory,
  }) : _credService = credService,
       _instanceService = instanceService,
       _clientFactory = clientFactory ?? http.Client.new;

  AuthFlowKind flowKindFor(ProviderProfile profile) {
    switch (profile.effectiveAuthFlow) {
      case 'device_code':
        return AuthFlowKind.deviceCode;
      case 'loopback':
        return AuthFlowKind.loopback;
      case 'external':
        return AuthFlowKind.external;
      case 'custom_endpoint':
        return AuthFlowKind.customEndpoint;
      case 'api_key':
      default:
        return AuthFlowKind.apiKey;
    }
  }

  /// Starts an auth session for [providerId]. Returns the data the UI needs to
  /// instruct the user (verification url, user code, etc.).
  Future<AuthSessionStart> start(String providerId) async {
    final profile =
        ProviderRegistry.findByNameOrAlias(providerId) ??
        (throw ArgumentError('Unknown provider: $providerId'));
    final flow = flowKindFor(profile);

    switch (profile.name) {
      case 'openai-codex':
        return _startCodexDeviceCode(profile, flow);
      default:
        if (flow == AuthFlowKind.apiKey ||
            flow == AuthFlowKind.customEndpoint) {
          throw StateError(
            'Provider ${profile.name} does not require an OAuth session.',
          );
        }
        throw UnimplementedError(
          'Auth flow $flow for ${profile.name} is not implemented yet.',
        );
    }
  }

  /// Starts an auth session bound to a specific `ProviderInstance` UUID. The
  /// pending session carries [instanceId]; on success the resulting tokens are
  /// written to the SecretStore keyed by [instanceId] (via
  /// `ProviderCredentialService`), so another flow for a sibling instance of
  /// the same template cannot overwrite or be overwritten (Plan 29 §8.2).
  ///
  /// [authMethod] is the auth method the instance was created with (one of
  /// [ProviderAuthMethod]); it determines whether an OAuth flow is actually
  /// started. API-key instances are rejected: they have no OAuth flow.
  Future<AuthSessionStart> startForInstance({
    required String instanceId,
    required String templateId,
    required String authMethod,
  }) async {
    if (ProviderAuthMethod.isApiKeyMethod(authMethod)) {
      throw StateError(
        'Instance $instanceId uses auth_method=$authMethod and has no OAuth flow.',
      );
    }
    final profile =
        ProviderRegistry.findByNameOrAlias(templateId) ??
        (throw ArgumentError('Unknown provider template: $templateId'));
    final flow = flowKindFor(profile);
    switch (profile.name) {
      case 'openai-codex':
        return _startCodexDeviceCode(profile, flow, instanceId: instanceId);
      default:
        throw UnimplementedError(
          'Auth flow $flow for ${profile.name} is not implemented yet.',
        );
    }
  }

  /// Polls an in-flight session once. Does not block; callers (UI or CLI)
  /// decide their own polling cadence using the returned interval hint.
  Future<AuthSessionPoll> poll(String sessionId) async {
    final session = _activeSessions[sessionId];
    if (session == null) {
      return AuthSessionPoll(
        status: AuthSessionStatus.error,
        errorMessage: 'Session not found or already completed.',
      );
    }
    if (session.isCancelled) {
      return AuthSessionPoll(status: AuthSessionStatus.cancelled);
    }
    return _pollCodexDeviceCode(session);
  }

  /// Submits a manual code (e.g. pasted by the user) for flows that support it.
  Future<AuthSessionPoll> submitCode(String sessionId, String code) async {
    return AuthSessionPoll(
      status: AuthSessionStatus.error,
      errorMessage: 'Manual code submission is not supported for this flow.',
    );
  }

  /// Cancels an in-flight session and cleans up any timers/listeners.
  void cancel(String sessionId) {
    final session = _activeSessions.remove(sessionId);
    if (session != null) {
      session.isCancelled = true;
      session.client.close();
    }
  }

  /// Returns the persisted auth status for a provider, independent of any
  /// active session.
  String statusFor(String providerId) {
    final record = _credStore.read(providerId);
    if (record == null) return 'missing';
    if (record.isExpired) {
      return (record.refreshToken != null && record.refreshToken!.isNotEmpty)
          ? 'expired'
          : 'relogin_required';
    }
    return record.status == 'relogin_required'
        ? 'relogin_required'
        : 'authenticated';
  }

  /// Instance-keyed auth status (Plan 29 §8.2). Reads the SecretStore through
  /// `ProviderCredentialService`; never returns a raw token. Returns one of
  /// `authenticated`, `expired`, `relogin_required`, or `missing`.
  String statusForInstance(String instanceId) {
    final credService = _credService;
    if (credService == null) return 'missing';
    final summary = credService.summary(instanceId);
    if (!summary.configured) return 'missing';
    return summary.reloginRequired
        ? 'relogin_required'
        : (summary.status == 'expired' ? 'expired' : 'authenticated');
  }

  /// Reconnect starts a fresh OAuth flow bound to [instanceId]; the prior
  /// tokens (if any) are replaced only after the new flow succeeds. Until
  /// then the old tokens remain usable (Plan 29 §6.2).
  Future<AuthSessionStart> reconnectForInstance({
    required String instanceId,
    required String templateId,
    required String authMethod,
  }) {
    return startForInstance(
      instanceId: instanceId,
      templateId: templateId,
      authMethod: authMethod,
    );
  }

  /// Disconnect removes the OAuth tokens for [instanceId] but keeps the
  /// instance metadata so the user can reconnect later (Plan 29 §6.2).
  Future<void> disconnectForInstance(String instanceId) async {
    final credService = _credService;
    if (credService == null) return;
    await credService.disconnect(instanceId);
  }

  // ── Codex device code ────────────────────────────────────────────────

  Future<AuthSessionStart> _startCodexDeviceCode(
    ProviderProfile profile,
    AuthFlowKind flow, {
    String? instanceId,
  }) async {
    final issuer = 'https://auth.openai.com';
    final clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
    final client = _clientFactory();

    final resp = await client.post(
      Uri.parse('$issuer/api/accounts/deviceauth/usercode'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'client_id': clientId}),
    );
    if (resp.statusCode != 200) {
      client.close();
      throw Exception('Failed to request device auth: HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final userCode = data['user_code']?.toString();
    final deviceAuthId = data['device_auth_id']?.toString();
    if (userCode == null || deviceAuthId == null) {
      client.close();
      throw Exception('Device auth response was incomplete.');
    }

    int interval = 5;
    final intervalRaw = data['interval'];
    if (intervalRaw is int) {
      interval = intervalRaw;
    } else if (intervalRaw is num) {
      interval = intervalRaw.toInt();
    } else if (intervalRaw is String) {
      interval = int.tryParse(intervalRaw) ?? 5;
    }
    if (interval < 3) interval = 3;

    final sessionId =
        'codex-${DateTime.now().microsecondsSinceEpoch}-${_sessionNonce.incrementAndGet()}';
    _activeSessions[sessionId] = _ActiveSession(
      sessionId: sessionId,
      providerId: profile.name,
      instanceId: instanceId,
      flow: flow,
      client: client,
      handle: {
        'issuer': issuer,
        'client_id': clientId,
        'device_auth_id': deviceAuthId,
        'user_code': userCode,
        'interval': interval,
        'token_url': 'https://auth.openai.com/oauth/token',
      },
    );

    return AuthSessionStart(
      sessionId: sessionId,
      flow: flow,
      verificationUri: '$issuer/codex/device',
      userCode: userCode,
      interval: interval,
      handle: _activeSessions[sessionId]!.handle,
    );
  }

  Future<AuthSessionPoll> _pollCodexDeviceCode(_ActiveSession session) async {
    final issuer = session.handle['issuer'] as String;
    final clientId = session.handle['client_id'] as String;
    final deviceAuthId = session.handle['device_auth_id'] as String;
    final userCode = session.handle['user_code'] as String;
    final tokenUrl = session.handle['token_url'] as String;

    final pollResp = await session.client.post(
      Uri.parse('$issuer/api/accounts/deviceauth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'device_auth_id': deviceAuthId, 'user_code': userCode}),
    );

    if (pollResp.statusCode == 200) {
      final codeResp = jsonDecode(pollResp.body) as Map<String, dynamic>;
      final authorizationCode = codeResp['authorization_code']?.toString();
      final codeVerifier = codeResp['code_verifier']?.toString();
      if (authorizationCode == null || codeVerifier == null) {
        return AuthSessionPoll(
          status: AuthSessionStatus.error,
          errorMessage: 'Incomplete authorization response.',
        );
      }
      // Exchange code for tokens.
      final redirectUri = '$issuer/deviceauth/callback';
      final tokenResp = await session.client.post(
        Uri.parse(tokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': authorizationCode,
          'redirect_uri': redirectUri,
          'client_id': clientId,
          'code_verifier': codeVerifier,
        },
      );
      if (tokenResp.statusCode != 200) {
        return AuthSessionPoll(
          status: AuthSessionStatus.error,
          errorMessage: 'Token exchange failed: HTTP ${tokenResp.statusCode}',
        );
      }
      final tokens = jsonDecode(tokenResp.body) as Map<String, dynamic>;
      final accessToken = tokens['access_token']?.toString();
      if (accessToken == null || accessToken.isEmpty) {
        return AuthSessionPoll(
          status: AuthSessionStatus.error,
          errorMessage: 'Token exchange did not return an access_token.',
        );
      }
      final idToken = tokens['id_token']?.toString();
      final identity = extractOAuthAccountIdentity(idToken ?? accessToken);
      final expiresIn = tokens['expires_in'];
      final expiresAt = expiresIn is num
          ? DateTime.now()
                .add(Duration(seconds: expiresIn.toInt()))
                .millisecondsSinceEpoch
          : null;
      final record = ProviderAuthRecord(
        providerId: session.providerId,
        accessToken: accessToken,
        refreshToken: tokens['refresh_token']?.toString(),
        idToken: idToken,
        expiresAt: expiresAt,
        scope: tokens['scope']?.toString(),
        tokenType: tokens['token_type']?.toString() ?? 'Bearer',
        status: 'authenticated',
        accountLabel: identity.accountLabel,
        accountName: identity.accountName,
      );
      if (session.instanceId != null && _credService != null) {
        // Plan 29 instance-keyed path: write to the SecretStore keyed by
        // instance UUID so sibling instances are untouched.
        final secret = SecretRecord(
          instanceId: session.instanceId!,
          accessToken: accessToken,
          refreshToken: tokens['refresh_token']?.toString(),
          idToken: idToken,
          expiresAt: expiresAt,
          scope: tokens['scope']?.toString(),
          tokenType: tokens['token_type']?.toString() ?? 'Bearer',
          status: 'authenticated',
          authMethod: ProviderAuthMethod.deviceCode,
          accountLabel: identity.accountLabel,
          accountName: identity.accountName,
        );
        await _credService.writeOAuthBundle(session.instanceId!, secret);
        // Do NOT mark ready here — a model must still be selected and the
        // endpoint verified. The instance stays draft/needs_auth until the
        // full setup completes (Plan 29 problem 7).
      } else {
        await _credStore.write(record);
      }
      _finishSession(session.sessionId);
      return AuthSessionPoll(
        status: AuthSessionStatus.approved,
        record: record,
      );
    } else if (pollResp.statusCode == 403 || pollResp.statusCode == 404) {
      return AuthSessionPoll(status: AuthSessionStatus.pending);
    } else {
      return AuthSessionPoll(
        status: AuthSessionStatus.error,
        errorMessage: 'Polling failed: HTTP ${pollResp.statusCode}',
      );
    }
  }

  void _finishSession(String sessionId) {
    final session = _activeSessions.remove(sessionId);
    if (session != null) {
      session.isCancelled = true;
      session.client.close();
    }
  }

  /// Removes the persisted OAuth session for a provider (sign out).
  Future<void> signOut(String providerId) => _credStore.remove(providerId);
}

/// Monotonic counter guaranteeing unique auth-session ids even when two starts
/// land in the same microsecond (parallel multi-account OAuth flows).
class _SessionNonce {
  int _v = 0;
  int incrementAndGet() => ++_v;
}

final _SessionNonce _sessionNonce = _SessionNonce();

class _ActiveSession {
  final String sessionId;
  final String providerId;

  /// Plan 29: when non-null, this pending session is bound to a specific
  /// `ProviderInstance` UUID and the resulting tokens are written to the
  /// SecretStore keyed by it (not by template id).
  final String? instanceId;
  final AuthFlowKind flow;
  final http.Client client;
  final Map<String, dynamic> handle;
  bool isCancelled = false;

  _ActiveSession({
    required this.sessionId,
    required this.providerId,
    this.instanceId,
    required this.flow,
    required this.client,
    required this.handle,
  });
}
