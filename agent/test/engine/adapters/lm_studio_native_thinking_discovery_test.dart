/// Production-bound regression coverage for bounded LM Studio native reasoning
/// discovery (Plan 77 / Task 77I5 — "Bounded LM Studio native-discovery lane").
///
/// The suite walks the real production path over one disposable Home, a
/// loopback `MockClient` provider and an in-memory state database:
///
/// `BaseOpenAIAdapter.getAvailableModels` (OpenAI-compatible `/v1/models`
/// discovery plus native `/api/v1/models` evidence) -> `ProviderModelCacheService`
/// -> `ThinkingCapabilityAssembler` -> `ThinkingSelectionResolver` ->
/// `BaseOpenAIAdapter` actual `/chat/completions` request body.
///
/// Scope boundaries: no real Home, credential, provider instance, runtime, UI or
/// model inference is involved, and no request is dispatched outside the
/// loopback mock. Native-only values (`on`/`off`) must never be mapped onto the
/// compatibility Chat wire, and an unmappable native default must never be
/// invented as a selectable level.
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
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

const _modelId = 'qwen/qwen3-4b-thinking-2507';
const _reasoningEvidenceKey = 'lm_studio_reasoning';
const _declaredControlKey = 'thinking_control';

/// One documented native `GET /api/v1/models` entry
/// (`https://lmstudio.ai/docs/developer/rest/list`).
Map<String, Object?> _nativeModel({
  required String key,
  List<Object?> allowedOptions = const ['off', 'on', 'low', 'medium', 'high'],
  Object? defaultOption = 'medium',
  List<String> loadedInstanceIds = const [],
  Object? reasoningOverride,
  bool includeCapabilities = true,
}) {
  return {
    'type': 'llm',
    'publisher': 'fixture',
    'key': key,
    'display_name': key,
    'architecture': 'qwen3',
    'size_bytes': 2500000000,
    'params_string': '4B',
    'loaded_instances': [
      for (final id in loadedInstanceIds)
        {
          'id': id,
          'config': {'context_length': 32768},
        },
    ],
    'max_context_length': 40960,
    'format': 'gguf',
    if (includeCapabilities)
      'capabilities': {
        'vision': false,
        'trained_for_tool_use': true,
        'reasoning':
            reasoningOverride ??
            {'allowed_options': allowedOptions, 'default': defaultOption},
      },
  };
}

class _Harness {
  static const baseUrl = 'http://127.0.0.1:1234/v1';
  static const instanceId = 'inst-lm-studio-native';

  final Directory scratch;
  final AgentStateDatabase state;
  final ProviderInstanceRepository repo;
  final Config config;
  final BaseOpenAIAdapter adapter;
  final ProviderModelCacheService cacheService;
  final ThinkingSelectionResolver selectionResolver;

  /// Live observations written by the loopback mock handler.
  final List<String> compatRequests;
  final List<String> nativeRequests;
  final List<Map<String, dynamic>> chatBodies;

  _Harness._({
    required this.scratch,
    required this.state,
    required this.repo,
    required this.config,
    required this.adapter,
    required this.cacheService,
    required this.selectionResolver,
    required this.compatRequests,
    required this.nativeRequests,
    required this.chatBodies,
  });

  ModelOption? cachedModel([String model = _modelId]) {
    final models = cacheService.snapshot(instanceId);
    if (models == null) return null;
    for (final model_ in models) {
      if (model_.value == model) return model_;
    }
    return null;
  }

  /// Resolves the production selection, then dispatches one real adapter request
  /// and returns the actual captured Chat body.
  Future<Map<String, dynamic>> send({
    String? selectionId,
    String model = _modelId,
  }) async {
    // The adapter resolves its route identity through the registered repository,
    // so bind this harness's own instance for this dispatch.
    GetIt.I.allowReassignment = true;
    GetIt.I.registerSingleton<Config>(config);
    GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);

    final resolution = selectionResolver.resolve(
      providerInstanceId: instanceId,
      modelId: model,
      selectionId: selectionId,
    );
    await adapter.generateResponse(
      [Message(role: MessageRole.user, content: 'ping')],
      modelOverride: model,
      options: LLMRequestOptions(
        providerInstanceId: instanceId,
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

/// Builds the isolated production-path harness.
///
/// [nativeModels] is the raw `models` value of the native response, so malformed
/// payload shapes can be exercised. [nativeStatus] simulates a failing probe.
Future<_Harness> _openHarness({
  required Object? nativeModels,
  int nativeStatus = 200,
  bool nativeThrows = false,
  List<String>? compatIds,
  Map<String, Object?> compatMetadata = const {},
  bool requireNativeAuth = false,
}) async {
  final scratch = Directory.systemTemp.createTempSync(
    'sanad-lm-studio-native-',
  );
  setSanadHomeOverride(scratch.path);
  final state = AgentStateDatabase.inMemory();
  final repo = ProviderInstanceRepository.fromDatabase(state.db);
  final config = Config(environment: const {});

  repo.createInstance(
    ProviderInstance(
      id: _Harness.instanceId,
      templateId: 'lm-studio',
      displayName: 'LM Studio Local',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      defaultModel: _modelId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );

  final compatRequests = <String>[];
  final nativeRequests = <String>[];
  final chatBodies = <Map<String, dynamic>>[];

  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/api/v1/models') {
      nativeRequests.add(request.url.toString());
      if (requireNativeAuth &&
          request.headers['authorization'] != 'Bearer fixture-key') {
        return http.Response('fixture authentication required', 401);
      }
      if (nativeThrows) {
        throw const SocketException('native probe refused');
      }
      if (nativeStatus != 200) {
        return http.Response('native probe failure', nativeStatus);
      }
      return http.Response(jsonEncode({'models': nativeModels}), 200);
    }
    if (path == '/v1/models') {
      compatRequests.add(request.url.toString());
      return http.Response(
        jsonEncode({
          'data': [
            for (final id in compatIds ?? const [_modelId])
              {
                ...compatMetadata,
                'id': id,
                'object': 'model',
                'owned_by': 'lm-studio',
              },
          ],
        }),
        200,
      );
    }
    if (path == '/v1/chat/completions') {
      chatBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        '{"choices":[{"message":{"role":"assistant","content":"ok"},'
        '"finish_reason":"stop"}]}',
        200,
      );
    }
    throw StateError('Unexpected request: ${request.url}');
  });

  final adapter = BaseOpenAIAdapter(
    config,
    ProviderRegistry.findByNameOrAlias('lm-studio')!,
    providerInstanceId: _Harness.instanceId,
    defaultModelOverride: _modelId,
    apiKeyOverride: 'fixture-key',
    baseUrlOverride: _Harness.baseUrl,
    client: client,
  );

  final registry = buildProviderThinkingRegistry();
  final assembler = ThinkingCapabilityAssembler(registry);
  final cacheService = ProviderModelCacheService(
    repo,
    _StaticAdapterRuntimeService(config, repo, adapter),
    assembler,
    config: config,
  );

  final harness = _Harness._(
    scratch: scratch,
    state: state,
    repo: repo,
    config: config,
    adapter: adapter,
    cacheService: cacheService,
    selectionResolver: ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    ),
    compatRequests: compatRequests,
    nativeRequests: nativeRequests,
    chatBodies: chatBodies,
  );

  return harness;
}

/// Returns the real production adapter for the model-list refresh boundary.
class _StaticAdapterRuntimeService extends AgentRuntimeService {
  final LLMAdapter adapter;

  _StaticAdapterRuntimeService(super.config, super.instanceRepo, this.adapter);

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;
}

void main() {
  group('LM Studio native reasoning discovery', () {
    test(
      'native finite declaration becomes the authoritative declared descriptor',
      () async {
        final h = await _openHarness(
          nativeModels: [_nativeModel(key: _modelId)],
        );
        addTearDown(h.dispose);

        await h.cacheService.refresh(_Harness.instanceId, manual: true);

        expect(h.adapter.availableModelsSource, 'live');
        expect(h.compatRequests, hasLength(1));
        expect(h.nativeRequests, hasLength(1));

        final model = h.cachedModel();
        expect(model, isNotNull);

        final metadata = model!.modelMetadata;
        expect(metadata[_declaredControlKey], {
          'status': 'supported',
          'wire': 'openai_chat_effort',
          'options': {'low': 'low', 'medium': 'medium', 'high': 'high'},
          'default_option': 'medium',
        });
        expect(metadata[_reasoningEvidenceKey], {
          'allowed_options': ['off', 'on', 'low', 'medium', 'high'],
          'default': 'medium',
        });

        final descriptor = model.thinkingControl;
        expect(descriptor, isNotNull);
        expect(descriptor!.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.kind, ThinkingControlKind.effort);
        expect(descriptor.options.map((o) => o.id).toList(), [
          'low',
          'medium',
          'high',
        ]);
        expect(descriptor.options.map((o) => o.label).toList(), [
          'Low',
          'Medium',
          'High',
        ]);
        expect(descriptor.options.every((o) => !o.isOff), isTrue);
        expect(descriptor.defaultOptionId, 'medium');
        expect(descriptor.source, 'endpoint_declared');
      },
    );

    test('every advertised option arrives on the actual Chat body', () async {
      final h = await _openHarness(nativeModels: [_nativeModel(key: _modelId)]);
      addTearDown(h.dispose);

      await h.cacheService.refresh(_Harness.instanceId, manual: true);

      for (final option in ['low', 'medium', 'high']) {
        final body = await h.send(selectionId: option);
        expect(body['reasoning_effort'], option, reason: 'option $option');
        expect(
          body.containsKey('thinking'),
          isFalse,
          reason: 'no fabricated thinking envelope on the Chat wire',
        );
        expect(body['model'], _modelId);
      }
      expect(h.chatBodies, hasLength(3));
    });

    test(
      'a mappable native default is preserved as the default selection',
      () async {
        final h = await _openHarness(
          nativeModels: [_nativeModel(key: _modelId, defaultOption: 'high')],
        );
        addTearDown(h.dispose);

        await h.cacheService.refresh(_Harness.instanceId, manual: true);

        expect(h.cachedModel()!.thinkingControl!.defaultOptionId, 'high');

        final resolution = h.selectionResolver.resolve(
          providerInstanceId: _Harness.instanceId,
          modelId: _modelId,
          selectionId: null,
        );
        expect(resolution.directive, isA<OpenAiEffortDirective>());
        expect((resolution.directive as OpenAiEffortDirective).effort, 'high');

        final body = await h.send(selectionId: null);
        expect(body['reasoning_effort'], 'high');
      },
    );

    test('an unmappable native default is not invented as a level', () async {
      final h = await _openHarness(
        nativeModels: [_nativeModel(key: _modelId, defaultOption: 'on')],
      );
      addTearDown(h.dispose);

      await h.cacheService.refresh(_Harness.instanceId, manual: true);

      final descriptor = h.cachedModel()!.thinkingControl!;
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((o) => o.id).toList(), [
        'low',
        'medium',
        'high',
      ]);
      expect(descriptor.defaultOptionId, isNull);

      final resolution = h.selectionResolver.resolve(
        providerInstanceId: _Harness.instanceId,
        modelId: _modelId,
        selectionId: null,
      );
      expect(resolution.directive, isA<UseProviderDefault>());

      final body = await h.send(selectionId: null);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
    });

    test(
      'native-only boolean declaration keeps raw evidence and fabricates no level',
      () async {
        final h = await _openHarness(
          nativeModels: [
            _nativeModel(
              key: _modelId,
              allowedOptions: const ['off', 'on'],
              defaultOption: 'on',
            ),
          ],
        );
        addTearDown(h.dispose);

        await h.cacheService.refresh(_Harness.instanceId, manual: true);

        final metadata = h.cachedModel()!.modelMetadata;
        expect(metadata[_reasoningEvidenceKey], {
          'allowed_options': ['off', 'on'],
          'default': 'on',
        });
        expect(metadata.containsKey(_declaredControlKey), isFalse);

        final descriptor = h.cachedModel()!.thinkingControl!;
        expect(descriptor.status, ThinkingCapabilityStatus.unknown);
        expect(descriptor.options, isEmpty);
        expect(descriptor.defaultOptionId, isNull);

        expect(
          () => h.selectionResolver.resolve(
            providerInstanceId: _Harness.instanceId,
            modelId: _modelId,
            selectionId: 'medium',
          ),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.capabilityUnknown,
            ),
          ),
        );
        expect(h.chatBodies, isEmpty, reason: 'no lossy dispatch of a level');
      },
    );

    test('malformed finite lists and defaults fabricate nothing', () async {
      final malformed = <Object>[
        {
          'allowed_options': ['low', 'bogus'],
          'default': 'low',
        },
        {
          'allowed_options': ['low', 'medium'],
          'default': 'high',
        },
        {'allowed_options': 'low', 'default': 'low'},
        {'allowed_options': <Object?>[], 'default': 'low'},
        {
          'allowed_options': ['low', 3],
          'default': 'low',
        },
        {
          'allowed_options': ['low'],
          'default': 7,
        },
        'not-an-object',
      ];

      for (final reasoning in malformed) {
        final h = await _openHarness(
          nativeModels: [
            _nativeModel(key: _modelId, reasoningOverride: reasoning),
          ],
        );
        addTearDown(h.dispose);

        await h.cacheService.refresh(_Harness.instanceId, manual: true);

        final metadata = h.cachedModel()!.modelMetadata;
        expect(
          metadata.containsKey(_declaredControlKey),
          isFalse,
          reason: 'malformed evidence must not declare support: $reasoning',
        );
        expect(metadata.containsKey(_reasoningEvidenceKey), isFalse);
        expect(
          h.cachedModel()!.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(h.chatBodies, isEmpty);
      }
    });

    test('a failed or missing native probe preserves live discovery', () async {
      for (final harness in [
        await _openHarness(nativeModels: const [], nativeStatus: 500),
        await _openHarness(nativeModels: const [], nativeThrows: true),
        await _openHarness(nativeModels: 'malformed-native-payload'),
      ]) {
        addTearDown(harness.dispose);

        await harness.cacheService.refresh(_Harness.instanceId, manual: true);

        expect(harness.adapter.availableModelsSource, 'live');
        expect(harness.compatRequests, hasLength(1));
        expect(harness.nativeRequests, isNotEmpty);

        final model = harness.cachedModel();
        expect(model, isNotNull);
        expect(model!.label, isNotEmpty);
        expect(model.modelMetadata.containsKey(_declaredControlKey), isFalse);
        expect(model.modelMetadata.containsKey(_reasoningEvidenceKey), isFalse);
        expect(model.thinkingControl!.status, ThinkingCapabilityStatus.unknown);

        final body = await harness.send(selectionId: null);
        expect(body.containsKey('reasoning_effort'), isFalse);
        expect(body['model'], _modelId);
      }
    });

    test(
      'one native model may repeat its key as a loaded instance id',
      () async {
        final h = await _openHarness(
          nativeModels: [
            _nativeModel(
              key: _modelId,
              loadedInstanceIds: [_modelId, _modelId],
            ),
          ],
        );
        addTearDown(h.dispose);
        await h.cacheService.refresh(_Harness.instanceId, manual: true);
        expect(
          h.cachedModel()!.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        final body = await h.send(selectionId: 'high');
        expect(body['reasoning_effort'], 'high');
      },
    );

    test(
      'native discovery reuses configured endpoint authentication',
      () async {
        final h = await _openHarness(
          nativeModels: [_nativeModel(key: _modelId)],
          requireNativeAuth: true,
        );
        addTearDown(h.dispose);
        await h.cacheService.refresh(_Harness.instanceId, manual: true);
        expect(
          h.cachedModel()!.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        expect((await h.send(selectionId: 'high'))['reasoning_effort'], 'high');
      },
    );

    test(
      'native enrichment does not replace compatibility declarations',
      () async {
        const compatControl = {
          'status': 'supported',
          'wire': 'openai_chat_effort',
          'options': {'low': 'low'},
          'default_option': 'low',
        };
        final h = await _openHarness(
          nativeModels: [
            _nativeModel(
              key: _modelId,
              allowedOptions: const ['high'],
              defaultOption: 'high',
            ),
          ],
          compatMetadata: const {'thinking_control': compatControl},
        );
        addTearDown(h.dispose);
        await h.cacheService.refresh(_Harness.instanceId, manual: true);
        expect(
          h.cachedModel()!.modelMetadata['thinking_control'],
          compatControl,
        );
        expect(
          h.cachedModel()!.modelMetadata.containsKey(_reasoningEvidenceKey),
          isFalse,
        );
        expect((await h.send(selectionId: 'low'))['reasoning_effort'], 'low');
      },
    );

    test('identity matching is exact and ambiguity is rejected', () async {
      // Exact native key match.
      final byKey = await _openHarness(
        nativeModels: [_nativeModel(key: _modelId)],
      );
      addTearDown(byKey.dispose);
      await byKey.cacheService.refresh(_Harness.instanceId, manual: true);
      expect(
        byKey.cachedModel()!.thinkingControl!.status,
        ThinkingCapabilityStatus.supported,
      );

      // Loaded-instance identifier match against a differently keyed entry.
      final byInstanceId = await _openHarness(
        nativeModels: [
          _nativeModel(key: 'some-other-key', loadedInstanceIds: [_modelId]),
        ],
      );
      addTearDown(byInstanceId.dispose);
      await byInstanceId.cacheService.refresh(
        _Harness.instanceId,
        manual: true,
      );
      expect(
        byInstanceId.cachedModel()!.thinkingControl!.status,
        ThinkingCapabilityStatus.supported,
      );

      // Case-distinct identifiers stay distinct.
      final caseDistinct = await _openHarness(
        nativeModels: [_nativeModel(key: _modelId.toUpperCase())],
      );
      addTearDown(caseDistinct.dispose);
      await caseDistinct.cacheService.refresh(
        _Harness.instanceId,
        manual: true,
      );
      expect(
        caseDistinct.cachedModel()!.thinkingControl!.status,
        ThinkingCapabilityStatus.unknown,
      );

      // Absent from the native list.
      final absent = await _openHarness(
        nativeModels: [_nativeModel(key: 'some-other-key')],
      );
      addTearDown(absent.dispose);
      await absent.cacheService.refresh(_Harness.instanceId, manual: true);
      expect(
        absent.cachedModel()!.thinkingControl!.status,
        ThinkingCapabilityStatus.unknown,
      );

      // Two distinct native entries claiming the same compatibility id.
      final ambiguous = await _openHarness(
        nativeModels: [
          _nativeModel(key: _modelId, defaultOption: 'low'),
          _nativeModel(key: 'other-key', loadedInstanceIds: [_modelId]),
        ],
      );
      addTearDown(ambiguous.dispose);
      await ambiguous.cacheService.refresh(_Harness.instanceId, manual: true);
      final ambiguousModel = ambiguous.cachedModel()!;
      expect(
        ambiguousModel.thinkingControl!.status,
        ThinkingCapabilityStatus.unknown,
      );
      expect(
        ambiguousModel.modelMetadata.containsKey(_declaredControlKey),
        isFalse,
      );
    });

    test('request assembly performs no additional endpoint probe', () async {
      final h = await _openHarness(nativeModels: [_nativeModel(key: _modelId)]);
      addTearDown(h.dispose);

      await h.cacheService.refresh(_Harness.instanceId, manual: true);
      final nativeProbesAfterRefresh = h.nativeRequests.length;
      expect(nativeProbesAfterRefresh, 1);

      await h.send(selectionId: 'high');

      expect(h.nativeRequests, hasLength(nativeProbesAfterRefresh));
      expect(h.compatRequests, hasLength(1));
      expect(h.chatBodies, hasLength(1));
      expect(h.chatBodies.single['reasoning_effort'], 'high');
    });
  });
}
