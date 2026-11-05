import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_runtime_cubit.dart';

class _FakeProviderRuntimeClient extends ProviderSetupClient {
  final List<bool> manualRefreshCalls = [];

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    return const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'inst-1',
          displayName: 'Z.AI Coding Plan',
          defaultModel: 'glm-5.1',
          status: 'ready',
          isDefault: false,
          cacheStatus: 'fetched',
          models: [
            ModelCacheModelDto(id: 'glm-5.1'),
          ],
        ),
      ],
      recent: [],
    );
  }

  @override
  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  }) async {
    manualRefreshCalls.add(manual);
  }

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => const [];

  @override
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent}) async =>
      const ProviderReadinessDto(hasProvider: true, runtimeReady: true);

  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) async =>
      const ProviderReadinessDto(hasProvider: true, runtimeReady: true);

  @override
  Future<AuthSessionDto> authStart({
    required String providerId,
    String? providerInstanceId,
    String? templateId,
    String? authMethod,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<AuthPollDto> authPoll({
    required String sessionId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<AuthPollDto> authSubmit({
    required String sessionId,
    required String code,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<void> authCancel({
    required String sessionId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<String> authStatus({
    required String providerId,
    String? providerInstanceId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<List<ModelOptionsDto>> modelOptions({
    String? providerId,
    bool fetchLive = false,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent}) => throw UnimplementedError();

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) => throw UnimplementedError();

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
  }) => throw UnimplementedError();

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
  }) => throw UnimplementedError();

  @override
  Future<ProviderInstanceDto> renameInstance({
    required String providerInstanceId,
    required String displayName,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<void> removeInstance({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<void> setInstanceDefault({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> testInstanceConnection({
    required String providerInstanceId,
    DeviceConfig? agent,
    bool probe = true,
  }) => throw UnimplementedError();

  @override
  Future<CredentialSummaryDto> updateCredential({
    required String providerInstanceId,
    required String action,
    String? apiKey,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<AuthSessionDto> authReconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<void> authDisconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) => throw UnimplementedError();
}

void main() {
  test('refreshModels forces manual refresh for provider instances', () async {
    final client = _FakeProviderRuntimeClient();
    final cubit = ProviderRuntimeCubit(client: client);
    addTearDown(cubit.close);

    await Future<void>.delayed(Duration.zero);
    client.manualRefreshCalls.clear();

    await cubit.refreshModels();

    expect(client.manualRefreshCalls, isNotEmpty);
    expect(client.manualRefreshCalls, everyElement(isTrue));
  });
}
