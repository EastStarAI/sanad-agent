/// Production-bound regression coverage for bounded OpenRouter finite reasoning
/// declaration discovery (Plan 77 / Task 77I5).
///
/// The suite walks the real production path over one disposable Home, a
/// loopback `MockClient` aggregator endpoint and an in-memory state database:
///
/// `BaseOpenAIAdapter.getAvailableModels` (aggregator `/models` discovery with
/// each item's documented `reasoning` metadata) -> `ProviderModelCacheService`
/// -> `ThinkingCapabilityAssembler` declared-endpoint tier ->
/// `ThinkingSelectionResolver` -> `BaseOpenAIAdapter` actual
/// `/chat/completions` request body.
///
/// Scope boundaries: no real Home, credential, provider instance, runtime, UI or
/// model inference is involved and no request leaves the loopback mocks. This
/// suite implements finite effort evidence only: `supports_max_tokens` never
/// creates a budget option, default or bound, and no effort value is ever
/// remapped onto another value.
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
import 'package:sanad_agent/core/provider_thinking/thinking_wire_vocabulary.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

import '../../support/thinking_matchers.dart';

/// A genuinely unknown synthetic aggregator model: absent from the models.dev
/// catalog's reasoning facts, absent from every shipped effort catalog, and
/// carrying no reasoning-suggestive name. Its only path to a supported control
/// is the documented discovery declaration under test.
const _modelId = 'synthvendor/relay-mystery-9';

/// Same trailing identifier under a different vendor namespace.
const _siblingModelId = 'othervendor/relay-mystery-9';

/// Case-distinct variant of the same logical identifier.
const _caseModelId = 'SynthVendor/Relay-Mystery-9';

/// Unknown synthetic id whose name merely suggests reasoning output.
const _suggestiveModelId = 'synthvendor/o3-reasoning-mystery-9';

/// Model whose only control evidence is its models.dev catalog entry.
const _evidencedModelId = 'openai/o3-mini';

const _declaredControlKey = 'thinking_control';
const _rawEvidenceKey = 'reasoning';

/// One documented aggregator `GET /models` item
/// (`https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md`).
Map<String, Object?> _item({
  required String id,
  Object? reasoning = const {
    'supported_efforts': ['high', 'medium', 'low'],
    'default_effort': 'low',
    'default_enabled': true,
  },
  bool includeReasoning = true,
  Object? contextLength = 400000,
}) {
  return {
    'id': id,
    'object': 'model',
    'owned_by': id.split('/').first,
    'name': id,
    'context_length': ?contextLength,
    if (includeReasoning) 'reasoning': reasoning,
  };
}

/// Mutable wire state so one harness can be healed and broken again.
class _Wire {
  _Wire({required this.items});

  List<Map<String, Object?>> items;
  int modelsStatus = 200;
  bool modelsThrow = false;
}

class _Harness {
  static const baseUrl = 'http://127.0.0.1:1234/v1';
  static const instanceId = 'inst-openrouter-discovery';

  final Directory scratch;
  final AgentStateDatabase state;
  final ProviderInstanceRepository repo;
  final Config config;
  final BaseOpenAIAdapter adapter;
  final ProviderModelCacheService cacheService;
  final ThinkingSelectionResolver selectionResolver;
  final _Wire wire;

  /// Live observations written by the loopback mocks.
  final List<String> modelsRequests;
  final List<Map<String, dynamic>> chatBodies;
  final List<String> modelsDevRequests;

  _Harness._({
    required this.scratch,
    required this.state,
    required this.repo,
    required this.config,
    required this.adapter,
    required this.cacheService,
    required this.selectionResolver,
    required this.wire,
    required this.modelsRequests,
    required this.chatBodies,
    required this.modelsDevRequests,
  });

  Future<List<ModelOption>> refresh() =>
      cacheService.refresh(instanceId, manual: true);

  ModelOption? cachedModel([String model = _modelId]) {
    final models = cacheService.snapshot(instanceId);
    if (models == null) return null;
    for (final option in models) {
      if (option.value == model) return option;
    }
    return null;
  }

  List<ModelOption> cachedModels() => cacheService.snapshot(instanceId) ?? [];

  /// Resolves the production selection, then dispatches one real adapter request
  /// and returns the actual captured Chat body.
  Future<Map<String, dynamic>> send({
    String? selectionId,
    String model = _modelId,
  }) async {
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

  /// Resolves one production selection without dispatching.
  ThinkingSelectionResolution resolve({
    String? selectionId,
    String model = _modelId,
  }) {
    return selectionResolver.resolve(
      providerInstanceId: instanceId,
      modelId: model,
      selectionId: selectionId,
    );
  }

  void writeConfigYaml(String yaml) {
    File('${scratch.path}/config.yaml').writeAsStringSync(yaml);
  }

  void dispose() {
    GetIt.I.reset();
    setSanadHomeOverride(null);
    state.dispose();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

/// The minimal models.dev catalog that admits the synthetic aggregator models to
/// production discovery (production OpenRouter discovery filters non-catalog
/// ids), with no reasoning facts of its own.
Map<String, Object?> _devCatalog(
  Iterable<String> ids, {
  Map<String, Map<String, Object?>> reasoningFacts = const {},
}) {
  return {
    'openrouter': {
      'models': {
        for (final id in ids)
          id: {
            'name': id,
            'tool_call': true,
            'limit': {'context': 262144},
            ...?reasoningFacts[id],
          },
      },
    },
  };
}

/// Builds the isolated production-path harness.
///
/// [wire] may be mutated by a test to change the aggregator payload, and
/// [requireAuth] makes the mock endpoint demand the configured discovery
/// authentication and profile headers.
Future<_Harness> _openHarness({
  _Wire? wire,
  bool requireAuth = false,
  String? configYaml,
  List<String>? agenticIds,
  String profileName = 'openrouter',
  Map<String, Map<String, Object?>> reasoningFacts = const {},
}) async {
  final scratch = Directory.systemTemp.createTempSync('sanad-openrouter-');
  setSanadHomeOverride(scratch.path);
  final state = AgentStateDatabase.inMemory();
  final repo = ProviderInstanceRepository.fromDatabase(state.db);
  final config = Config(environment: const {});

  repo.createInstance(
    ProviderInstance(
      id: _Harness.instanceId,
      templateId: profileName,
      displayName: 'Gateway',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      defaultModel: _modelId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );

  if (configYaml != null) {
    File('${scratch.path}/config.yaml').writeAsStringSync(configYaml);
    config.reloadModelAwarePolicy();
  }

  final activeWire =
      wire ??
      _Wire(
        items: [
          _item(id: _modelId),
          _item(id: _siblingModelId, contextLength: null),
        ],
      );
  final modelsRequests = <String>[];
  final chatBodies = <Map<String, dynamic>>[];
  final modelsDevRequests = <String>[];

  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/v1/models') {
      modelsRequests.add(request.url.toString());
      if (requireAuth) {
        if (request.headers['authorization'] != 'Bearer fixture-key' ||
            request.headers['http-referer'] != 'https://sanad.eaststarai.com') {
          return http.Response('fixture authentication required', 401);
        }
      }
      if (activeWire.modelsThrow) {
        throw const SocketException('models endpoint refused');
      }
      if (activeWire.modelsStatus != 200) {
        return http.Response(
          'models endpoint failure',
          activeWire.modelsStatus,
        );
      }
      return http.Response(jsonEncode({'data': activeWire.items}), 200);
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

  final catalog = _devCatalog(
    agenticIds ??
        [_modelId, _siblingModelId, _caseModelId, ...reasoningFacts.keys],
    reasoningFacts: reasoningFacts,
  );
  final modelsDevClient = MockClient((request) async {
    modelsDevRequests.add(request.url.toString());
    return http.Response(jsonEncode(catalog), 200);
  });
  final modelsDevService = ModelsDevService(
    client: modelsDevClient,
    cacheFilePathOverride: '${scratch.path}/models_dev_cache.json',
  );

  final adapter = BaseOpenAIAdapter(
    config,
    ProviderRegistry.findByNameOrAlias(profileName)!,
    providerInstanceId: _Harness.instanceId,
    defaultModelOverride: _modelId,
    apiKeyOverride: 'fixture-key',
    baseUrlOverride: _Harness.baseUrl,
    client: client,
    modelsDevService: modelsDevService,
  );

  final registry = buildProviderThinkingRegistry();
  final assembler = ThinkingCapabilityAssembler(
    registry,
    config,
    modelsDevService.modelEntrySync,
  );
  final cacheService = ProviderModelCacheService(
    repo,
    _StaticAdapterRuntimeService(config, repo, adapter),
    assembler,
    config: config,
    modelsDevService: modelsDevService,
  );

  return _Harness._(
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
      config: config,
    ),
    wire: activeWire,
    modelsRequests: modelsRequests,
    chatBodies: chatBodies,
    modelsDevRequests: modelsDevRequests,
  );
}

/// Returns the real production adapter for the model-list refresh boundary.
class _StaticAdapterRuntimeService extends AgentRuntimeService {
  final LLMAdapter adapter;

  _StaticAdapterRuntimeService(super.config, super.instanceRepo, this.adapter);

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;
}

/// The seven documented gateway effort values in documented descending order.
const _documentedGatewayEfforts = <String>[
  'max',
  'xhigh',
  'high',
  'medium',
  'low',
  'minimal',
  'none',
];

/// Explicit unknown route-control evidence published when the discovery wire
/// documents `reasoning` for a model but yields no representable declaration.
const _unresolvedControl = {'status': 'unknown'};

/// Model-only configuration override used to prove override precedence.
String _overrideYaml(String modelId) =>
    '''
model_capabilities:
  "$modelId":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: low
      default_option: low
''';

/// Owned declaration expected for a finite documented effort list.
Map<String, Object?> _declared(List<String> options, [String? defaultOption]) {
  return {
    'status': 'supported',
    'wire': 'openai_chat_effort',
    'options': {for (final option in options) option: option},
    'default_option': ?defaultOption,
  };
}

void main() {
  group('OpenRouter finite reasoning discovery', () {
    test(
      'live discovery turns the documented declaration into the authoritative '
      'descriptor without disturbing other metadata',
      () async {
        final h = await _openHarness();
        addTearDown(h.dispose);

        await h.refresh();

        expect(h.adapter.availableModelsSource, 'live');
        expect(h.modelsRequests, hasLength(1));

        final model = h.cachedModel();
        expect(model, isNotNull);
        expect(model!.label, 'Relay Mystery 9');
        expect(model.provider, 'openrouter');
        expect(model.contextWindow, 400000);
        expect(model.supportsReasoningOutput, isFalse);
        expect(
          h.cachedModel(_siblingModelId)!.contextWindow,
          262144,
          reason: 'unrelated context metadata stays untouched by discovery',
        );
        expect(model.modelMetadata['object'], 'model');
        expect(model.modelMetadata['owned_by'], 'synthvendor');
        expect(model.modelMetadata[_rawEvidenceKey], {
          'supported_efforts': ['high', 'medium', 'low'],
          'default_effort': 'low',
          'default_enabled': true,
        });
        expect(
          model.modelMetadata[_declaredControlKey],
          _declared(['high', 'medium', 'low'], 'low'),
        );

        final descriptor = model.thinkingControl;
        expect(descriptor, isNotNull);
        expect(descriptor!.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.kind, ThinkingControlKind.effort);
        expect(descriptor.options.map((o) => o.id).toList(), [
          'high',
          'medium',
          'low',
        ]);
        expect(descriptor.options.map((o) => o.label).toList(), [
          'High',
          'Medium',
          'Low',
        ]);
        expect(descriptor.options.every((o) => !o.isOff), isTrue);
        expect(descriptor.options.every((o) => !o.isProviderDefault), isTrue);
        expect(descriptor.defaultOptionId, 'low');
        expect(descriptor.source, 'endpoint_declared');
      },
    );

    test('every advertised effort reaches the actual Chat body with its exact '
        'documented value', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['xhigh', 'high', 'medium', 'low'],
                'default_effort': 'medium',
                'default_enabled': true,
                'mandatory': false,
                'supports_max_tokens': true,
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);

      await h.refresh();

      final advertised = h
          .cachedModel()!
          .thinkingControl!
          .options
          .map((o) => o.id)
          .toList();
      expect(advertised, ['xhigh', 'high', 'medium', 'low']);

      for (final option in advertised) {
        final body = await h.send(selectionId: option);
        expect(body['reasoning'], {
          'enabled': true,
          'effort': option,
        }, reason: 'advertised option $option must keep its exact value');
        expect(body['model'], _modelId);
        expect(
          body.containsKey('reasoning_effort'),
          isFalse,
          reason: 'the aggregator envelope owns the wire shape',
        );
        expect(body.containsKey('max_tokens'), isFalse);
        expect(body.containsKey('max_completion_tokens'), isFalse);
      }
      expect(h.chatBodies, hasLength(advertised.length));
      expect(
        (h.cachedModel()!.modelMetadata[_rawEvidenceKey]!
            as Map)['supports_max_tokens'],
        isTrue,
        reason: 'documented budget support stays raw evidence only',
      );
      expect(
        h.cachedModel()!.thinkingControl!.kind,
        ThinkingControlKind.effort,
      );
      expect(
        h.cachedModel()!.thinkingControl!.options.every(
          (option) => !option.isOff,
        ),
        isTrue,
      );
    });

    test(
      'a documented default is descriptor metadata only: an omitted, empty or '
      'whitespace selection stays plain provider-default omission, and the '
      'documented value is sent only when it is selected',
      () async {
        final withDefault = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': ['high', 'low'],
                  'default_effort': 'high',
                },
              ),
            ],
          ),
        );
        addTearDown(withDefault.dispose);
        await withDefault.refresh();

        expect(
          withDefault.cachedModel()!.thinkingControl!.defaultOptionId,
          'high',
          reason: 'the documented default stays truthful descriptor metadata',
        );
        // Omission is never turned into an explicit request field, even with a
        // documented default: the default is dispatched only when it is actually
        // selected.
        final resolution = withDefault.resolve();
        expect(resolution.directive, isA<UseProviderDefault>());
        expect((await withDefault.send()).containsKey('reasoning'), isFalse);
        expect((await withDefault.send(selectionId: 'high'))['reasoning'], {
          'enabled': true,
          'effort': 'high',
        });

        final withoutDefault = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': ['high', 'low'],
                },
              ),
            ],
          ),
        );
        addTearDown(withoutDefault.dispose);
        await withoutDefault.refresh();

        final descriptor = withoutDefault.cachedModel()!.thinkingControl!;
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.defaultOptionId, isNull);
        expect(withoutDefault.resolve().directive, isA<UseProviderDefault>());

        final body = await withoutDefault.send();
        expect(body.containsKey('reasoning'), isFalse);
        expect(body['model'], _modelId);
      },
    );

    test('default_effort none documents off-by-default and never preselects a '
        'disable', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['max', 'high', 'low', 'minimal', 'none'],
                'default_effort': 'none',
                'default_enabled': true,
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);
      await h.refresh();

      final descriptor = h.cachedModel()!.thinkingControl!;
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((o) => o.id).toList(), [
        'max',
        'high',
        'low',
        'minimal',
        'none',
      ]);
      expect(descriptor.defaultOptionId, isNull);
      expect(descriptor.options.last.isOff, isTrue);
      expect(
        descriptor.options.last.label,
        'None',
        reason: 'the existing descriptor labels the documented effort value',
      );
      expect(h.resolve().directive, isA<UseProviderDefault>());

      expect((await h.send())['reasoning'], isNull);
      expect((await h.send(selectionId: 'none'))['reasoning'], {
        'effort': 'none',
      });
      expect((await h.send(selectionId: 'minimal'))['reasoning'], {
        'enabled': true,
        'effort': 'minimal',
      });
    });

    test('default_enabled is a genuine Boolean that never invents an effort '
        'default', () async {
      final enabledNoEffort = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'low'],
                'default_enabled': true,
              },
            ),
          ],
        ),
      );
      addTearDown(enabledNoEffort.dispose);
      await enabledNoEffort.refresh();
      expect(
        enabledNoEffort.cachedModel()!.thinkingControl!.defaultOptionId,
        isNull,
        reason: 'no default effort is implied by default_enabled',
      );

      final disabled = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'low'],
                'default_effort': 'high',
                'default_enabled': false,
              },
            ),
          ],
        ),
      );
      addTearDown(disabled.dispose);
      await disabled.refresh();

      final descriptor = disabled.cachedModel()!.thinkingControl!;
      expect(descriptor.options.map((o) => o.id).toList(), ['high', 'low']);
      expect(
        descriptor.defaultOptionId,
        isNull,
        reason: 'reasoning is off by default, so Default stays omission',
      );
      expect(disabled.resolve().directive, isA<UseProviderDefault>());
      expect((await disabled.send()).containsKey('reasoning'), isFalse);

      final malformed = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'low'],
                'default_enabled': 'yes',
              },
            ),
          ],
        ),
      );
      addTearDown(malformed.dispose);
      await malformed.refresh();
      final malformedModel = malformed.cachedModel()!;
      expect(
        malformedModel.modelMetadata[_declaredControlKey],
        _unresolvedControl,
        reason:
            'a non-Boolean flag is not a genuine declaration, so the exact '
            'route publishes unknown control evidence instead',
      );
      expect(
        malformedModel.modelMetadata[_rawEvidenceKey],
        isNotNull,
        reason: 'raw discovery evidence is preserved verbatim',
      );
      final malformedDescriptor = malformedModel.thinkingControl!;
      expect(malformedDescriptor.status, ThinkingCapabilityStatus.unknown);
      expect(malformedDescriptor.source, 'endpoint_declared');
      expect(malformedDescriptor.options, isEmpty);
      expect(malformedDescriptor.defaultOptionId, isNull);
    });

    test(
      'mandatory models advertise no Off option and reject a stale Off before '
      'any dispatch',
      () async {
        final h = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': ['high', 'medium', 'none'],
                  'default_effort': 'medium',
                  'mandatory': true,
                },
              ),
            ],
          ),
        );
        addTearDown(h.dispose);
        await h.refresh();

        final descriptor = h.cachedModel()!.thinkingControl!;
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.options.map((o) => o.id).toList(), [
          'high',
          'medium',
        ]);
        expect(descriptor.options.every((o) => !o.isOff), isTrue);
        expect(descriptor.defaultOptionId, 'medium');

        for (final stale in ['none', 'off']) {
          expect(
            () => h.resolve(selectionId: stale),
            throwsA(
              isA<ThinkingSelectionException>().having(
                (e) => e.code,
                'code',
                ThinkingSelectionErrorCode.optionUnavailable,
              ),
            ),
            reason: 'a stale disabled selection must be refused, not remapped',
          );
        }
        expect(h.chatBodies, isEmpty, reason: 'zero dispatch for Off');

        expect((await h.send(selectionId: 'high'))['reasoning'], {
          'enabled': true,
          'effort': 'high',
        });
      },
    );

    test('a mandatory route keeps its documented max/minimal tiers without a '
        'disable', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['max', 'minimal', 'none'],
                'default_effort': 'max',
                'mandatory': true,
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);
      await h.refresh();

      final descriptor = h.cachedModel()!.thinkingControl!;
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((o) => o.id).toList(), ['max', 'minimal']);
      expect(descriptor.options.every((o) => !o.isOff), isTrue);
      expect(descriptor.defaultOptionId, 'max');
      for (final stale in ['none', 'off']) {
        expect(
          () => h.resolve(selectionId: stale),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.optionUnavailable,
            ),
          ),
        );
      }
      expect(h.chatBodies, isEmpty, reason: 'no disable dispatch');
      expect((await h.send(selectionId: 'minimal'))['reasoning'], {
        'enabled': true,
        'effort': 'minimal',
      });
    });

    test('an omitted mandatory member is not inferred to be false', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'none'],
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);
      await h.refresh();

      final descriptor = h.cachedModel()!.thinkingControl!;
      expect(descriptor.options.map((o) => o.id).toList(), ['high', 'none']);
      expect(descriptor.options.last.isOff, isTrue);
      expect((await h.send(selectionId: 'none'))['reasoning'], {
        'effort': 'none',
      });
    });

    test(
      'an Off-only declaration stays an honest single-option control',
      () async {
        final h = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': ['none'],
                },
              ),
            ],
          ),
        );
        addTearDown(h.dispose);
        await h.refresh();

        final descriptor = h.cachedModel()!.thinkingControl!;
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.options.map((o) => o.id).toList(), ['none']);
        expect(descriptor.options.single.isOff, isTrue);
        expect(descriptor.defaultOptionId, isNull);
        expect(h.resolve().directive, isA<UseProviderDefault>());
        expect((await h.send(selectionId: 'none'))['reasoning'], {
          'effort': 'none',
        });
      },
    );

    test(
      'explicit null, empty and missing effort members are distinguishable and '
      'never revive an unrelated ladder',
      () async {
        final explicitNull = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': null,
                  'default_effort': 'high',
                },
              ),
            ],
          ),
        );
        addTearDown(explicitNull.dispose);
        await explicitNull.refresh();

        final nullModel = explicitNull.cachedModel()!;
        expect(nullModel.modelMetadata[_rawEvidenceKey], {
          'supported_efforts': null,
          'default_effort': 'high',
        });
        expect(
          nullModel.modelMetadata[_declaredControlKey],
          _declared(_documentedGatewayEfforts, 'high'),
          reason:
              'an explicit null documents every gateway value and is declared '
              'truthfully in documented descending order',
        );
        final nullDescriptor = nullModel.thinkingControl!;
        expect(nullDescriptor.status, ThinkingCapabilityStatus.supported);
        expect(
          nullDescriptor.options.map((o) => o.id).toList(),
          _documentedGatewayEfforts,
        );
        expect(
          nullDescriptor.options.map((o) => o.id).toSet(),
          ThinkingWireVocabulary.effortIds,
          reason: 'discovery and the typed vocabulary must not drift',
        );
        expect(nullDescriptor.defaultOptionId, 'high');
        expect(nullDescriptor.options.singleWhere((o) => o.isOff).id, 'none');

        // Literal, independently documented bodies for every one of the seven
        // advertised values: exactly `none` is the disable envelope and every
        // other documented value keeps its own enabled-effort envelope.
        const expectedBodies = <String, Map<String, Object>>{
          'max': {'enabled': true, 'effort': 'max'},
          'xhigh': {'enabled': true, 'effort': 'xhigh'},
          'high': {'enabled': true, 'effort': 'high'},
          'medium': {'enabled': true, 'effort': 'medium'},
          'low': {'enabled': true, 'effort': 'low'},
          'minimal': {'enabled': true, 'effort': 'minimal'},
          'none': {'effort': 'none'},
        };
        expect(
          expectedBodies.keys.toList(),
          _documentedGatewayEfforts,
          reason:
              'the literal bodies cover exactly the documented gateway values',
        );
        for (final advertised in nullDescriptor.options.map((o) => o.id)) {
          final body = await explicitNull.send(selectionId: advertised);
          expect(
            body['reasoning'],
            expectedBodies[advertised],
            reason: 'advertised value $advertised must keep its exact envelope',
          );
          expect(body['model'], _modelId);
          expect(
            body.containsKey('reasoning_effort'),
            isFalse,
            reason: 'the aggregator envelope owns the wire shape',
          );
          expect(body.containsKey('max_tokens'), isFalse);
          expect(body.containsKey('max_completion_tokens'), isFalse);
        }
        expect(explicitNull.chatBodies, hasLength(7));

        // A known documented default never turns an omitted, empty or
        // whitespace-only selection into a request field.
        for (final omittedSelection in <String?>[null, '', '   ']) {
          expect(
            explicitNull.resolve(selectionId: omittedSelection).directive,
            isA<UseProviderDefault>(),
            reason:
                'selection "$omittedSelection" is provider-default omission',
          );
          final body = await explicitNull.send(selectionId: omittedSelection);
          expect(
            body.containsKey('reasoning'),
            isFalse,
            reason:
                'selection "$omittedSelection" must omit thinking fields even '
                'though default_option_id is a known "high"',
          );
          expect(body['model'], _modelId);
        }
        expect(explicitNull.chatBodies, hasLength(10));

        final empty = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': <String>[],
                  'default_effort': 'high',
                },
              ),
            ],
          ),
        );
        addTearDown(empty.dispose);
        await empty.refresh();
        final emptyModel = empty.cachedModel()!;
        expect(emptyModel.modelMetadata[_rawEvidenceKey], {
          'supported_efforts': <String>[],
          'default_effort': 'high',
        });
        expect(
          emptyModel.modelMetadata[_declaredControlKey],
          _unresolvedControl,
          reason:
              'an empty list documents no effort choice, which is explicit '
              'route evidence rather than absent evidence',
        );
        expect(
          emptyModel.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(emptyModel.thinkingControl!.source, 'endpoint_declared');

        final omitted = await _openHarness(
          wire: _Wire(
            items: [
              _item(id: _modelId, reasoning: const {'default_enabled': true}),
            ],
          ),
        );
        addTearDown(omitted.dispose);
        await omitted.refresh();
        final omittedModel = omitted.cachedModel()!;
        expect(omittedModel.modelMetadata[_rawEvidenceKey], {
          'default_enabled': true,
        });
        expect(
          omittedModel.modelMetadata[_declaredControlKey],
          _unresolvedControl,
          reason:
              'a present reasoning member without an effort member documents '
              'no effort selector for this route',
        );
        expect(
          omittedModel.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(
          () => omitted.resolve(selectionId: 'high'),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'every documented canonical effort is declared truthfully and reaches the '
      'exact body, including minimal beside low and max beside xhigh',
      () async {
        for (final entry in [
          (
            efforts: <String>[
              'max',
              'xhigh',
              'high',
              'medium',
              'low',
              'minimal',
              'none',
            ],
            defaultEffort: 'xhigh',
          ),
          (efforts: <String>['max', 'xhigh', 'low'], defaultEffort: 'xhigh'),
          (efforts: <String>['minimal', 'low'], defaultEffort: 'low'),
          (efforts: <String>['max', 'low'], defaultEffort: 'max'),
          (efforts: <String>['minimal', 'max'], defaultEffort: null),
        ]) {
          final h = await _openHarness(
            wire: _Wire(
              items: [
                _item(
                  id: _modelId,
                  reasoning: {
                    'supported_efforts': entry.efforts,
                    'default_effort': ?entry.defaultEffort,
                  },
                ),
              ],
            ),
          );
          addTearDown(h.dispose);
          await h.refresh();

          final model = h.cachedModel()!;
          expect(model.modelMetadata[_rawEvidenceKey], {
            'supported_efforts': entry.efforts,
            if (entry.defaultEffort != null)
              'default_effort': entry.defaultEffort,
          }, reason: 'documented ${entry.efforts} must stay verbatim');
          expect(
            model.modelMetadata[_declaredControlKey],
            _declared(entry.efforts, entry.defaultEffort),
            reason:
                'documented ${entry.efforts} is declared without reduction, '
                'clamping or aliasing',
          );

          final descriptor = model.thinkingControl!;
          expect(descriptor.status, ThinkingCapabilityStatus.supported);
          expect(
            descriptor.options.map((o) => o.id).toList(),
            entry.efforts,
            reason: 'the documented finite set and its order are exact',
          );
          expect(descriptor.defaultOptionId, entry.defaultEffort);
          expect(descriptor.source, 'endpoint_declared');

          for (final effort in entry.efforts) {
            final expected = effort == 'none'
                ? const {'effort': 'none'}
                : {'enabled': true, 'effort': effort};
            final body = await h.send(selectionId: effort);
            expect(
              body['reasoning'],
              expected,
              reason:
                  'documented effort $effort keeps its own exact value with no '
                  'clamping, promotion or legacy alias remap',
            );
            expect(body['model'], _modelId);
            expect(body.containsKey('reasoning_effort'), isFalse);
          }
          expect(h.chatBodies, hasLength(entry.efforts.length));
        }
      },
    );

    test(
      'malformed declarations fabricate no support and publish explicit unknown '
      'route evidence',
      () async {
        final malformed = <Object>[
          'not-an-object',
          {'supported_efforts': 'high'},
          {
            'supported_efforts': ['High'],
          },
          {
            'supported_efforts': [' high '],
          },
          {
            'supported_efforts': ['bogus'],
          },
          {
            'supported_efforts': ['high', 'high'],
          },
          {
            'supported_efforts': ['high', 3],
          },
          {
            'supported_efforts': ['high', null],
          },
          {
            'supported_efforts': ['low'],
            'default_effort': 5,
          },
          {
            'supported_efforts': ['low'],
            'default_effort': 'high',
          },
          {
            'supported_efforts': ['low'],
            'default_effort': '',
          },
          {
            'supported_efforts': ['low'],
            'mandatory': 'true',
          },
          {
            'supported_efforts': ['low'],
            'mandatory': null,
          },
          {
            'supported_efforts': ['low'],
            'default_enabled': 1,
          },
          {
            'supported_efforts': ['none'],
            'mandatory': true,
          },
        ];

        for (final reasoning in malformed) {
          final h = await _openHarness(
            wire: _Wire(
              items: [_item(id: _modelId, reasoning: reasoning)],
            ),
          );
          addTearDown(h.dispose);
          await h.refresh();

          final model = h.cachedModel()!;
          expect(
            model.modelMetadata[_declaredControlKey],
            _unresolvedControl,
            reason: 'malformed evidence declares no support: $reasoning',
          );
          expect(
            model.modelMetadata[_rawEvidenceKey],
            reasoning,
            reason: 'raw discovery evidence stays verbatim: $reasoning',
          );
          expect(
            model.thinkingControl!.status,
            ThinkingCapabilityStatus.unknown,
          );
          expect(model.thinkingControl!.source, 'endpoint_declared');
          expect(model.thinkingControl!.options, isEmpty);
          expect(model.thinkingControl!.defaultOptionId, isNull);

          expect(() => h.resolve(selectionId: 'low'), sendsNoThinkingField);
          expect(h.chatBodies, isEmpty);
        }
      },
    );

    test(
      'the route authority answers for models with no usable aggregator '
      'evidence while an intrinsic catalog model keeps its knowledge',
      () async {
        final unknown = await _openHarness(
          wire: _Wire(items: [_item(id: _modelId, includeReasoning: false)]),
        );
        addTearDown(unknown.dispose);
        await unknown.refresh();

        final unknownModel = unknown.cachedModel()!;
        expect(
          unknownModel.modelMetadata.containsKey(_declaredControlKey),
          isFalse,
        );
        expect(
          unknownModel.modelMetadata.containsKey(_rawEvidenceKey),
          isFalse,
        );
        // No settings, provider-reported or models.dev evidence: unknown,
        // never a fabricated `unsupported`.
        expect(
          unknownModel.thinkingControl!.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(unknownModel.thinkingControl!.source, 'unconfigured');

        // The same absence must not veto the serving vendor's models.dev facts.
        final evidenced = await _openHarness(
          wire: _Wire(
            items: [_item(id: _evidencedModelId, includeReasoning: false)],
          ),
          reasoningFacts: const {
            _evidencedModelId: {
              'reasoning': true,
              'reasoning_options': [
                {
                  'type': 'effort',
                  'values': ['low', 'medium', 'high'],
                },
              ],
            },
          },
        );
        addTearDown(evidenced.dispose);
        await evidenced.refresh();

        final evidencedModel = evidenced.cachedModel(_evidencedModelId)!;
        expect(
          evidencedModel.modelMetadata.containsKey(_declaredControlKey),
          isFalse,
        );
        expect(
          evidencedModel.thinkingControl!.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(
          evidencedModel.thinkingControl!.options.map((o) => o.id).toList(),
          ['low', 'medium', 'high'],
        );
        // The shipped default (layer 3) for this exact id answers before the
        // models.dev entry (layer 4); the facts agree.
        expect(evidencedModel.thinkingControl!.source, 'shipped_default');
        expect(evidencedModel.thinkingControl!.defaultOptionId, 'medium');

        // A names-only item that merely suggests reasoning output authorizes no
        // selectable control.
        final suggestive = await _openHarness(
          wire: _Wire(
            items: [_item(id: _suggestiveModelId, includeReasoning: false)],
          ),
          agenticIds: const [_suggestiveModelId],
        );
        addTearDown(suggestive.dispose);
        await suggestive.refresh();

        final suggestiveModel = suggestive.cachedModel(_suggestiveModelId)!;
        expect(suggestiveModel.supportsReasoningOutput, isTrue);
        expect(
          suggestiveModel.modelMetadata.containsKey(_declaredControlKey),
          isFalse,
        );
        expect(
          suggestiveModel.thinkingControl!.status,
          isNot(ThinkingCapabilityStatus.supported),
        );
        expect(suggestiveModel.thinkingControl!.options, isEmpty);
        expect(
          () => suggestive.resolve(selectionId: 'high'),
          sendsNoThinkingField,
        );
        expect(suggestive.chatBodies, isEmpty);
      },
    );

    test(
      'a generic custom Chat endpoint never consumes the aggregator schema',
      () async {
        final h = await _openHarness(
          profileName: kCustomProviderTemplateId,
          wire: _Wire(
            items: [
              _item(
                id: _modelId,
                reasoning: const {
                  'supported_efforts': ['high', 'low'],
                  'default_effort': 'low',
                },
              ),
            ],
          ),
        );
        addTearDown(h.dispose);
        await h.refresh();

        final model = h.cachedModel()!;
        expect(model.modelMetadata[_rawEvidenceKey], {
          'supported_efforts': ['high', 'low'],
          'default_effort': 'low',
        }, reason: 'the item is discovered, but its schema is not consumed');
        expect(model.modelMetadata.containsKey(_declaredControlKey), isFalse);
        expect(model.thinkingControl!.status, ThinkingCapabilityStatus.unknown);
        expect(model.thinkingControl!.options, isEmpty);
        expect(() => h.resolve(selectionId: 'high'), sendsNoThinkingField);
        expect(h.chatBodies, isEmpty);
      },
    );

    test(
      'a discovered declaration is authoritative for its exact route and wins '
      'over intrinsic catalog knowledge',
      () async {
        final h = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _evidencedModelId,
                reasoning: const {
                  'supported_efforts': ['high', 'none'],
                  'default_effort': 'high',
                },
              ),
            ],
          ),
        );
        addTearDown(h.dispose);
        await h.refresh();

        final descriptor = h.cachedModel(_evidencedModelId)!.thinkingControl!;
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.options.map((o) => o.id).toList(), ['high', 'none']);
        expect(descriptor.defaultOptionId, 'high');
        expect(descriptor.source, 'endpoint_declared');
        expect(
          (await h.send(
            selectionId: 'none',
            model: _evidencedModelId,
          ))['reasoning'],
          {'effort': 'none'},
        );
      },
    );

    test('the full documented vocabulary is authoritative for a catalog-known '
        'exact route', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _evidencedModelId,
              reasoning: const {
                'supported_efforts': ['max', 'minimal'],
                'default_effort': 'max',
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);
      await h.refresh();

      final descriptor = h.cachedModel(_evidencedModelId)!.thinkingControl!;
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((o) => o.id).toList(), [
        'max',
        'minimal',
      ], reason: 'the documented set wins over the intrinsic catalog ladder');
      expect(descriptor.defaultOptionId, 'max');
      expect(descriptor.source, 'endpoint_declared');
      // A tier outside the documented set clamps to the nearest lower
      // documented level; it never escalates.
      expect(
        h.resolve(selectionId: 'medium', model: _evidencedModelId).selectionId,
        'minimal',
      );
      expect(
        () => h.resolve(selectionId: 'none', model: _evidencedModelId),
        throwsA(isA<ThinkingSelectionException>()),
        reason: 'nothing lower than the documented set exists to clamp to',
      );
      expect(
        (await h.send(
          selectionId: 'max',
          model: _evidencedModelId,
        ))['reasoning'],
        {'enabled': true, 'effort': 'max'},
      );
      expect(
        (await h.send(
          selectionId: 'minimal',
          model: _evidencedModelId,
        ))['reasoning'],
        {'enabled': true, 'effort': 'minimal'},
      );

      // Explicit null documents all seven gateway values on the same exact
      // catalog-known route, and `none` alone stays the disable envelope.
      final allValues = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _evidencedModelId,
              reasoning: const {'supported_efforts': null},
            ),
          ],
        ),
      );
      addTearDown(allValues.dispose);
      await allValues.refresh();

      final allDescriptor = allValues
          .cachedModel(_evidencedModelId)!
          .thinkingControl!;
      expect(allDescriptor.status, ThinkingCapabilityStatus.supported);
      expect(
        allDescriptor.options.map((o) => o.id).toList(),
        _documentedGatewayEfforts,
      );
      // The gateway declares no default; the shipped record for the exact id
      // fills its documented `medium`, one of the gateway options (default
      // fill, 2026-10-21). Options still come only from the gateway.
      expect(allDescriptor.defaultOptionId, 'medium');
      expect(allDescriptor.defaultSource, 'shipped_default');
      expect(
        (await allValues.send(
          selectionId: 'none',
          model: _evidencedModelId,
        ))['reasoning'],
        {'effort': 'none'},
      );
      expect(
        (await allValues.send(
          selectionId: 'xhigh',
          model: _evidencedModelId,
        ))['reasoning'],
        {'enabled': true, 'effort': 'xhigh'},
      );
    });

    test(
      'unusable route evidence on a known model keeps intrinsic facts, refuses '
      'old choices and adds no probe',
      () async {
        final item = _item(
          id: _evidencedModelId,
          reasoning: const {'mandatory': true},
        );
        item['architecture'] = const {
          'input_modalities': ['text', 'image'],
        };
        item['supported_parameters'] = const ['tools', 'reasoning'];

        final h = await _openHarness(wire: _Wire(items: [item]));
        addTearDown(h.dispose);
        await h.refresh();

        final model = h.cachedModel(_evidencedModelId)!;
        expect(model.modelMetadata[_declaredControlKey], _unresolvedControl);
        expect(model.modelMetadata[_rawEvidenceKey], {'mandatory': true});
        // Intrinsic and unrelated discovery facts stay intact.
        expect(model.modelMetadata['architecture'], {
          'input_modalities': ['text', 'image'],
        });
        expect(model.modelMetadata['supported_parameters'], [
          'tools',
          'reasoning',
        ]);
        expect(model.modelMetadata['object'], 'model');
        expect(model.contextWindow, 400000);
        expect(model.supportsReasoningOutput, isTrue);
        expect(model.label, isNotEmpty);

        final descriptor = model.thinkingControl!;
        expect(descriptor.status, ThinkingCapabilityStatus.unknown);
        expect(descriptor.source, 'endpoint_declared');
        expect(descriptor.options, isEmpty);
        expect(descriptor.defaultOptionId, isNull);

        // Previously selectable intrinsic tiers are refused with zero dispatch.
        for (final stale in ['low', 'medium', 'high', 'none']) {
          expect(
            () => h.resolve(selectionId: stale, model: _evidencedModelId),
            sendsNoThinkingField,
            reason: 'stale intrinsic tier $stale must not dispatch',
          );
        }
        expect(h.chatBodies, isEmpty);

        // The route still dispatches normally with a real provider default
        // omission and no thinking field.
        final body = await h.send(model: _evidencedModelId);
        expect(body.containsKey('reasoning'), isFalse);
        final probesAfterSend = h.modelsRequests.length;
        await h.send(model: _evidencedModelId, selectionId: null);
        expect(h.modelsRequests, hasLength(probesAfterSend));
      },
    );

    test(
      'a model-only override still wins over unusable route evidence',
      () async {
        final h = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _evidencedModelId,
                reasoning: const {'supported_efforts': <String>[]},
              ),
            ],
          ),
          configYaml: _overrideYaml(_evidencedModelId),
        );
        addTearDown(h.dispose);
        await h.refresh();

        final model = h.cachedModel(_evidencedModelId)!;
        expect(model.modelMetadata[_declaredControlKey], _unresolvedControl);
        expect(model.thinkingControl!.source, 'config_override');
        expect(model.thinkingControl!.options.map((o) => o.id).toList(), [
          'low',
        ]);
        expect(model.thinkingControl!.defaultOptionId, 'low');
        expect(
          (await h.send(
            selectionId: 'low',
            model: _evidencedModelId,
          ))['reasoning'],
          {'enabled': true, 'effort': 'low'},
        );
      },
    );

    test('identity is exact: siblings, case variants and conflicting duplicates '
        'stay isolated or ambiguous', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'low'],
              },
            ),
            _item(id: _siblingModelId, includeReasoning: false),
            _item(
              id: _caseModelId,
              reasoning: const {
                'supported_efforts': ['medium'],
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);
      await h.refresh();

      expect(
        h
            .cachedModel(_modelId)!
            .thinkingControl!
            .options
            .map((o) => o.id)
            .toList(),
        ['high', 'low'],
      );
      expect(
        h
            .cachedModel(_caseModelId)!
            .thinkingControl!
            .options
            .map((o) => o.id)
            .toList(),
        ['medium'],
        reason: 'a case-distinct identity keeps its own declaration',
      );
      final sibling = h.cachedModel(_siblingModelId)!;
      expect(
        sibling.modelMetadata.containsKey(_declaredControlKey),
        isFalse,
        reason: 'a sibling namespace never borrows another model control',
      );
      expect(
        sibling.thinkingControl!.status,
        isNot(ThinkingCapabilityStatus.supported),
      );

      // Two items claiming one exact identity with conflicting evidence are
      // ambiguous and declare nothing.
      final conflicting = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high'],
              },
            ),
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['low'],
              },
            ),
          ],
        ),
      );
      addTearDown(conflicting.dispose);
      await conflicting.refresh();
      for (final option in conflicting.cachedModels()) {
        expect(
          option.modelMetadata[_declaredControlKey],
          _unresolvedControl,
          reason:
              'conflicting duplicate evidence is ambiguous, so neither claim '
              'may revive an intrinsic ladder',
        );
      }
      expect(
        () => conflicting.resolve(selectionId: 'high', model: _modelId),
        sendsNoThinkingField,
      );
      expect(conflicting.chatBodies, isEmpty);

      // Repeated identical evidence for one identity is consistent, not
      // ambiguous.
      final consistent = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high'],
              },
            ),
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high'],
              },
            ),
          ],
        ),
      );
      addTearDown(consistent.dispose);
      await consistent.refresh();
      for (final option in consistent.cachedModels()) {
        expect(option.modelMetadata[_declaredControlKey], _declared(['high']));
      }

      // A names-only row and a declared row for one exact identity are a mixed
      // duplicate: the identity is ambiguous, so both rows publish explicit
      // unknown control evidence in either response order and neither may
      // revive an intrinsic ladder.
      for (final namesOnlyFirst in [true, false]) {
        final declared = _item(
          id: _modelId,
          reasoning: const {
            'supported_efforts': ['high'],
          },
        );
        final namesOnly = _item(id: _modelId, includeReasoning: false);
        final mixed = await _openHarness(
          wire: _Wire(
            items: namesOnlyFirst
                ? [namesOnly, declared]
                : [declared, namesOnly],
          ),
        );
        addTearDown(mixed.dispose);
        await mixed.refresh();

        final rows = mixed.cachedModels();
        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(
            row.modelMetadata[_declaredControlKey],
            _unresolvedControl,
            reason:
                'a mixed duplicate must not let either row revive an '
                'unrelated ladder (names-only first: $namesOnlyFirst)',
          );
          expect(row.thinkingControl!.status, ThinkingCapabilityStatus.unknown);
          expect(row.thinkingControl!.options, isEmpty);
        }
        expect(
          () => mixed.resolve(selectionId: 'high', model: _modelId),
          sendsNoThinkingField,
        );
        expect(mixed.chatBodies, isEmpty);
      }
    });

    test(
      'an existing compatibility declaration is preserved and never competes '
      'with aggregator evidence',
      () async {
        const compatibilityControl = {
          'status': 'supported',
          'wire': 'openai_chat_effort',
          'options': {'low': 'low'},
          'default_option': 'low',
        };
        final item = _item(
          id: _modelId,
          reasoning: const {
            'supported_efforts': ['high'],
          },
        );
        item[_declaredControlKey] = compatibilityControl;

        final h = await _openHarness(wire: _Wire(items: [item]));
        addTearDown(h.dispose);
        await h.refresh();

        final model = h.cachedModel()!;
        expect(
          model.modelMetadata[_declaredControlKey],
          compatibilityControl,
          reason: 'the compatibility wire owns its own declaration',
        );
        expect(model.thinkingControl!.options.map((o) => o.id).toList(), [
          'low',
        ]);
        expect(model.thinkingControl!.defaultOptionId, 'low');
        expect((await h.send()).containsKey('reasoning'), isFalse);
        expect((await h.send(selectionId: 'low'))['reasoning'], {
          'enabled': true,
          'effort': 'low',
        });
      },
    );

    test('a model-only configuration override wins over discovery and removal '
        'restores the discovered declaration', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'medium'],
                'default_effort': 'high',
              },
            ),
          ],
        ),
        configYaml: _overrideYaml(_modelId),
      );
      addTearDown(h.dispose);
      await h.refresh();

      final overridden = h.cachedModel()!;
      expect(
        overridden.modelMetadata[_declaredControlKey],
        _declared(['high', 'medium'], 'high'),
        reason: 'discovery evidence stays separate from the override',
      );
      expect(overridden.thinkingControl!.source, 'config_override');
      expect(overridden.thinkingControl!.options.map((o) => o.id).toList(), [
        'low',
      ]);
      expect((await h.send(selectionId: 'low'))['reasoning'], {
        'enabled': true,
        'effort': 'low',
      });
      // `high` is not in the override's set: it clamps down to `low`.
      expect(h.resolve(selectionId: 'high').selectionId, 'low');

      // Removing the override returns the route to its discovered declaration
      // through the existing refresh boundary.
      File(
        '${h.scratch.path}/config.yaml',
      ).writeAsStringSync('model_capabilities: {}\n');
      await h.refresh();

      final restored = h.cachedModel()!;
      expect(restored.thinkingControl!.source, 'endpoint_declared');
      expect(restored.thinkingControl!.options.map((o) => o.id).toList(), [
        'high',
        'medium',
      ]);
      expect(restored.thinkingControl!.defaultOptionId, 'high');
      expect((await h.send(selectionId: 'medium'))['reasoning'], {
        'enabled': true,
        'effort': 'medium',
      });
    });

    test(
      'repeated explicit refresh replaces evidence instead of carrying the old '
      'enriched descriptor',
      () async {
        final h = await _openHarness();
        addTearDown(h.dispose);
        await h.refresh();
        expect(
          h.cachedModel()!.modelMetadata[_declaredControlKey],
          _declared(['high', 'medium', 'low'], 'low'),
        );

        h.wire.items = [
          _item(
            id: _modelId,
            reasoning: const {
              'supported_efforts': ['medium'],
            },
          ),
        ];
        await h.refresh();

        final replaced = h.cachedModel()!;
        expect(replaced.modelMetadata[_rawEvidenceKey], {
          'supported_efforts': ['medium'],
        });
        expect(
          replaced.modelMetadata[_declaredControlKey],
          _declared(['medium']),
        );
        expect(replaced.thinkingControl!.options.map((o) => o.id).toList(), [
          'medium',
        ]);
        expect(replaced.thinkingControl!.defaultOptionId, isNull);
        expect(h.modelsRequests, hasLength(2));

        // A failing refresh falls back without fabricating or carrying the old
        // declaration.
        h.wire.modelsStatus = 500;
        await h.refresh();

        final failed = h.cachedModel()!;
        expect(h.adapter.availableModelsSource, 'fallback');
        expect(failed.modelMetadata.containsKey(_declaredControlKey), isFalse);
        expect(failed.modelMetadata.containsKey(_rawEvidenceKey), isFalse);
        expect(
          failed.thinkingControl!.status,
          isNot(ThinkingCapabilityStatus.supported),
        );
        final body = await h.send();
        expect(body.containsKey('reasoning'), isFalse);
        expect(body['model'], _modelId);
      },
    );

    test('discovery reuses the configured endpoint authentication', () async {
      final h = await _openHarness(requireAuth: true);
      addTearDown(h.dispose);

      await h.refresh();

      expect(h.adapter.availableModelsSource, 'live');
      expect(
        h.cachedModel()!.thinkingControl!.status,
        ThinkingCapabilityStatus.supported,
      );
      expect((await h.send(selectionId: 'high'))['reasoning'], {
        'enabled': true,
        'effort': 'high',
      });
    });

    test(
      'principal: explicit no-effort evidence cannot revive intrinsic tiers',
      () async {
        for (final reasoning in <Map<String, Object?>>[
          {'supported_efforts': <String>[]},
          {'mandatory': true},
        ]) {
          final h = await _openHarness(
            wire: _Wire(
              items: [_item(id: _evidencedModelId, reasoning: reasoning)],
            ),
          );
          addTearDown(h.dispose);
          await h.refresh();
          final descriptor = h.cachedModel(_evidencedModelId)!.thinkingControl!;
          expect(
            descriptor.status,
            isNot(ThinkingCapabilityStatus.supported),
            reason: 'explicit no effort selector is not names-only discovery',
          );
          expect(descriptor.options, isEmpty);
          expect(
            () => h.resolve(model: _evidencedModelId, selectionId: 'high'),
            sendsNoThinkingField,
          );
          expect(h.chatBodies, isEmpty);
        }
      },
    );

    test(
      'principal: conflicting duplicate evidence cannot revive intrinsic tiers',
      () async {
        final h = await _openHarness(
          wire: _Wire(
            items: [
              _item(
                id: _evidencedModelId,
                reasoning: const {
                  'supported_efforts': ['high'],
                },
              ),
              _item(
                id: _evidencedModelId,
                reasoning: const {
                  'supported_efforts': ['low'],
                },
              ),
            ],
          ),
        );
        addTearDown(h.dispose);
        await h.refresh();
        final descriptor = h.cachedModel(_evidencedModelId)!.thinkingControl!;
        expect(descriptor.status, isNot(ThinkingCapabilityStatus.supported));
        expect(descriptor.options, isEmpty);
        expect(
          () => h.resolve(model: _evidencedModelId, selectionId: 'high'),
          sendsNoThinkingField,
        );
        expect(h.chatBodies, isEmpty);
      },
    );

    test(
      'principal: partial duplicate evidence cannot resurrect a wider ladder',
      () async {
        for (final missingFirst in [true, false]) {
          final declared = _item(
            id: _evidencedModelId,
            reasoning: const {
              'supported_efforts': ['high'],
            },
          );
          final namesOnly = _item(
            id: _evidencedModelId,
            includeReasoning: false,
          );
          final h = await _openHarness(
            wire: _Wire(
              items: missingFirst
                  ? [namesOnly, declared]
                  : [declared, namesOnly],
            ),
          );
          addTearDown(h.dispose);
          await h.refresh();
          final duplicates = h.cachedModels().where(
            (m) => m.value == _evidencedModelId,
          );
          expect(duplicates, isNotEmpty);
          for (final model in duplicates) {
            final descriptor = model.thinkingControl!;
            if (descriptor.status == ThinkingCapabilityStatus.supported) {
              expect(descriptor.options.map((o) => o.id).toList(), [
                'high',
              ], reason: 'a duplicate names-only row cannot revive medium/low');
            } else {
              expect(descriptor.options, isEmpty);
            }
          }
          expect(
            () => h.resolve(model: _evidencedModelId, selectionId: 'medium'),
            sendsNoThinkingField,
          );
          expect(h.chatBodies, isEmpty);
        }
      },
    );

    test('request assembly performs no additional endpoint probe', () async {
      final h = await _openHarness(
        wire: _Wire(
          items: [
            _item(
              id: _modelId,
              reasoning: const {
                'supported_efforts': ['high', 'low'],
              },
            ),
          ],
        ),
      );
      addTearDown(h.dispose);

      await h.refresh();
      final modelsRequestsAfterRefresh = h.modelsRequests.length;
      final catalogRequestsAfterRefresh = h.modelsDevRequests.length;
      expect(modelsRequestsAfterRefresh, 1);

      await h.send(selectionId: 'high');
      await h.send(selectionId: 'low');
      await h.send();

      expect(h.modelsRequests, hasLength(modelsRequestsAfterRefresh));
      expect(h.modelsDevRequests, hasLength(catalogRequestsAfterRefresh));
      expect(h.chatBodies, hasLength(3));
      expect(h.chatBodies.first['reasoning'], {
        'enabled': true,
        'effort': 'high',
      });
      expect(h.chatBodies.last.containsKey('reasoning'), isFalse);
    });
  });
}
