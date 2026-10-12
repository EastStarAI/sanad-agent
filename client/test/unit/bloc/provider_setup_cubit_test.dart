import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';

/// A fake [ProviderSetupClient] that returns preset responses and records
/// the calls made so the cubit flow can be asserted without a socket.
class _FakeProviderSetupClient extends ProviderSetupClient {
  _FakeProviderSetupClient({
    this.providers = const [],
    List<ProviderInstanceDto> instances = const [],
    this.runtimeReady = false,
    this.modelOptionsResult,
    this.authSession,
    this.authPollResult = const AuthPollDto(status: AuthPollStatus.pending),
    this.modelRefreshError,
  }) : instances = List<ProviderInstanceDto>.from(instances);

  final List<ProviderDto> providers;
  final List<ProviderInstanceDto> instances;
  bool runtimeReady;
  final ModelOptionsDto? modelOptionsResult;
  AuthSessionDto? authSession;
  AuthPollDto authPollResult;
  Completer<AuthPollDto>? authPollCompleter;
  Completer<void>? modelRefreshCompleter;
  Object? modelRefreshError;
  Object? updateInstanceError;
  String updateInstanceStatus = 'ready';
  Map<String, dynamic> testConnectionResult = const {'success': true};

  final List<String> authStartCalls = [];
  final List<String?> authStartInstanceIds = [];
  final List<Map<String, dynamic>> createInstanceCalls = [];
  final List<Map<String, dynamic>> updateInstanceCalls = [];
  final List<Map<String, dynamic>> updateCredentialCalls = [];
  final List<String> testConnectionCalls = [];
  final List<String> removeInstanceCalls = [];

  /// Deterministic concurrency proof for the parallel provider-load path.
  int _activeLoadReads = 0;
  int maxConcurrentLoadReads = 0;
  void _enterLoadRead() {
    _activeLoadReads++;
    if (_activeLoadReads > maxConcurrentLoadReads) {
      maxConcurrentLoadReads = _activeLoadReads;
    }
  }

  void _leaveLoadRead() {
    _activeLoadReads--;
  }

  /// When set, [listInstances] waits on this completer before returning,
  /// letting tests assert that other reads proceed meanwhile (parallelism).
  Completer<void>? instancesGate;

  /// When set, [runtimeCheck] waits on this completer before returning.
  Completer<void>? readinessGate;

  /// When set, [runtimeCheck] throws it before returning.
  Object? runtimeCheckFailure;

  int listTemplatesCalls = 0;
  int listInstancesCalls = 0;
  int runtimeCheckCalls = 0;

  @override
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent}) async => ProviderReadinessDto(
    hasProvider: runtimeReady,
    runtimeReady: runtimeReady,
  );

  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) async {
    runtimeCheckCalls++;
    _enterLoadRead();
    try {
      final gate = readinessGate;
      if (gate != null) {
        await gate.future;
      }
      final failure = runtimeCheckFailure;
      if (failure != null) {
        throw failure;
      }
      return ProviderReadinessDto(
        hasProvider: runtimeReady,
        runtimeReady: runtimeReady,
      );
    } finally {
      _leaveLoadRead();
    }
  }

  @override
  Future<AuthSessionDto> authStart({
    required String providerId,
    String? providerInstanceId,
    String? templateId,
    String? authMethod,
    DeviceConfig? agent,
  }) async {
    authStartCalls.add(providerId);
    authStartInstanceIds.add(providerInstanceId);
    return authSession ??
        const AuthSessionDto(
          sessionId: 's1',
          flow: 'deviceCode',
          userCode: 'ABC123',
          verificationUri: 'https://example.com',
        );
  }

  @override
  Future<AuthPollDto> authPoll({
    required String sessionId,
    DeviceConfig? agent,
  }) async => authPollCompleter?.future ?? authPollResult;

  @override
  Future<AuthPollDto> authSubmit({
    required String sessionId,
    required String code,
    DeviceConfig? agent,
  }) async => authPollResult;

  @override
  Future<void> authCancel({
    required String sessionId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<String> authStatus({
    required String providerId,
    String? providerInstanceId,
    DeviceConfig? agent,
  }) async => 'missing';

  @override
  Future<List<ModelOptionsDto>> modelOptions({
    String? providerId,
    bool fetchLive = false,
    DeviceConfig? agent,
  }) async => [if (modelOptionsResult != null) modelOptionsResult!];

  @override
  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent}) async {
    listTemplatesCalls++;
    _enterLoadRead();
    try {
      return providers
          .map(
            (p) => ProviderTemplateDto(
              name: p.id,
              displayName: p.displayName,
              description: p.description,
              defaultBaseUrl: p.defaultBaseUrl,
              keyEnv: p.keyEnv,
              envModelName: p.envModelName,
              envBaseUrlName: p.envBaseUrlName,
              authType: p.authType,
              authFlow: p.authFlow,
              apiMode: p.apiMode,
              docsUrl: p.docsUrl,
              supportsModelFetch: p.supportsModelFetch,
              disconnectable: p.disconnectable,
              fallbackModels: p.fallbackModels,
              aliases: p.aliases,
              authMethods: _authMethodsForFlow(p.authFlow),
            ),
          )
          .toList();
    } finally {
      _leaveLoadRead();
    }
  }

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async {
    listInstancesCalls++;
    _enterLoadRead();
    try {
      final gate = instancesGate;
      if (gate != null) {
        await gate.future;
      }
      return instances;
    } finally {
      _leaveLoadRead();
    }
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
    createInstanceCalls.add({
      'templateId': templateId,
      'displayName': displayName,
      'authMethod': authMethod,
      'protocol': protocol,
      'baseUrl': baseUrl,
      'defaultModel': defaultModel,
      'requestsPerMinute': requestsPerMinute,
      'allowAutoFailover': allowAutoFailover,
      'isDefault': isDefault,
    });
    final instance = ProviderInstanceDto(
      id: 'inst-1',
      templateId: templateId,
      displayName: displayName,
      protocol: protocol ?? 'openai',
      authMethod: authMethod,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      status: 'ready',
      isDefault: isDefault,
      configRevision: 1,
      credentialRevision: 1,
      requestsPerMinute: requestsPerMinute ?? 0,
      allowAutoFailover: allowAutoFailover ?? true,
    );
    instances.add(instance);
    return instance;
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
    updateInstanceCalls.add({
      'instance': providerInstanceId,
      'displayName': displayName,
      'defaultModel': defaultModel,
      'baseUrl': baseUrl,
      'protocol': protocol,
      'allowAutoFailover': allowAutoFailover,
    });
    if (updateInstanceError case final error?) throw error;
    final existing = instances.where((instance) => instance.id == providerInstanceId).firstOrNull;
    final updated = ProviderInstanceDto(
      id: providerInstanceId,
      templateId: existing?.templateId ?? 'openai',
      displayName: displayName ?? existing?.displayName ?? 'OpenAI',
      protocol: protocol ?? existing?.protocol ?? 'openai',
      authMethod: existing?.authMethod ?? 'api_key',
      baseUrl: baseUrl ?? existing?.baseUrl,
      defaultModel: defaultModel ?? existing?.defaultModel,
      status: updateInstanceStatus,
      isDefault: true,
      configRevision: 2,
      credentialRevision: 1,
      requestsPerMinute: requestsPerMinute ?? existing?.requestsPerMinute ?? 0,
      allowAutoFailover: allowAutoFailover ?? existing?.allowAutoFailover ?? true,
    );
    final index = instances.indexWhere(
      (instance) => instance.id == providerInstanceId,
    );
    if (index != -1) {
      instances[index] = updated;
    }
    return updated;
  }

  @override
  Future<ProviderInstanceDto> renameInstance({
    required String providerInstanceId,
    required String displayName,
    DeviceConfig? agent,
  }) async {
    return ProviderInstanceDto(
      id: providerInstanceId,
      templateId: 'openai',
      displayName: displayName,
      protocol: 'openai',
      authMethod: 'api_key',
      status: 'ready',
      isDefault: true,
      configRevision: 2,
      credentialRevision: 1,
    );
  }

  @override
  Future<void> removeInstance({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    removeInstanceCalls.add(providerInstanceId);
    instances.removeWhere((instance) => instance.id == providerInstanceId);
  }

  @override
  Future<void> setInstanceDefault({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<Map<String, dynamic>> testInstanceConnection({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    testConnectionCalls.add(providerInstanceId);
    return testConnectionResult;
  }

  @override
  Future<CredentialSummaryDto> updateCredential({
    required String providerInstanceId,
    required String action,
    String? apiKey,
    DeviceConfig? agent,
  }) async {
    updateCredentialCalls.add({
      'instance': providerInstanceId,
      'action': action,
      'key': apiKey,
    });
    return const CredentialSummaryDto(
      authMethod: 'api_key',
      hasSecret: true,
      status: 'ready',
    );
  }

  @override
  Future<AuthSessionDto> authReconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> authDisconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    if (modelOptionsResult != null) {
      return ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'inst-1',
            displayName: 'OpenAI',
            defaultModel: modelOptionsResult!.selectedModel,
            status: runtimeReady ? 'ready' : 'draft',
            isDefault: true,
            cacheStatus: 'ready',
            models: modelOptionsResult!.models.map((m) => ModelCacheModelDto(id: m)).toList(),
          ),
        ],
        recent: const [],
      );
    }
    return const ModelCacheSnapshotDto(instances: [], recent: []);
  }

  @override
  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  }) async {
    if (modelRefreshCompleter case final completer?) {
      await completer.future;
    }
    if (modelRefreshError case final error?) throw error;
  }

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => const [];

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) async {}

  List<String> _authMethodsForFlow(String flow) {
    switch (flow) {
      case 'device_code':
      case 'external':
      case 'loopback':
        return [flow, 'api_key'];
      case 'custom_endpoint':
        return const ['api_key'];
      default:
        return const ['api_key'];
    }
  }
}

ProviderDto _apiKeyProvider({
  String id = 'openai',
  String flow = 'api_key',
  bool configured = false,
  List<String> models = const ['gpt-4o', 'gpt-4o-mini'],
}) {
  return ProviderDto(
    id: id,
    name: id,
    displayName: id,
    description: 'Test provider',
    authType: 'api_key',
    authFlow: flow,
    apiMode: 'chat_completions',
    supportsModelFetch: false,
    disconnectable: true,
    fallbackModels: models,
    aliases: const [],
    configured: configured,
    authenticated: configured,
    isCurrent: false,
    models: models,
    authStatus: configured ? 'authenticated' : 'missing',
  );
}

void main() {
  group('ProviderSetupCubit', () {
    test(
      'load with not-ready runtime shows picker and populates providers',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [
            _apiKeyProvider(),
            _apiKeyProvider(id: 'anthropic'),
          ],
          runtimeReady: false,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        expect(cubit.state.status, ProviderSetupStatus.picker);
        expect(cubit.state.providers.length, 2);
        expect(cubit.state.readiness?.runtimeReady, false);
        await cubit.close();
      },
    );

    test('load without forcePicker and ready runtime reaches ready', () async {
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider(configured: true)],
        instances: [
          const ProviderInstanceDto(
            id: 'inst-openai',
            templateId: 'openai',
            displayName: 'OpenAI',
            protocol: 'openai_compatible',
            authMethod: 'api_key',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: true,
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: false);
      expect(cubit.state.status, ProviderSetupStatus.ready);
      await cubit.close();
    });

    test(
      'load without forcePicker and existing instances opens configured providers list',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-openai',
              templateId: 'openai',
              displayName: 'OpenAI',
              protocol: 'openai_compatible',
              authMethod: 'api_key',
              status: 'draft',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
            ),
          ],
          runtimeReady: false,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load();
        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        await cubit.close();
      },
    );

    test(
      'load issues templates/instances/readiness in parallel and each exactly once',
      () async {
        final gate = Completer<void>();
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-openai',
              templateId: 'openai',
              displayName: 'OpenAI',
              protocol: 'openai_compatible',
              authMethod: 'api_key',
              status: 'draft',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
            ),
          ],
          runtimeReady: false,
        )..instancesGate = gate;
        final cubit = ProviderSetupCubit(client: fake);

        // Start load. The slowest read (instances) is gated; the other two
        // independent reads must already be in flight while it resolves. This
        // proves parallel overlap without any timing assertion.
        final loading = cubit.load();
        await Future<void>.delayed(Duration.zero);
        expect(fake.maxConcurrentLoadReads, greaterThanOrEqualTo(2));

        // Release the gate; the snapshot only completes after all reads.
        gate.complete();
        await loading;
        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        expect(cubit.state.instances.length, 1);
        // Each independent read is issued exactly once per load: no repeated
        // hydration/DB/credential reads or duplicate requests (plan 97g).
        expect(fake.listTemplatesCalls, 1);
        expect(fake.listInstancesCalls, 1);
        expect(fake.runtimeCheckCalls, 1);
        await cubit.close();
      },
    );

    test(
      'load surfaces error and never emits a partial snapshot when a read fails',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider()],
          runtimeReady: false,
        )..runtimeCheckFailure = StateError('boom');
        final cubit = ProviderSetupCubit(client: fake);
        // The cubit must absorb the failure into the typed error state
        // (never letting a partial snapshot leak), and the returned future
        // must NOT rethrow.
        await expectLater(
          cubit.load(forcePicker: true),
          completes,
        );
        expect(cubit.state.status, ProviderSetupStatus.error);
        expect(cubit.state.error, isNotNull);
        // No partial snapshot: templates/instances must not be populated.
        expect(cubit.state.providers, isEmpty);
        expect(cubit.state.instances, isEmpty);
        await cubit.close();
      },
    );

    test(
      'a read failing while another is still pending is captured, not '
      'an unhandled async error',
      () async {
        // Instances is held open while readiness fails immediately. Every
        // future must have its error handler attached at issue time (record
        // `.wait` [+ _FutureResult._waitAll]) so the mid-flight failure is
        // aggregated into the typed error state. Under a serial await, this
        // error would be delivered with no handler attached and the test
        // framework would report it as unhandled.
        final gate = Completer<void>();
        final fake =
            _FakeProviderSetupClient(
                providers: [_apiKeyProvider()],
                runtimeReady: false,
              )
              ..instancesGate = gate
              ..runtimeCheckFailure = StateError('late boom');
        final cubit = ProviderSetupCubit(client: fake);

        final loading = cubit.load(forcePicker: true);
        await Future<void>.delayed(Duration.zero);
        // Readiness already failed while instances is still gated.
        gate.complete();
        await expectLater(loading, completes);
        expect(cubit.state.status, ProviderSetupStatus.error);
        expect(cubit.state.error, isNotNull);
        expect(cubit.state.instances, isEmpty);
        await cubit.close();
      },
    );

    test(
      'a late-arriving failure is captured after the other reads completed',
      () async {
        // templates/instances resolve normally; readiness only fails when its
        // gate opens, so the failure arrives after the other reads settled.
        final gate = Completer<void>();
        final fake =
            _FakeProviderSetupClient(
                providers: [_apiKeyProvider()],
                runtimeReady: false,
              )
              ..readinessGate = gate
              ..runtimeCheckFailure = StateError('late boom');
        final cubit = ProviderSetupCubit(client: fake);

        final loading = cubit.load(forcePicker: true);
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        await expectLater(loading, completes);
        expect(cubit.state.status, ProviderSetupStatus.error);
        expect(cubit.state.error, isNotNull);
        expect(cubit.state.instances, isEmpty);
        await cubit.close();
      },
    );

    test('selectTemplate routes picker selection into instance form', () async {
      final fake = _FakeProviderSetupClient(providers: [_apiKeyProvider()]);
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(
        const ProviderTemplateDto(
          name: 'openai',
          displayName: 'OpenAI',
          description: '',
          authType: 'api_key',
          authFlow: 'api_key',
          apiMode: 'chat_completions',
          supportsModelFetch: true,
          disconnectable: true,
          fallbackModels: [],
          aliases: [],
          protocol: 'openai_compatible',
          apiKeyRequirement: 'required',
        ),
      );
      expect(cubit.state.status, ProviderSetupStatus.instanceForm);
      expect(cubit.state.selectedTemplate?.name, 'openai');
      await cubit.close();
    });

    test(
      'create api_key instance then saveApiKey routes to modelSelection',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider()],
          modelOptionsResult: ModelOptionsDto(
            providerId: 'openai',
            models: const ['gpt-4o', 'gpt-4o-mini'],
            authenticated: true,
            authType: 'api_key',
            source: 'fallback',
          ),
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'openai',
            displayName: 'OpenAI',
            description: '',
            authType: 'api_key',
            authFlow: 'api_key',
            apiMode: 'chat_completions',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            apiKeyRequirement: 'required',
          ),
        );
        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI Work',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          defaultModel: 'gpt-4o',
        );
        await cubit.saveApiKey(apiKey: 'sk-test');
        expect(cubit.state.status, ProviderSetupStatus.modelSelection);
        expect(cubit.state.modelOptions?.models, ['gpt-4o', 'gpt-4o-mini']);
        expect(
          fake.createInstanceCalls.single['displayName'],
          equals('OpenAI Work'),
        );
        await cubit.close();
      },
    );

    test(
      'confirmModel sets default and reaches ready when runtime ready',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          modelOptionsResult: ModelOptionsDto(
            providerId: 'openai',
            models: const ['gpt-4o'],
            selectedModel: 'gpt-4o',
            authenticated: true,
            authType: 'api_key',
            source: 'fallback',
          ),
          runtimeReady: true,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'openai',
            displayName: 'OpenAI',
            description: '',
            authType: 'api_key',
            authFlow: 'api_key',
            apiMode: 'chat_completions',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            apiKeyRequirement: 'required',
          ),
        );
        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI Work',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          defaultModel: 'gpt-4o',
        );
        await cubit.saveApiKey(apiKey: 'sk-test');
        cubit.selectModel('gpt-4o');
        await cubit.confirmModel();
        expect(cubit.state.status, ProviderSetupStatus.ready);
        await cubit.close();
      },
    );

    test(
      'confirmModel refreshes configured providers list when ready screen is disabled',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          modelOptionsResult: ModelOptionsDto(
            providerId: 'openai',
            models: const ['gpt-4o'],
            selectedModel: 'gpt-4o',
            authenticated: true,
            authType: 'api_key',
            source: 'fallback',
          ),
          runtimeReady: true,
        );
        final cubit = ProviderSetupCubit(client: fake, showReadyState: false);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'openai',
            displayName: 'OpenAI',
            description: '',
            authType: 'api_key',
            authFlow: 'api_key',
            apiMode: 'chat_completions',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            apiKeyRequirement: 'required',
          ),
        );
        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI Work',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          defaultModel: 'gpt-4o',
        );
        await cubit.saveApiKey(apiKey: 'sk-test');
        cubit.selectModel('gpt-4o');
        await cubit.confirmModel();

        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        expect(cubit.state.instances, hasLength(1));
        expect(cubit.state.instances.single.displayName, 'OpenAI Work');
        await cubit.close();
      },
    );

    test(
      'create OAuth instance starts auth with a provider instance id',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(id: 'openai-codex', flow: 'device_code')],
          authSession: const AuthSessionDto(
            sessionId: 's1',
            flow: 'deviceCode',
            userCode: 'ABCDEF',
            verificationUri: 'https://example.com',
            interval: 1,
          ),
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'openai-codex',
            displayName: 'OpenAI Codex',
            description: '',
            authType: 'oauth_device_code',
            authFlow: 'device_code',
            apiMode: 'codex_responses',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            apiKeyRequirement: 'optional',
            authMethods: ['device_code', 'api_key'],
          ),
        );
        await cubit.createOrUpdateInstance(
          displayName: 'Codex Work',
          authMethod: 'device_code',
          protocol: 'openai_compatible',
          defaultModel: 'gpt-4o',
        );
        expect(cubit.state.status, ProviderSetupStatus.deviceCode);
        expect(cubit.state.authSession?.userCode, 'ABCDEF');
        expect(fake.authStartCalls, ['openai-codex']);
        expect(fake.authStartInstanceIds, ['inst-1']);
        await cubit.close();
      },
    );

    test('approved poll advances to modelSelection', () async {
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider(id: 'openai-codex', flow: 'device_code')],
        authSession: const AuthSessionDto(
          sessionId: 's1',
          flow: 'deviceCode',
          userCode: 'ABC',
          interval: 1,
        ),
        authPollResult: const AuthPollDto(
          status: AuthPollStatus.approved,
          authenticated: true,
        ),
        modelOptionsResult: ModelOptionsDto(
          providerId: 'openai-codex',
          models: const ['gpt-4o'],
          authenticated: true,
          authType: 'oauth_external',
          source: 'fallback',
        ),
        runtimeReady: true,
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(
        const ProviderTemplateDto(
          name: 'openai-codex',
          displayName: 'OpenAI Codex',
          description: '',
          authType: 'oauth_device_code',
          authFlow: 'device_code',
          apiMode: 'codex_responses',
          supportsModelFetch: true,
          disconnectable: true,
          fallbackModels: [],
          aliases: [],
          protocol: 'openai_compatible',
          apiKeyRequirement: 'optional',
          authMethods: ['device_code', 'api_key'],
        ),
      );
      await cubit.createOrUpdateInstance(
        displayName: 'Codex Work',
        authMethod: 'device_code',
        protocol: 'openai_compatible',
        defaultModel: 'gpt-4o',
      );
      await cubit.pollOnce();
      expect(cubit.state.status, ProviderSetupStatus.modelSelection);
      expect(fake.createInstanceCalls.length, 1);
      await cubit.close();
    });

    test('a late approved poll cannot revive a cancelled OAuth setup', () async {
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider(id: 'openai-codex', flow: 'device_code')],
        authSession: const AuthSessionDto(
          sessionId: 's1',
          flow: 'deviceCode',
          userCode: 'ABC',
          interval: 30,
        ),
        modelOptionsResult: ModelOptionsDto(
          providerId: 'openai-codex',
          models: const ['gpt-4o'],
          authenticated: true,
          authType: 'oauth_external',
          source: 'live',
        ),
      )..authPollCompleter = Completer<AuthPollDto>();
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(
        const ProviderTemplateDto(
          name: 'openai-codex',
          displayName: 'OpenAI Codex',
          description: '',
          authType: 'oauth_device_code',
          authFlow: 'device_code',
          apiMode: 'codex_responses',
          supportsModelFetch: true,
          disconnectable: true,
          fallbackModels: [],
          aliases: [],
          protocol: 'openai_compatible',
          apiKeyRequirement: 'optional',
          authMethods: ['device_code'],
        ),
      );
      await cubit.createOrUpdateInstance(
        displayName: 'Codex Work',
        authMethod: 'device_code',
        protocol: 'openai_compatible',
      );

      final pendingPoll = cubit.pollOnce();
      await Future<void>.delayed(Duration.zero);
      await cubit.cancelAuth();
      fake.authPollCompleter!.complete(
        const AuthPollDto(
          status: AuthPollStatus.approved,
          authenticated: true,
        ),
      );
      await pendingPoll;

      expect(cubit.state.status, ProviderSetupStatus.picker);
      expect(cubit.state.authSession, isNull);
      expect(cubit.state.selectedInstance, isNull);
      expect(fake.removeInstanceCalls, ['inst-1']);
      await cubit.close();
    });

    test('cancelAuth discards the provisional OAuth instance', () async {
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider(id: 'openai-codex', flow: 'device_code')],
        authSession: const AuthSessionDto(
          sessionId: 's1',
          flow: 'deviceCode',
          userCode: 'ABC',
          interval: 1,
        ),
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(
        const ProviderTemplateDto(
          name: 'openai-codex',
          displayName: 'OpenAI Codex',
          description: '',
          authType: 'oauth_device_code',
          authFlow: 'device_code',
          apiMode: 'codex_responses',
          supportsModelFetch: true,
          disconnectable: true,
          fallbackModels: [],
          aliases: [],
          protocol: 'openai_compatible',
          apiKeyRequirement: 'optional',
          authMethods: ['device_code', 'api_key'],
        ),
      );
      await cubit.createOrUpdateInstance(
        displayName: 'Codex Work',
        authMethod: 'device_code',
        protocol: 'openai_compatible',
        defaultModel: 'gpt-4o',
      );
      await cubit.cancelAuth();
      expect(cubit.state.status, ProviderSetupStatus.picker);
      expect(cubit.state.authSession, isNull);
      expect(fake.removeInstanceCalls, ['inst-1']);
      await cubit.close();
    });

    test('saveCustomEndpoint sends protocol for custom providers', () async {
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider(id: 'custom', flow: 'custom_endpoint')],
        runtimeReady: true,
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(
        const ProviderTemplateDto(
          name: 'custom',
          displayName: 'Custom Provider',
          description: '',
          authType: 'api_key',
          authFlow: 'custom_endpoint',
          apiMode: 'chat_completions',
          supportsModelFetch: true,
          disconnectable: true,
          fallbackModels: [],
          aliases: [],
          protocol: 'openai_compatible',
          apiKeyRequirement: 'optional',
        ),
      );
      await cubit.saveCustomEndpoint(
        protocol: 'anthropic_compatible',
        baseUrl: 'http://localhost:11434',
        model: 'llama3.1',
      );
      expect(cubit.state.status, ProviderSetupStatus.ready);
      expect(
        fake.createInstanceCalls.single['protocol'],
        equals('anthropic_compatible'),
      );
      await cubit.close();
    });

    test(
      'new api-key instance stores the entered key once then opens model selection',
      () async {
        // Task 57 collects the key in provider details and writes it to the
        // newly created provisional instance before model discovery.
        final fake = _FakeProviderSetupClient(providers: [_apiKeyProvider()]);
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'openai',
            displayName: 'OpenAI',
            description: '',
            authType: 'api_key',
            authFlow: 'api_key',
            apiMode: 'chat_completions',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            apiKeyRequirement: 'required',
          ),
        );
        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI Work',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          credentialAction: 'keep',
          newApiKey: 'sk-once',
        );
        expect(cubit.state.status, ProviderSetupStatus.modelSelection);
        expect(fake.createInstanceCalls.single['defaultModel'], isNull);
        expect(fake.updateCredentialCalls, [
          {'instance': 'inst-1', 'action': 'replace', 'key': 'sk-once'},
        ]);
        await cubit.close();
      },
    );

    test('Back then Continue reuses the same provisional instance', () async {
      final fake = _FakeProviderSetupClient(providers: [_apiKeyProvider()]);
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(
        const ProviderTemplateDto(
          name: 'openai',
          displayName: 'OpenAI',
          description: '',
          authType: 'api_key',
          authFlow: 'api_key',
          apiMode: 'chat_completions',
          supportsModelFetch: true,
          disconnectable: true,
          fallbackModels: [],
          aliases: [],
        ),
      );
      cubit.rememberDraft(
        displayName: 'OpenAI Work',
        protocol: 'openai_compatible',
        apiKey: 'sk-local',
        allowAutoFailover: true,
      );

      await cubit.createOrUpdateInstance(
        displayName: 'OpenAI Work',
        authMethod: 'api_key',
        protocol: 'openai_compatible',
        newApiKey: 'sk-local',
      );
      final provisionalId = cubit.state.provisionalInstanceId;
      await cubit.backToProviderDetails();
      await cubit.createOrUpdateInstance(
        displayName: 'OpenAI Work',
        authMethod: 'api_key',
        protocol: 'openai_compatible',
        newApiKey: 'sk-local',
      );

      expect(provisionalId, 'inst-1');
      expect(cubit.state.provisionalInstanceId, provisionalId);
      expect(fake.createInstanceCalls, hasLength(1));
      expect(fake.instances.where((instance) => instance.id == provisionalId), hasLength(1));
      expect(cubit.draftApiKey, 'sk-local');
      await cubit.close();
    });

    test('discard removes only the provisional instance', () async {
      final existing = ProviderInstanceDto(
        id: 'existing',
        templateId: 'openai',
        displayName: 'Existing',
        protocol: 'openai_compatible',
        authMethod: 'api_key',
        status: 'ready',
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
      );
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider()],
        instances: [existing],
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate(cubit.state.templates.single);
      await cubit.createOrUpdateInstance(
        displayName: 'New setup',
        authMethod: 'api_key',
        protocol: 'openai_compatible',
        newApiKey: 'sk-new',
      );

      await cubit.discardProvisionalSetup();

      expect(fake.removeInstanceCalls, ['inst-1']);
      expect(fake.instances.map((instance) => instance.id), ['existing']);
      expect(cubit.state.provisionalInstanceId, isNull);
      await cubit.close();
    });

    test(
      'saveApiKey with empty key for optional template does not call replace',
      () async {
        // Regression (Plan 29 problem 3): an optional template may proceed
        // with an empty key; 'replace' with an empty value must never be sent.
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(id: 'custom', flow: 'custom_endpoint')],
          modelOptionsResult: ModelOptionsDto(
            providerId: 'custom',
            models: const ['llama3.1'],
            selectedModel: 'llama3.1',
            authenticated: true,
            authType: 'api_key',
            source: 'fallback',
          ),
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'custom',
            displayName: 'Custom',
            description: '',
            authType: 'api_key',
            authFlow: 'custom_endpoint',
            apiMode: 'chat_completions',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            apiKeyRequirement: 'optional',
          ),
        );
        // Empty key for optional template.
        await cubit.saveApiKey(apiKey: '');
        // Should reach model selection without sending a credential update.
        expect(fake.updateCredentialCalls, isEmpty);
        expect(cubit.state.status, ProviderSetupStatus.modelSelection);
        await cubit.close();
      },
    );

    test(
      'editing an instance without a stored key can save metadata without sending replace',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-openai',
              templateId: 'openai',
              displayName: 'OpenAI',
              protocol: 'openai_compatible',
              authMethod: 'api_key',
              status: 'draft',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
              credential: CredentialSummaryDto(
                authMethod: 'api_key',
                hasSecret: false,
                status: 'missing',
              ),
            ),
          ],
          runtimeReady: false,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load();
        cubit.selectInstanceForEdit(fake.instances.single);

        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI Renamed',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          defaultModel: 'gpt-4o',
          credentialAction: 'keep',
        );

        expect(fake.updateCredentialCalls, isEmpty);
        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        await cubit.close();
      },
    );

    test(
      'replacing an existing API key verifies the connection before reporting success',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-openai',
              templateId: 'openai',
              displayName: 'OpenAI',
              protocol: 'openai_compatible',
              authMethod: 'api_key',
              defaultModel: 'gpt-4o',
              status: 'ready',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
              credential: CredentialSummaryDto(
                authMethod: 'api_key',
                hasSecret: true,
                status: 'ready',
              ),
            ),
          ],
          runtimeReady: true,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load();
        cubit.selectInstanceForEdit(fake.instances.single);

        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          credentialAction: 'replace',
          newApiKey: 'sk-new',
        );

        expect(fake.updateCredentialCalls.single, {
          'instance': 'inst-openai',
          'action': 'replace',
          'key': 'sk-new',
        });
        expect(fake.testConnectionCalls, ['inst-openai']);
        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        expect(cubit.state.instanceFeedback['inst-openai'], 'Changes saved.');
        await cubit.close();
      },
    );

    test(
      'an authoritative draft after testing keeps an existing API-key edit open',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-openai',
              templateId: 'openai',
              displayName: 'OpenAI',
              protocol: 'openai_compatible',
              authMethod: 'api_key',
              defaultModel: 'gpt-4o',
              status: 'ready',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
            ),
          ],
          runtimeReady: true,
        )..updateInstanceStatus = 'draft';
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load();
        cubit.selectInstanceForEdit(fake.instances.single);

        await cubit.createOrUpdateInstance(
          displayName: 'OpenAI',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          credentialAction: 'replace',
          newApiKey: 'sk-invalid',
        );

        expect(fake.testConnectionCalls, ['inst-openai']);
        expect(cubit.state.status, ProviderSetupStatus.instanceForm);
        expect(
          cubit.state.error,
          'The API key was saved, but its connection could not be verified. Check the key and try again.',
        );
        await cubit.close();
      },
    );

    test(
      'editing an existing OAuth provider does not trigger re-authentication',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(id: 'openai-codex', flow: 'device_code', configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-codex',
              templateId: 'openai-codex',
              displayName: 'Codex Work',
              protocol: 'openai_compatible',
              authMethod: 'device_code',
              defaultModel: 'gpt-4o',
              status: 'ready',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
            ),
          ],
          runtimeReady: true,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load();
        cubit.selectInstanceForEdit(fake.instances.single);

        await cubit.createOrUpdateInstance(
          displayName: 'Codex Renamed',
          authMethod: 'device_code',
          protocol: 'openai_compatible',
          credentialAction: 'keep',
        );

        expect(fake.authStartCalls, isEmpty);
        expect(fake.updateCredentialCalls, isEmpty);
        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        expect(cubit.state.instanceFeedback['inst-codex'], 'Changes saved.');
        await cubit.close();
      },
    );

    test(
      'editing an existing OAuth provider preserves auto-failover without re-authentication',
      () async {
        final fake = _FakeProviderSetupClient(
          providers: [_apiKeyProvider(id: 'openai-codex', flow: 'device_code', configured: true)],
          instances: [
            const ProviderInstanceDto(
              id: 'inst-codex',
              templateId: 'openai-codex',
              displayName: 'Codex Work',
              protocol: 'openai_compatible',
              authMethod: 'device_code',
              defaultModel: 'gpt-4o',
              status: 'ready',
              isDefault: true,
              configRevision: 1,
              credentialRevision: 1,
              allowAutoFailover: false,
            ),
          ],
          runtimeReady: true,
        );
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load();
        cubit.selectInstanceForEdit(fake.instances.single);

        await cubit.createOrUpdateInstance(
          displayName: 'Codex Work',
          authMethod: 'device_code',
          protocol: 'openai_compatible',
          allowAutoFailover: true,
          credentialAction: 'keep',
        );

        expect(fake.authStartCalls, isEmpty);
        expect(
          fake.updateInstanceCalls.last['allowAutoFailover'],
          true,
        );
        expect(cubit.state.status, ProviderSetupStatus.instancesList);
        await cubit.close();
      },
    );

    test(
      'createOrUpdateInstance omits dormant rate-limit and forwards auto-failover',
      () async {
        final fake = _FakeProviderSetupClient(providers: [_apiKeyProvider()]);
        final cubit = ProviderSetupCubit(client: fake);
        await cubit.load(forcePicker: true);
        cubit.selectTemplate(
          const ProviderTemplateDto(
            name: 'nvidia',
            displayName: 'NVIDIA NIM',
            description: '',
            authType: 'api_key',
            authFlow: 'api_key',
            apiMode: 'chat_completions',
            supportsModelFetch: true,
            disconnectable: true,
            fallbackModels: [],
            aliases: [],
            protocol: 'openai_compatible',
            defaultRequestsPerMinute: 38,
          ),
        );

        await cubit.createOrUpdateInstance(
          displayName: 'NVIDIA Work',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          defaultModel: 'llama-3.3',
          allowAutoFailover: false,
        );

        expect(
          fake.createInstanceCalls.single,
          containsPair('requestsPerMinute', isNull),
        );
        expect(
          fake.createInstanceCalls.single,
          containsPair('allowAutoFailover', false),
        );
        await cubit.close();
      },
    );

    test('model discovery failure stays explicit and manual input survives save failure', () async {
      final fake = _FakeProviderSetupClient(
        providers: [
          _apiKeyProvider(models: const ['cached-model']),
        ],
        modelRefreshError: StateError('secret transport detail'),
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate((await fake.listTemplates()).single);

      await cubit.createOrUpdateInstance(
        displayName: 'OpenAI Work',
        authMethod: 'api_key',
        protocol: 'openai_compatible',
        newApiKey: 'sk-test',
      );

      expect(cubit.state.status, ProviderSetupStatus.modelSelection);
      expect(
        cubit.state.modelDiscoveryStatus,
        ModelDiscoveryStatus.failed,
      );
      expect(cubit.state.modelOptions?.source, 'cached_suggestions');
      expect(cubit.state.modelOptions?.models, ['cached-model']);
      expect(cubit.state.modelDiscoveryError, isNot(contains('secret')));

      cubit.startManualModelEntry();
      cubit.selectModel('manual-model');
      fake.updateInstanceError = StateError('save failed');
      await cubit.confirmModel();

      expect(cubit.state.modelDiscoveryStatus, ModelDiscoveryStatus.manual);
      expect(cubit.state.selectedModel, 'manual-model');
      expect(cubit.state.error, 'Could not save the default model.');
      await cubit.close();
    });

    test('a late model refresh cannot reopen selection after Back', () async {
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider()],
        modelOptionsResult: ModelOptionsDto(
          providerId: 'openai',
          models: const ['gpt-4o'],
          authenticated: true,
          authType: 'api_key',
          source: 'live',
        ),
      )..modelRefreshCompleter = Completer<void>();
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load(forcePicker: true);
      cubit.selectTemplate((await fake.listTemplates()).single);

      final pendingCreate = cubit.createOrUpdateInstance(
        displayName: 'OpenAI Work',
        authMethod: 'api_key',
        protocol: 'openai_compatible',
        newApiKey: 'sk-test',
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, ProviderSetupStatus.modelSelection);
      expect(cubit.state.modelDiscoveryStatus, ModelDiscoveryStatus.loading);

      await cubit.backToProviderDetails();
      fake.modelRefreshCompleter!.complete();
      await pendingCreate;

      expect(cubit.state.status, ProviderSetupStatus.instanceForm);
      expect(cubit.state.modelOptions, isNull);
      await cubit.close();
    });

    test('editing metadata never mutates fixed connection settings', () async {
      final instance = const ProviderInstanceDto(
        id: 'inst-openai',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: 'openai_compatible',
        authMethod: 'api_key',
        baseUrl: 'https://saved.example',
        status: 'ready',
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
      );
      final fake = _FakeProviderSetupClient(
        providers: [_apiKeyProvider(configured: true)],
        instances: [instance],
      );
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load();
      cubit.selectInstanceForEdit(instance);

      await cubit.createOrUpdateInstance(
        displayName: 'Renamed',
        authMethod: 'api_key',
        baseUrl: 'https://ignored.example',
        protocol: 'anthropic_compatible',
      );

      expect(fake.updateInstanceCalls.single['displayName'], 'Renamed');
      expect(fake.updateInstanceCalls.single['baseUrl'], isNull);
      expect(fake.updateInstanceCalls.single['protocol'], isNull);
      await cubit.close();
    });

    test('Codex connection test consumes the canonical success flag and keeps the list visible', () async {
      final instance = const ProviderInstanceDto(
        id: 'inst-codex',
        templateId: 'openai-codex',
        displayName: 'Codex',
        protocol: 'openai_compatible',
        authMethod: 'device_code',
        status: 'ready',
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
      );
      final fake = _FakeProviderSetupClient(
        providers: [
          _apiKeyProvider(
            id: 'openai-codex',
            flow: 'device_code',
            configured: true,
          ),
        ],
        instances: [instance],
      )..testConnectionResult = const {'success': true, 'models_count': 4};
      final cubit = ProviderSetupCubit(client: fake);
      await cubit.load();
      await cubit.testInstance(instance.id);

      expect(cubit.state.status, ProviderSetupStatus.instancesList);
      expect(
        cubit.state.instanceFeedback[instance.id],
        'Connection test passed.',
      );
      await cubit.close();
    });

    test('verification launch copy is scoped to the active auth session', () async {
      final cubit = ProviderSetupCubit(client: _FakeProviderSetupClient());
      await cubit.startOAuthAuth(
        templateId: 'openai-codex',
        authMethod: 'device_code',
      );
      cubit.recordVerificationLaunch(sessionId: 'stale', opened: true);
      expect(cubit.state.verificationLaunchAttempted, isFalse);

      cubit.recordVerificationLaunch(sessionId: 's1', opened: false);
      expect(cubit.state.verificationLaunchAttempted, isTrue);
      expect(cubit.state.verificationPageOpened, isFalse);
      expect(cubit.state.verificationLaunchError, isNotNull);

      cubit.recordVerificationLaunch(sessionId: 's1', opened: true);
      expect(cubit.state.verificationPageOpened, isTrue);
      expect(cubit.state.verificationLaunchError, isNull);
      await cubit.close();
    });
  });
}
