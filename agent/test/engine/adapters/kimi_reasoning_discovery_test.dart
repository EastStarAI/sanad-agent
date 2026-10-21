/// Production-path regression coverage for Kimi/Moonshot provider-reported
/// reasoning discovery (live acceptance defect D1).
///
/// `BaseOpenAIAdapter.getAvailableModels` (Kimi `/models` item metadata) ->
/// `ProviderModelCacheService` -> `ThinkingCapabilityAssembler` declared tier ->
/// `ThinkingSelectionResolver` -> the actual `/chat/completions` body.
///
/// The item shape is the exact `kimi-for-coding` metadata the provider reported
/// live: `supports_reasoning`, `supports_thinking_type: "only"`, `think_efforts`
/// and the nested `reasoning` object. No request leaves the loopback mocks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

const _modelId = 'kimi-for-coding';
const _instanceId = 'inst-kimi-discovery';
const _baseUrl = 'http://127.0.0.1:1234/v1';

/// The exact live `kimi-for-coding` `/models` item metadata.
Map<String, Object?> _liveKimiItem() => {
  'id': _modelId,
  'object': 'model',
  'created': 1761264000,
  'owned_by': 'moonshot',
  'supports_reasoning': true,
  'supports_thinking_type': 'only',
  'think_efforts': {
    'support': true,
    'valid_efforts': ['low', 'high', 'max'],
    'default_effort': 'max',
  },
  'reasoning': {
    'type': 'only',
    'effort': {
      'valid': ['low', 'high', 'max'],
      'default': 'max',
    },
  },
};

class _StaticAdapterRuntimeService extends AgentRuntimeService {
  final LLMAdapter adapter;
  _StaticAdapterRuntimeService(super.config, super.instanceRepo, this.adapter);
  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;
}

class _Harness {
  final Directory scratch;
  final AgentStateDatabase state;
  final ProviderInstanceRepository repo;
  final Config config;
  final BaseOpenAIAdapter adapter;
  final ProviderModelCacheService cache;
  final ThinkingSelectionResolver resolver;
  final List<Map<String, dynamic>> chatBodies;

  _Harness(
    this.scratch,
    this.state,
    this.repo,
    this.config,
    this.adapter,
    this.cache,
    this.resolver,
    this.chatBodies,
  );

  ModelOption? cached() {
    for (final m in cache.snapshot(_instanceId) ?? const <ModelOption>[]) {
      if (m.value == _modelId) return m;
    }
    return null;
  }

  Future<Map<String, dynamic>> send(String? selectionId) async {
    GetIt.I.allowReassignment = true;
    GetIt.I.registerSingleton<Config>(config);
    GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
    final resolution = resolver.resolve(
      providerInstanceId: _instanceId,
      modelId: _modelId,
      selectionId: selectionId,
    );
    await adapter.generateResponse(
      [Message(role: MessageRole.user, content: 'ping')],
      modelOverride: _modelId,
      options: LLMRequestOptions(
        providerInstanceId: _instanceId,
        thinkingDirective: resolution.directive,
      ),
    );
    return chatBodies.last;
  }

  void dispose() {
    GetIt.I.reset();
    setSanadHomeOverride(null);
    state.dispose();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

Future<_Harness> _open(Map<String, Object?> item) async {
  final scratch = Directory.systemTemp.createTempSync('sanad-kimi-');
  setSanadHomeOverride(scratch.path);
  final state = AgentStateDatabase.inMemory();
  final repo = ProviderInstanceRepository.fromDatabase(state.db);
  final config = Config(environment: const {});
  repo.createInstance(
    ProviderInstance(
      id: _instanceId,
      templateId: 'kimi',
      displayName: 'Moonshot',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      defaultModel: _modelId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );
  final chatBodies = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    if (request.url.path == '/v1/models') {
      return http.Response(
        jsonEncode({
          'data': [item],
        }),
        200,
      );
    }
    if (request.url.path == '/v1/chat/completions') {
      chatBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        '{"choices":[{"message":{"role":"assistant","content":"ok"},'
        '"finish_reason":"stop"}]}',
        200,
      );
    }
    throw StateError('Unexpected request: ${request.url}');
  });
  // The models.dev catalog only admits the id; it carries no reasoning facts.
  final modelsDev = ModelsDevService(
    client: MockClient(
      (_) async => http.Response(
        jsonEncode({
          'kimi-for-coding': {
            'models': {
              _modelId: {
                'name': _modelId,
                'tool_call': true,
                'limit': {'context': 262144},
              },
            },
          },
        }),
        200,
      ),
    ),
    cacheFilePathOverride: '${scratch.path}/models_dev_cache.json',
  );
  final adapter = BaseOpenAIAdapter(
    config,
    ProviderRegistry.findByNameOrAlias('kimi')!,
    providerInstanceId: _instanceId,
    defaultModelOverride: _modelId,
    apiKeyOverride: 'fixture-key',
    baseUrlOverride: _baseUrl,
    client: client,
    modelsDevService: modelsDev,
  );
  final registry = buildProviderThinkingRegistry();
  final assembler = ThinkingCapabilityAssembler(registry, config);
  final cache = ProviderModelCacheService(
    repo,
    _StaticAdapterRuntimeService(config, repo, adapter),
    assembler,
    config: config,
    modelsDevService: modelsDev,
  );
  return _Harness(
    scratch,
    state,
    repo,
    config,
    adapter,
    cache,
    ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
      config: config,
    ),
    chatBodies,
  );
}

void main() {
  group('D1 Kimi provider-reported reasoning discovery', () {
    test('live kimi-for-coding metadata yields a supported always-on effort '
        'descriptor with the declared default', () async {
      final h = await _open(_liveKimiItem());
      addTearDown(h.dispose);
      await h.cache.refresh(_instanceId, manual: true);

      final model = h.cached();
      expect(model, isNotNull);
      expect(model!.supportsReasoningOutput, isTrue);
      final control = model.thinkingControl!;
      expect(control.status, ThinkingCapabilityStatus.supported);
      expect(control.kind, ThinkingControlKind.effort);
      expect(control.options.map((o) => o.id), ['low', 'high', 'max']);
      // `only`: thinking cannot be disabled, so no Off option exists.
      expect(control.options.any((o) => o.isOff), isFalse);
      expect(control.defaultOptionId, 'max');
    });

    test('an explicit effort dispatches its exact reasoning_effort and '
        'omission stays provider default on the wire', () async {
      final h = await _open(_liveKimiItem());
      addTearDown(h.dispose);
      await h.cache.refresh(_instanceId, manual: true);

      final high = h.resolver.resolve(
        providerInstanceId: _instanceId,
        modelId: _modelId,
        selectionId: 'high',
      );
      expect(high.directive, isA<OpenAiEffortDirective>());
      final highBody = await h.send('high');
      expect(highBody['reasoning_effort'], 'high');
      expect(highBody.containsKey('thinking'), isFalse);

      final maxBody = await h.send('max');
      expect(maxBody['reasoning_effort'], 'max');

      final defaultBody = await h.send(null);
      expect(defaultBody.containsKey('reasoning_effort'), isFalse);
      expect(defaultBody.containsKey('thinking'), isFalse);
    });

    test('an undeclared effort clamps to the nearest lower declared one', () async {
      final h = await _open(_liveKimiItem());
      addTearDown(h.dispose);
      await h.cache.refresh(_instanceId, manual: true);
      // `medium` is not offered: it clamps down to `low`, never up to `high`.
      final clamped = h.resolver.resolve(
        providerInstanceId: _instanceId,
        modelId: _modelId,
        selectionId: 'medium',
      );
      expect(clamped.selectionId, 'low');
      expect((clamped.directive as OpenAiEffortDirective).effort, 'low');
      // `none` is not a clamp target (never falls to off/none) and the
      // always-on route offers no disable, so it is rejected.
      expect(
        () => h.resolver.resolve(
          providerInstanceId: _instanceId,
          modelId: _modelId,
          selectionId: 'none',
        ),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (e) => e.code,
            'code',
            ThinkingSelectionErrorCode.optionUnavailable,
          ),
        ),
      );
    });

    test('names-only items keep the existing unknown descriptor', () async {
      final h = await _open({
        'id': _modelId,
        'object': 'model',
        'owned_by': 'moonshot',
      });
      addTearDown(h.dispose);
      await h.cache.refresh(_instanceId, manual: true);
      expect(
        h.cached()!.thinkingControl!.status,
        ThinkingCapabilityStatus.unknown,
      );
    });
  });

  group('kimiThinkingControlFromDiscovery validation', () {
    Map<String, Object?>? parse(Map<String, Object?> item) =>
        BaseOpenAIAdapter.kimiThinkingControlFromDiscovery(item);

    test('accepts the exact live shape', () {
      expect(parse(_liveKimiItem()), {
        'status': 'supported',
        'wire': 'openai_chat_effort',
        'options': {'low': 'low', 'high': 'high', 'max': 'max'},
        'default_option': 'max',
      });
    });

    test('rejects missing or false supports_reasoning', () {
      expect(parse({..._liveKimiItem(), 'supports_reasoning': false}), isNull);
      expect(parse({..._liveKimiItem()}..remove('supports_reasoning')), isNull);
    });

    test('rejects a non-only thinking type instead of inventing a toggle', () {
      final item = _liveKimiItem()
        ..['supports_thinking_type'] = 'optional'
        ..['reasoning'] = {
          'type': 'optional',
          'effort': {
            'valid': ['low', 'high', 'max'],
            'default': 'max',
          },
        };
      expect(parse(item), isNull);
    });

    test('rejects disagreeing effort forms, a disabling effort and a '
        'default outside the declared set', () {
      expect(
        parse(
          _liveKimiItem()
            ..['think_efforts'] = {
              'support': true,
              'valid_efforts': ['low', 'high'],
              'default_effort': 'high',
            },
        ),
        isNull,
      );
      expect(
        parse(
          _liveKimiItem()
            ..remove('reasoning')
            ..['think_efforts'] = {
              'support': true,
              'valid_efforts': ['none', 'high'],
            },
        ),
        isNull,
      );
      expect(
        parse(
          _liveKimiItem()
            ..remove('reasoning')
            ..['think_efforts'] = {
              'support': true,
              'valid_efforts': ['low', 'high'],
              'default_effort': 'max',
            },
        ),
        isNull,
      );
      expect(
        parse(
          _liveKimiItem()
            ..['think_efforts'] = {
              'support': false,
              'valid_efforts': ['low', 'high', 'max'],
            },
        ),
        isNull,
      );
    });

    test('accepts a single consistent effort form', () {
      final item = _liveKimiItem()..remove('think_efforts');
      expect(parse(item)?['default_option'], 'max');
    });
  });
}
