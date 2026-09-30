import 'dart:io';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_endpoint_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/missing_provider_adapter.dart';

String _tempStorePath() =>
    '${Directory.systemTemp.path}/sanad-secret-store-test-${DateTime.now().microsecondsSinceEpoch}-${const Uuid().v4()}.json';

void main() {
  group('ProviderEndpointResolver', () {
    test('normalizes baseUrl properly', () {
      expect(
        ProviderEndpointResolver.normalizeBaseUrl(
          ' https://api.openai.com/v1/ ',
        ),
        equals('https://api.openai.com/v1'),
      );
      expect(
        ProviderEndpointResolver.normalizeBaseUrl('http://localhost:11434///'),
        equals('http://localhost:11434'),
      );
      expect(
        ProviderEndpointResolver.normalizeBaseUrl(
          'url https://api.cursor.com/v1',
        ),
        equals('https://api.cursor.com/v1'),
      );
    });

    test('rejects malformed or unsupported base URLs', () {
      for (final value in ['not a url', 'file:///tmp/models']) {
        expect(
          () => ProviderEndpointResolver.resolveOpenAiModelsEndpointCandidates(
            value,
          ),
          throwsFormatException,
        );
      }
    });

    test('does not duplicate v1 in model endpoint candidates', () {
      expect(
        ProviderEndpointResolver.resolveOpenAiModelsEndpointCandidates(
          'https://api.cursor.com/v1',
        ).map((uri) => uri.toString()),
        equals(['https://api.cursor.com/v1/models']),
      );
    });

    test('resolves models endpoint', () {
      expect(
        ProviderEndpointResolver.resolveModelsEndpoint(
          'https://api.openai.com/v1',
          ProviderProtocol.openaiCompatible,
        ).toString(),
        equals('https://api.openai.com/v1/models'),
      );
      expect(
        ProviderEndpointResolver.resolveModelsEndpoint(
          'https://api.anthropic.com',
          ProviderProtocol.anthropicCompatible,
        ).toString(),
        equals('https://api.anthropic.com/v1/models'),
      );
      expect(
        ProviderEndpointResolver.resolveModelsEndpoint(
          'https://api.anthropic.com/v1',
          ProviderProtocol.anthropicCompatible,
        ).toString(),
        equals('https://api.anthropic.com/v1/models'),
      );
    });

    test('resolves chat endpoint', () {
      expect(
        ProviderEndpointResolver.resolveChatEndpoint(
          'https://api.openai.com/v1',
          ProviderProtocol.openaiCompatible,
        ).toString(),
        equals('https://api.openai.com/v1/chat/completions'),
      );
      expect(
        ProviderEndpointResolver.resolveChatEndpoint(
          'https://api.anthropic.com',
          ProviderProtocol.anthropicCompatible,
        ).toString(),
        equals('https://api.anthropic.com/v1/messages'),
      );
      expect(
        ProviderEndpointResolver.resolveChatEndpoint(
          'https://api.anthropic.com/v1',
          ProviderProtocol.anthropicCompatible,
        ).toString(),
        equals('https://api.anthropic.com/v1/messages'),
      );
    });
  });

  group('RouteSignature and AgentRuntimeService', () {
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late Directory tempSanadHome;
    late String tempStorePath;
    late SecureFileSecretStore secretStore;
    late ProviderCredentialService credService;
    late Config config;
    late AgentRuntimeService runtime;

    setUp(() {
      tempSanadHome = Directory.systemTemp.createTempSync(
        'sanad-runtime-service-test-',
      );
      setSanadHomeOverride(tempSanadHome.path);
      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      tempStorePath = _tempStorePath();
      secretStore = SecureFileSecretStore(storePath: tempStorePath);
      credService = ProviderCredentialService(repo, secretStore);
      config = Config();
      runtime = AgentRuntimeService(config, repo, credService: credService);
    });

    tearDown(() {
      state.dispose();
      setSanadHomeOverride(null);
      final file = File(tempStorePath);
      if (file.existsSync()) {
        file.deleteSync();
      }
      if (tempSanadHome.existsSync()) {
        tempSanadHome.deleteSync(recursive: true);
      }
    });

    test(
      'RouteSignature equality and hashCode include all revision/config fields',
      () {
        final sig1 = RouteSignature(
          providerInstanceId: 'inst-1',
          templateId: 'openai',
          protocol: ProviderProtocol.openaiCompatible,
          normalizedBaseUrl: 'https://api.openai.com/v1',
          modelId: 'gpt-4o',
          configRevision: 1,
          credentialRevision: 1,
        );
        final sig2 = RouteSignature(
          providerInstanceId: 'inst-1',
          templateId: 'openai',
          protocol: ProviderProtocol.openaiCompatible,
          normalizedBaseUrl: 'https://api.openai.com/v1',
          modelId: 'gpt-4o',
          configRevision: 1,
          credentialRevision: 1,
        );
        final sig3 = RouteSignature(
          providerInstanceId: 'inst-1',
          templateId: 'openai',
          protocol: ProviderProtocol.openaiCompatible,
          normalizedBaseUrl: 'https://api.openai.com/v1',
          modelId: 'gpt-4o',
          configRevision: 2,
          credentialRevision: 1,
        );

        expect(sig1, equals(sig2));
        expect(sig1.hashCode, equals(sig2.hashCode));
        expect(sig1, isNot(equals(sig3)));
      },
    );

    test('resolves signature from default instance', () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI Personal',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'https://api.openai.com/v1',
          defaultModel: 'gpt-4o',
          status: 'ready',
          isDefault: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      final signature = runtime.resolveSignature();
      expect(signature.providerInstanceId, equals('inst-1'));
      expect(signature.templateId, equals('openai'));
      expect(signature.modelId, equals('gpt-4o'));
    });

    test(
      'defaultAdapter falls back to a lazy error adapter when no provider is configured',
      () async {
        final adapter = runtime.defaultAdapter();

        expect(adapter, isA<MissingProviderAdapter>());
        await expectLater(
          adapter.getContextLimit(),
          throwsA(
            isA<MissingProviderConfigurationException>().having(
              (error) => error.toString(),
              'message',
              contains('No default provider instance is set'),
            ),
          ),
        );
      },
    );

    test(
      'resolveSignature throws when instance is not found and DB is not empty',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI Personal',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            baseUrl: 'https://api.openai.com/v1',
            defaultModel: 'gpt-4o',
            status: 'ready',
            isDefault: true,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        expect(
          () => runtime.resolveSignature(providerId: 'inst-missing'),
          throwsStateError,
        );
      },
    );

    test(
      'builds adapter with baseUrlOverride and apiKeyOverride from database/secretStore',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI Personal',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            baseUrl: 'https://api.custom-openai.com/v1',
            defaultModel: 'gpt-4o',
            status: 'ready',
            isDefault: true,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        await credService.applyApiKeyEdit(
          'inst-1',
          action: 'replace',
          newApiKey: 'sk-test-key',
        );

        final signature = runtime.resolveSignature();
        final adapter = runtime.adapterFor(signature);

        expect(adapter, isA<BaseOpenAIAdapter>());
        final openaiAdapter = adapter as BaseOpenAIAdapter;
        expect(
          openaiAdapter.baseUrl,
          equals('https://api.custom-openai.com/v1'),
        );
        expect(openaiAdapter.apiKey, equals('sk-test-key'));
      },
    );

    test(
      'custom anthropic-compatible instances preserve anthropic protocol inside the adapter profile',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-anthropic-custom',
            templateId: kCustomProviderTemplateId,
            displayName: 'Custom Anthropic Gateway',
            protocol: ProviderProtocol.anthropicCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            baseUrl: 'http://localhost:9000/v1',
            defaultModel: 'claude-sonnet-4.5',
            status: InstanceStatus.ready,
            isDefault: true,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        await credService.applyApiKeyEdit(
          'inst-anthropic-custom',
          action: 'replace',
          newApiKey: 'anthropic-test-key',
        );

        final signature = runtime.resolveSignature();
        final adapter = runtime.adapterFor(signature);

        expect(adapter, isA<BaseAnthropicAdapter>());
        final anthropicAdapter = adapter as BaseAnthropicAdapter;
        expect(
          anthropicAdapter.profile.effectiveProtocol,
          equals(ProviderProtocol.anthropicCompatible),
        );
      },
    );

    test('concurrency and isolation between sibling instances', () async {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-work',
          templateId: 'openai',
          displayName: 'OpenAI Work',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'https://api.work.com/v1',
          defaultModel: 'gpt-4o',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.createInstance(
        ProviderInstance(
          id: 'inst-personal',
          templateId: 'openai',
          displayName: 'OpenAI Personal',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'https://api.personal.com/v1',
          defaultModel: 'gpt-4o-mini',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      await credService.applyApiKeyEdit(
        'inst-work',
        action: 'replace',
        newApiKey: 'sk-work-key',
      );
      await credService.applyApiKeyEdit(
        'inst-personal',
        action: 'replace',
        newApiKey: 'sk-personal-key',
      );

      final sigWork = runtime.resolveSignature(providerId: 'inst-work');
      final sigPersonal = runtime.resolveSignature(providerId: 'inst-personal');

      final adapterWork = runtime.adapterFor(sigWork) as BaseOpenAIAdapter;
      final adapterPersonal =
          runtime.adapterFor(sigPersonal) as BaseOpenAIAdapter;

      expect(adapterWork, isNot(equals(adapterPersonal)));
      expect(adapterWork.baseUrl, equals('https://api.work.com/v1'));
      expect(adapterWork.apiKey, equals('sk-work-key'));
      expect(adapterPersonal.baseUrl, equals('https://api.personal.com/v1'));
      expect(adapterPersonal.apiKey, equals('sk-personal-key'));
    });

    test(
      'uses revision-matched catalog context windows for unknown models per instance',
      () async {
        for (final entry in const [
          ('instance-a', 272000),
          ('instance-b', 196000),
        ]) {
          repo.createInstance(
            ProviderInstance(
              id: entry.$1,
              templateId: 'openai-codex',
              displayName: entry.$1,
              protocol: ProviderProtocol.openaiCompatible,
              authMethod: ProviderAuthMethod.deviceCode,
              baseUrl: 'https://chatgpt.com/backend-api/codex',
              defaultModel: 'future-catalog-model',
              status: InstanceStatus.ready,
              configRevision: 3,
              credentialRevision: 4,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
          repo.upsertModelCache(
            instanceId: entry.$1,
            cacheKey: 'models',
            models: [
              {
                'value': 'future-catalog-model',
                'label': 'Future Catalog Model',
                'context_window': entry.$2,
              },
            ],
            fetchedAt: DateTime.now(),
            source: 'live',
            configRevision: 3,
            credentialRevision: 4,
          );
        }

        final adapterA = runtime.adapterFor(
          runtime.resolveSignature(providerId: 'instance-a'),
        );
        final adapterB = runtime.adapterFor(
          runtime.resolveSignature(providerId: 'instance-b'),
        );

        expect(adapterA, isA<CodexResponsesAdapter>());
        expect(adapterB, isA<CodexResponsesAdapter>());
        expect(await adapterA.getContextLimit(), 272000);
        expect(await adapterB.getContextLimit(), 196000);
      },
    );

    test(
      'explicit config context window overrides matching catalog metadata',
      () async {
        File('${tempSanadHome.path}/config.yaml').writeAsStringSync('''
context:
  modelLimits:
    future-catalog-model: 444000
''');
        repo.createInstance(
          ProviderInstance(
            id: 'instance-configured',
            templateId: 'openai-codex',
            displayName: 'Configured Context',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.deviceCode,
            baseUrl: 'https://chatgpt.com/backend-api/codex',
            defaultModel: 'future-catalog-model',
            status: InstanceStatus.ready,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'instance-configured',
          cacheKey: 'models',
          models: [
            {
              'value': 'future-catalog-model',
              'label': 'Future Catalog Model',
              'context_window': 333000,
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );
        final configuredRuntime = AgentRuntimeService(
          Config(environment: const {}),
          repo,
        );
        final adapter = configuredRuntime.adapterFor(
          configuredRuntime.resolveSignature(providerId: 'instance-configured'),
        );

        expect(await adapter.getContextLimit(), 444000);
      },
    );

    test('rejects catalog context windows from stale revisions', () async {
      repo.createInstance(
        ProviderInstance(
          id: 'instance-stale',
          templateId: 'openai-codex',
          displayName: 'Stale Catalog',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.deviceCode,
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          defaultModel: 'future-catalog-model',
          status: InstanceStatus.ready,
          configRevision: 2,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      repo.upsertModelCache(
        instanceId: 'instance-stale',
        cacheKey: 'models',
        models: [
          {
            'value': 'future-catalog-model',
            'label': 'Future Catalog Model',
            'context_window': 333000,
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      final adapter = runtime.adapterFor(
        runtime.resolveSignature(providerId: 'instance-stale'),
      );

      expect(await adapter.getContextLimit(), 4000);
    });

    test('defaultAdapter resolves live after a provider is added, '
        'not frozen from a prior missing-provider state', () {
      // Step 1: No provider configured yet — defaultAdapter returns a
      // lazy MissingProviderAdapter, exactly as it would during a fresh
      // daemon boot before onboarding.
      final missingAdapter = runtime.defaultAdapter();
      expect(missingAdapter, isA<MissingProviderAdapter>());

      // Step 2: Simulate the onboarding completing: a default instance
      // is now present in the database.
      repo.createInstance(
        ProviderInstance(
          id: 'inst-after-setup',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'https://api.openai.com/v1',
          defaultModel: 'gpt-4o',
          status: InstanceStatus.ready,
          isDefault: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      // Step 3: defaultAdapter() must now resolve the live instance —
      // it must NOT return the stale MissingProviderAdapter from step 1.
      // This is the exact regression: the first message after onboarding
      // must not fail with "No default provider instance is set."
      final liveAdapter = runtime.defaultAdapter();
      expect(liveAdapter, isNot(isA<MissingProviderAdapter>()));
      expect(liveAdapter, isA<BaseOpenAIAdapter>());
    });

    test('invalidate() clears the adapter cache so a new instance signature '
        'builds a fresh adapter', () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-1',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'https://api.openai.com/v1',
          defaultModel: 'gpt-4o',
          status: InstanceStatus.ready,
          isDefault: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final sig1 = runtime.resolveSignature();
      final adapter1 = runtime.adapterFor(sig1);
      expect(adapter1, isA<BaseOpenAIAdapter>());

      // invalidate() must clear the cache.
      runtime.invalidate();

      // After invalidation, the same signature must build a new adapter
      // instance (not the same object).
      final sig2 = runtime.resolveSignature();
      final adapter2 = runtime.adapterFor(sig2);
      expect(adapter2, isA<BaseOpenAIAdapter>());
      expect(identical(adapter1, adapter2), isFalse);
    });
  });
}
