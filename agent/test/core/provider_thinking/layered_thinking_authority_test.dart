/// Five-layer thinking-capability authority (live acceptance D1/D2):
/// settings -> provider-reported -> shipped defaults -> models.dev serving
/// vendor -> models.dev canonical model -> unknown.
///
/// Every expectation is written from the fixture evidence below, never from the
/// production serializer. Each supported row resolves every advertised option
/// through the real resolver and dispatches it through the real production
/// adapter, asserting the request body that actually leaves Sanad.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/models_dev_thinking_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

/// models.dev vendor entries, exactly as the Test Home catalog reports them
/// (vendor `opencode-go`) plus first-party vendors for wire coverage.
const Map<String, Map<String, Map<String, dynamic>>> _catalog = {
  'opencode-go': {
    'gpt-6-luna': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
        },
      ],
      'provider': {
        'npm': '@ai-sdk/openai',
        'api': 'https://opencode.ai/inference/go/openai/v1',
      },
    },
    'claude-haiku-5-5': {
      'reasoning': true,
      'reasoning_options': [
        {'type': 'toggle'},
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high', 'xhigh', 'max'],
        },
      ],
      'provider': {
        'npm': '@ai-sdk/anthropic',
        'api': 'https://opencode.ai/inference/go/anthropic/v1',
      },
    },
    'deepseek-v4.1-flash': {
      'reasoning': true,
      'interleaved': {'field': 'reasoning_content'},
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'high', 'max'],
        },
      ],
    },
    'kimi-k3': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['max'],
        },
      ],
    },
    // Exact Test Home `opencode-go` GLM entries (live acceptance r2 G1): the
    // serving route reports efforts only, with no toggle.
    'glm-5.2': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['high', 'max'],
        },
      ],
      'canonical_model_id': 'zhipuai/glm-5.2',
    },
    'glm-5.3': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'high', 'max'],
        },
      ],
      'canonical_model_id': 'zhipuai/glm-5.3',
    },
    // Layer 5 fixtures: a provider entry built from a lab `base_model`.
    'canonical-only': {
      'reasoning': true,
      'canonical_model_id': 'canonlab/canon-model',
    },
    'canonical-ignored': {
      'reasoning': true,
      'canonical_model_id': 'canonlab/canon-model',
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['high'],
        },
      ],
    },
    // Illustrative models.dev shapes for the kept gains; the exact Test Home
    // entries for these two ids were not available to this change.
    'qwen3.8-max': {
      'reasoning': true,
      'reasoning_options': [
        {'type': 'toggle'},
        {'type': 'budget_tokens', 'min': 1024},
      ],
    },
    'gemini-4-argon-contributor': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
        },
      ],
    },
    // Default-donor fixtures: the serving entry reports options and no
    // default; the canonical entry declares one (in, then out of, the set).
    'canon-default-in': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
        },
      ],
      'canonical_model_id': 'canonlab/canon-default-in',
    },
    'canon-default-out': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['high', 'max'],
        },
      ],
      'canonical_model_id': 'canonlab/canon-default-out',
    },
    'plain-reasoner': {'reasoning': true},
    'no-reasoning': {'reasoning': false},
    'always-on-only': {
      'reasoning': true,
      'reasoning_options': [
        {'type': 'only'},
      ],
    },
    'malformed-effort': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'turbo'],
        },
      ],
    },
  },
  'canonlab': {
    'canon-default-in': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
          'default': 'medium',
        },
      ],
    },
    'canon-default-out': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium'],
          'default': 'medium',
        },
      ],
    },
    'canon-model': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'high'],
        },
      ],
    },
  },
  'zhipuai': {
    'glm-5.2': {
      'reasoning': true,
      'reasoning_options': [
        {'type': 'toggle'},
        {
          'type': 'effort',
          'values': ['high', 'max'],
        },
      ],
    },
  },
  'deepseek': {
    'deepseek-v4.1-flash': {
      'reasoning': true,
      'reasoning_options': [
        {'type': 'toggle'},
        {
          'type': 'effort',
          'values': ['low', 'high', 'max'],
          'default': 'high',
        },
      ],
    },
  },
  'openai': {
    'gpt-6-luna': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
          'default': 'medium',
        },
      ],
    },
    'o3': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
          'default': 'medium',
        },
      ],
    },
    'gpt-6-astra': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high', 'xhigh', 'max'],
        },
      ],
    },
    'settings-wins': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'high'],
        },
      ],
    },
    'reported-wins': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'high'],
        },
      ],
    },
  },
  'anthropic': {
    'claude-haiku-5-5': {
      'reasoning': true,
      'reasoning_options': [
        {'type': 'toggle'},
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high', 'max'],
        },
      ],
    },
  },
  'google': {
    'gemini-4-argon': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
          'default': 'medium',
        },
      ],
    },
  },
  'openrouter': {
    'openai/o3': {
      'reasoning': true,
      'reasoning_options': [
        {
          'type': 'effort',
          'values': ['low', 'medium', 'high'],
        },
      ],
    },
  },
};

Map<String, dynamic>? _lookup(String templateId, String modelId) {
  final vendor =
      ModelsDevLookupFixture.vendorFor[templateId] ?? templateId.toLowerCase();
  return _catalog[vendor]?[modelId];
}

/// Mirrors `ModelsDevService.providerToModelsDev` for the templates used here.
class ModelsDevLookupFixture {
  static const vendorFor = {'openai-codex': 'openai', 'gemini': 'google'};
}

void main() {
  late Directory tempHome;
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ThinkingCapabilityAssembler assembler;
  late ThinkingSelectionResolver resolver;
  late Config config;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('sanad_layered_thinking_');
    setSanadHomeOverride(tempHome.path);
    File(p.join(tempHome.path, 'config.yaml')).writeAsStringSync('''
model_capabilities:
  grok-4.5:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: low
  settings-wins:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        medium: medium
      default_option: medium
''');
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    if (getIt.isRegistered<ProviderInstanceRepository>()) {
      getIt.unregister<ProviderInstanceRepository>();
    }
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    config = Config(environment: {'SANAD_HOME': tempHome.path});
    final registry = buildProviderThinkingRegistry();
    assembler = ThinkingCapabilityAssembler(registry, config, _lookup);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
      config: config,
    );
  });

  tearDown(() {
    if (getIt.isRegistered<ProviderInstanceRepository>()) {
      getIt.unregister<ProviderInstanceRepository>();
    }
    setSanadHomeOverride(null);
    state.dispose();
    if (tempHome.existsSync()) tempHome.deleteSync(recursive: true);
  });

  ProviderInstance route(
    String templateId, {
    String protocol = ProviderProtocol.openaiCompatible,
    String? model,
    Map<String, Object?> metadata = const {},
  }) {
    final id = 'inst-$templateId-${model ?? ''}-$protocol';
    final existing = repo.findById(id);
    if (existing != null) return existing;
    final inst = ProviderInstance(
      id: id,
      templateId: templateId,
      displayName: id,
      protocol: protocol,
      authMethod: ProviderAuthMethod.apiKey,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    repo.createInstance(inst);
    if (model != null && metadata.isNotEmpty) {
      repo.upsertModelCache(
        instanceId: id,
        cacheKey: 'models',
        models: [
          {'value': model, 'model_metadata': metadata},
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: inst.configRevision,
        credentialRevision: inst.credentialRevision,
      );
    }
    return inst;
  }

  ThinkingControlDescriptor descriptorFor(
    ProviderInstance inst,
    String model, {
    Map<String, Object?> metadata = const {},
  }) => assembler.assemble(
    instance: inst,
    model: ModelOption(value: model, label: model, modelMetadata: metadata),
  );

  /// Dispatches one resolved selection through the real production adapter
  /// for the route and returns the captured request body.
  Future<Map<String, dynamic>> wireBody(
    ProviderInstance inst,
    String model,
    String? selectionId,
  ) async {
    final resolution = resolver.resolve(
      providerInstanceId: inst.id,
      modelId: model,
      selectionId: selectionId,
    );
    final profile = ProviderRegistry.findByNameOrAlias(inst.templateId)!;
    Map<String, dynamic>? captured;
    final client = MockClient((request) async {
      captured = jsonDecode(request.body) as Map<String, dynamic>;
      if (profile.apiMode == 'codex_responses') {
        return http.Response(
          jsonEncode({
            'id': 'resp-1',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'ok'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (inst.protocol == ProviderProtocol.anthropicCompatible) {
        return http.Response(
          jsonEncode({
            'id': 'msg-1',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final LLMAdapter adapter =
        inst.protocol == ProviderProtocol.anthropicCompatible
        ? BaseAnthropicAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://layered.invalid/v1',
            apiKeyOverride: 'test-key',
          )
        : profile.apiMode == 'codex_responses'
        ? CodexResponsesAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://layered.invalid/v1',
            apiKeyOverride: 'test-key',
          )
        : BaseOpenAIAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://layered.invalid/v1',
            apiKeyOverride: 'test-key',
          );
    await adapter.generateResponse(
      [Message(role: MessageRole.user, content: 'layered')],
      modelOverride: model,
      options: LLMRequestOptions(
        thinkingDirective: resolution.directive,
        providerInstanceId: inst.id,
        maxOutputTokens: 32000,
      ),
    );
    expect(captured, isNotNull);
    return captured!;
  }

  ThinkingSelectionResolution resolve(
    ProviderInstance inst,
    String model,
    String? selectionId,
  ) => resolver.resolve(
    providerInstanceId: inst.id,
    modelId: model,
    selectionId: selectionId,
  );

  group('layer precedence (first layer with a record wins as a whole)', () {
    test('1 settings: config.yaml overrides a shipped default', () {
      final d = descriptorFor(route('opencode-go'), 'grok-4.5');
      expect(d.source, 'config_override');
      expect(d.options.map((o) => o.id), ['low']);
      expect(d.defaultOptionId, isNull, reason: 'no field mixing');
    });

    test(
      '2 provider-reported item metadata overrides a shipped default',
      () async {
        const reported = {
          'supported_reasoning_levels': [
            {'effort': 'low'},
          ],
        };
        final inst = route('openai', model: 'o3', metadata: reported);
        final d = descriptorFor(inst, 'o3', metadata: reported);
        expect(d.options.map((o) => o.id), ['low']);
        expect(d.defaultOptionId, isNull);
        final body = await wireBody(inst, 'o3', 'low');
        expect(body['reasoning_effort'], 'low');
      },
    );

    test('3 shipped defaults override the models.dev serving-vendor entry', () {
      final d = descriptorFor(route('opencode-go'), 'deepseek-v4.1-flash');
      expect(d.source, ThinkingCapabilityAssembler.shippedDefaultSource);
      expect(d.options.map((o) => o.id), ['off', 'low', 'high', 'max']);
      expect(d.defaultOptionId, 'high');
    });

    test('4 models.dev serving vendor answers when no earlier layer does', () {
      final d = descriptorFor(route('opencode-go'), 'gpt-6-luna');
      expect(d.source, ModelsDevThinkingEvidence.sourceId);
    });

    test('5 canonical_model_id fills only when the vendor entry reports no '
        'reasoning_options', () {
      final inst = route('opencode-go');
      final canonical = descriptorFor(inst, 'canonical-only');
      expect(canonical.status, ThinkingCapabilityStatus.supported);
      expect(canonical.options.map((o) => o.id), ['low', 'high']);
      final vendorWins = descriptorFor(inst, 'canonical-ignored');
      expect(vendorWins.options.map((o) => o.id), ['high']);
    });

    test('no layer: unknown; an explicit selection passes through unchanged '
        'and the turn sends no thinking field', () async {
      final inst = route('opencode-go');
      final d = descriptorFor(inst, 'absent-everywhere');
      expect(d.status, ThinkingCapabilityStatus.unknown);
      expect(d.source, 'unconfigured');
      final r = resolve(inst, 'absent-everywhere', 'xhigh');
      expect(r.selectionId, 'xhigh');
      expect(r.directive, isA<UseProviderDefault>());
      final body = await wireBody(inst, 'absent-everywhere', 'xhigh');
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
    });

    test('custom routes never consume a vendor catalog entry', () {
      final d = descriptorFor(route(kCustomProviderTemplateId), 'gpt-6-luna');
      expect(d.status, ThinkingCapabilityStatus.unknown);
    });
  });

  group('regression: real Test Home OpenCode Go list regains its controls', () {
    // Pre-regression options/defaults from the tables removed after 2607a342.
    const rows = [
      (
        model: 'deepseek-v4.1-flash',
        options: ['off', 'low', 'high', 'max'],
        defaultId: 'high',
      ),
      (
        model: 'deepseek-v4-pro',
        options: ['off', 'low', 'high', 'max'],
        defaultId: 'high',
      ),
      (model: 'glm-5.3', options: ['low', 'high', 'max'], defaultId: 'max'),
      (model: 'glm-5.1', options: ['off', 'on'], defaultId: 'on'),
      (model: 'kimi-k3', options: ['low', 'high', 'max'], defaultId: 'max'),
      (model: 'kimi-k2.6', options: ['on', 'off'], defaultId: 'on'),
      (
        model: 'grok-4.6',
        options: ['low', 'medium', 'high', 'xhigh'],
        defaultId: 'high',
      ),
    ];
    for (final row in rows) {
      test(
        '${row.model}: ${row.options.join('/')} default ${row.defaultId}',
        () async {
          final inst = route('opencode-go');
          final d = descriptorFor(inst, row.model);
          expect(d.status, ThinkingCapabilityStatus.supported);
          expect(d.source, ThinkingCapabilityAssembler.shippedDefaultSource);
          expect(d.options.map((o) => o.id).toList(), row.options);
          expect(d.defaultOptionId, row.defaultId);
          expect(d.options.where((o) => o.isProviderDefault).map((o) => o.id), [
            row.defaultId,
          ]);
          // Every advertised option reaches the Go Chat wire.
          for (final id in row.options) {
            final body = await wireBody(inst, row.model, id);
            if (id == 'off') {
              expect(body['thinking'], {'type': 'disabled'}, reason: row.model);
              expect(body.containsKey('reasoning_effort'), isFalse);
            } else if (id == 'on') {
              expect(body['thinking'], {'type': 'enabled'}, reason: row.model);
              expect(body.containsKey('reasoning_effort'), isFalse);
            } else {
              expect(body['reasoning_effort'], id, reason: row.model);
            }
          }
        },
      );
    }

    test('DeepSeek and GLM efforts enable thinking on the Go wire', () async {
      final inst = route('opencode-go');
      for (final (model, effort) in [
        ('deepseek-v4.1-flash', 'max'),
        ('glm-5.3', 'high'),
      ]) {
        final body = await wireBody(inst, model, effort);
        expect(body['thinking'], {'type': 'enabled'}, reason: model);
        expect(body['reasoning_effort'], effort);
      }
      // Kimi K3 and Grok efforts carry only the standard field.
      for (final model in ['kimi-k3', 'grok-4.6']) {
        final body = await wireBody(inst, model, 'high');
        expect(body.containsKey('thinking'), isFalse, reason: model);
        expect(body['reasoning_effort'], 'high');
      }
    });
  });

  group('G1: glm-5.2 follows the serving route evidence on OpenCode Go', () {
    // Live acceptance r2: Go rejected `thinking: {type: disabled}` for
    // glm-5.2 with HTTP 400 (thinking-only upstream). Its Go models.dev entry
    // reports efforts high/max with no toggle. The shipped record is scoped to
    // first-party routes, so Go falls through to that serving entry.
    test('Go: models.dev high/max, no Off; efforts carry reasoning_effort '
        'only', () async {
      final go = route('opencode-go');
      final d = descriptorFor(go, 'glm-5.2');
      expect(d.status, ThinkingCapabilityStatus.supported);
      expect(d.source, ModelsDevThinkingEvidence.sourceId);
      expect(d.options.map((o) => o.id).toList(), ['high', 'max']);
      expect(d.options.where((o) => o.isOff), isEmpty);
      for (final id in ['high', 'max']) {
        final body = await wireBody(go, 'glm-5.2', id);
        expect(body['reasoning_effort'], id);
        expect(body.containsKey('thinking'), isFalse);
      }
      expect(
        () => resolve(go, 'glm-5.2', 'off'),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (e) => e.code,
            'code',
            ThinkingSelectionErrorCode.optionUnavailable,
          ),
        ),
      );
    });

    test('a carried Medium (offered on another route) is not admitted for '
        'glm-5.2 on Go: nothing lower than High exists, so it is rejected '
        'rather than clamped up or down to Off', () {
      expect(
        () => resolve(route('opencode-go'), 'glm-5.2', 'medium'),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (e) => e.code,
            'code',
            ThinkingSelectionErrorCode.optionUnavailable,
          ),
        ),
      );
      // `xhigh` clamps down to the offered `high`, never up to `max`.
      expect(
        resolve(route('opencode-go'), 'glm-5.2', 'xhigh').selectionId,
        'high',
      );
    });

    test(
      'first-party Z.AI keeps the documented off/high/max, default max',
      () async {
        final zai = route('zai');
        final d = descriptorFor(zai, 'glm-5.2');
        expect(d.source, ThinkingCapabilityAssembler.shippedDefaultSource);
        expect(d.options.map((o) => o.id).toList(), ['off', 'high', 'max']);
        expect(d.defaultOptionId, 'max');
        final off = await wireBody(zai, 'glm-5.2', 'off');
        expect(off['thinking'], {'type': 'disabled'});
      },
    );

    test('glm-5.3 on Go keeps the shipped record (matches the Go entry)', () {
      final d = descriptorFor(route('opencode-go'), 'glm-5.3');
      expect(d.source, ThinkingCapabilityAssembler.shippedDefaultSource);
      expect(d.options.map((o) => o.id).toList(), ['low', 'high', 'max']);
      expect(d.defaultOptionId, 'max');
    });
  });

  group('default fill: a winning layer with options but no default takes the '
      'next declared default for the same model id (2026-10-21 rule)', () {
    test('glm-5.2 on Go: models.dev options, shipped default max', () async {
      final go = route('opencode-go');
      final d = descriptorFor(go, 'glm-5.2');
      expect(d.source, ModelsDevThinkingEvidence.sourceId);
      expect(d.options.map((o) => o.id).toList(), [
        'high',
        'max',
      ], reason: 'options still come only from the winning layer');
      expect(d.defaultOptionId, 'max');
      expect(d.defaultSource, ThinkingCapabilityAssembler.shippedDefaultSource);
      expect(d.options.singleWhere((o) => o.isProviderDefault).id, 'max');
      expect(
        ThinkingControlDescriptor.fromMap(d.toMap()).defaultSource,
        ThinkingCapabilityAssembler.shippedDefaultSource,
      );
      // Filling a default is metadata only: an unset selection still omits
      // the field, and the filled value is dispatched only when selected.
      final unset = resolve(go, 'glm-5.2', null);
      expect(unset.selectionId, isNull);
      expect(unset.directive, isA<UseProviderDefault>());
      final body = await wireBody(go, 'glm-5.2', 'max');
      expect(body['reasoning_effort'], 'max');
      expect(body.containsKey('thinking'), isFalse);
    });

    test('a winning layer\'s own default keeps its own provenance', () {
      final zai = descriptorFor(route('zai'), 'glm-5.2');
      expect(zai.defaultOptionId, 'max');
      expect(
        zai.defaultSource,
        ThinkingCapabilityAssembler.shippedDefaultSource,
      );
      final config = descriptorFor(route('opencode-go'), 'settings-wins');
      expect(config.defaultOptionId, 'medium');
      expect(config.defaultSource, 'config_override');
    });

    test('the canonical entry donates a default that is a winning option', () {
      final d = descriptorFor(route('opencode-go'), 'canon-default-in');
      expect(d.options.map((o) => o.id).toList(), ['low', 'medium', 'high']);
      expect(d.defaultOptionId, 'medium');
      expect(
        d.defaultSource,
        ThinkingCapabilityAssembler.modelsDevCanonicalDefaultSource,
      );
    });

    test('a donated default outside the winning options is ignored', () {
      final d = descriptorFor(route('opencode-go'), 'canon-default-out');
      expect(d.options.map((o) => o.id).toList(), ['high', 'max']);
      expect(d.defaultOptionId, isNull);
      expect(d.defaultSource, isNull);
      // Settings win with `low` only; the shipped default `high` is not an
      // option there, so no default is filled.
      final settings = descriptorFor(route('opencode-go'), 'grok-4.5');
      expect(settings.defaultOptionId, isNull);
    });

    test('no layer declares a default: none is invented', () {
      final d = descriptorFor(route('opencode-go'), 'gpt-6-luna');
      expect(d.defaultOptionId, isNull);
      expect(d.defaultSource, isNull);
      // The compatible-Chat degrade of a shipped record keeps no default: the
      // shipped record is the winner and never donates to itself.
      final compat = descriptorFor(
        route(kCustomProviderTemplateId),
        'deepseek-v4.1-flash',
      );
      expect(compat.defaultOptionId, isNull);
    });
  });

  group('gains kept from models.dev on OpenCode Go', () {
    test('gpt-6-luna: none..max from the serving vendor, no default', () async {
      final inst = route('opencode-go');
      final d = descriptorFor(inst, 'gpt-6-luna');
      expect(d.options.map((o) => o.id), [
        'none',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      expect(d.defaultOptionId, isNull);
      final body = await wireBody(inst, 'gpt-6-luna', 'xhigh');
      expect(body['reasoning_effort'], 'xhigh');
    });

    test('claude-haiku-5-5: toggle plus effort with a leading Off', () async {
      final inst = route('opencode-go');
      final d = descriptorFor(inst, 'claude-haiku-5-5');
      expect(d.options.map((o) => o.id), [
        'off',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      final off = await wireBody(inst, 'claude-haiku-5-5', 'off');
      expect(off['thinking'], {'type': 'disabled'});
    });

    test('qwen3.8: a budget_tokens range never voids the declared toggle', () {
      final d = descriptorFor(route('opencode-go'), 'qwen3.8-max');
      expect(d.status, ThinkingCapabilityStatus.supported);
      expect(d.options.map((o) => o.id), ['on', 'off']);
    });

    test('gemini argon contributor keeps its models.dev efforts on Go', () {
      final d = descriptorFor(
        route('opencode-go'),
        'gemini-4-argon-contributor',
      );
      expect(d.options.map((o) => o.id), ['low', 'medium', 'high']);
    });

    test('models.dev positive reports and fail-closed evidence', () {
      final inst = route('opencode-go');
      expect(
        descriptorFor(inst, 'no-reasoning').status,
        ThinkingCapabilityStatus.unsupported,
      );
      expect(
        descriptorFor(inst, 'always-on-only').status,
        ThinkingCapabilityStatus.unsupported,
      );
      expect(
        descriptorFor(inst, 'plain-reasoner').status,
        ThinkingCapabilityStatus.unknown,
      );
      expect(
        descriptorFor(inst, 'malformed-effort').status,
        ThinkingCapabilityStatus.unknown,
      );
    });
  });

  group('clamp to the nearest lower supported level', () {
    test('clamps down, never escalates, never falls to off/none', () {
      final go = route('opencode-go');
      // deepseek-v4.1-flash offers off/low/high/max.
      expect(resolve(go, 'deepseek-v4.1-flash', 'xhigh').selectionId, 'high');
      expect(resolve(go, 'deepseek-v4.1-flash', 'medium').selectionId, 'low');
      // glm-5.2 offers off/high/max: nothing lower than `high` but Off, so a
      // requested `low` is rejected rather than dropping to Off.
      expect(
        () => resolve(go, 'glm-5.2', 'low'),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (e) => e.code,
            'code',
            ThinkingSelectionErrorCode.optionUnavailable,
          ),
        ),
      );
      // kimi-k3 offers low/high/max: `xhigh` clamps to `high`, not up to max.
      expect(resolve(go, 'kimi-k3', 'xhigh').selectionId, 'high');
      // A supported exact value is never altered.
      expect(resolve(go, 'kimi-k3', 'max').selectionId, 'max');
    });

    test('an unknown set passes the selection through unchanged', () {
      final r = resolve(route('opencode-go'), 'absent-everywhere', 'medium');
      expect(r.selectionId, 'medium');
      expect(r.directive, isA<UseProviderDefault>());
    });
  });

  group('route wire encoders (family encoders stay in code)', () {
    test(
      'deepseek template: native codec enables thinking with the effort',
      () async {
        final inst = route('deepseek');
        final d = descriptorFor(inst, 'deepseek-v4.1-flash');
        expect(d.options.map((o) => o.id), ['off', 'low', 'high', 'max']);
        expect(d.defaultOptionId, 'high');
        final high = await wireBody(inst, 'deepseek-v4.1-flash', 'high');
        expect(high['thinking'], {'type': 'enabled'});
        expect(high['reasoning_effort'], 'high');
        final off = await wireBody(inst, 'deepseek-v4.1-flash', 'off');
        expect(off['thinking'], {'type': 'disabled'});
        expect(off.containsKey('reasoning_effort'), isFalse);
      },
    );

    test('generic compatible Chat degrades a native record to positive '
        'efforts with no Off and no default', () async {
      final inst = route(kCustomProviderTemplateId);
      final d = descriptorFor(inst, 'deepseek-v4.1-flash');
      expect(d.options.map((o) => o.id), ['low', 'high', 'max']);
      expect(d.defaultOptionId, isNull);
      final body = await wireBody(inst, 'deepseek-v4.1-flash', 'high');
      expect(body['reasoning_effort'], 'high');
      expect(body.containsKey('thinking'), isFalse);
    });

    test(
      'openai-codex Responses: reasoning.effort carries the selection',
      () async {
        final inst = route('openai-codex');
        final body = await wireBody(inst, 'gpt-6-luna', 'xhigh');
        expect((body['reasoning'] as Map)['effort'], 'xhigh');
        // A shipped Chat effort record follows the route onto Responses.
        final o3 = await wireBody(inst, 'o3', 'high');
        expect((o3['reasoning'] as Map)['effort'], 'high');
      },
    );

    test('anthropic Messages: adaptive effort and a typed disable', () async {
      final inst = route(
        'anthropic',
        protocol: ProviderProtocol.anthropicCompatible,
      );
      final high = await wireBody(inst, 'claude-haiku-5-5', 'high');
      expect(high['thinking'], {'type': 'adaptive'});
      expect((high['output_config'] as Map)['effort'], 'high');
      final off = await wireBody(inst, 'claude-haiku-5-5', 'off');
      expect(off['thinking'], {'type': 'disabled'});
      // Shipped manual budget record: Off and an exact budget.
      final budget = await wireBody(inst, 'claude-sonnet-4-5', 'medium');
      expect(budget['thinking'], {'type': 'enabled', 'budget_tokens': 8192});
      final budgetOff = await wireBody(inst, 'claude-sonnet-4-5', 'off');
      expect(budgetOff['thinking'], {'type': 'disabled'});
    });

    test('gemini: levels travel as thinking_level', () async {
      final inst = route('gemini');
      final d = descriptorFor(inst, 'gemini-4-argon');
      expect(d.kind, ThinkingControlKind.level);
      expect(d.defaultOptionId, 'medium');
      final body = await wireBody(inst, 'gemini-4-argon', 'high');
      expect(
        ((body['extra_body'] as Map)['google'] as Map)['thinking_config'],
        {'thinking_level': 'high'},
      );
    });

    test('openrouter: the aggregator envelope carries shipped facts', () async {
      final inst = route('openrouter');
      final body = await wireBody(inst, 'openai/o3', 'low');
      expect(body['reasoning'], {'enabled': true, 'effort': 'low'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });
  });
}
