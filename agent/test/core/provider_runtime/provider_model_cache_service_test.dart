import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/provider_runtime/copilot_credential_lifecycle.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

class MockLLMAdapter implements LLMAdapter {
  final Future<List<ModelOption>> Function() getModelsHandler;

  MockLLMAdapter(this.getModelsHandler);

  @override
  Future<List<ModelOption>> getAvailableModels() => getModelsHandler();

  @override
  Future<int> getContextLimit([String? modelOverride]) => Future.value(4096);

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => throw UnimplementedError();

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => throw UnimplementedError();
}

class TestAgentRuntimeService extends AgentRuntimeService {
  LLMAdapter? adapterOverride;

  TestAgentRuntimeService(
    super.config,
    super.instanceRepo, {
    super.copilotLifecycle,
    super.credService,
  });

  @override
  LLMAdapter adapterFor(RouteSignature signature) {
    if (adapterOverride != null) return adapterOverride!;
    return super.adapterFor(signature);
  }
}

void main() {
  group('RecentModelSelectionService', () {
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late RecentModelSelectionService recentService;

    setUp(() {
      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      recentService = RecentModelSelectionService(repo);
    });

    tearDown(() {
      state.dispose();
    });

    test('records recent selections and respects limit of 100', () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      for (var i = 1; i <= 105; i++) {
        recentService.selectModel(instanceId: 'inst-1', modelId: 'model-$i');
      }

      final list = recentService.getRecentSelections();
      expect(list.length, equals(100));
      expect(
        list.first['model_id'],
        equals('model-105'),
      ); // Latest selection at top
    });

    test('re-selecting a model bumps it to the top', () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      recentService.selectModel(instanceId: 'inst-1', modelId: 'model-a');
      recentService.selectModel(instanceId: 'inst-1', modelId: 'model-b');
      recentService.selectModel(
        instanceId: 'inst-1',
        modelId: 'model-a',
      ); // bump a

      final list = recentService.getRecentSelections();
      expect(list.first['model_id'], equals('model-a'));
      expect(list.last['model_id'], equals('model-b'));
    });

    test('rename updates the returned display name immediately', () {
      final inst = ProviderInstance(
        id: 'inst-1',
        templateId: 'openai',
        displayName: 'OpenAI Original',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(inst);

      recentService.selectModel(instanceId: 'inst-1', modelId: 'model-a');

      repo.update(
        inst.copyWith(displayName: 'OpenAI Renamed', configRevision: 2),
      );

      final list = recentService.getRecentSelections();
      expect(list.first['instance_display_name'], equals('OpenAI Renamed'));
    });

    test('delete cascade deletes selections', () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      recentService.selectModel(instanceId: 'inst-1', modelId: 'model-a');
      expect(recentService.getRecentSelections().length, equals(1));

      repo.delete('inst-1');
      expect(recentService.getRecentSelections().length, equals(0));
    });
  });

  group('ProviderModelCacheService', () {
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late Config config;
    late TestAgentRuntimeService runtime;
    late ProviderModelCacheService cacheService;

    setUp(() {
      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      config = Config();
      runtime = TestAgentRuntimeService(config, repo);
      cacheService = ProviderModelCacheService(
        repo,
        runtime,
        cooldown: const Duration(seconds: 2),
      );
    });

    tearDown(() {
      state.dispose();
    });

    test(
      'snapshot returns null when config or credential revision mismatch',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 2,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        // Write a cache with old config revision (1)
        repo.upsertModelCache(
          instanceId: 'inst-1',
          cacheKey: 'models',
          models: [
            {'value': 'gpt-4', 'label': 'GPT-4'},
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        expect(cacheService.snapshot('inst-1'), isNull);
      },
    );

    test('snapshot returns list of models when revisions match', () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 2,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      repo.upsertModelCache(
        instanceId: 'inst-1',
        cacheKey: 'models',
        models: [
          {'value': 'gpt-4', 'label': 'GPT-4'},
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 2,
        credentialRevision: 1,
      );

      final snap = cacheService.snapshot('inst-1');
      expect(snap, isNotNull);
      expect(snap!.first.value, equals('gpt-4'));
    });

    test('refresh live updates model list in database', () async {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 2,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      runtime.adapterOverride = MockLLMAdapter(() async {
        return [ModelOption(value: 'gpt-4o', label: 'GPT-4o')];
      });

      final refreshed = await cacheService.refresh('inst-1', manual: true);
      expect(refreshed.first.value, equals('gpt-4o'));

      final snap = cacheService.snapshot('inst-1');
      expect(snap, isNotNull);
      expect(snap!.first.value, equals('gpt-4o'));
    });

    test('refresh coalesces concurrent refreshes', () async {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 2,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      var callCount = 0;
      runtime.adapterOverride = MockLLMAdapter(() async {
        callCount++;
        await Future.delayed(const Duration(milliseconds: 50));
        return [ModelOption(value: 'gpt-4o', label: 'GPT-4o')];
      });

      final f1 = cacheService.refresh('inst-1', manual: true);
      final f2 = cacheService.refresh('inst-1', manual: true);

      final results = await Future.wait([f1, f2]);
      expect(results[0].first.value, equals('gpt-4o'));
      expect(results[1].first.value, equals('gpt-4o'));
      expect(callCount, equals(1)); // Coalesced into exactly 1 call!
    });

    test('refresh respects cooldown unless manual: true', () async {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 2,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      var callCount = 0;
      runtime.adapterOverride = MockLLMAdapter(() async {
        callCount++;
        return [ModelOption(value: 'gpt-4o', label: 'GPT-4o')];
      });

      // 1. Initial manual refresh
      await cacheService.refresh('inst-1', manual: true);
      expect(callCount, equals(1));

      // 2. Immediate non-manual refresh within cooldown (returns cached, doesn't call live)
      await cacheService.refresh('inst-1', manual: false);
      expect(callCount, equals(1));

      // 3. Manual refresh bypasses cooldown
      await cacheService.refresh('inst-1', manual: true);
      expect(callCount, equals(2));
    });

    test('refresh survives malformed base URL without prior cache', () async {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'custom',
          displayName: 'Broken Provider',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'not a url',
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final refreshed = await cacheService.refresh('inst-1', manual: true);

      expect(refreshed, isNotEmpty);
      final cachedRow = repo.readModelCache('inst-1', 'models')!;
      expect(cachedRow['source'], equals('fallback'));
      expect(cachedRow['last_error'], isNotNull);
    });

    test(
      'refresh persists failed state when live fetch throws without cache',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        var callCount = 0;
        runtime.adapterOverride = MockLLMAdapter(() async {
          callCount++;
          throw const FormatException('boom');
        });

        await expectLater(
          cacheService.refresh('inst-1', manual: true),
          throwsA(isA<FormatException>()),
        );

        final cachedRow = repo.readModelCache('inst-1', 'models')!;
        expect(cachedRow['source'], equals('failed'));
        expect(cachedRow['last_error'], contains('boom'));

        await expectLater(
          cacheService.refresh('inst-1', manual: true),
          throwsA(isA<FormatException>()),
        );
        expect(callCount, equals(2));
      },
    );

    test(
      'refresh failure falls back to last successful entry in DB and logs error',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 2,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        // Pre-populate cache with a successful fetch
        repo.upsertModelCache(
          instanceId: 'inst-1',
          cacheKey: 'models',
          models: [
            {'value': 'gpt-4', 'label': 'GPT-4'},
          ],
          fetchedAt: DateTime.now().subtract(const Duration(minutes: 10)),
          source: 'live',
          configRevision: 2,
          credentialRevision: 1,
        );

        // Make the next call throw an error
        runtime.adapterOverride = MockLLMAdapter(() async {
          throw SocketException('Network disconnected');
        });

        // Should succeed and fall back to the cached 'gpt-4'
        final refreshed = await cacheService.refresh('inst-1', manual: true);
        expect(refreshed.first.value, equals('gpt-4'));

        // Check DB metadata has the error string
        final cachedRow = repo.readModelCache('inst-1', 'models')!;
        expect(cachedRow['last_error'], contains('Network disconnected'));
        expect(cachedRow['source'], equals('cache_stale'));
      },
    );

    test(
      'Copilot recovery wrapper preserves fallback model-source metadata',
      () async {
        final secrets = SecureFileSecretStore(
          storePath:
              '${Directory.systemTemp.path}/sanad-copilot-cache-${DateTime.now().microsecondsSinceEpoch}.json',
        );
        final creds = ProviderCredentialService(repo, secrets);
        final runtimeWithCopilot = TestAgentRuntimeService(
          config,
          repo,
          copilotLifecycle: CopilotCredentialLifecycle(
            instances: repo,
            creds: creds,
          ),
          credService: creds,
        );
        final cache = ProviderModelCacheService(
          repo,
          runtimeWithCopilot,
          cooldown: const Duration(seconds: 2),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'inst-copilot',
            templateId: kGithubCopilotTemplateId,
            displayName: 'Copilot',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.deviceCode,
            baseUrl: 'not a url',
            defaultModel: 'gpt-4o',
            status: InstanceStatus.ready,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final refreshed = await cache.refresh('inst-copilot', manual: true);
        expect(refreshed, isNotEmpty);
        final cachedRow = repo.readModelCache('inst-copilot', 'models')!;
        expect(cachedRow['source'], equals('fallback'));
        expect(cachedRow['last_error'], isNotNull);
      },
    );
  });
}
