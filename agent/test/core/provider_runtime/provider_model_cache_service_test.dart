import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../../support/thinking_matchers.dart';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
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

  TestAgentRuntimeService(super.config, super.instanceRepo) : super();

  @override
  LLMAdapter adapterFor(RouteSignature signature) {
    if (adapterOverride != null) return adapterOverride!;
    return super.adapterFor(signature);
  }
}

/// The serving vendor's models.dev entries this suite relies on (the catalog
/// layer of the capability authority; no model-name table is consulted).
Map<String, dynamic>? _modelsDevFixture(String templateId, String modelId) {
  if (templateId != 'openai') return null;
  return switch (modelId) {
    'o3' || 'o3-mini' => {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
        },
      ],
    },
    _ => null,
  };
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

      final baseTime = DateTime.utc(2025, 1, 1);
      for (var i = 1; i <= 105; i++) {
        recentService.selectModel(
          instanceId: 'inst-1',
          modelId: 'model-$i',
          selectedAt: baseTime.add(Duration(seconds: i)),
        );
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
        buildDefaultThinkingCapabilityAssembler(
          modelsDevLookup: _modelsDevFixture,
        ),
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

    test(
      'refresh enriches cached models with thinking_control metadata',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-thinking',
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

        runtime.adapterOverride = MockLLMAdapter(
          () async => [
            ModelOption(value: 'o3', label: 'O3', supportsReasoning: true),
          ],
        );

        final models = await cacheService.refresh(
          'inst-thinking',
          manual: true,
        );
        expect(models, hasLength(1));
        expect(models.first.thinkingControl, isNotNull);
        expect(
          models.first.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );

        final cached = cacheService.snapshot('inst-thinking');
        expect(cached?.first.thinkingControl, isNotNull);
        expect(cached?.first.toJson()['thinking_control'], isNotNull);
      },
    );

    test(
      'reasoning output alone does not imply supported thinking controls',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-reasoning-only',
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

        runtime.adapterOverride = MockLLMAdapter(
          () async => [
            ModelOption(
              value: 'gpt-test',
              label: 'GPT Test',
              supportsReasoning: true,
            ),
          ],
        );

        final models = await cacheService.refresh(
          'inst-reasoning-only',
          manual: true,
        );

        // No layer reports a control: absence of evidence is `unknown`, never
        // a positive `unsupported` claim.
        expect(
          models.first.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(models.first.supportsReasoningOutput, isTrue);
      },
    );

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
        expect(
          refreshed.first.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(refreshed.first.thinkingControl!.source, 'live_probe_failed');

        // Check DB metadata has the error string
        final cachedRow = repo.readModelCache('inst-1', 'models')!;
        expect(cachedRow['last_error'], contains('Network disconnected'));
        expect(cachedRow['source'], equals('cache_stale'));
        final cachedModel = ModelOption.fromJson(
          Map<String, dynamic>.from((cachedRow['models'] as List).first as Map),
        );
        expect(
          cachedModel.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
      },
    );

    test(
      'failed refresh retains model-owned thinking facts while live-probe evidence stays invalidated',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-facts',
            templateId: 'openai',
            displayName: 'OpenAI',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 3,
            credentialRevision: 2,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final assembler = buildDefaultThinkingCapabilityAssembler(
          modelsDevLookup: _modelsDevFixture,
        );
        final instance = repo.findById('inst-facts')!;

        // A source-backed exact model fact (`o3-mini`) and a live-probe-derived
        // fixture are both persisted by an earlier successful refresh.
        final modelOwnedFact = assembler.assemble(
          instance: instance,
          model: ModelOption(value: 'o3-mini', label: 'o3-mini'),
        );
        expect(modelOwnedFact.status, ThinkingCapabilityStatus.supported);
        expect(modelOwnedFact.source, ThinkingCapabilityAssembler.shippedDefaultSource);

        final liveEvidence = ThinkingControlDescriptor(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.toggle,
          options: const [
            ThinkingControlOption(id: 'off', label: 'Off', isOff: true),
            ThinkingControlOption(id: 'on', label: 'On'),
          ],
          defaultOptionId: 'on',
          capabilityRevision: '3:2:ollama_live:probable-local',
          source: 'live',
        );

        repo.upsertModelCache(
          instanceId: 'inst-facts',
          cacheKey: 'models',
          models: [
            ModelOption(
              value: 'o3-mini',
              label: 'o3-mini',
              thinkingControl: modelOwnedFact,
            ).toJson(),
            ModelOption(
              value: 'probable-local',
              label: 'Probable Local',
              thinkingControl: liveEvidence,
            ).toJson(),
          ],
          fetchedAt: DateTime.now().subtract(const Duration(minutes: 10)),
          source: 'live',
          configRevision: 3,
          credentialRevision: 2,
        );

        runtime.adapterOverride = MockLLMAdapter(() async {
          throw SocketException('Network disconnected');
        });

        final refreshed = await cacheService.refresh(
          'inst-facts',
          manual: true,
        );
        expect(
          repo.readModelCache('inst-facts', 'models')!['source'],
          equals('cache_stale'),
        );

        // Model-owned fact survives: the documented capability is not a network
        // claim and must not silently reset to provider-managed.
        final retainedFact = refreshed.firstWhere(
          (model) => model.value == 'o3-mini',
        );
        expect(
          retainedFact.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(
          retainedFact.thinkingControl!.source,
          ThinkingCapabilityAssembler.shippedDefaultSource,
        );

        // Live-probe evidence keeps its authoritative failure provenance.
        final invalidatedLive = refreshed.firstWhere(
          (model) => model.value == 'probable-local',
        );
        expect(
          invalidatedLive.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(invalidatedLive.thinkingControl!.source, 'live_probe_failed');

        // The user-visible effect: the retained fact still resolves to its
        // typed native directive after the failed refresh.
        final registry = buildProviderThinkingRegistry();
        final resolver = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: assembler,
          registry: registry,
          config: config,
        );
        final resolution = resolver.resolve(
          providerInstanceId: 'inst-facts',
          modelId: 'o3-mini',
          selectionId: 'high',
        );
        expect(
          resolution.descriptor.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(resolution.directive, isA<OpenAiEffortDirective>());
        expect((resolution.directive as OpenAiEffortDirective).effort, 'high');

        // The invalidated live model still fails closed.
        expect(
          () => resolver.resolve(
            providerInstanceId: 'inst-facts',
            modelId: 'probable-local',
            selectionId: 'on',
          ),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'manual refresh forces catalog reload and updates subsequent admission while prior frozen turn remains immutable',
      () async {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-catalog',
            templateId: 'openai',
            displayName: 'OpenAI Relay',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        runtime.adapterOverride = MockLLMAdapter(() async {
          return [
            ModelOption(value: 'claude-haiku-4.5', label: 'Claude Haiku 4.5'),
          ];
        });

        int catalogHttpCalls = 0;
        bool catalogImageSupport = false;

        final tempDir = Directory.systemTemp.createTempSync(
          'mdev-refresh-test-',
        );
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            catalogHttpCalls++;
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4.5': {
                      'modalities': {
                        'input': catalogImageSupport
                            ? ['text', 'image']
                            : ['text'],
                      },
                    },
                  },
                },
              }),
              200,
            );
          }),
        );

        final serviceWithCatalog = ProviderModelCacheService(
          repo,
          runtime,
          buildDefaultThinkingCapabilityAssembler(
          modelsDevLookup: _modelsDevFixture,
        ),
          config: config,
          modelsDevService: modelsDev,
        );

        final resolver = RouteCapabilityResolver(
          instances: repo,
          config: config,
          modelsDevService: modelsDev,
        );

        // 1. Initial hydration: image is false
        await modelsDev.ensureLoaded();
        expect(catalogHttpCalls, 1);

        // 2. Turn 1 admission: freezes profile as unsupported
        final turn1Profile = resolver.resolveSync(
          providerInstanceId: 'inst-catalog',
          modelId: 'claude-haiku-4.5',
        );
        expect(turn1Profile.imageSupport, RouteImageSupport.unsupported);
        expect(
          catalogHttpCalls,
          1,
          reason: 'Zero HTTP during Turn 1 admission',
        );

        // 3. Fake catalog changes to true
        catalogImageSupport = true;

        // 4. Explicit manual refresh is called
        await serviceWithCatalog.refresh('inst-catalog', manual: true);
        expect(
          catalogHttpCalls,
          2,
          reason: 'Manual refresh forced catalog reload',
        );

        // 5. Next admission (Turn 2) resolves supported
        final turn2Profile = resolver.resolveSync(
          providerInstanceId: 'inst-catalog',
          modelId: 'claude-haiku-4.5',
        );
        expect(turn2Profile.imageSupport, RouteImageSupport.supported);
        expect(
          catalogHttpCalls,
          2,
          reason: 'Zero HTTP during Turn 2 admission',
        );

        // 6. Prior frozen Turn 1 profile remains immutable
        expect(turn1Profile.imageSupport, RouteImageSupport.unsupported);
      },
    );
  });

  group('failed refresh reconstructs thinking descriptors from current authority', () {
    late Directory tempHome;
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late Config config;
    late TestAgentRuntimeService runtime;
    late ProviderModelCacheService cacheService;
    late ThinkingCapabilityAssembler assembler;
    late ThinkingSelectionResolver resolver;

    const overrideHome = '''
model_capabilities:
  declared-fixture:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: low
        high: high
''';

    /// Valid Home configuration without the model-only thinking override.
    const overrideFreeHome = '''
model_capabilities:
  unrelated-fixture-marker:
    supports_image_input: true
''';

    void writeHomeConfig(String content) {
      File(p.join(tempHome.path, 'config.yaml')).writeAsStringSync(content);
      config.reloadModelAwarePolicy();
    }

    ProviderInstance openAiInstance({int configRevision = 1}) {
      final inst = ProviderInstance(
        id: 'inst-authority',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        configRevision: configRevision,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(inst);
      return inst;
    }

    void seedCache(ProviderInstance instance, List<ModelOption> models) {
      repo.upsertModelCache(
        instanceId: instance.id,
        cacheKey: 'models',
        models: models.map((model) => model.toJson()).toList(),
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 20)),
        source: 'live',
        configRevision: instance.configRevision,
        credentialRevision: instance.credentialRevision,
      );
    }

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync(
        'sanad_refresh_authority_',
      );
      setSanadHomeOverride(tempHome.path);
      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      config = Config(environment: {'SANAD_HOME': tempHome.path});
      runtime = TestAgentRuntimeService(config, repo);
      assembler = ThinkingCapabilityAssembler(
        buildProviderThinkingRegistry(),
        config,
        _modelsDevFixture,
      );
      resolver = ThinkingSelectionResolver(
        instances: repo,
        cacheResolver: ThinkingControlCacheResolver(repo),
        assembler: assembler,
        registry: buildProviderThinkingRegistry(),
        config: config,
      );
      cacheService = ProviderModelCacheService(
        repo,
        runtime,
        assembler,
        config: config,
        cooldown: const Duration(seconds: 2),
      );
      writeHomeConfig(overrideFreeHome);
    });

    tearDown(() {
      try {
        setSanadHomeOverride(null);
        state.dispose();
      } finally {
        if (tempHome.existsSync()) {
          tempHome.deleteSync(recursive: true);
        }
      }
    });

    void failRefreshAdapter() {
      runtime.adapterOverride = MockLLMAdapter(() async {
        throw SocketException('Network disconnected');
      });
    }

    test(
      'unchanged authority: model-owned fact survives and still resolves',
      () async {
        final inst = openAiInstance();
        final enriched = assembler.enrich(
          instance: inst,
          model: ModelOption(value: 'o3-mini', label: 'o3-mini'),
        );
        expect(
          enriched.thinkingControl!.source,
          ThinkingCapabilityAssembler.shippedDefaultSource,
        );
        seedCache(inst, [enriched]);
        failRefreshAdapter();

        final refreshed = await cacheService.refresh(inst.id, manual: true);
        final retained = refreshed.firstWhere((m) => m.value == 'o3-mini');
        expect(
          retained.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(
          retained.thinkingControl!.source,
          ThinkingCapabilityAssembler.shippedDefaultSource,
        );
        expect(
          repo.readModelCache(inst.id, 'models')!['source'],
          equals('cache_stale'),
        );

        final resolution = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'o3-mini',
          selectionId: 'high',
        );
        expect((resolution.directive as OpenAiEffortDirective).effort, 'high');
      },
    );

    test('removed override is not resurrected by a failed refresh', () async {
      final inst = ProviderInstance(
        id: 'inst-authority-override',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(inst);
      writeHomeConfig(overrideHome);

      final enriched = assembler.enrich(
        instance: inst,
        model: ModelOption(value: 'declared-fixture', label: 'Declared'),
      );
      expect(enriched.thinkingControl!.source, 'config_override');
      expect(
        enriched.thinkingControl!.status,
        ThinkingCapabilityStatus.supported,
      );
      seedCache(inst, [enriched]);

      // The user removes the model-only override from the Home configuration.
      writeHomeConfig(overrideFreeHome);
      failRefreshAdapter();

      final refreshed = await cacheService.refresh(inst.id, manual: true);
      final model = refreshed.firstWhere((m) => m.value == 'declared-fixture');
      expect(
        model.thinkingControl!.status,
        ThinkingCapabilityStatus.unknown,
        reason: 'a removed override must not be resurrected from cache',
      );
      expect(model.thinkingControl!.source, 'live_probe_failed');
      expect(
        () => resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'declared-fixture',
          selectionId: 'high',
        ),
        sendsNoThinkingField,
      );
    });

    test(
      'changed config revision fails closed instead of retaining stale controls',
      () async {
        final inst = openAiInstance();
        final enriched = assembler.enrich(
          instance: inst,
          model: ModelOption(value: 'o3-mini', label: 'o3-mini'),
        );
        seedCache(inst, [enriched]);

        // The route configuration changed after the cached descriptor was written.
        repo.update(inst.copyWith(configRevision: 2));
        failRefreshAdapter();

        final refreshed = await cacheService.refresh(inst.id, manual: true);
        final model = refreshed.firstWhere((m) => m.value == 'o3-mini');
        expect(model.thinkingControl!.status, ThinkingCapabilityStatus.unknown);
        expect(model.thinkingControl!.source, 'live_probe_failed');
      },
    );

    test(
      'route mode change fails closed for a declaration it cannot honor',
      () async {
        final inst = ProviderInstance(
          id: 'inst-authority-mode',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);
        writeHomeConfig(overrideHome);
        final enriched = assembler.enrich(
          instance: inst,
          model: ModelOption(value: 'declared-fixture', label: 'Declared'),
        );
        expect(
          enriched.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        seedCache(inst, [enriched]);

        // The actual API mode changes; the Chat effort declaration is no longer
        // compatible and must not survive the failed refresh.
        repo.update(
          inst.copyWith(protocol: ProviderProtocol.anthropicCompatible),
        );
        failRefreshAdapter();

        final refreshed = await cacheService.refresh(inst.id, manual: true);
        final model = refreshed.firstWhere(
          (m) => m.value == 'declared-fixture',
        );
        expect(model.thinkingControl!.status, ThinkingCapabilityStatus.unknown);
        expect(model.thinkingControl!.source, 'live_probe_failed');
      },
    );

    test(
      'endpoint-declared controls are not reclassified as intrinsic support',
      () async {
        final inst = ProviderInstance(
          id: 'inst-authority-endpoint',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // The endpoint itself declares the control in its discovery metadata.
        final enriched = assembler.enrich(
          instance: inst,
          model: ModelOption(
            value: 'declared-endpoint-fixture',
            label: 'Declared Endpoint',
            modelMetadata: const {
              'thinking_control': {
                'status': 'supported',
                'wire': 'openai_chat_effort',
                'options': {'low': 'low', 'high': 'high'},
              },
            },
          ),
        );
        expect(enriched.thinkingControl!.source, 'endpoint_declared');
        expect(
          enriched.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        seedCache(inst, [enriched]);
        failRefreshAdapter();

        final refreshed = await cacheService.refresh(inst.id, manual: true);
        final model = refreshed.firstWhere(
          (m) => m.value == 'declared-endpoint-fixture',
        );
        expect(
          model.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
          reason:
              'route-owned endpoint evidence cannot be revalidated by a failed '
              'model-list refresh and must not be retained as intrinsic support',
        );
        expect(model.thinkingControl!.source, 'live_probe_failed');
      },
    );

    test(
      'changed credential revision fails closed instead of retaining controls',
      () async {
        final inst = openAiInstance();
        final enriched = assembler.enrich(
          instance: inst,
          model: ModelOption(value: 'o3-mini', label: 'o3-mini'),
        );
        seedCache(inst, [enriched]);

        repo.update(inst.copyWith(credentialRevision: 2));
        failRefreshAdapter();

        final refreshed = await cacheService.refresh(inst.id, manual: true);
        final model = refreshed.firstWhere((m) => m.value == 'o3-mini');
        expect(model.thinkingControl!.status, ThinkingCapabilityStatus.unknown);
        expect(model.thinkingControl!.source, 'live_probe_failed');
      },
    );

    test(
      'authoritative failure and live evidence keep their invalidation',
      () async {
        final inst = openAiInstance();
        final invalidated = ModelOption(
          value: 'o3-mini',
          label: 'o3-mini',
          thinkingControl: ThinkingControlDescriptor.unknown(
            capabilityRevision: 'probe_failed:o3-mini',
            source: 'live_probe_failed',
          ),
        );
        final liveEvidence = ModelOption(
          value: 'probable-local',
          label: 'Probable Local',
          thinkingControl: ThinkingControlDescriptor(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.toggle,
            options: const [
              ThinkingControlOption(id: 'off', label: 'Off', isOff: true),
              ThinkingControlOption(id: 'on', label: 'On'),
            ],
            defaultOptionId: 'on',
            capabilityRevision: '1:1:ollama_live:probable-local',
            source: 'live',
          ),
        );
        seedCache(inst, [invalidated, liveEvidence]);
        failRefreshAdapter();

        final refreshed = await cacheService.refresh(inst.id, manual: true);
        for (final model in refreshed) {
          expect(
            model.thinkingControl!.status,
            ThinkingCapabilityStatus.unknown,
            reason: '${model.value} must not be resurrected',
          );
          expect(model.thinkingControl!.source, 'live_probe_failed');
        }
      },
    );
  });
}
