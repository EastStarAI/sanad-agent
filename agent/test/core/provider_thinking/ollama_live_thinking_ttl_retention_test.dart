import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_stale_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

/// Production-wired regressions for native Ollama thinking facts whose live
/// probe evidence is older than [ThinkingControlStaleEvidence.liveEvidenceTtl].
///
/// The discovery half runs the real [OllamaAdapter] over mock HTTP
/// (`/api/tags` + `/api/show`), the cache half persists exactly what
/// `ProviderModelCacheService` persists, and the resolution half uses the real
/// [ThinkingSelectionResolver] before asserting the adapter's own `/api/chat`
/// wire body.
void main() {
  const instanceId = 'inst-ollama-gemma';
  const modelId = 'gemma4:e2b';
  const baseUrl = 'http://127.0.0.1:11434';
  const liveTtlExcess = Duration(minutes: 11);

  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ThinkingCapabilityAssembler assembler;
  late ThinkingSelectionResolver resolver;
  late Config config;
  late Map<String, dynamic> showPayloadForModel;
  late List<Map<String, dynamic>> chatBodies;

  OllamaAdapter buildAdapter() => OllamaAdapter(
    config,
    ProviderRegistry.findByNameOrAlias('ollama')!,
    client: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/api/tags')) {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': modelId, 'model': modelId},
            ],
          }),
          200,
        );
      }
      if (path.endsWith('/api/show')) {
        final name = (jsonDecode(request.body) as Map)['name'] as String;
        final payload = showPayloadForModel[name];
        if (payload == null) {
          return http.Response('{"error":"model not found"}', 404);
        }
        return http.Response(jsonEncode(payload), 200);
      }
      if (path.endsWith('/api/chat')) {
        chatBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'message': {'role': 'assistant', 'content': 'ok'},
            'done': true,
          }),
          200,
        );
      }
      return http.Response('Not found', 404);
    }),
    providerInstanceId: instanceId,
    baseUrlOverride: baseUrl,
    defaultModelOverride: modelId,
  );

  ProviderInstance currentInstance() => repo.findById(instanceId)!;

  /// Mirrors `ProviderModelCacheService._doLiveRefresh` persistence.
  Future<List<ModelOption>> refreshLiveCache(OllamaAdapter adapter) async {
    final liveModels = await adapter.getAvailableModels();
    final fetchedAt = DateTime.now().toUtc();
    final enriched = assembler.enrichAll(
      instance: currentInstance(),
      models: liveModels,
      observedAt: fetchedAt,
    );
    repo.upsertModelCache(
      instanceId: instanceId,
      cacheKey: 'models',
      models: enriched.map((model) => model.toJson()).toList(),
      fetchedAt: fetchedAt,
      source: adapter.availableModelsSource,
      configRevision: currentInstance().configRevision,
      credentialRevision: currentInstance().credentialRevision,
    );
    return enriched;
  }

  /// Deterministically ages persisted live evidence past the TTL instead of
  /// sleeping through it, keeping every other fact byte-identical.
  void agePersistedLiveEvidence(Duration age) {
    final cached = repo.readModelCache(instanceId, 'models')!;
    final agedAt = DateTime.now().toUtc().subtract(age);
    final agedModels = (cached['models'] as List<dynamic>).map((raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      final control = map['thinking_control'];
      if (control is Map) {
        final agedControl = Map<String, dynamic>.from(control);
        agedControl['observed_at'] = agedAt.toIso8601String();
        map['thinking_control'] = agedControl;
      }
      return map;
    }).toList();
    repo.upsertModelCache(
      instanceId: instanceId,
      cacheKey: 'models',
      models: agedModels,
      fetchedAt: agedAt,
      source: cached['source'].toString(),
      configRevision: cached['config_revision'] as int,
      credentialRevision: cached['credential_revision'] as int,
    );
  }

  ThinkingControlDescriptor cachedDescriptor() {
    final cached = repo.readModelCache(instanceId, 'models')!;
    final models = cached['models'] as List<dynamic>;
    final entry = Map<String, dynamic>.from(models.first as Map);
    return ModelOption.fromJson(entry).thinkingControl!;
  }

  /// Mirrors the production refresh-failure persistence: the prior ids stay,
  /// every descriptor is marked `live_probe_failed`, and the row records
  /// `cache_stale`.
  void failLiveRefresh() {
    final cached = repo.readModelCache(instanceId, 'models')!;
    final staleModels = (cached['models'] as List<dynamic>)
        .map(
          (raw) => ModelOption.fromJson(Map<String, dynamic>.from(raw as Map)),
        )
        .toList(growable: false);
    final probeFailed = assembler.markProbeFailed(
      instance: currentInstance(),
      models: staleModels,
    );
    repo.upsertModelCache(
      instanceId: instanceId,
      cacheKey: 'models',
      models: probeFailed.map((model) => model.toJson()).toList(),
      fetchedAt: DateTime.now().toUtc(),
      source: 'cache_stale',
      configRevision: cached['config_revision'] as int,
      credentialRevision: cached['credential_revision'] as int,
      lastError: 'probe failed',
    );
  }

  ThinkingSelectionResolution resolveDefault() => resolver.resolve(
    providerInstanceId: instanceId,
    modelId: modelId,
    selectionId: null,
  );

  ThinkingSelectionResolution resolveOff() => resolver.resolve(
    providerInstanceId: instanceId,
    modelId: modelId,
    selectionId: 'off',
  );

  ThinkingSelectionResolution resolveOn() => resolver.resolve(
    providerInstanceId: instanceId,
    modelId: modelId,
    selectionId: 'on',
  );

  /// The exact model route's persisted discovery metadata.
  Map<String, Object?> persistedModelMetadata() {
    final cached = repo.readModelCache(instanceId, 'models')!;
    final models = cached['models'] as List<dynamic>;
    return ModelOption.fromJson(
      Map<String, dynamic>.from(models.first as Map),
    ).modelMetadata;
  }

  Future<Map<String, dynamic>> captureChatBody(
    NativeThinkingDirective directive,
  ) async {
    chatBodies.clear();
    final adapter = buildAdapter();
    await adapter.generateResponse(
      [Message(role: MessageRole.user, content: 'hi')],
      options: LLMRequestOptions(thinkingDirective: directive),
    );
    return chatBodies.single;
  }

  final throwsThinkingUnknown = throwsA(
    isA<ThinkingSelectionException>().having(
      (error) => error.code,
      'code',
      ThinkingSelectionErrorCode.capabilityUnknown,
    ),
  );

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    final registry = buildProviderThinkingRegistry();
    assembler = ThinkingCapabilityAssembler(registry);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
    config = Config(
      environment: {
        'LLM_MODEL': modelId,
        'AGENT_NAME': 'TestAgent',
        'LLM_BASE_URL': baseUrl,
      },
    );
    chatBodies = [];
    showPayloadForModel = {
      modelId: {
        'capabilities': ['completion', 'tools', 'thinking'],
        'thinking': {
          'values': [false, true],
          'default': true,
        },
        'parameters': 'think',
      },
    };

    repo.createInstance(
      ProviderInstance(
        id: instanceId,
        templateId: 'ollama',
        displayName: 'Local Ollama',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: baseUrl,
        defaultModel: modelId,
        status: InstanceStatus.ready,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  });

  tearDown(() => state.dispose());

  test(
    'live-probed native On/Off/default survive past the 5-minute evidence TTL with typed native wire',
    () async {
      final adapter = buildAdapter();
      final enriched = await refreshLiveCache(adapter);

      // Discovery really produced live Boolean native facts for this route.
      expect(adapter.availableModelsSource, 'live');
      final discovered = enriched.single.thinkingControl!;
      expect(discovered.status, ThinkingCapabilityStatus.supported);
      expect(discovered.source, 'live');
      expect(discovered.kind, ThinkingControlKind.toggle);
      expect(discovered.defaultOptionId, 'on');
      expect(
        discovered.options.map((option) => option.id),
        containsAll(<String>['off', 'on']),
      );

      agePersistedLiveEvidence(liveTtlExcess);

      final aged = cachedDescriptor();
      expect(
        ThinkingControlStaleEvidence.isStale(aged),
        isTrue,
        reason: 'The regression only exists once live evidence outlives the TTL',
      );

      // Explicit Off stays selectable and reaches the native wire.
      final off = resolver.resolve(
        providerInstanceId: instanceId,
        modelId: modelId,
        selectionId: 'off',
      );
      expect(off.descriptor.status, ThinkingCapabilityStatus.supported);
      expect(off.directive, const ThinkingToggleDirective(enabled: false));
      expect((await captureChatBody(off.directive))['think'], isFalse);

      // Explicit On stays selectable and reaches the native wire.
      final on = resolver.resolve(
        providerInstanceId: instanceId,
        modelId: modelId,
        selectionId: 'on',
      );
      expect(on.descriptor.status, ThinkingCapabilityStatus.supported);
      expect(on.directive, const ThinkingToggleDirective(enabled: true));
      expect((await captureChatBody(on.directive))['think'], isTrue);

      // Provider default still resolves and omits the wire key entirely.
      final providerDefault = resolver.resolve(
        providerInstanceId: instanceId,
        modelId: modelId,
        selectionId: null,
      );
      expect(
        providerDefault.descriptor.status,
        ThinkingCapabilityStatus.supported,
      );
      expect(providerDefault.directive, isA<UseProviderDefault>());
      expect(
        (await captureChatBody(providerDefault.directive)).containsKey('think'),
        isFalse,
      );
    },
  );

  test(
    'malformed native declaration discovered over live mock HTTP fails closed instead of retaining facts',
    () async {
      showPayloadForModel[modelId] = {
        'capabilities': ['completion', 'tools', 'thinking'],
        'thinking': {'values': <dynamic>[], 'default': true},
      };

      final adapter = buildAdapter();
      final enriched = await refreshLiveCache(adapter);
      expect(
        enriched.single.thinkingControl!.status,
        ThinkingCapabilityStatus.unknown,
      );

      agePersistedLiveEvidence(liveTtlExcess);
      expect(cachedDescriptor().status, ThinkingCapabilityStatus.unknown);

      expect(
        () => resolver.resolve(
          providerInstanceId: instanceId,
          modelId: modelId,
          selectionId: 'off',
        ),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (error) => error.code,
            'code',
            ThinkingSelectionErrorCode.capabilityUnknown,
          ),
        ),
      );
      expect(chatBodies, isEmpty);
    },
  );

  test(
    'refresh failure markers are never bypassed by TTL retention',
    () async {
      final adapter = buildAdapter();
      await refreshLiveCache(adapter);
      expect(cachedDescriptor().source, 'live');

      failLiveRefresh();

      // The failed refresh keeps the discovered ids and their still-valid native
      // declaration in persisted metadata, yet resolution must not rebuild a
      // supported descriptor from that metadata under the same revisions.
      expect(
        OllamaThinkingProbe.parseThinkingDeclaration(persistedModelMetadata()),
        isNotNull,
      );
      expect(cachedDescriptor().source, 'live_probe_failed');
      expect(cachedDescriptor().status, ThinkingCapabilityStatus.unknown);
      expect(
        resolveDefault().descriptor.status,
        ThinkingCapabilityStatus.unknown,
      );
      expect(() => resolveOff(), throwsThinkingUnknown);

      agePersistedLiveEvidence(liveTtlExcess);

      expect(
        resolveDefault().descriptor.status,
        ThinkingCapabilityStatus.unknown,
      );
      expect(() => resolveOff(), throwsThinkingUnknown);
      expect(chatBodies, isEmpty);
    },
  );

  test(
    'config and credential invalidation plus a successful refresh clear failure provenance and restore native facts',
    () async {
      final adapter = buildAdapter();
      await refreshLiveCache(adapter);
      failLiveRefresh();

      // Same config/credential revision as the failure: fail closed.
      expect(resolveDefault().descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(() => resolveOff(), throwsThinkingUnknown);

      // Config invalidation alone does not erase failure provenance or invent
      // success; the route stays unresolved until a live probe succeeds.
      repo.update(currentInstance().copyWith(configRevision: 2));
      expect(currentInstance().configRevision, 2);
      expect(cachedDescriptor().source, 'live_probe_failed');
      expect(resolveDefault().descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(resolveDefault().descriptor.capabilityRevision, startsWith('2:1:'));
      expect(() => resolveOff(), throwsThinkingUnknown);

      // A successful live probe under the new revision drops the failure
      // provenance and restores the model-owned facts end to end.
      final configRefreshed = await refreshLiveCache(buildAdapter());
      expect(configRefreshed.single.thinkingControl!.source, 'live');
      expect(
        configRefreshed.single.thinkingControl!.status,
        ThinkingCapabilityStatus.supported,
      );
      final recovered = cachedDescriptor();
      expect(recovered.source, 'live');
      expect(recovered.status, ThinkingCapabilityStatus.supported);
      expect(ThinkingControlStaleEvidence.isInvalidated(recovered), isFalse);
      expect(
        ThinkingControlStaleEvidence.isStale(recovered),
        isFalse,
        reason: 'Freshly re-probed evidence is not stale',
      );
      expect(resolveDefault().descriptor.status, ThinkingCapabilityStatus.supported);
      expect(resolveDefault().directive, isA<UseProviderDefault>());
      expect(resolveOff().directive, const ThinkingToggleDirective(enabled: false));
      expect(resolveOn().directive, const ThinkingToggleDirective(enabled: true));
      expect((await captureChatBody(resolveOff().directive))['think'], isFalse);

      // Credential invalidation repeats the cycle: the old revision's cache
      // facts are not reused, and a successful refresh restores them.
      repo.update(currentInstance().copyWith(credentialRevision: 2));
      expect(currentInstance().credentialRevision, 2);
      expect(resolveDefault().descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(() => resolveOff(), throwsThinkingUnknown);

      final credentialRefreshed = await refreshLiveCache(buildAdapter());
      expect(
        credentialRefreshed.single.thinkingControl!.status,
        ThinkingCapabilityStatus.supported,
      );
      expect(cachedDescriptor().source, 'live');
      expect(resolveOn().directive, const ThinkingToggleDirective(enabled: true));
      expect((await captureChatBody(resolveOn().directive))['think'], isTrue);
    },
  );

  test(
    'revision change invalidates retained native facts instead of resurrecting them',
    () async {
      final adapter = buildAdapter();
      await refreshLiveCache(adapter);
      agePersistedLiveEvidence(liveTtlExcess);
      expect(cachedDescriptor().source, 'live');

      // Provider configuration mutation invalidates the whole cached revision.
      repo.update(currentInstance().copyWith(configRevision: 2));
      expect(currentInstance().configRevision, 2);

      final providerDefault = resolver.resolve(
        providerInstanceId: instanceId,
        modelId: modelId,
        selectionId: null,
      );
      expect(
        providerDefault.descriptor.status,
        ThinkingCapabilityStatus.unknown,
      );
      expect(
        providerDefault.descriptor.capabilityRevision,
        startsWith('2:1:'),
      );

      expect(
        () => resolver.resolve(
          providerInstanceId: instanceId,
          modelId: modelId,
          selectionId: 'off',
        ),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (error) => error.code,
            'code',
            ThinkingSelectionErrorCode.capabilityUnknown,
          ),
        ),
      );
      expect(chatBodies, isEmpty);
    },
  );

  test(
    'supported live evidence that the current model evidence no longer validates still degrades to unknown after the TTL',
    () async {
      // The route reports no thinking capability, so the assembler rebuild for
      // the same revision is unsupported/unknown rather than a validated native
      // declaration.
      showPayloadForModel[modelId] = {
        'capabilities': ['completion', 'tools'],
      };

      final adapter = buildAdapter();
      await refreshLiveCache(adapter);

      // Seed a supported `live` descriptor at exactly the revision the current
      // model evidence rebuilds, so the retention gate is what decides the
      // outcome rather than the route revision mismatch.
      final rebuiltRevision = assembler
          .assemble(
            instance: currentInstance(),
            model: ModelOption(value: modelId, label: modelId),
          )
          .capabilityRevision;
      final cached = repo.readModelCache(instanceId, 'models')!;
      final observedAt = DateTime.now().toUtc().subtract(liveTtlExcess);
      repo.upsertModelCache(
        instanceId: instanceId,
        cacheKey: 'models',
        models: [
          {
            'value': modelId,
            'thinking_control': {
              'status': 'supported',
              'kind': 'toggle',
              'options': [
                {'id': 'off', 'label': 'Off', 'is_off': true},
                {'id': 'on', 'label': 'On'},
              ],
              'default_option_id': 'on',
              'capability_revision': rebuiltRevision,
              'source': 'live',
              'observed_at': observedAt.toIso8601String(),
            },
          },
        ],
        fetchedAt: observedAt,
        source: 'live',
        configRevision: cached['config_revision'] as int,
        credentialRevision: cached['credential_revision'] as int,
      );

      final providerDefault = resolver.resolve(
        providerInstanceId: instanceId,
        modelId: modelId,
        selectionId: null,
      );
      expect(
        providerDefault.descriptor.status,
        ThinkingCapabilityStatus.unknown,
      );
      expect(providerDefault.descriptor.source, 'stale_live_evidence');

      expect(
        () => resolver.resolve(
          providerInstanceId: instanceId,
          modelId: modelId,
          selectionId: 'on',
        ),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (error) => error.code,
            'code',
            ThinkingSelectionErrorCode.capabilityUnknown,
          ),
        ),
      );
    },
  );
}
