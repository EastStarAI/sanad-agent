import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';

/// Socket-backed implementation of [ProviderSetupClient].
class ProviderSetupClientImpl extends ProviderSetupClient {
  ProviderSetupClientImpl({
    required DeviceConnectionCoordinator connectionCoordinator,
    DeviceCommandClient? commandClient,
  }) : _connectionCoordinator = connectionCoordinator,
       _commandClient = commandClient ?? DeviceCommandClient(connectionCoordinator: connectionCoordinator);

  final DeviceConnectionCoordinator _connectionCoordinator;
  final DeviceCommandClient _commandClient;

  @override
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent}) => _readiness(isRuntimeCheck: false, agent: agent);

  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) => _readiness(isRuntimeCheck: true, agent: agent);

  Future<ProviderReadinessDto> _readiness({
    required bool isRuntimeCheck,
    required DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: isRuntimeCheck ? 'provider.runtime_check' : 'provider.setup_status',
      payload: const {},
      expectedEvent: 'provider_readiness_result',
      agent: agent,
    );
    return ProviderReadinessDto.fromJson(payload);
  }

  @override
  Future<AuthSessionDto> authStart({
    required String providerId,
    String? providerInstanceId,
    String? templateId,
    String? authMethod,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.auth.start',
      payload: {
        'provider_id': providerId,
        if (providerInstanceId != null) 'provider_instance_id': providerInstanceId,
        if (templateId != null) 'template_id': templateId,
        if (authMethod != null) 'auth_method': authMethod,
      },
      expectedEvent: 'provider_auth_started',
      agent: agent,
    );
    return AuthSessionDto.fromJson(payload);
  }

  @override
  Future<AuthPollDto> authPoll({
    required String sessionId,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.auth.poll',
      payload: {'session_id': sessionId},
      expectedEvent: 'provider_auth_polled',
      agent: agent,
    );
    return AuthPollDto.fromJson(payload);
  }

  @override
  Future<AuthPollDto> authSubmit({
    required String sessionId,
    required String code,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.auth.submit',
      payload: {'session_id': sessionId, 'code': code},
      expectedEvent: 'provider_auth_polled',
      agent: agent,
    );
    return AuthPollDto.fromJson(payload);
  }

  @override
  Future<void> authCancel({
    required String sessionId,
    DeviceConfig? agent,
  }) async {
    await _request(
      command: 'provider.auth.cancel',
      payload: {'session_id': sessionId},
      expectedEvent: 'provider_auth_cancelled',
      agent: agent,
    );
  }

  @override
  Future<String> authStatus({
    required String providerId,
    String? providerInstanceId,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.auth.status',
      payload: {
        'provider_id': providerId,
        if (providerInstanceId != null) 'provider_instance_id': providerInstanceId,
      },
      expectedEvent: 'provider_auth_status_result',
      agent: agent,
    );
    return (payload['status'] ?? 'missing').toString();
  }

  @override
  Future<List<ModelOptionsDto>> modelOptions({
    String? providerId,
    bool fetchLive = false,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'model.options',
      payload: {
        if (providerId != null) 'provider_id': providerId,
        'fetch_live': fetchLive,
      },
      expectedEvent: 'model_options_result',
      agent: agent,
      timeout: const Duration(seconds: 20),
    );
    final list =
        (payload['options'] as List?)?.map((e) => ModelOptionsDto.fromJson(e as Map<String, dynamic>)).toList() ??
        const <ModelOptionsDto>[];
    return list;
  }

  // ── Plan 29 Multi-Instance Commands ────────────────────────────────────

  @override
  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent}) async {
    final payload = await _request(
      command: 'provider.templates.list',
      payload: const {},
      expectedEvent: 'provider.templates.result',
      agent: agent,
    );
    final list =
        (payload['templates'] as List?)?.map((e) => ProviderTemplateDto.fromJson(e as Map<String, dynamic>)).toList() ??
        const <ProviderTemplateDto>[];
    return list;
  }

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async {
    final payload = await _request(
      command: 'provider.instances.list',
      payload: const {},
      expectedEvent: 'provider.instances.result',
      agent: agent,
    );
    final list =
        (payload['instances'] as List?)?.map((e) => ProviderInstanceDto.fromJson(e as Map<String, dynamic>)).toList() ??
        const <ProviderInstanceDto>[];
    return list;
  }

  @override
  Future<ProviderInstanceDto> createInstance({
    required String templateId,
    required String displayName,
    required String authMethod,
    String? protocol,
    String? baseUrl,
    String? defaultModel,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    bool isDefault = false,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.instance.create',
      payload: {
        'template_id': templateId,
        'display_name': displayName,
        'auth_method': authMethod,
        if (protocol != null) 'protocol': protocol,
        if (baseUrl != null) 'base_url': baseUrl,
        if (defaultModel != null) 'default_model': defaultModel,
        if (requestsPerMinute != null) 'requests_per_minute': requestsPerMinute,
        if (allowAutoFailover != null) 'allow_auto_failover': allowAutoFailover,
        'is_default': isDefault,
      },
      expectedEvent: 'provider.instance.created',
      agent: agent,
    );
    final error = payload['error']?.toString();
    if (error != null && error.isNotEmpty) {
      throw StateError(error);
    }
    return ProviderInstanceDto.fromJson(payload['instance'] as Map<String, dynamic>);
  }

  @override
  Future<ProviderInstanceDto> updateInstance({
    required String providerInstanceId,
    String? displayName,
    String? defaultModel,
    String? baseUrl,
    String? protocol,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.instance.update',
      payload: {
        'provider_instance_id': providerInstanceId,
        if (displayName != null) 'display_name': displayName,
        if (defaultModel != null) 'default_model': defaultModel,
        if (baseUrl != null) 'base_url': baseUrl,
        if (protocol != null) 'protocol': protocol,
        if (requestsPerMinute != null) 'requests_per_minute': requestsPerMinute,
        if (allowAutoFailover != null) 'allow_auto_failover': allowAutoFailover,
      },
      expectedEvent: 'provider.instance.updated',
      agent: agent,
    );
    final error = payload['error']?.toString();
    if (error != null && error.isNotEmpty) {
      throw StateError(error);
    }
    return ProviderInstanceDto.fromJson(payload['instance'] as Map<String, dynamic>);
  }

  @override
  Future<ProviderInstanceDto> renameInstance({
    required String providerInstanceId,
    required String displayName,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.instance.rename',
      payload: {
        'provider_instance_id': providerInstanceId,
        'display_name': displayName,
      },
      expectedEvent: 'provider.instance.renamed',
      agent: agent,
    );
    return ProviderInstanceDto.fromJson(payload['instance'] as Map<String, dynamic>);
  }

  @override
  Future<void> removeInstance({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    await _request(
      command: 'provider.instance.remove',
      payload: {'provider_instance_id': providerInstanceId},
      expectedEvent: 'provider.instance.removed',
      agent: agent,
    );
  }

  @override
  Future<void> setInstanceDefault({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    await _request(
      command: 'provider.instance.set_default',
      payload: {'provider_instance_id': providerInstanceId},
      expectedEvent: 'provider.instance.default_changed',
      agent: agent,
    );
  }

  @override
  Future<Map<String, dynamic>> testInstanceConnection({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.instance.test',
      payload: {'provider_instance_id': providerInstanceId},
      expectedEvent: 'provider.instance.test_result',
      agent: agent,
      timeout: const Duration(seconds: 15),
    );
    return payload;
  }

  @override
  Future<CredentialSummaryDto> updateCredential({
    required String providerInstanceId,
    required String action,
    String? apiKey,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.credential.update',
      payload: {
        'provider_instance_id': providerInstanceId,
        'action': action,
        if (apiKey != null) 'api_key': apiKey,
      },
      expectedEvent: 'provider.credential.updated',
      agent: agent,
    );
    final error = payload['error']?.toString();
    if (error != null && error.isNotEmpty) {
      throw StateError(error);
    }
    return CredentialSummaryDto.fromJson(payload['credential'] as Map<String, dynamic>);
  }

  @override
  Future<AuthSessionDto> authReconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.auth.reconnect',
      payload: {'provider_instance_id': providerInstanceId},
      expectedEvent: 'provider_auth_started',
      agent: agent,
    );
    return AuthSessionDto.fromJson(payload);
  }

  @override
  Future<void> authDisconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    await _request(
      command: 'provider.auth.disconnect',
      payload: {'provider_instance_id': providerInstanceId},
      expectedEvent: 'provider.instance.updated',
      agent: agent,
    );
  }

  // ── Plan 29 Model Cache & Recent Commands ──────────────────────────────

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    final payload = await _request(
      command: 'model.snapshot',
      payload: const {},
      expectedEvent: 'model.snapshot_result',
      agent: agent,
    );
    return ModelCacheSnapshotDto.fromJson(payload);
  }

  @override
  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  }) async {
    // model.refresh emits a non-final `started` event first, then `updated`
    // (success) or `failed` (error). Complete only on the terminal statuses;
    // completing on `started` would read the snapshot before the refresh
    // finishes (Plan 29 §11.3).
    final result = await _request(
      command: 'model.refresh',
      payload: {
        'provider_instance_id': providerInstanceId,
        'manual': manual,
      },
      expectedEvent: 'model.cache_updated',
      agent: agent,
      timeout: const Duration(seconds: 20),
      payloadFilter: (p) {
        final status = p['status']?.toString();
        return status == 'updated' || status == 'failed';
      },
    );
    final status = result['status']?.toString();
    if (status == 'failed') {
      throw StateError(
        'Model refresh failed: ${result['error'] ?? 'unknown error'}',
      );
    }
  }

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async {
    final payload = await _request(
      command: 'model.recent.list',
      payload: const {},
      expectedEvent: 'model.recent.recent_result',
      agent: agent,
    );
    final list =
        (payload['recent'] as List?)?.map((e) => RecentModelDto.fromJson(e as Map<String, dynamic>)).toList() ??
        const <RecentModelDto>[];
    return list;
  }

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) async {
    await _request(
      command: 'model.recent.record',
      payload: {
        'provider_instance_id': providerInstanceId,
        'model_id': modelId,
      },
      expectedEvent: 'model.recent.recent_recorded',
      agent: agent,
    );
  }

  // ── Task 55: Provider account usage limits ─────────────────────────────

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.usage.get',
      payload: {'provider_instance_id': providerInstanceId},
      expectedEvent: 'provider.usage.result',
      agent: agent,
      timeout: const Duration(seconds: 20),
    );
    return ProviderUsageResultDto.fromJson(payload);
  }

  @override
  Future<ProviderUsageResetResultDto> usageReset({
    required String providerInstanceId,
    required String idempotencyKey,
    String? confirmationToken,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.usage.reset',
      payload: {
        'provider_instance_id': providerInstanceId,
        'idempotency_key': idempotencyKey,
        if (confirmationToken != null) 'confirmation_token': confirmationToken,
      },
      expectedEvent: 'provider.usage.reset_result',
      agent: agent,
      timeout: const Duration(seconds: 40),
    );
    return ProviderUsageResetResultDto.fromJson(payload);
  }

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async {
    final payload = await _request(
      command: 'provider.usage.support',
      payload: {'provider_instance_ids': providerInstanceIds},
      expectedEvent: 'provider.usage.support_result',
      agent: agent,
    );
    return ProviderUsageSupportDto.fromJson(payload);
  }

  Future<Map<String, dynamic>> _request({
    required String command,
    required Map<String, dynamic> payload,
    required String expectedEvent,
    required DeviceConfig? agent,
    Duration timeout = const Duration(seconds: 10),

    /// Optional predicate over the payload; the response is matched only when
    /// it returns true. Used to disambiguate multi-stage responses (e.g.
    /// model.refresh emits `started`, `updated`, and `failed` under the same
    /// event name + request_id — only `updated`/`failed` complete the request).
    bool Function(Map<String, dynamic> payload)? payloadFilter,
  }) async {
    final target =
        agent ??
        DeviceConfig(
          id: _connectionCoordinator.currentDeviceId,
          name: 'This device',
          hardwareId: _connectionCoordinator.currentDeviceId,
          isOnline: _connectionCoordinator.localSocketService.isConnected,
        );
    return _commandClient.request(
      device: target,
      command: command,
      payload: payload,
      expectedEvent: expectedEvent,
      timeout: timeout,
      payloadMatches: payloadFilter,
    );
  }
}
