import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';

/// Abstract data-layer contract for the provider/model socket commands.
/// Extended in Plan 29 for multi-instance support and persistent model caching.
abstract class ProviderSetupClient {
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent});

  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent});

  Future<AuthSessionDto> authStart({
    required String providerId,
    String? providerInstanceId,
    String? templateId,
    String? authMethod,
    DeviceConfig? agent,
  });

  Future<AuthPollDto> authPoll({
    required String sessionId,
    DeviceConfig? agent,
  });

  Future<AuthPollDto> authSubmit({
    required String sessionId,
    required String code,
    DeviceConfig? agent,
  });

  Future<void> authCancel({
    required String sessionId,
    DeviceConfig? agent,
  });

  Future<String> authStatus({
    required String providerId,
    String? providerInstanceId,
    DeviceConfig? agent,
  });

  Future<List<ModelOptionsDto>> modelOptions({
    String? providerId,
    bool fetchLive = false,
    DeviceConfig? agent,
  });

  // ── Plan 29 Multi-Instance Commands ────────────────────────────────────

  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent});

  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent});

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
  });

  Future<ProviderInstanceDto> updateInstance({
    required String providerInstanceId,
    String? displayName,
    String? defaultModel,
    String? baseUrl,
    String? protocol,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    DeviceConfig? agent,
  });

  Future<ProviderInstanceDto> renameInstance({
    required String providerInstanceId,
    required String displayName,
    DeviceConfig? agent,
  });

  Future<void> removeInstance({
    required String providerInstanceId,
    DeviceConfig? agent,
  });

  Future<void> setInstanceDefault({
    required String providerInstanceId,
    DeviceConfig? agent,
  });

  Future<Map<String, dynamic>> testInstanceConnection({
    required String providerInstanceId,
    DeviceConfig? agent,
  });

  Future<CredentialSummaryDto> updateCredential({
    required String providerInstanceId,
    required String action,
    String? apiKey,
    DeviceConfig? agent,
  });

  Future<AuthSessionDto> authReconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  });

  Future<void> authDisconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  });

  // ── Plan 29 Model Cache & Recent Commands ──────────────────────────────

  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent});

  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  });

  /// Broadcast stream of model cache update events (`started`, `updated`, `failed`)
  /// emitted on terminal model refreshes and authoritative daemon notifications.
  Stream<ModelCacheUpdateEvent> get modelUpdates => const Stream.empty();

  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent});

  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  });

  // ── Task 55: Provider account usage limits ─────────────────────────────

  /// Fetches a usage snapshot for [providerInstanceId]. Returns a typed result
  /// (available / unsupported / unavailable / auth_required / failed).
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => ProviderUsageResultDto(
    status: 'unsupported',
    providerInstanceId: providerInstanceId,
  );

  Future<ProviderUsageResetResultDto> usageReset({
    required String providerInstanceId,
    required String idempotencyKey,
    String? confirmationToken,
    DeviceConfig? agent,
  }) async => ProviderUsageResetResultDto(
    status: 'unsupported',
    providerInstanceId: providerInstanceId,
    message: 'Usage resets are not supported for this account.',
  );

  /// Returns a per-instance support map so the client can decide which
  /// instances warrant a `Usage & limits` disclosure without a full fetch.
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async => ProviderUsageSupportDto(
    support: {for (final id in providerInstanceIds) id: false},
  );
}
