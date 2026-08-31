import 'dart:async';

import 'package:http/http.dart' as http;

import 'copilot_token_exchanger.dart';
import 'provider_credential_service.dart';
import 'provider_instance_repository.dart';
import 'provider_protocol_constants.dart';
import 'secret_record.dart';

/// Instance-scoped Copilot access-token refresh.
///
/// Proactive refresh runs when the Copilot API token expires within
/// [GithubCopilotProtocol.refreshSafetyMargin]. Reactive recovery is a single
/// forced exchange after HTTP 401. Concurrent callers for the same instance
/// share one in-flight exchange. Permanent failures (no GitHub user token,
/// classic PAT, 401/403/404 exchange) persist `relogin_required` and never
/// loop.
class CopilotCredentialLifecycle {
  final ProviderInstanceRepository _instances;
  final ProviderCredentialService _creds;
  final http.Client Function() _clientFactory;
  final CopilotTokenExchanger _exchanger;
  final Map<String, Future<bool>> _inflight = {};

  CopilotCredentialLifecycle({
    required ProviderInstanceRepository instances,
    required ProviderCredentialService creds,
    http.Client Function()? clientFactory,
    CopilotTokenExchanger? exchanger,
  }) : _instances = instances,
       _creds = creds,
       _clientFactory = clientFactory ?? http.Client.new,
       _exchanger = exchanger ?? CopilotTokenExchanger();

  /// Refreshes when the Copilot token is missing or within the safety margin.
  /// Returns `true` when a new token was written.
  Future<bool> ensureFresh(String instanceId, {DateTime? now}) {
    return _coalesced(instanceId, () => _exchange(instanceId, force: false, now: now));
  }

  /// Forces one exchange after a Copilot 401. Returns `true` when a new token
  /// was written and the caller may retry once.
  Future<bool> recoverUnauthorized(String instanceId) async {
    final pending = _inflight[instanceId];
    if (pending != null) await pending;
    return _coalesced(instanceId, () => _exchange(instanceId, force: true));
  }

  Future<bool> _coalesced(String instanceId, Future<bool> Function() action) {
    final existing = _inflight[instanceId];
    if (existing != null) return existing;
    final future = action();
    _inflight[instanceId] = future;
    return future.whenComplete(() {
      if (identical(_inflight[instanceId], future)) {
        _inflight.remove(instanceId);
      }
    });
  }

  Future<bool> _exchange(
    String instanceId, {
    required bool force,
    DateTime? now,
  }) async {
    final instance = _instances.findById(instanceId);
    if (instance == null || instance.templateId != kGithubCopilotTemplateId) {
      return false;
    }
    final record = _creds.rawForResolver(instanceId);
    if (record == null) return false;
    if (record.status == 'relogin_required') return false;

    final githubToken = record.refreshToken?.trim() ?? '';
    if (githubToken.isEmpty) {
      await _markReloginRequired(instanceId, record);
      return false;
    }
    if (GithubCopilotProtocol.isClassicPersonalAccessToken(githubToken)) {
      await _markReloginRequired(instanceId, record);
      return false;
    }

    if (!force) {
      final access = record.accessToken?.trim() ?? '';
      if (access.isNotEmpty &&
          !record.isExpiringWithin(
            GithubCopilotProtocol.refreshSafetyMargin,
            now: now,
          )) {
        return false;
      }
    }

    final client = _clientFactory();
    try {
      final exchanged = await _exchanger.exchange(
        client: client,
        githubUserToken: githubToken,
        now: now,
      );
      final updated = record.copyWith(
        accessToken: exchanged.token,
        expiresAt: exchanged.expiresAt,
        lastRefreshAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
        status: 'authenticated',
      );
      await _creds.writeOAuthBundle(instanceId, updated, now: now);
      return true;
    } on CopilotExchangeException catch (error) {
      if (error.permanent) {
        await _markReloginRequired(instanceId, record, now: now);
      }
      return false;
    } on FormatException {
      await _markReloginRequired(instanceId, record, now: now);
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Persists `relogin_required` after a second Copilot 401 on the same turn.
  Future<void> markReloginRequired(String instanceId, {DateTime? now}) async {
    final record = _creds.rawForResolver(instanceId);
    if (record == null) return;
    await _markReloginRequired(instanceId, record, now: now);
  }

  Future<void> _markReloginRequired(
    String instanceId,
    SecretRecord record, {
    DateTime? now,
  }) async {
    if (record.status == 'relogin_required') return;
    await _creds.writeOAuthBundle(
      instanceId,
      record.copyWith(status: 'relogin_required'),
      now: now,
    );
  }
}
