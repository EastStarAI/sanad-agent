import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:test/test.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_config_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';

void main() {
  late Directory tempDir;
  late EnvFileService env;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-bridge-provider');
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.registerSingleton<AuthManager>(AuthManager());
    getIt.registerSingleton<SessionManager>(SessionManager());
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
      ),
    );
    getIt.registerSingleton<LocalRuntimeCatalog>(
      LocalRuntimeCatalog(
        workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      ),
    );
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(
        getIt<LocalWorkspaceRuntimeService>(),
        getIt<LocalRuntimeCatalog>(),
      ),
    );

    env = EnvFileService(envPath: '${tempDir.path}/.env');
    final credStore = ProviderCredentialStore(
      storePath: '${tempDir.path}/provider_auth.json',
    );
    getIt.registerSingleton<EnvFileService>(env);
    getIt.registerSingleton<ProviderCredentialStore>(credStore);
    getIt.registerSingleton<ProviderCatalogService>(ProviderCatalogService());
    getIt.registerSingleton<ProviderStateService>(
      ProviderStateService(env, credStore),
    );
    getIt.registerSingleton<ProviderCredentialResolver>(
      ProviderCredentialResolver(env, credStore),
    );
    getIt.registerSingleton<ProviderAuthSessionService>(
      ProviderAuthSessionService(credStore),
    );
    getIt.registerSingleton<ProviderConfigService>(
      ProviderConfigService(env, credStore),
    );
    getIt.registerSingleton<ModelOptionsService>(
      ModelOptionsService(env, getIt<ProviderCredentialResolver>()),
    );
    getIt.registerSingleton<ModelSelectionService>(ModelSelectionService(env));

    // Register Plan 29 database & services
    final db = AgentStateDatabase.inMemory();
    final repo = ProviderInstanceRepository.fromDatabase(db.db);
    final secretStore = SecureFileSecretStore();
    final credService = ProviderCredentialService(repo, secretStore);
    final instanceService = ProviderInstanceService(repo);
    final configObj = Config();

    getIt.registerSingleton<AgentStateDatabase>(db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<SecretStore>(secretStore);
    getIt.registerSingleton<ProviderCredentialService>(credService);
    getIt.registerSingleton<ProviderInstanceService>(instanceService);
    getIt.registerSingleton<Config>(configObj);

    getIt.registerSingleton<ProviderReadinessService>(
      ProviderReadinessService(
        getIt<ProviderInstanceRepository>(),
        getIt<SecretStore>(),
      ),
    );

    final runtimeService = AgentRuntimeService(
      configObj,
      repo,
      credentialResolver: getIt<ProviderCredentialResolver>(),
      credService: credService,
    );
    getIt.registerSingleton<AgentRuntimeService>(runtimeService);

    final cacheService = ProviderModelCacheService(repo, runtimeService);
    getIt.registerSingleton<ProviderModelCacheService>(cacheService);
    final recentService = RecentModelSelectionService(repo);
    getIt.registerSingleton<RecentModelSelectionService>(recentService);
    // Phase H §2: history snapshot must surface runtime_notice + queue.
    getIt.registerSingleton<ProviderRateLimiter>(ProviderRateLimiter());
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(
        getIt<ProviderInstanceRepository>(),
        getIt<ProviderRateLimiter>(),
      ),
    );
    getIt.registerSingleton<SessionRunOrchestrator>(SessionRunOrchestrator());
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
    await getIt.reset();
  });

  Future<Map<String, dynamic>> sendCommand(
    String command, {
    Map<String, dynamic> payload = const {},
  }) async {
    final bridge = getIt<SanadProtocolBridge>();
    Map<String, dynamic>? captured;
    await bridge.handleCommand(
      {
        'command': command,
        'payload': payload,
        'device_id': 'test-device',
        'hardware_id': 'test-hw',
      },
      (envelope) async {
        // Capture only the first command-result envelope.
        captured ??= envelope;
      },
    );
    return captured ?? {};
  }

  test('provider.templates.list returns catalog templates', () async {
    final envelope = await sendCommand(
      'provider.templates.list',
      payload: {'request_id': 'req-1'},
    );
    expect(
      envelope['event'],
      equals(CanonicalEventTypes.providerTemplatesResult),
    );
    expect(envelope['request_id'], equals('req-1'));
    final payload = envelope['payload'] as Map<String, dynamic>;
    final templates = payload['templates'] as List;
    expect(templates, isNotEmpty);
    expect(
      templates.any((t) => (t as Map<String, dynamic>)['name'] == 'openai'),
      isTrue,
    );
    expect(
      templates.any((t) => (t as Map<String, dynamic>)['name'] == 'xai-oauth'),
      isFalse,
    );
  });

  test('provider.instance.create creates a draft instance', () async {
    final envelope = await sendCommand(
      'provider.instance.create',
      payload: {
        'request_id': 'req-2',
        'template_id': 'openai',
        'display_name': 'OpenAI Work',
        'auth_method': 'api_key',
      },
    );
    expect(
      envelope['event'],
      equals(CanonicalEventTypes.providerInstanceCreated),
    );
    final payload = envelope['payload'] as Map<String, dynamic>;
    final instance = payload['instance'] as Map<String, dynamic>;
    expect(instance['display_name'], equals('OpenAI Work'));
    expect(instance['status'], equals(InstanceStatus.draft));
    final repo = getIt<ProviderInstanceRepository>();
    final instances = repo.findByTemplate('openai');
    expect(instances.isNotEmpty, isTrue);
  });

  test(
    'provider.instance.create returns an error envelope for duplicate display names',
    () async {
      final repo = getIt<ProviderInstanceRepository>();
      repo.createInstance(
        ProviderInstance(
          id: 'existing-inst',
          templateId: 'openai-codex',
          displayName: 'ChatGPT Plus Subscription',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.deviceCode,
          status: InstanceStatus.ready,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final envelope = await sendCommand(
        'provider.instance.create',
        payload: {
          'request_id': 'req-dup',
          'template_id': 'openai-codex',
          'display_name': 'ChatGPT Plus Subscription',
          'auth_method': 'device_code',
        },
      );
      expect(
        envelope['event'],
        equals(CanonicalEventTypes.providerInstanceCreated),
      );
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(
        payload['error'],
        contains('Display name "ChatGPT Plus Subscription" is already in use.'),
      );
    },
  );

  test('provider.auth.start rejects requests without instance UUID', () async {
    final envelope = await sendCommand(
      'provider.auth.start',
      payload: {
        'request_id': 'req-auth-no-instance',
        'provider_id': 'openai-codex',
        'template_id': 'openai-codex',
        'auth_method': 'device_code',
      },
    );
    expect(envelope['event'], equals(CanonicalEventTypes.providerAuthStarted));
    final payload = envelope['payload'] as Map<String, dynamic>;
    expect(payload['error'], contains('provider_instance_id is required'));
  });

  test('model.options returns model list for a provider', () async {
    File('${tempDir.path}/.env').writeAsStringSync('''
ACTIVE_PROVIDER=openrouter
OPENROUTER_API_KEY=sk-or-test
''');

    final envelope = await sendCommand(
      'model.options',
      payload: {'request_id': 'req-4', 'provider_id': 'openrouter'},
    );
    expect(envelope['event'], equals(CanonicalEventTypes.modelOptionsResult));
    final payload = envelope['payload'] as Map<String, dynamic>;
    final options = payload['options'] as List;
    expect(options, isNotEmpty);
    final first = options.first as Map<String, dynamic>;
    expect(first['provider_id'], equals('openrouter'));
    expect(first['models'], isA<List>());
  });

  test(
    'model.refresh emits failed after started for a refresh error',
    () async {
      final bridge = getIt<SanadProtocolBridge>();
      final terminal = Completer<Map<String, dynamic>>();
      final statuses = <String>[];

      await bridge.handleCommand(
        {
          'command': 'model.refresh',
          'payload': {
            'request_id': 'req-refresh-failed',
            'provider_instance_id': 'missing-instance',
            'manual': true,
          },
          'device_id': 'test-device',
          'hardware_id': 'test-hw',
        },
        (envelope) async {
          final payload = (envelope['payload'] as Map).cast<String, dynamic>();
          final status = payload['status']?.toString();
          if (status == null) return;
          statuses.add(status);
          if (status == 'failed' && !terminal.isCompleted) {
            terminal.complete(payload);
          }
        },
      );

      final failed = await terminal.future.timeout(const Duration(seconds: 1));
      expect(statuses, equals(['started', 'failed']));
      expect(failed['request_id'], equals('req-refresh-failed'));
      expect(failed['error'], contains('Instance not found'));
    },
  );

  test('provider.runtime_check returns readiness with request_id', () async {
    final repo = getIt<ProviderInstanceRepository>();
    final secretStore = getIt<SecretStore>();
    repo.createInstance(
      ProviderInstance(
        id: 'openrouter-inst',
        templateId: 'openrouter',
        displayName: 'OpenRouter',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'mistralai/mistral-large-2512',
        status: InstanceStatus.ready,
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await secretStore.write(
      'openrouter-inst',
      SecretRecord(
        instanceId: 'openrouter-inst',
        apiKey: 'sk-or-test',
        authMethod: ProviderAuthMethod.apiKey,
      ),
    );

    final envelope = await sendCommand(
      'provider.runtime_check',
      payload: {'request_id': 'req-6'},
    );
    expect(
      envelope['event'],
      equals(CanonicalEventTypes.providerReadinessResult),
    );
    expect(envelope['request_id'], equals('req-6'));
    final payload = envelope['payload'] as Map<String, dynamic>;
    expect(payload['runtime_ready'], isTrue);
    expect(payload['active_provider'], equals('openrouter-inst'));
  });

  test(
    'model.snapshot includes instance status for runtime-ready UI',
    () async {
      final repo = getIt<ProviderInstanceRepository>();
      repo.createInstance(
        ProviderInstance(
          id: 'openai-inst',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gpt-4o',
          status: InstanceStatus.draft,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'openai-inst',
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o', 'label': 'GPT-4o'},
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final envelope = await sendCommand(
        'model.snapshot',
        payload: {'request_id': 'req-7'},
      );
      expect(
        envelope['event'],
        equals(CanonicalEventTypes.modelSnapshotResult),
      );
      final payload = envelope['payload'] as Map<String, dynamic>;
      final instances = payload['instances'] as List;
      final openai = instances.cast<Map<String, dynamic>>().firstWhere(
        (i) => i['id'] == 'openai-inst',
      );
      expect(openai['status'], equals(InstanceStatus.draft));
    },
  );

  test(
    'model.snapshot and model.recent.list normalize provider-prefixed model ids',
    () async {
      final repo = getIt<ProviderInstanceRepository>();
      repo.createInstance(
        ProviderInstance(
          id: 'gemini-inst',
          templateId: 'gemini',
          displayName: 'Gemini',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gemini/models/gemma-4-31b-it',
          status: InstanceStatus.ready,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'gemini-inst',
        cacheKey: 'models',
        models: const [
          {'value': 'gemini/models/gemma-4-31b-it', 'label': 'Gemma 4 31b It'},
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final recentService = getIt<RecentModelSelectionService>();
      recentService.selectModel(
        instanceId: 'gemini-inst',
        modelId: 'gemini/models/gemma-4-31b-it',
      );

      final snapshotEnvelope = await sendCommand(
        'model.snapshot',
        payload: {'request_id': 'req-7b'},
      );
      final snapshotPayload =
          snapshotEnvelope['payload'] as Map<String, dynamic>;
      final instances = snapshotPayload['instances'] as List;
      final gemini = instances.cast<Map<String, dynamic>>().firstWhere(
        (i) => i['id'] == 'gemini-inst',
      );
      expect(gemini['default_model'], equals('gemma-4-31b-it'));
      final models = gemini['models'] as List;
      expect(
        (models.first as Map<String, dynamic>)['value'],
        equals('gemma-4-31b-it'),
      );

      final recentEnvelope = await sendCommand(
        'model.recent.list',
        payload: {'request_id': 'req-7c'},
      );
      final recentPayload = recentEnvelope['payload'] as Map<String, dynamic>;
      final recent = recentPayload['recent'] as List;
      expect(
        (recent.first as Map<String, dynamic>)['model_id'],
        equals('gemma-4-31b-it'),
      );
    },
  );

  test(
    'provider.instance.test returns success: false and details if connection fails or falls back',
    () async {
      final repo = getIt<ProviderInstanceRepository>();

      await getIt.unregister<AgentRuntimeService>();
      await getIt.unregister<ProviderModelCacheService>();

      final mockAdapter = _MockTestAdapter(
        getIt<Config>(),
        ProviderRegistry.findByNameOrAlias('openai')!,
        () async {
          throw const SocketException('Connection refused');
        },
      );
      mockAdapter.setAvailableModelsSource('fallback');
      mockAdapter.setLastModelsException(
        const SocketException('Connection refused'),
      );

      final runtimeService = _TestRuntimeService(
        getIt<Config>(),
        repo,
        (sig) => mockAdapter,
        credentialResolver: getIt<ProviderCredentialResolver>(),
        credService: getIt<ProviderCredentialService>(),
      );
      getIt.registerSingleton<AgentRuntimeService>(runtimeService);

      final cacheService = ProviderModelCacheService(repo, runtimeService);
      getIt.registerSingleton<ProviderModelCacheService>(cacheService);

      repo.createInstance(
        ProviderInstance(
          id: 'test-fail-inst',
          templateId: 'openai',
          displayName: 'Test Fail',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      repo.upsertModelCache(
        instanceId: 'test-fail-inst',
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o', 'label': 'GPT-4o'},
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final envelope = await sendCommand(
        'provider.instance.test',
        payload: {
          'request_id': 'req-test-fail',
          'provider_instance_id': 'test-fail-inst',
        },
      );

      expect(
        envelope['event'],
        equals(CanonicalEventTypes.providerInstanceTestResult),
      );
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(payload['success'], isFalse);
      expect(payload['error'], contains('Connection refused'));
    },
  );

  test(
    'provider.instance.test returns success: true when cache source is live',
    () async {
      final repo = getIt<ProviderInstanceRepository>();

      await getIt.unregister<AgentRuntimeService>();
      await getIt.unregister<ProviderModelCacheService>();

      final mockAdapter = _MockTestAdapter(
        getIt<Config>(),
        ProviderRegistry.findByNameOrAlias('openai')!,
        () async {
          return [ModelOption(value: 'gpt-4o', label: 'GPT-4o')];
        },
      );
      mockAdapter.setAvailableModelsSource('live');

      final runtimeService = _TestRuntimeService(
        getIt<Config>(),
        repo,
        (sig) => mockAdapter,
        credentialResolver: getIt<ProviderCredentialResolver>(),
        credService: getIt<ProviderCredentialService>(),
      );
      getIt.registerSingleton<AgentRuntimeService>(runtimeService);

      final cacheService = ProviderModelCacheService(repo, runtimeService);
      getIt.registerSingleton<ProviderModelCacheService>(cacheService);

      repo.createInstance(
        ProviderInstance(
          id: 'test-success-inst',
          templateId: 'openai',
          displayName: 'Test Success',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final envelope = await sendCommand(
        'provider.instance.test',
        payload: {
          'request_id': 'req-test-success',
          'provider_instance_id': 'test-success-inst',
        },
      );

      expect(
        envelope['event'],
        equals(CanonicalEventTypes.providerInstanceTestResult),
      );
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(payload['success'], isTrue);
    },
  );

  test('provider.instance.set_default rejects draft instances', () async {
    final repo = getIt<ProviderInstanceRepository>();
    repo.createInstance(
      ProviderInstance(
        id: 'draft-inst',
        templateId: 'openai',
        displayName: 'OpenAI Draft',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o',
        status: InstanceStatus.draft,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    await expectLater(
      () => sendCommand(
        'provider.instance.set_default',
        payload: {
          'request_id': 'req-default-draft',
          'provider_instance_id': 'draft-inst',
        },
      ),
      throwsStateError,
    );
  });

  // ── Plan 30 Phase H §2: history snapshot surfaces runtime_notice + queue ─
  test(
    'get_session_history includes the active runtime_notice and queued_messages (Phase H §2)',
    () async {
      final sessionManager = getIt<SessionManager>();
      final recovery = getIt<RuntimeRecoveryService>();

      // Create a session with a completed message so history is non-empty.
      final session = sessionManager.createSession('gpt-4o');
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(role: MessageRole.user, content: 'hello'),
        Message(role: MessageRole.assistant, content: 'hi there'),
      ]);

      // Inject an active recovery notice via the recovery service (same
      // in-memory source of truth the daemon uses).
      recovery.reportRateLimitWait(
        sessionId: session.sessionId,
        providerInstanceId: 'inst-1',
        retryAfter: const Duration(seconds: 30),
        limit: 38,
        requestId: 'req-active',
      );

      final envelope = await sendCommand(
        'get_session_history',
        payload: {
          'request_id': 'req-history-1',
          'session_id': session.sessionId,
        },
      );
      final payload = envelope['payload'] as Map<String, dynamic>;

      // The notice must be present alongside the messages.
      expect(payload.containsKey('runtime_notice'), isTrue);
      final notice = payload['runtime_notice'] as Map<String, dynamic>;
      expect(notice['status'], equals('waiting'));
      expect(notice['reason'], equals('rate_limit'));
      expect(notice['session_id'], equals(session.sessionId));
      expect(notice['limit']['requests_per_minute'], equals(38));

      // A new client fetching the same history sees the same notice as long
      // as the daemon (here: the in-memory recovery service) is still running.
      final envelope2 = await sendCommand(
        'get_session_history',
        payload: {
          'request_id': 'req-history-2',
          'session_id': session.sessionId,
        },
      );
      final payload2 = envelope2['payload'] as Map<String, dynamic>;
      expect(payload2.containsKey('runtime_notice'), isTrue);
      expect(
        (payload2['runtime_notice'] as Map<String, dynamic>)['status'],
        equals('waiting'),
      );

      // After clearing the notice, history no longer carries it.
      recovery.clear(session.sessionId, emit: false);
      final envelope3 = await sendCommand(
        'get_session_history',
        payload: {
          'request_id': 'req-history-3',
          'session_id': session.sessionId,
        },
      );
      final payload3 = envelope3['payload'] as Map<String, dynamic>;
      expect(payload3.containsKey('runtime_notice'), isFalse);
    },
  );

  test(
    'Gate B: get_session_history does NOT return persisted waiting notice if not active in-memory',
    () async {
      final sessionManager = getIt<SessionManager>();
      final db = getIt<AgentStateDatabase>();
      final repo = PersistedRuntimeStateRepository(db.db);
      getIt.registerSingleton<PersistedRuntimeStateRepository>(repo);
      addTearDown(() => getIt.unregister<PersistedRuntimeStateRepository>());

      final session = sessionManager.createSession('gpt-4o');
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(role: MessageRole.user, content: 'hello'),
      ]);

      // Save a notice directly to the repository (simulating old data from before restart).
      repo.upsertNotice(
        sessionId: session.sessionId,
        status: 'waiting',
        reason: 'rate_limit',
        title: 'Old Rate Limit',
        message: 'This is old data',
      );

      final envelope = await sendCommand(
        'get_session_history',
        payload: {
          'request_id': 'req-history-q',
          'session_id': session.sessionId,
        },
      );
      final payload = envelope['payload'] as Map<String, dynamic>;

      // Waiting notices stay runtime-owned and must not be surfaced from
      // durable storage alone.
      expect(payload.containsKey('runtime_notice'), isFalse);
    },
  );

  test(
    'Gate B: get_session_history returns persisted blocked notice lazily when it is not active in-memory',
    () async {
      final sessionManager = getIt<SessionManager>();
      final db = getIt<AgentStateDatabase>();
      final repo = PersistedRuntimeStateRepository(db.db);
      getIt.registerSingleton<PersistedRuntimeStateRepository>(repo);
      addTearDown(() => getIt.unregister<PersistedRuntimeStateRepository>());

      final session = sessionManager.createSession('gpt-4o');
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(role: MessageRole.user, content: 'hello'),
      ]);

      repo.upsertNotice(
        sessionId: session.sessionId,
        status: 'blocked',
        reason: 'unknown',
        title: 'Needs input',
        message: 'blocked from previous run',
        actions: ['stop'],
      );

      final envelope = await sendCommand(
        'get_session_history',
        payload: {
          'request_id': 'req-history-blocked',
          'session_id': session.sessionId,
        },
      );
      final payload = envelope['payload'] as Map<String, dynamic>;

      expect(payload['runtime_notice'], isNotNull);
      final notice = payload['runtime_notice'] as Map<String, dynamic>;
      expect(notice['status'], equals('blocked'));
      expect(notice['actions'], contains('stop'));
      expect(notice['actions'], contains('retry'));
      expect(notice['actions'], contains('changeProvider'));
    },
  );

  // ── Plan 30 Phase H: Additional Verification Tests ──
  group('Plan 30 Phase H — Session Recovery & Stop Corrections', () {
    test(
      'user route confirmation is authoritative and targets every sanad client',
      () async {
        final state = getIt<AgentStateDatabase>();
        final sessionManager = getIt<SessionManager>();
        final repo = getIt<ProviderInstanceRepository>();
        final session = sessionManager.createSession('old-model');
        sessionManager.updateSessionProviderId(session.sessionId, 'provider-a');
        state.db.execute(
          '''
          INSERT INTO sessions (
            session_id, model, provider_id, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?)
          ''',
          [
            session.sessionId,
            'old-model',
            'provider-a',
            DateTime.now().toUtc().toIso8601String(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
        final transitionRepository = SessionRouteTransitionRepository(state);
        final coordinator = SessionRouteMutationCoordinator(
          state: state,
          workItems: SessionWorkItemRepository(state),
          transitions: transitionRepository,
          providerInstances: repo,
        );
        getIt.registerSingleton<SessionRouteTransitionRepository>(
          transitionRepository,
        );
        getIt.registerSingleton<SessionRouteMutationCoordinator>(coordinator);

        final envelopes = <Map<String, dynamic>>[];
        await getIt<SanadProtocolBridge>().handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionPreferences,
            sessionId: session.sessionId,
            payload: {
              'request_id': 'request-user-route',
              'provider_instance_id': 'provider-b',
              'model': 'exact-model',
            },
          ),
          (envelope) async => envelopes.add(envelope),
        );

        final envelope = envelopes.single;
        expect(
          envelope['event'],
          CanonicalEventTypes.sessionPreferencesUpdated,
        );
        expect(envelope['delivery'], {
          'scope': 'platform_family',
          'platform_family': 'sanad_client',
        });
        expect(envelope['payload'], containsPair('source', 'user'));
        expect(
          envelope['payload'],
          containsPair('previous_provider_instance_id', 'provider-a'),
        );
        expect(
          envelope['payload'],
          containsPair('provider_instance_id', 'provider-b'),
        );
        expect(envelope['payload'], containsPair('model', 'exact-model'));
        expect(envelope['payload'], containsPair('route_revision', 2));
        expect(envelope['payload'], contains('updated_at'));
        expect(
          transitionRepository.findForSession(session.sessionId),
          hasLength(1),
        );

        final autoTransition = coordinator.mutate(
          sessionId: session.sessionId,
          providerInstanceId: 'provider-c',
          model: 'exact-model',
          source: SessionRouteSource.autoFailover,
          reason: 'rate_limit',
          requestId: 'request-user-route',
        );
        final historyEnvelopes = <Map<String, dynamic>>[];
        await getIt<SanadProtocolBridge>().handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: session.sessionId,
            payload: const {'request_id': 'history-after-failover'},
          ),
          (historyEnvelope) async => historyEnvelopes.add(historyEnvelope),
        );
        final historyPayload =
            historyEnvelopes.single['payload'] as Map<String, dynamic>;
        final historyRows = (historyPayload['messages'] as List)
            .cast<Map<String, dynamic>>();
        final informational = historyRows.singleWhere(
          (item) => item['type'] == 'session_route_transition',
        );
        expect(informational['event_id'], autoTransition.eventId);
        expect(informational['route_revision'], autoTransition.routeRevision);
        expect(informational['content'], contains('Switched automatically'));
        // The session has no messages carrying the transition request_id, so
        // the notice falls back to real-time ordering (appended last here).
        final anchoredIndex = historyRows.indexWhere(
          (item) => item['type'] == 'session_route_transition',
        );
        expect(anchoredIndex, historyRows.length - 1);
      },
    );

    test(
      'auto-failover history notice snapshots provider display names and position',
      () async {
        final state = getIt<AgentStateDatabase>();
        final sessionManager = getIt<SessionManager>();
        final repo = getIt<ProviderInstanceRepository>();
        final oldInstance = ProviderInstance(
          id: 'failover-old',
          templateId: 'openai',
          displayName: 'Old Provider',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          status: InstanceStatus.ready,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final newInstance = ProviderInstance(
          id: 'failover-new',
          templateId: 'openai',
          displayName: 'New Provider',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          status: InstanceStatus.ready,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(oldInstance);
        repo.createInstance(newInstance);
        final transitionRepository = SessionRouteTransitionRepository(state);
        final coordinator = SessionRouteMutationCoordinator(
          state: state,
          workItems: SessionWorkItemRepository(state),
          transitions: transitionRepository,
          providerInstances: repo,
        );
        getIt.registerSingleton<SessionRouteTransitionRepository>(
          transitionRepository,
        );
        getIt.registerSingleton<SessionRouteMutationCoordinator>(coordinator);

        // Seed the session through the same SessionManager the history
        // handler reads from, then persist its row + provider onto the test
        // state DB so the coordinator (bound to `state`) sees it too.
        const failingRequestId = 'request-failover-anchor';
        final session = sessionManager.createSession('old-model');
        final sessionId = session.sessionId;
        sessionManager.saveSessionHistory(sessionId, [
          Message(
            role: MessageRole.user,
            content: 'first user message',
            metadata: {'request_id': failingRequestId},
          ),
          Message(role: MessageRole.user, content: 'second user message'),
        ]);
        sessionManager.updateSessionModeling(
          sessionId,
          providerId: oldInstance.id,
          model: 'old-model',
        );
        state.db.execute(
          '''
          INSERT INTO sessions (
            session_id, model, provider_id, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?)
          ''',
          [
            sessionId,
            'old-model',
            oldInstance.id,
            DateTime.now().toUtc().toIso8601String(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );

        coordinator.mutate(
          sessionId: sessionId,
          providerInstanceId: newInstance.id,
          model: 'new-model',
          source: SessionRouteSource.autoFailover,
          reason: 'rate_limit',
          requestId: failingRequestId,
        );

        final historyEnvelopes = <Map<String, dynamic>>[];
        await getIt<SanadProtocolBridge>().handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: const {'request_id': 'history-display-names'},
          ),
          (historyEnvelope) async => historyEnvelopes.add(historyEnvelope),
        );
        final historyPayload =
            historyEnvelopes.single['payload'] as Map<String, dynamic>;
        final historyRows = (historyPayload['messages'] as List)
            .cast<Map<String, dynamic>>();
        final transitionIndex = historyRows.indexWhere(
          (item) => item['type'] == 'session_route_transition',
        );
        expect(transitionIndex, isNot(-1));
        final informational = historyRows[transitionIndex];

        // Display names are snapshotted at write time — never raw UUIDs.
        expect(informational['content'], contains('Old Provider'));
        expect(informational['content'], contains('New Provider'));
        expect(informational['content'], contains('because rate limit'));
        expect(informational['content'], isNot(contains('rate_limit')));
        expect(informational['content'], isNot(contains(oldInstance.id)));
        expect(informational['content'], isNot(contains(newInstance.id)));
        expect(informational['previous_provider_display_name'], 'Old Provider');
        expect(informational['provider_display_name'], 'New Provider');

        // The notice sits immediately after the user message that owns the
        // failing request, before any later message.
        final anchorIndex = historyRows.indexWhere(
          (item) => item['request_id'] == failingRequestId,
        );
        expect(anchorIndex, isNot(-1));
        expect(transitionIndex, anchorIndex + 1);
        expect(
          historyRows[transitionIndex + 1]['content'],
          'second user message',
        );
      },
    );

    test(
      'continue_with_provider emits a canonical session_preferences_updated route confirmation for all sanad clients',
      () async {
        final sessionManager = getIt<SessionManager>();
        final repo = getIt<ProviderInstanceRepository>();
        final bridge = getIt<SanadProtocolBridge>();
        final session = sessionManager.createSession('old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'old-provider',
          model: 'old-model',
        );

        repo.createInstance(
          ProviderInstance(
            id: 'confirmed-provider',
            templateId: 'openai',
            displayName: 'Confirmed Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'confirmed-model',
            status: InstanceStatus.ready,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final envelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.sessionRuntimeContinueWithProvider,
            sessionId: session.sessionId,
            payload: {
              'request_id': 'req-confirm-route',
              'provider_instance_id': 'confirmed-provider',
              'model_id': 'confirmed-model',
            },
          ),
          (envelope) async {
            envelopes.add(envelope);
          },
        );

        final confirmedEnvelope = envelopes.firstWhere(
          (envelope) =>
              envelope['event'] ==
              CanonicalEventTypes.sessionPreferencesUpdated,
        );
        expect(confirmedEnvelope['payload']['session_id'], session.sessionId);
        expect(
          confirmedEnvelope['payload']['provider_instance_id'],
          'confirmed-provider',
        );
        expect(
          confirmedEnvelope['payload']['model_provider'],
          'confirmed-provider',
        );
        expect(confirmedEnvelope['payload']['model'], 'confirmed-model');
        expect(confirmedEnvelope['payload']['request_id'], 'req-confirm-route');
        expect(confirmedEnvelope['delivery'], {
          'scope': 'platform_family',
          'platform_family': 'sanad_client',
        });
      },
    );

    test(
      'session.runtime_stop is idempotent and broadcasts notice clearance',
      () async {
        final sessionManager = getIt<SessionManager>();
        final recovery = getIt<RuntimeRecoveryService>();
        final session = sessionManager.createSession('gpt-4o');

        // 1. Inject an active notice
        recovery.reportRateLimitWait(
          sessionId: session.sessionId,
          providerInstanceId: 'inst-1',
          retryAfter: const Duration(seconds: 30),
        );
        expect(recovery.hasActiveNotice(session.sessionId), isTrue);

        // 2. Call stop command
        await sendCommand(
          'session.runtime_stop',
          payload: {
            'request_id': 'req-stop-1',
            'session_id': session.sessionId,
          },
        );
        // Verify stop was processed and active notice is cleared
        expect(recovery.hasActiveNotice(session.sessionId), isFalse);
        expect(recovery.isStopped(session.sessionId), isTrue);

        // 3. Call stop command again (idempotency check)
        await sendCommand(
          'session.runtime_stop',
          payload: {
            'request_id': 'req-stop-2',
            'session_id': session.sessionId,
          },
        );
        expect(recovery.hasActiveNotice(session.sessionId), isFalse);
      },
    );

    test('atomic route preference updates on provider/model override', () async {
      final sessionManager = getIt<SessionManager>();
      final repo = getIt<ProviderInstanceRepository>();
      final session = sessionManager.createSession('gpt-4o');

      // Create a test provider instance with a default model
      final testInst = ProviderInstance(
        id: 'test-inst-uuid',
        templateId: 'openai',
        displayName: 'Test OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o-mini',
        status: InstanceStatus.ready,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(testInst);

      // Call continue_with_provider with both provider and model
      await sendCommand(
        'session.runtime_continue_with_provider',
        payload: {
          'request_id': 'req-continue-1',
          'session_id': session.sessionId,
          'provider_instance_id': 'test-inst-uuid',
          'model_id': 'gpt-4-turbo',
        },
      );

      // Verify the session database preferences were updated atomically
      final updatedSession = sessionManager.getSession(session.sessionId);
      expect(updatedSession?.providerId, equals('test-inst-uuid'));
      expect(updatedSession?.model, equals('gpt-4-turbo'));

      // Create a second test provider instance with a default model
      final testInst2 = ProviderInstance(
        id: 'test-inst-uuid-2',
        templateId: 'openai',
        displayName: 'Test OpenAI 2',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o-mini-2',
        status: InstanceStatus.ready,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(testInst2);

      // Call continue_with_provider with only provider_instance_id (old client compatibility)
      await sendCommand(
        'session.runtime_continue_with_provider',
        payload: {
          'request_id': 'req-continue-2',
          'session_id': session.sessionId,
          'provider_instance_id': 'test-inst-uuid-2',
          // no model_id
        },
      );
      final updatedSession2 = sessionManager.getSession(session.sessionId);
      expect(updatedSession2?.providerId, equals('test-inst-uuid-2'));
      // Must resolve the new provider's default model without guessing
      expect(updatedSession2?.model, equals('gpt-4o-mini-2'));
    });

    test(
      'continue_with_provider does not overwrite session route when provider has no default model',
      () async {
        final sessionManager = getIt<SessionManager>();
        final repo = getIt<ProviderInstanceRepository>();
        final recovery = getIt<RuntimeRecoveryService>();
        final session = sessionManager.createSession('gpt-4o');
        sessionManager.updateSessionProviderId(session.sessionId, 'inst-1');

        repo.createInstance(
          ProviderInstance(
            id: 'no-default-model',
            templateId: 'openai',
            displayName: 'No Default',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: '',
            status: InstanceStatus.ready,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        await sendCommand(
          'session.runtime_continue_with_provider',
          payload: {
            'request_id': 'req-continue-no-default',
            'session_id': session.sessionId,
            'provider_instance_id': 'no-default-model',
          },
        );

        final updatedSession = sessionManager.getSession(session.sessionId);
        expect(updatedSession?.providerId, equals('inst-1'));
        expect(updatedSession?.model, equals('gpt-4o'));

        final notice = recovery.activeNotice(session.sessionId);
        expect(notice, isNotNull);
        expect(notice!.reason, equals(RuntimeFailureReason.modelNotFound));
        expect(notice.message, contains('Please choose a model'));
      },
    );

    test(
      'session.runtime_retry switches an active waiting run to the new provider/model',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final adapter = _RetryThenSucceedAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        repo.createInstance(
          ProviderInstance(
            id: 'old-provider',
            templateId: 'openai',
            displayName: 'Old Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'old-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'new-provider',
            templateId: 'openai',
            displayName: 'New Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'new-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final session = sessionManager.createSession('old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'old-provider',
          model: 'old-model',
        );

        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'First request'),
            turnRequest: const AgentTurnRequest(
              sessionId: 'ignored',
              message: 'First request',
              providerInstanceId: 'old-provider',
              providerId: 'old-provider',
              model: 'old-model',
              requestId: 'req-old',
            ),
          ),
        );

        await adapter.firstFailure.future;
        await _waitUntil(() {
          final notice = getIt<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          return notice?.status.name == 'waiting';
        });

        await sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-retry-new',
            'session_id': session.sessionId,
            'provider_instance_id': 'new-provider',
            'model_id': 'new-model',
          },
        );

        await running;

        expect(
          runtime.routes,
          containsAllInOrder([
            ('old-provider', 'old-model'),
            ('new-provider', 'new-model'),
          ]),
        );
        expect(adapter.modelOverrides, equals(['old-model', 'new-model']));
      },
    );

    test(
      'continue_with_provider switches an active waiting run to the selected route',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final adapter = _WaitingRetryThenHangAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        for (final route in const [
          ('waiting-old-provider', 'waiting-old-model', 'Waiting Old'),
          ('waiting-new-provider', 'waiting-new-model', 'Waiting New'),
        ]) {
          repo.createInstance(
            ProviderInstance(
              id: route.$1,
              templateId: 'openai',
              displayName: route.$3,
              protocol: ProviderProtocol.openaiCompatible,
              authMethod: ProviderAuthMethod.apiKey,
              defaultModel: route.$2,
              status: InstanceStatus.ready,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        final session = sessionManager.createSession('waiting-old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'waiting-old-provider',
          model: 'waiting-old-model',
        );
        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'switch my wait'),
            turnRequest: AgentTurnRequest(
              sessionId: session.sessionId,
              message: 'switch my wait',
              providerInstanceId: 'waiting-old-provider',
              providerId: 'waiting-old-provider',
              model: 'waiting-old-model',
              requestId: 'req-waiting-change',
            ),
          ),
        );

        await adapter.firstFailure.future;
        await _waitUntil(
          () =>
              getIt<RuntimeRecoveryService>()
                  .activeNotice(session.sessionId)
                  ?.status ==
              RuntimeNoticeStatus.waiting,
        );
        expect(orchestrator.hasSuspendedEvent(session.sessionId), isFalse);

        await sendCommand(
          'session.runtime_continue_with_provider',
          payload: {
            'request_id': 'req-waiting-change-command',
            'session_id': session.sessionId,
            'provider_instance_id': 'waiting-new-provider',
            'model_id': 'waiting-new-model',
          },
        );
        await adapter.resumeStarted.future;
        expect(
          getIt<RuntimeRecoveryService>()
              .activeNotice(session.sessionId)
              ?.status,
          RuntimeNoticeStatus.resuming,
          reason:
              'The resuming notice must remain until real provider progress.',
        );
        adapter.release.complete(
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'retry ok'),
          ),
        );
        await running;

        expect(
          runtime.routes,
          containsAllInOrder([
            ('waiting-old-provider', 'waiting-old-model'),
            ('waiting-new-provider', 'waiting-new-model'),
          ]),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          equals('waiting-new-provider'),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.model,
          equals('waiting-new-model'),
        );
        expect(
          getIt<RuntimeRecoveryService>().activeNotice(session.sessionId),
          isNull,
        );
      },
    );

    test(
      'continue_with_provider reroutes a resumed run waiting on a retry',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final recovery = getIt<RuntimeRecoveryService>();
        final adapter = _BlockedThenWaitingAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        for (final route in const [
          ('resume-old-provider', 'resume-old-model', 'Resume Old'),
          ('resume-new-provider', 'resume-new-model', 'Resume New'),
        ]) {
          repo.createInstance(
            ProviderInstance(
              id: route.$1,
              templateId: 'openai',
              displayName: route.$3,
              protocol: ProviderProtocol.openaiCompatible,
              authMethod: ProviderAuthMethod.apiKey,
              defaultModel: route.$2,
              status: InstanceStatus.ready,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        final session = sessionManager.createSession('resume-old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'resume-old-provider',
          model: 'resume-old-model',
        );
        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(
              role: MessageRole.user,
              content: 'resume then switch provider',
            ),
            turnRequest: AgentTurnRequest(
              sessionId: session.sessionId,
              message: 'resume then switch provider',
              providerInstanceId: 'resume-old-provider',
              providerId: 'resume-old-provider',
              model: 'resume-old-model',
              requestId: 'req-resumed-wait',
            ),
          ),
        );

        await adapter.firstFailure.future;
        await _waitUntil(
          () =>
              recovery.activeNotice(session.sessionId)?.status ==
              RuntimeNoticeStatus.blocked,
        );
        expect(orchestrator.hasSuspendedEvent(session.sessionId), isTrue);

        final retry = sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-resumed-retry',
            'session_id': session.sessionId,
          },
        );
        await adapter.resumedFailure.future;
        await _waitUntil(
          () =>
              recovery.activeNotice(session.sessionId)?.status ==
              RuntimeNoticeStatus.waiting,
        );

        await sendCommand(
          'session.runtime_continue_with_provider',
          payload: {
            'request_id': 'req-resumed-provider-change',
            'session_id': session.sessionId,
            'provider_instance_id': 'resume-new-provider',
            'model_id': 'resume-new-model',
          },
        );
        await Future.wait([retry, running]);

        expect(adapter.callCount, equals(3));
        expect(
          runtime.routes,
          containsAllInOrder([
            ('resume-old-provider', 'resume-old-model'),
            ('resume-old-provider', 'resume-old-model'),
            ('resume-new-provider', 'resume-new-model'),
          ]),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          equals('resume-new-provider'),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.model,
          equals('resume-new-model'),
        );
        expect(recovery.activeNotice(session.sessionId), isNull);
      },
    );

    test(
      'stale runtime retry during a normal active turn is an idempotent no-op',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final recovery = getIt<RuntimeRecoveryService>();
        final adapter = _HangingAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        repo.createInstance(
          ProviderInstance(
            id: 'normal-provider',
            templateId: 'openai',
            displayName: 'Normal Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'normal-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );
        final session = sessionManager.createSession('normal-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'normal-provider',
          model: 'normal-model',
        );
        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'normal turn'),
            turnRequest: AgentTurnRequest(
              sessionId: session.sessionId,
              message: 'normal turn',
              providerInstanceId: 'normal-provider',
              providerId: 'normal-provider',
              model: 'normal-model',
              requestId: 'req-normal-turn',
            ),
          ),
        );
        await adapter.started.future;

        await sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-stale-retry',
            'session_id': session.sessionId,
          },
        );
        expect(recovery.activeNotice(session.sessionId), isNull);
        expect(orchestrator.isSessionBusy(session.sessionId), isTrue);

        adapter.release.complete(
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'normal done',
            ),
          ),
        );
        await running;
        expect(recovery.activeNotice(session.sessionId), isNull);
      },
    );

    test(
      'session.runtime_retry keeps a blocked notice when no suspended owner is available',
      () async {
        final sessionManager = getIt<SessionManager>();
        final recovery = getIt<RuntimeRecoveryService>();
        final session = sessionManager.createSession('gpt-4o');

        recovery.reportFailure(
          sessionId: session.sessionId,
          reason: RuntimeFailureReason.unknown,
          requestId: 'req-missing-owner',
          providerInstanceId: 'inst-1',
          title: 'Blocked',
          message: 'blocked before retry',
          forceBlocked: true,
        );

        await sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-retry-missing-owner',
            'session_id': session.sessionId,
          },
        );

        final notice = recovery.activeNotice(session.sessionId);
        expect(notice, isNotNull);
        expect(notice!.status, equals(RuntimeNoticeStatus.blocked));
        expect(notice.message, contains('could not find the saved work'));
      },
    );

    test(
      'session.runtime_continue_with_provider keeps a blocked notice when resume has no suspended owner',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final recovery = getIt<RuntimeRecoveryService>();
        final session = sessionManager.createSession('gpt-4o');

        repo.createInstance(
          ProviderInstance(
            id: 'continue-new-provider',
            templateId: 'openai',
            displayName: 'Continue Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'continue-model',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        recovery.reportFailure(
          sessionId: session.sessionId,
          reason: RuntimeFailureReason.unknown,
          requestId: 'req-change-missing-owner',
          providerInstanceId: 'inst-1',
          title: 'Blocked',
          message: 'blocked before provider change',
          forceBlocked: true,
        );

        await sendCommand(
          'session.runtime_continue_with_provider',
          payload: {
            'request_id': 'req-change-missing-owner',
            'session_id': session.sessionId,
            'provider_instance_id': 'continue-new-provider',
          },
        );

        final updatedSession = sessionManager.getSession(session.sessionId);
        expect(updatedSession?.providerId, equals('continue-new-provider'));
        expect(updatedSession?.model, equals('continue-model'));

        final notice = recovery.activeNotice(session.sessionId);
        expect(notice, isNotNull);
        expect(notice!.status, equals(RuntimeNoticeStatus.blocked));
        expect(notice.message, contains('could not find the saved work'));
      },
    );

    test(
      'concurrent session.runtime_retry commands resume exactly once and never emit a missing-work blocked notice',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final recovery = getIt<RuntimeRecoveryService>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final sessionManager = getIt<SessionManager>();
        final adapter = _RetryThenHangAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        repo.createInstance(
          ProviderInstance(
            id: 'old-provider',
            templateId: 'openai',
            displayName: 'Old Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'old-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final session = sessionManager.createSession('old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'old-provider',
          model: 'old-model',
        );

        // Start the initial request without awaiting so the test stays in
        // control while the orchestrator's auto-retry loop is suspended.
        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'resume me once'),
            turnRequest: AgentTurnRequest(
              sessionId: session.sessionId,
              message: 'resume me once',
              providerInstanceId: 'old-provider',
              providerId: 'old-provider',
              model: 'old-model',
              requestId: 'req-concurrent-retry',
            ),
          ),
        );

        // Wait for the first failure and the suspended notice to settle.
        await adapter.firstFailure.future;
        await _waitUntil(() {
          final notice = recovery.activeNotice(session.sessionId);
          return notice?.status == RuntimeNoticeStatus.blocked;
        });

        expect(orchestrator.hasSuspendedEvent(session.sessionId), isTrue);
        expect(adapter.callCount, equals(1));

        final firstRetry = sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-retry-one',
            'session_id': session.sessionId,
          },
        );
        await adapter.resumeStarted.future;

        final secondRetry = sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-retry-two',
            'session_id': session.sessionId,
          },
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final midNotice = recovery.activeNotice(session.sessionId);
        expect(
          midNotice == null || midNotice.status != RuntimeNoticeStatus.blocked,
          isTrue,
          reason:
              'A concurrent retry must be treated as idempotent instead of '
              'publishing a missing-work blocked notice.',
        );

        adapter.release.complete(
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'retry finished once',
            ),
          ),
        );

        await Future.wait([firstRetry, secondRetry]);
        await running;

        expect(adapter.callCount, equals(2));
        expect(recovery.activeNotice(session.sessionId), isNull);
        expect(orchestrator.hasSuspendedEvent(session.sessionId), isFalse);
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          equals('old-provider'),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.model,
          equals('old-model'),
        );
      },
    );

    test(
      'retry claimant keeps its route when a concurrent change-provider arrives second',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final recovery = getIt<RuntimeRecoveryService>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final sessionManager = getIt<SessionManager>();
        final adapter = _RetryThenHangAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        repo.createInstance(
          ProviderInstance(
            id: 'old-provider',
            templateId: 'openai',
            displayName: 'Old Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'old-model',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'winner-provider',
            templateId: 'openai',
            displayName: 'Winner',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'winner-model',
            status: InstanceStatus.ready,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final session = sessionManager.createSession('old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'old-provider',
          model: 'old-model',
        );

        // Start the initial request without awaiting so the test stays in
        // control while the orchestrator's auto-retry loop is suspended.
        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(
              role: MessageRole.user,
              content: 'change route once',
            ),
            turnRequest: AgentTurnRequest(
              sessionId: session.sessionId,
              message: 'change route once',
              providerInstanceId: 'old-provider',
              providerId: 'old-provider',
              model: 'old-model',
              requestId: 'req-concurrent-change',
            ),
          ),
        );

        // Wait for the first failure and the suspended notice to settle.
        await adapter.firstFailure.future;
        await _waitUntil(() {
          final notice = recovery.activeNotice(session.sessionId);
          return notice?.status == RuntimeNoticeStatus.blocked;
        });

        expect(orchestrator.hasSuspendedEvent(session.sessionId), isTrue);
        expect(adapter.callCount, equals(1));

        final retry = sendCommand(
          'session.runtime_retry',
          payload: {
            'request_id': 'req-retry-winner',
            'session_id': session.sessionId,
          },
        );
        await adapter.resumeStarted.future;

        final changeProvider = sendCommand(
          'session.runtime_continue_with_provider',
          payload: {
            'request_id': 'req-change-loser',
            'session_id': session.sessionId,
            'provider_instance_id': 'winner-provider',
          },
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final midNotice = recovery.activeNotice(session.sessionId);
        expect(
          midNotice == null || midNotice.status != RuntimeNoticeStatus.blocked,
          isTrue,
          reason:
              'The losing concurrent command must be a no-op, not a '
              'missing-work blocked notice.',
        );

        adapter.release.complete(
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'retry kept the original route',
            ),
          ),
        );

        await Future.wait([retry, changeProvider]);
        await running;

        expect(adapter.callCount, equals(2));
        expect(recovery.activeNotice(session.sessionId), isNull);
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          equals('old-provider'),
        );
        expect(
          sessionManager.getSession(session.sessionId)?.model,
          equals('old-model'),
        );
        expect(adapter.modelOverrides, equals(['old-model', 'old-model']));
      },
    );

    test(
      'get_session_history includes runtime_notice and actual queued_messages request ids',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final adapter = _HangingAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        repo.createInstance(
          ProviderInstance(
            id: 'hist-provider',
            templateId: 'openai',
            displayName: 'History Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'hist-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final session = sessionManager.createSession('hist-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'hist-provider',
          model: 'hist-model',
        );

        final running = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'Waiting now'),
            turnRequest: const AgentTurnRequest(
              sessionId: 'ignored',
              message: 'Waiting now',
              providerInstanceId: 'hist-provider',
              providerId: 'hist-provider',
              model: 'hist-model',
              requestId: 'req-history-active',
            ),
          ),
        );

        await adapter.started.future;

        await orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'Queued later'),
            metadata: {
              'payload': {'request_id': 'req-history-queued'},
            },
            turnRequest: const AgentTurnRequest(
              sessionId: 'ignored',
              message: 'Queued later',
              providerInstanceId: 'hist-provider',
              providerId: 'hist-provider',
              model: 'hist-model',
              requestId: 'req-history-queued',
              deliveryIntent: MessageDeliveryIntent.queue,
            ),
          ),
        );

        getIt<RuntimeRecoveryService>().reportRateLimitWait(
          sessionId: session.sessionId,
          providerInstanceId: 'hist-provider',
          retryAfter: const Duration(seconds: 30),
          requestId: 'req-history-active',
        );

        final envelope = await sendCommand(
          'get_session_history',
          payload: {
            'request_id': 'req-history-read',
            'session_id': session.sessionId,
          },
        );

        final payload = envelope['payload'] as Map<String, dynamic>;
        final queuedMessages = payload['queued_messages'] as List<dynamic>;
        expect(payload['runtime_notice'], isNotNull);
        expect(queuedMessages, isNotEmpty);
        expect(
          (queuedMessages.first
              as Map<String, dynamic>)['metadata']['request_id'],
          equals('req-history-queued'),
        );

        unawaited(orchestrator.requestStop(session.sessionId));
        unawaited(running.catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
    );

    test(
      'new message during waiting resumes suspended work first then executes queued message on the new route',
      () async {
        final repo = getIt<ProviderInstanceRepository>();
        final sessionManager = getIt<SessionManager>();
        final orchestrator = getIt<SessionRunOrchestrator>();
        final adapter = _RetryThenSucceedTwiceAdapter();
        final runtime = _RecordingRuntimeService(repo, adapter);
        getIt.registerSingleton<AgentRuntimeService>(runtime);
        getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
          (sessionId, _) => AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: sessionId,
          ),
        );

        final now = DateTime.now();
        repo.createInstance(
          ProviderInstance(
            id: 'msg-old-provider',
            templateId: 'openai',
            displayName: 'Msg Old',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'msg-old-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'msg-new-provider',
            templateId: 'openai',
            displayName: 'Msg New',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'msg-new-model',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final session = sessionManager.createSession('msg-old-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'msg-old-provider',
          model: 'msg-old-model',
        );

        final firstRun = orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'Pending first'),
            turnRequest: const AgentTurnRequest(
              sessionId: 'ignored',
              message: 'Pending first',
              providerInstanceId: 'msg-old-provider',
              providerId: 'msg-old-provider',
              model: 'msg-old-model',
              requestId: 'req-wait-first',
            ),
          ),
        );

        await adapter.firstFailure.future;
        await _waitUntil(() {
          final notice = getIt<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          return notice?.status.name == 'waiting';
        });

        await orchestrator.handleEvent(
          GatewayEvent(
            sessionId: session.sessionId,
            platformId: 'sanad_gateway',
            message: Message(role: MessageRole.user, content: 'Queued second'),
            turnRequest: const AgentTurnRequest(
              sessionId: 'ignored',
              message: 'Queued second',
              providerInstanceId: 'msg-new-provider',
              providerId: 'msg-new-provider',
              model: 'msg-new-model',
              requestId: 'req-wait-second',
            ),
          ),
        );

        await firstRun;
        await _waitUntil(() => adapter.callCount >= 3);

        expect(
          runtime.routes,
          containsAllInOrder([
            ('msg-old-provider', 'msg-old-model'),
            ('msg-new-provider', 'msg-new-model'),
            ('msg-new-provider', 'msg-new-model'),
          ]),
        );
        expect(
          adapter.lastUserContents,
          equals(['Pending first', 'Pending first', 'Queued second']),
        );
      },
    );
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  _NoopMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async {
    return const [];
  }
}

class _RecordingRuntimeService extends AgentRuntimeService {
  _RecordingRuntimeService(this.repo, this.adapter) : super(Config(), repo);

  final ProviderInstanceRepository repo;
  final LLMAdapter adapter;
  final List<(String, String)> routes = [];

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    routes.add((providerId ?? '', modelId ?? ''));
    return RouteSignature(
      providerInstanceId: providerId ?? '',
      templateId: 'openai',
      protocol: ProviderProtocol.openaiCompatible,
      normalizedBaseUrl: 'https://provider.invalid/v1',
      modelId: modelId ?? '',
      configRevision: 1,
      credentialRevision: 1,
    );
  }

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;
}

class _HangingAdapter implements LLMAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<AgentResponse> release = Completer<AgentResponse>();

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    if (!started.isCompleted) {
      started.complete();
    }
    return release.future;
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) {
    if (!started.isCompleted) {
      started.complete();
    }
    late final StreamController<AgentResponse> controller;
    controller = StreamController<AgentResponse>(
      onListen: () {
        release.future.then((response) {
          if (!controller.isClosed) {
            controller.add(response);
            controller.close();
          }
        });
      },
    );
    return controller.stream;
  }
}

class _RetryThenSucceedAdapter implements LLMAdapter {
  final Completer<void> firstFailure = Completer<void>();
  final List<String?> modelOverrides = [];
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    modelOverrides.add(modelOverride);
    callCount += 1;
    if (callCount == 1) {
      if (!firstFailure.isCompleted) {
        firstFailure.complete();
      }
      throw const LlmHttpException(
        statusCode: 429,
        body: 'Too Many Requests',
        headers: {'retry-after': '5'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'retry ok'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class _WaitingRetryThenHangAdapter implements LLMAdapter {
  final Completer<void> firstFailure = Completer<void>();
  final Completer<void> resumeStarted = Completer<void>();
  final Completer<AgentResponse> release = Completer<AgentResponse>();
  final List<String?> modelOverrides = [];
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    modelOverrides.add(modelOverride);
    callCount += 1;
    if (callCount == 1) {
      if (!firstFailure.isCompleted) firstFailure.complete();
      throw const LlmHttpException(
        statusCode: 429,
        body: 'Too Many Requests',
        headers: {'retry-after': '5'},
        operation: 'chat.completions',
      );
    }
    if (!resumeStarted.isCompleted) resumeStarted.complete();
    return release.future;
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class _RetryThenSucceedTwiceAdapter implements LLMAdapter {
  final Completer<void> firstFailure = Completer<void>();
  final List<String?> modelOverrides = [];
  final List<String?> lastUserContents = [];
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    modelOverrides.add(modelOverride);
    lastUserContents.add(
      history.where((m) => m.role == MessageRole.user).last.content,
    );
    callCount += 1;
    if (callCount == 1) {
      if (!firstFailure.isCompleted) {
        firstFailure.complete();
      }
      throw const LlmHttpException(
        statusCode: 429,
        body: 'Too Many Requests',
        headers: {'retry-after': '5'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'ok-$callCount'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class _BlockedThenWaitingAdapter implements LLMAdapter {
  final Completer<void> firstFailure = Completer<void>();
  final Completer<void> resumedFailure = Completer<void>();
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    if (callCount == 1) {
      firstFailure.complete();
      throw Exception('unexpected internal failure');
    }
    if (callCount == 2) {
      resumedFailure.complete();
      throw const LlmHttpException(
        statusCode: 429,
        body: 'Too Many Requests',
        headers: {'retry-after': '60'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'switched'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }
}

class _RetryThenHangAdapter implements LLMAdapter {
  final Completer<void> firstFailure = Completer<void>();
  final Completer<void> resumeStarted = Completer<void>();
  final Completer<AgentResponse> release = Completer<AgentResponse>();
  final List<String?> modelOverrides = [];
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    modelOverrides.add(modelOverride);
    callCount += 1;
    if (callCount == 1) {
      if (!firstFailure.isCompleted) {
        firstFailure.complete();
      }
      // Throw a non-HTTP error that classifies as `unknown` (budget 0) so the
      // run is immediately suspended without an auto-retry loop. This creates
      // a stable blocked notice + suspended owner for concurrent-resume tests.
      throw Exception('unexpected internal failure');
    }
    if (!resumeStarted.isCompleted) {
      resumeStarted.complete();
    }
    return release.future;
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class _MockTestAdapter extends BaseOpenAIAdapter {
  final Future<List<ModelOption>> Function() getModelsHandler;

  _MockTestAdapter(super.config, super.profile, this.getModelsHandler);

  @override
  Future<List<ModelOption>> getAvailableModels() => getModelsHandler();
}

class _TestRuntimeService extends AgentRuntimeService {
  final LLMAdapter Function(RouteSignature) adapterResolver;

  _TestRuntimeService(
    super.config,
    super.instanceRepo,
    this.adapterResolver, {
    super.credentialResolver,
    super.credService,
  });

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapterResolver(signature);
}
