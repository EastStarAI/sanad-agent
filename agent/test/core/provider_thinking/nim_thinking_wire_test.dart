/// Focused NVIDIA NIM native-wire coverage.
///
/// The shipped `nvidia` template is the hosted NIM catalog
/// (`https://integrate.api.nvidia.com/v1`). Capability comes only from the
/// layered authority (settings, provider-reported metadata, models.dev); this
/// suite proves the typed `chat_template_kwargs` Boolean serializer and its
/// declaration validation, the self-hosted-only Qwen contract (exposed through
/// an explicit validated declaration, never through hosted availability), the
/// absence of any undocumented `thinking` envelope, and that model names alone
/// never acquire controls.
///
/// Every expectation is an independently written literal body fact; no
/// production serializer generates expected output.
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
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

import '../../support/thinking_matchers.dart';

const _selfHostedQwenDeclaration = '''
model_capabilities:
  "qwen/qwen3.8-27b":
    thinking_control:
      status: supported
      wire: nim_qwen_thinking
      options:
        off: false
        low: low
        medium: medium
        xhigh: xhigh
      default_option: xhigh
''';

void main() {
  late Directory tempHome;
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late Config config;
  late ThinkingCapabilityAssembler assembler;
  late ThinkingSelectionResolver resolver;
  late List<Map<String, dynamic>> capturedBodies;

  void setUpHarness({String configYaml = ''}) {
    tempHome = Directory.systemTemp.createTempSync('sanad_nim_wire_home_');
    File(p.join(tempHome.path, 'config.yaml')).writeAsStringSync(configYaml);
    setSanadHomeOverride(tempHome.path);
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    if (getIt.isRegistered<ProviderInstanceRepository>()) {
      getIt.unregister<ProviderInstanceRepository>();
    }
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    config = Config(environment: {'SANAD_HOME': tempHome.path});
    final registry = buildProviderThinkingRegistry();
    assembler = ThinkingCapabilityAssembler(registry, config);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
      config: config,
    );
    capturedBodies = [];
  }

  void tearDownHarness() {
    try {
      if (getIt.isRegistered<ProviderInstanceRepository>()) {
        getIt.unregister<ProviderInstanceRepository>();
      }
      setSanadHomeOverride(null);
      state.dispose();
    } finally {
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    }
  }

  var instanceCounter = 0;

  ProviderInstance instanceFor(
    String templateId, {
    String? protocol,
    Map<String, Object?>? metadata,
  }) {
    instanceCounter++;
    final inst = ProviderInstance(
      id: 'nim-$templateId-$instanceCounter'.toLowerCase(),
      templateId: templateId,
      displayName: 'NIM $templateId $instanceCounter',
      protocol: protocol ?? ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    repo.createInstance(inst);
    if (metadata != null) {
      repo.upsertModelCache(
        instanceId: inst.id,
        cacheKey: 'models',
        models: [
          {
            'value': 'endpoint-declared-fixture',
            'label': 'Endpoint Declared',
            'model_metadata': metadata,
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: inst.configRevision,
        credentialRevision: inst.credentialRevision,
      );
    }
    return inst;
  }

  /// Dispatches one selection through the real adapter and returns the captured
  /// body, asserting exactly one HTTP request (no extra request-time probe).
  Future<Map<String, dynamic>> dispatch({
    required ProviderInstance inst,
    required String modelId,
    required Object directive,
  }) async {
    final profile = ProviderRegistry.findByNameOrAlias(inst.templateId)!;
    capturedBodies.clear();
    final client = MockClient((request) async {
      capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'id': 'chatcmpl-nim',
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
    final LLMAdapter adapter = BaseOpenAIAdapter(
      config,
      profile,
      providerInstanceId: inst.id,
      client: client,
      baseUrlOverride: 'https://integrate.api.nvidia.com/v1',
      apiKeyOverride: 'test-key',
    );
    await adapter.generateResponse(
      [Message(role: MessageRole.user, content: 'nim')],
      modelOverride: modelId,
      options: LLMRequestOptions(
        thinkingDirective: directive as dynamic,
        providerInstanceId: inst.id,
        maxOutputTokens: 32000,
      ),
    );
    expect(capturedBodies, hasLength(1));
    return capturedBodies.single;
  }

  group('principal native-wire review', () {
    test('Qwen declarations reject fake Off and elevated Low mappings', () {
      for (final options in <Map<String, Object>>[
        {'off': 'low'},
        {'none': 'medium'},
        {'low': 'xhigh'},
        {'high': false},
      ]) {
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': 'nim_qwen_thinking',
            'options': options,
          }),
          throwsA(isA<FormatException>()),
          reason: '$options must not change meaning',
        );
      }
    });

    test('principal remaining: effort labels cannot hide a Boolean enable', () {
      for (final wire in ['nim_kimi_thinking', 'nim_qwen_thinking']) {
        for (final id in ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']) {
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': wire,
              'options': {id: true},
            }),
            throwsA(isA<FormatException>()),
            reason: '$wire $id must not become an unspecified enabled default',
          );
        }
      }
    });

    test(
      'principal remaining: declared default does not replace provider omission',
      () async {
        setUpHarness(configYaml: _selfHostedQwenDeclaration);
        addTearDown(tearDownHarness);
        final inst = instanceFor(kCustomProviderTemplateId);
        final resolution = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'qwen/qwen3.8-27b',
          selectionId: null,
        );
        final body = await dispatch(
          inst: inst,
          modelId: 'qwen/qwen3.8-27b',
          directive: resolution.directive,
        );
        expect(
          body.containsKey('reasoning_effort'),
          isFalse,
          reason:
              'Default is omission even if a known native default is documented',
        );
        expect(body.containsKey('chat_template_kwargs'), isFalse);
        expect(resolution.directive, isA<UseProviderDefault>());
        expect(resolution.selectionId, isNull);
      },
    );

    test('canonical effort ids reject both Boolean values on kwargs wires', () {
      for (final wire in ['nim_kimi_thinking', 'nim_qwen_thinking']) {
        for (final id in ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']) {
          for (final value in [true, false]) {
            expect(
              () => ThinkingControlOverride.parse({
                'status': 'supported',
                'wire': wire,
                'options': {id: value},
              }),
              throwsA(isA<FormatException>()),
              reason: '$wire $id: $value must not become a Boolean mapping',
            );
          }
        }
      }
      // Genuine on/off and honest custom Boolean ids stay admissible, and the
      // exact Qwen effort mappings still work.
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'nim_qwen_thinking',
          'options': {'off': false, 'on': true, 'fast-mode': true},
        }),
        returnsNormally,
      );
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'nim_qwen_thinking',
          'options': {'off': false, 'xhigh': 'xhigh'},
        }),
        returnsNormally,
      );
    });

    test('principal Google declaration: canonical minimal remains a level', () {
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'google_thinking',
          'options': {'minimal': 'minimal', 'high': 'high'},
        }),
        returnsNormally,
      );
    });

    test(
      'principal Google declaration: zero budget is not a fake off level',
      () async {
        addTearDown(tearDownHarness);
        setUpHarness(
          configYaml: '''
model_capabilities:
  google-declared-fixture:
    thinking_control:
      status: supported
      wire: google_thinking
      options:
        off: 0
        high: high
''',
        );
        for (final template in ['gemini', 'openrouter']) {
          final inst = instanceFor(template);
          final resolution = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'google-declared-fixture',
            selectionId: 'off',
          );
          expect(resolution.directive, isA<GoogleBudgetDirective>());
          final body = await dispatch(
            inst: inst,
            modelId: 'google-declared-fixture',
            directive: resolution.directive,
          );
          if (template == 'openrouter') {
            expect(body['reasoning'], {'effort': 'none'});
          } else {
            expect(body['extra_body'], {
              'google': {
                'thinking_config': {'thinking_budget': 0},
              },
            });
          }
        }
      },
    );

    test(
      'principal canonical mappings: no effort label may change meaning',
      () {
        for (final wire in [
          'openai_chat_effort',
          'codex_responses_effort',
          'anthropic_adaptive',
          'google_thinking',
        ]) {
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': wire,
              'options': {'minimal': 'high'},
            }),
            throwsFormatException,
            reason: '$wire must not elevate Minimal to High',
          );
        }
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': 'toggle_effort',
            'options': {'low': true},
          }),
          throwsFormatException,
          reason: 'Low cannot mean an unspecified Boolean enable',
        );
      },
    );

    test('canonical mapping invariants hold across every typed control', () {
      const tiers = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

      // 1. Effort wires: every canonical id keeps its own meaning; opaque ids
      // stay free to carry an explicit admitted value.
      for (final wire in ['openai_chat_effort', 'codex_responses_effort']) {
        for (final id in tiers) {
          for (final other in tiers.where((value) => value != id)) {
            expect(
              () => ThinkingControlOverride.parse({
                'status': 'supported',
                'wire': wire,
                'options': {id: other},
              }),
              throwsFormatException,
              reason: '$wire $id must not remap to $other',
            );
          }
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': wire,
              'options': {id: id},
            }),
            returnsNormally,
            reason: '$wire $id must carry its own canonical value',
          );
        }
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': wire,
            'options': {'turbo-tier': 'high'},
          }),
          returnsNormally,
          reason: '$wire opaque ids may map to an explicit admitted value',
        );
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': wire,
            'options': {'turbo-tier': 'ultra'},
          }),
          throwsFormatException,
        );
      }

      // 2. Anthropic adaptive: same invariant plus the legitimate Boolean
      // disable and opaque explicit values.
      for (final id in ['low', 'medium', 'high', 'max']) {
        for (final other in [
          'low',
          'medium',
          'high',
          'max',
        ].where((value) => value != id)) {
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': 'anthropic_adaptive',
              'options': {id: other},
            }),
            throwsFormatException,
            reason: 'anthropic_adaptive $id must not remap to $other',
          );
        }
      }
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'anthropic_adaptive',
          'options': {
            'off': false,
            'custom-effort': 'high',
            'medium': 'medium',
          },
        }),
        returnsNormally,
      );

      // 3. Google levels: canonical level ids keep their own meaning; numeric
      // budgets remain legitimate for opaque ids and for the documented
      // zero-budget disable.
      for (final id in ['minimal', 'low', 'medium', 'high']) {
        for (final other in [
          'minimal',
          'low',
          'medium',
          'high',
        ].where((value) => value != id)) {
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': 'google_thinking',
              'options': {id: other},
            }),
            throwsFormatException,
            reason: 'google_thinking $id must not remap to $other',
          );
        }
      }
      // No canonical effort-tier id may alias into a different string level,
      // including a tier this wire does not support as a level.
      for (final id in tiers) {
        for (final level in ['minimal', 'low', 'medium', 'high']) {
          final matches = id == level;
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': 'google_thinking',
              'options': {id: level},
            }),
            matches ? returnsNormally : throwsFormatException,
            reason:
                'google_thinking $id -> $level must '
                '${matches ? "keep" : "not change"} its meaning',
          );
        }
      }
      // Unsupported canonical tiers stay rejected as levels under their own
      // name too, and a genuinely opaque id may still map to an admitted level.
      for (final id in ['xhigh', 'max']) {
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': 'google_thinking',
            'options': {id: id},
          }),
          throwsFormatException,
          reason: '$id is not an admitted Google level',
        );
      }
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'google_thinking',
          'options': {'custom-level': 'high', 'budget-tier': 'medium'},
        }),
        returnsNormally,
      );
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'google_thinking',
          'options': {'off': 0, 'budget-tier': 4096, 'minimal': 'minimal'},
        }),
        returnsNormally,
      );
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'google_thinking',
          'options': {'off': 'off'},
        }),
        returnsNormally,
      );

      // 4. Generic toggle: a canonical effort label may not hide a Boolean in
      // either direction, while genuine on/off and honest custom ids stay.
      for (final id in tiers) {
        for (final value in [true, false]) {
          expect(
            () => ThinkingControlOverride.parse({
              'status': 'supported',
              'wire': 'toggle_effort',
              'options': {id: value},
            }),
            throwsFormatException,
            reason: 'toggle_effort $id: $value must not hide a Boolean',
          );
        }
      }
      expect(
        () => ThinkingControlOverride.parse({
          'status': 'supported',
          'wire': 'toggle_effort',
          'options': {'off': false, 'on': true, 'deep-mode': true},
        }),
        returnsNormally,
      );
    });

    test(
      'declared canonical Google Minimal reaches the actual Chat body',
      () async {
        addTearDown(tearDownHarness);
        setUpHarness(
          configYaml: '''
model_capabilities:
  google-level-fixture:
    thinking_control:
      status: supported
      wire: google_thinking
      options:
        off: 0
        minimal: minimal
        high: high
''',
        );
        final inst = instanceFor('gemini');
        final resolution = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'google-level-fixture',
          selectionId: 'minimal',
        );
        final body = await dispatch(
          inst: inst,
          modelId: 'google-level-fixture',
          directive: resolution.directive,
        );
        expect(body['extra_body'], {
          'google': {
            'thinking_config': {'thinking_level': 'minimal'},
          },
        });
        expect(body.containsKey('reasoning_effort'), isFalse);
        expect(capturedBodies, hasLength(1));
      },
    );

    test('typed effort declarations retain canonical minimal and max', () {
      for (final wire in ['openai_chat_effort', 'codex_responses_effort']) {
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': wire,
            'options': {'minimal': 'minimal', 'max': 'max'},
          }),
          returnsNormally,
          reason: '$wire must express the documented vocabulary',
        );
      }
    });


    test(
      'template kwargs declaration is incompatible with aggregator envelope',
      () {
        setUpHarness(configYaml: _selfHostedQwenDeclaration);
        addTearDown(tearDownHarness);
        final inst = instanceFor('openrouter');
        const modelId = 'qwen/qwen3.8-27b';
        final descriptor = assembler.assemble(
          instance: inst,
          model: ModelOption(value: modelId, label: modelId),
        );
        expect(
          descriptor.status,
          isNot(ThinkingCapabilityStatus.supported),
          reason: 'aggregator codec cannot serialize template kwargs',
        );
        expect(
          () => resolver.resolve(
            providerInstanceId: inst.id,
            modelId: modelId,
            selectionId: 'off',
          ),
          sendsNoThinkingField,
        );
        expect(capturedBodies, isEmpty);
      },
    );
  });

  group('provider-default omission holds for both declaration authorities', () {
    setUp(() => setUpHarness(configYaml: _selfHostedQwenDeclaration));
    tearDown(tearDownHarness);

    /// Endpoint-declared variant of the same control.
    Map<String, Object?> endpointDeclaredModel() => {
      'thinking_control': {
        'status': 'supported',
        'wire': 'nim_qwen_thinking',
        'options': {
          'off': false,
          'low': 'low',
          'medium': 'medium',
          'xhigh': 'xhigh',
        },
        'default_option': 'xhigh',
      },
    };

    test('configuration declaration omits on null/empty/whitespace', () async {
      final inst = instanceFor(kCustomProviderTemplateId);
      for (final omitted in <String?>[null, '', '   ']) {
        final resolution = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'qwen/qwen3.8-27b',
          selectionId: omitted,
        );
        expect(resolution.selectionId, isNull);
        expect(resolution.directive, isA<UseProviderDefault>());
        expect(resolution.descriptor.defaultOptionId, 'xhigh');
        final body = await dispatch(
          inst: inst,
          modelId: 'qwen/qwen3.8-27b',
          directive: resolution.directive,
        );
        expect(body.containsKey('reasoning_effort'), isFalse);
        expect(body.containsKey('chat_template_kwargs'), isFalse);
      }
      expect(capturedBodies, isNotEmpty);
    });

    test('endpoint declaration omits on null/empty/whitespace', () async {
      final inst = instanceFor(
        kCustomProviderTemplateId,
        metadata: endpointDeclaredModel(),
      );
      for (final omitted in <String?>[null, '', '  ']) {
        final resolution = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'endpoint-declared-fixture',
          selectionId: omitted,
        );
        expect(resolution.selectionId, isNull);
        expect(resolution.directive, isA<UseProviderDefault>());
        final body = await dispatch(
          inst: inst,
          modelId: 'endpoint-declared-fixture',
          directive: resolution.directive,
        );
        expect(body.containsKey('reasoning_effort'), isFalse);
        expect(body.containsKey('chat_template_kwargs'), isFalse);
      }
    });

    test('incompatible declaration still omits on Default and rejects an '
        'explicit unsupported selection', () async {
      // The aggregator cannot serialize template kwargs; Default must still
      // omit rather than substitute anything.
      final inst = instanceFor('openrouter');
      final resolution = resolver.resolve(
        providerInstanceId: inst.id,
        modelId: 'qwen/qwen3.8-27b',
        selectionId: null,
      );
      expect(resolution.selectionId, isNull);
      expect(resolution.directive, isA<UseProviderDefault>());
      final body = await dispatch(
        inst: inst,
        modelId: 'qwen/qwen3.8-27b',
        directive: resolution.directive,
      );
      expect(body.containsKey('reasoning'), isFalse);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(
        () => resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'qwen/qwen3.8-27b',
          selectionId: 'off',
        ),
        sendsNoThinkingField,
      );
    });
  });

  group('wire admission requires the actual protocol and serializer', () {
    setUp(() => setUpHarness());
    tearDown(tearDownHarness);

    test('a non-OpenAI-compatible protocol never qualifies, whatever the '
        'configured API-mode string says', () {
      // The template-kwargs wire is only carried by the OpenAI-compatible Chat
      // codec (generic/custom Chat) and the hosted NIM catalog.
      for (final proto in [
        'anthropic_compatible',
        'anthropic',
        'ollama',
        'google',
      ]) {
        for (final mode in ['chat', 'chat_completions', 'anthropic_messages']) {
          expect(
            ThinkingRoutePolicy.isWireCompatible(
              wire: 'nim_qwen_thinking',
              protocol: proto,
              apiMode: mode,
              templateId: 'custom',
            ),
            isFalse,
            reason: '$proto/$mode must not admit template kwargs',
          );
        }
      }

      // The same protocol/AI-mode gate applies to the Kimi kwargs wire.
      expect(
        ThinkingRoutePolicy.isWireCompatible(
          wire: 'nim_kimi_thinking',
          protocol: 'ollama',
          apiMode: 'chat',
          templateId: 'custom',
        ),
        isFalse,
      );

      // Eligible serializer dialects stay admitted.
      for (final template in [
        kCustomProviderTemplateId,
        'lm-studio',
        'llama-cpp',
        'nvidia',
      ]) {
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'nim_qwen_thinking',
            protocol: ProviderProtocol.openaiCompatible,
            apiMode: 'chat_completions',
            templateId: template,
            isCustom: template == kCustomProviderTemplateId,
          ),
          isTrue,
          reason: '$template Chat must admit template kwargs',
        );
      }

      // The aggregator keeps its own envelope and stays incompatible.
      expect(
        ThinkingRoutePolicy.isWireCompatible(
          wire: 'nim_qwen_thinking',
          protocol: ProviderProtocol.openaiCompatible,
          apiMode: 'chat_completions',
          templateId: 'openrouter',
        ),
        isFalse,
      );
    });

    test('a mismatched-protocol endpoint declaration is non-selectable and '
        'rejects before dispatch', () {
      // The endpoint declares a template-kwargs control, but the route's actual
      // protocol is Anthropic Messages: the declaration must not be selectable.
      final inst = instanceFor(
        kCustomProviderTemplateId,
        protocol: ProviderProtocol.anthropicCompatible,
      );
      final descriptor = assembler.assemble(
        instance: inst,
        model: ModelOption(
          value: 'qwen/qwen3.8-27b',
          label: 'Qwen3.8-27B',
          modelMetadata: const {
            'thinking_control': {
              'status': 'supported',
              'wire': 'nim_qwen_thinking',
              'options': {'off': false, 'xhigh': 'xhigh'},
            },
          },
        ),
      );
      expect(descriptor.status, isNot(ThinkingCapabilityStatus.supported));
      expect(descriptor.options, isEmpty);
      expect(
        () => resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'qwen/qwen3.8-27b',
          selectionId: 'xhigh',
        ),
        sendsNoThinkingField,
      );
      expect(capturedBodies, isEmpty);
    });
  });

  group('hosted NIM contracts', () {
    setUp(() => setUpHarness());
    tearDown(tearDownHarness);




    test('documented hosted ids come from shipped nim records', () async {
      final inst = instanceFor('nvidia');
      final deepSeek = assembler.assemble(
        instance: inst,
        model: ModelOption(
          value: 'deepseek-ai/deepseek-v4-flash',
          label: 'DeepSeek V4 Flash',
        ),
      );
      expect(deepSeek.source, 'shipped_default');
      expect(deepSeek.options.map((o) => o.id), ['none', 'high', 'max']);
      expect(deepSeek.defaultOptionId, 'high');
      expect(
        deepSeek.options.where((o) => o.isOff).map((o) => o.id),
        ['none'],
      );
      final high = resolver.resolve(
        providerInstanceId: inst.id,
        modelId: 'deepseek-ai/deepseek-v4-flash',
        selectionId: 'high',
      );
      final body = await dispatch(
        inst: inst,
        modelId: 'deepseek-ai/deepseek-v4-flash',
        directive: high.directive,
      );
      expect(body['reasoning_effort'], 'high');
      expect(body.containsKey('thinking'), isFalse);

      final kimiToggle = resolver.resolve(
        providerInstanceId: inst.id,
        modelId: 'moonshotai/kimi-k2.6',
        selectionId: 'off',
      );
      final kwargs = await dispatch(
        inst: inst,
        modelId: 'moonshotai/kimi-k2.6',
        directive: kimiToggle.directive,
      );
      expect(kwargs['chat_template_kwargs'], {'thinking': false});
      expect(kwargs.containsKey('reasoning_effort'), isFalse);

      // The same hosted records never apply on a generic Chat route.
      final custom = instanceFor(kCustomProviderTemplateId);
      expect(
        assembler
            .assemble(
              instance: custom,
              model: ModelOption(
                value: 'moonshotai/kimi-k2.6',
                label: 'Kimi K2.6',
              ),
            )
            .status,
        ThinkingCapabilityStatus.unknown,
      );
    });

    test('hosted ids without documented controls stay unknown', () {
      final inst = instanceFor('nvidia');
      const unknownIds = [
        'deepseek-ai/deepseek-v4.1-flash',
        'moonshotai/kimi-k2-thinking',
        'qwen/qwen3-next-80b-a3b-thinking',
        'qwen/qwen3.8-27b',
        'deepseek-v4-flash',
        'kimi-k3',
        'kimi-k2.6',
        'DEEPSEEK-AI/DEEPSEEK-V4-FLASH',
        'moonshotai/kimi-k3-preview',
        'qwen/qwen3.5-122b-a10b-thinking',
      ];
      for (final modelId in unknownIds) {
        final descriptor = assembler.assemble(
          instance: inst,
          model: ModelOption(value: modelId, label: modelId),
        );
        expect(
          descriptor.status,
          ThinkingCapabilityStatus.unknown,
          reason: '$modelId must not acquire NIM controls',
        );
        expect(descriptor.options, isEmpty);
        expect(
          () => resolver.resolve(
            providerInstanceId: inst.id,
            modelId: modelId,
            selectionId: 'high',
          ),
          sendsNoThinkingField,
        );
      }
    });

    test('hosted contracts are not advertised on an incompatible mode', () {
      // The same exact ids on an Anthropic Messages route advertise nothing.
      final inst = instanceFor(
        kCustomProviderTemplateId,
        protocol: ProviderProtocol.anthropicCompatible,
      );
      for (final modelId in [
        'deepseek-ai/deepseek-v4-flash',
        'moonshotai/kimi-k2.6',
        'qwen/qwen3.5-122b-a10b',
      ]) {
        final descriptor = assembler.assemble(
          instance: inst,
          model: ModelOption(value: modelId, label: modelId),
        );
        expect(descriptor.status, isNot(ThinkingCapabilityStatus.supported));
        expect(descriptor.options, isEmpty);
      }
    });
  });

  group('self-hosted NIM Qwen through an explicit declaration', () {
    setUp(() => setUpHarness(configYaml: _selfHostedQwenDeclaration));
    tearDown(tearDownHarness);

    test(
      'declared tiers and Boolean disable reach the documented fields',
      () async {
        final inst = instanceFor(kCustomProviderTemplateId);
        final descriptor = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'qwen/qwen3.8-27b', label: 'Qwen3.8-27B'),
        );
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.options.map((option) => option.id), [
          'off',
          'low',
          'medium',
          'xhigh',
        ]);
        expect(descriptor.defaultOptionId, 'xhigh');

        final expectations = <String, Object>{
          'low': 'low',
          'medium': 'medium',
          'xhigh': 'xhigh',
        };
        for (final entry in expectations.entries) {
          final resolution = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'qwen/qwen3.8-27b',
            selectionId: entry.key,
          );
          final body = await dispatch(
            inst: inst,
            modelId: 'qwen/qwen3.8-27b',
            directive: resolution.directive,
          );
          expect(body['reasoning_effort'], entry.value);
          expect(body.containsKey('chat_template_kwargs'), isFalse);
          expect(body.containsKey('thinking'), isFalse);
        }

        final off = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'qwen/qwen3.8-27b',
          selectionId: 'off',
        );
        final offBody = await dispatch(
          inst: inst,
          modelId: 'qwen/qwen3.8-27b',
          directive: off.directive,
        );
        expect(offBody['chat_template_kwargs'], {'enable_thinking': false});
        expect(offBody.containsKey('reasoning_effort'), isFalse);

        // The declared default (`xhigh`) stays truthful descriptor metadata, but
        // an omitted/empty/whitespace selection is provider Default by omission:
        // no effort and no template kwargs reach the body.
        for (final omitted in <String?>[null, '', '   ']) {
          final omittedResolution = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'qwen/qwen3.8-27b',
            selectionId: omitted,
          );
          expect(omittedResolution.selectionId, isNull);
          expect(omittedResolution.directive, isA<UseProviderDefault>());
          final omittedBody = await dispatch(
            inst: inst,
            modelId: 'qwen/qwen3.8-27b',
            directive: omittedResolution.directive,
          );
          expect(omittedBody.containsKey('reasoning_effort'), isFalse);
          expect(omittedBody.containsKey('chat_template_kwargs'), isFalse);
        }

        // Explicitly selecting the advertised default dispatches its exact value.
        final explicitDefault = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'qwen/qwen3.8-27b',
          selectionId: 'xhigh',
        );
        final defaultBody = await dispatch(
          inst: inst,
          modelId: 'qwen/qwen3.8-27b',
          directive: explicitDefault.directive,
        );
        expect(defaultBody['reasoning_effort'], 'xhigh');
        expect(defaultBody.containsKey('chat_template_kwargs'), isFalse);
      },
    );

    test('the declaration is rejected for a malformed wire or value', () {
      // A fake-off declaration is an actionable configuration error, not a
      // silently honoured control.
      final malformedHome = Directory.systemTemp.createTempSync(
        'sanad_nim_malformed_',
      );
      addTearDown(() {
        if (malformedHome.existsSync()) {
          malformedHome.deleteSync(recursive: true);
        }
      });
      File(p.join(malformedHome.path, 'config.yaml')).writeAsStringSync('''
model_capabilities:
  "qwen/qwen3.8-27b":
    thinking_control:
      status: supported
      wire: nim_qwen_thinking
      options:
        off: true
''');
      setSanadHomeOverride(malformedHome.path);
      expect(
        () => Config(environment: {'SANAD_HOME': malformedHome.path}),
        throwsFormatException,
      );
      setSanadHomeOverride(tempHome.path);
    });

    test('an unknown wire id is rejected rather than silently accepted', () {
      final arbitraryHome = Directory.systemTemp.createTempSync(
        'sanad_nim_arbitrary_',
      );
      addTearDown(() {
        if (arbitraryHome.existsSync()) {
          arbitraryHome.deleteSync(recursive: true);
        }
      });
      File(p.join(arbitraryHome.path, 'config.yaml')).writeAsStringSync('''
model_capabilities:
  "qwen/qwen3.8-27b":
    thinking_control:
      status: supported
      wire: nim_arbitrary_json
      options:
        low: low
''');
      setSanadHomeOverride(arbitraryHome.path);
      expect(
        () => Config(environment: {'SANAD_HOME': arbitraryHome.path}),
        throwsFormatException,
      );
      setSanadHomeOverride(tempHome.path);
    });
  });

  group('declared template kwargs stay bound to a serializer that can carry '
      'them', () {
    setUp(() => setUpHarness(configYaml: _selfHostedQwenDeclaration));
    tearDown(tearDownHarness);

    test('aggregator, Responses, Messages and native Ollama reject the '
        'declaration', () {
      final incompatible = <String, ProviderInstance>{
        // Aggregator envelope owns a different serializer.
        'openrouter': instanceFor('openrouter'),
        // Responses body cannot carry template kwargs.
        'openai-codex': instanceFor('openai-codex'),
        // Messages body cannot carry template kwargs.
        'anthropic': instanceFor(
          kCustomProviderTemplateId,
          protocol: ProviderProtocol.anthropicCompatible,
        ),
        // Native Ollama owns its typed `think` field.
        'ollama': instanceFor('ollama'),
      };

      for (final entry in incompatible.entries) {
        final descriptor = assembler.assemble(
          instance: entry.value,
          model: ModelOption(value: 'qwen/qwen3.8-27b', label: 'Qwen3.8-27B'),
        );
        expect(
          descriptor.status,
          isNot(ThinkingCapabilityStatus.supported),
          reason: '${entry.key} cannot serialize chat_template_kwargs',
        );
        expect(descriptor.options, isEmpty);
        expect(
          () => resolver.resolve(
            providerInstanceId: entry.value.id,
            modelId: 'qwen/qwen3.8-27b',
            selectionId: 'off',
          ),
          sendsNoThinkingField,
          reason: '${entry.key} must reject before dispatch',
        );
        expect(capturedBodies, isEmpty);
      }
    });

    test('a legitimate generic compatible Chat route stays selectable', () {
      final inst = instanceFor(kCustomProviderTemplateId);
      final descriptor = assembler.assemble(
        instance: inst,
        model: ModelOption(value: 'qwen/qwen3.8-27b', label: 'Qwen3.8-27B'),
      );
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((option) => option.id), [
        'off',
        'low',
        'medium',
        'xhigh',
      ]);
    });
  });


  group('no hosted advertisement without an explicit declaration', () {
    setUp(() => setUpHarness());
    tearDown(tearDownHarness);

    test('the self-hosted id stays unknown on hosted and generic routes', () {
      for (final templateId in ['nvidia', kCustomProviderTemplateId]) {
        final inst = instanceFor(templateId);
        final descriptor = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'qwen/qwen3.8-27b', label: 'Qwen3.8-27B'),
        );
        expect(
          descriptor.status,
          ThinkingCapabilityStatus.unknown,
          reason: '$templateId must not advertise self-hosted-only facts',
        );
      }

      // The shipped NVIDIA fallback list never gains the self-hosted model.
      final nvidiaProfile = ProviderRegistry.findByNameOrAlias('nvidia')!;
      expect(
        nvidiaProfile.fallbackModels.contains('qwen/qwen3.8-27b'),
        isFalse,
      );
    });
  });
}
