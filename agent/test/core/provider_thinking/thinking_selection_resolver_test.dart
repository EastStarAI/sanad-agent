import 'dart:io';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/google_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/openai_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/toggle_effort_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

import '../../support/thinking_matchers.dart';

class _SupportedEffortPolicy implements ProviderThinkingPolicy {
  @override
  String get policyId => 'test_effort';

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: const [
        ThinkingControlOption(id: 'low', label: 'Low'),
        ThinkingControlOption(id: 'medium', label: 'Medium'),
      ],
      capabilityRevision: 'rev-test',
      source: 'profile',
    );
  }

  @override
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  ) {
    if (selectionId == null || selectionId.isEmpty) {
      return const UseProviderDefault();
    }
    return OpenAiEffortDirective(selectionId);
  }
}

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ThinkingCapabilityAssembler assembler;
  late ThinkingSelectionResolver resolver;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    final registry = buildProviderThinkingRegistry();
    registry.register(_SupportedEffortPolicy());
    assembler = ThinkingCapabilityAssembler(registry);
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
  });

  tearDown(() => state.dispose());

  test('null selection resolves to provider default', () {
    repo.createInstance(_instance());

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'gpt-test',
      selectionId: null,
    );

    expect(resolution.selectionId, isNull);
    expect(resolution.directive, isA<UseProviderDefault>());
  });

  test('explicit unsupported route rejects selection before adapter call', () {
    repo.createInstance(_instance());
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'gpt-test',
          // Provider-reported: the endpoint declares no request-time control.
          'model_metadata': {
            'thinking_control': {'status': 'unsupported'},
          },
          'thinking_control': {
            'status': 'unsupported',
            'capability_revision': 'rev-1',
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'inst-1',
        modelId: 'gpt-test',
        selectionId: 'medium',
      ),
      throwsA(
        isA<ThinkingSelectionException>().having(
          (error) => error.code,
          'code',
          ThinkingSelectionErrorCode.capabilityUnsupported,
        ),
      ),
    );
  });

  test('unknown template rejects explicit selection before adapter call', () {
    repo.createInstance(
      ProviderInstance(
        id: 'inst-unknown',
        templateId: 'missing-template',
        displayName: 'Missing',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'inst-unknown',
        modelId: 'gpt-test',
        selectionId: 'medium',
      ),
      sendsNoThinkingField,
    );
  });

  test('stale live evidence rejects cached supported descriptor', () {
    repo.createInstance(_instance());
    final staleObservedAt = DateTime.now().toUtc().subtract(
      const Duration(minutes: 10),
    );
    // The cache row carries the current capability revision (including any
    // default-fill suffix): read it from one fresh resolution first.
    void cacheStaleLive(String revision) => repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          // Provider-reported native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': revision,
            'source': 'live',
            'observed_at': staleObservedAt.toIso8601String(),
          },
        },
      ],
      fetchedAt: staleObservedAt,
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );
    cacheStaleLive('placeholder');
    cacheStaleLive(
      resolver
          .resolve(
            providerInstanceId: 'inst-1',
            modelId: 'o3',
            selectionId: null,
          )
          .descriptor
          .capabilityRevision,
    );

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: null,
    );

    expect(resolution.descriptor.status, ThinkingCapabilityStatus.unknown);
    expect(resolution.descriptor.source, 'stale_live_evidence');
  });

  test('legacy fast alias maps to low when available in cache descriptor', () {
    repo.createInstance(_instance());
    const capabilityRevision = '1:1:openai_chat_effort:o3';
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          // Provider-reported native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': capabilityRevision,
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: 'fast',
    );

    expect(resolution.selectionId, 'low');
    expect(resolution.descriptor.isSupported, isTrue);
  });

  test('explicit valid selection resolves a typed native directive', () {
    repo.createInstance(_instance());
    const capabilityRevision = '1:1:openai_chat_effort:o3';
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o3',
          // Provider-reported native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'low', 'label': 'Low'},
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': capabilityRevision,
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    final resolution = resolver.resolve(
      providerInstanceId: 'inst-1',
      modelId: 'o3',
      selectionId: 'medium',
    );

    expect(resolution.selectionId, 'medium');
    expect(resolution.directive, isA<OpenAiEffortDirective>());
  });

  test('unavailable legacy alias is rejected instead of silently ignored', () {
    repo.createInstance(_instance());
    const capabilityRevision = '1:1:openai_chat_effort:o1';
    repo.upsertModelCache(
      instanceId: 'inst-1',
      cacheKey: 'models',
      models: [
        {
          'value': 'o1',
          // Provider-reported native levels (capability authority).
          'supported_reasoning_levels': [
            {'effort': 'medium'},
            {'effort': 'high'},
          ],
          'thinking_control': {
            'status': 'supported',
            'kind': 'effort',
            'options': [
              {'id': 'medium', 'label': 'Medium'},
              {'id': 'high', 'label': 'High'},
            ],
            'capability_revision': capabilityRevision,
            'source': 'profile',
          },
        },
      ],
      fetchedAt: DateTime.now(),
      source: 'live',
      configRevision: 1,
      credentialRevision: 1,
    );

    expect(
      () => resolver.resolve(
        providerInstanceId: 'inst-1',
        modelId: 'o1',
        selectionId: 'fast',
      ),
      throwsA(
        isA<ThinkingSelectionException>().having(
          (error) => error.code,
          'code',
          ThinkingSelectionErrorCode.optionUnavailable,
        ),
      ),
    );
  });

  test(
    'manual anthropic route clamps an unoffered budget tier to the nearest lower one',
    () {
      repo.createInstance(_anthropicInstance());
      repo.upsertModelCache(
        instanceId: 'anthropic-1',
        cacheKey: 'models',
        models: [
          {
            'value': 'claude-sonnet-4-5',
            'thinking_control': {
              'status': 'supported',
              'kind': 'tokenBudget',
              'options': [
                {'id': 'off', 'label': 'Off', 'is_off': true},
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
                {'id': 'high', 'label': 'High'},
              ],
              'capability_revision': 'rev-anthropic-manual',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      // The shipped Claude manual-budget record offers off/low/medium/high:
      // an unoffered `max` clamps down to the nearest lower tier, `high`.
      final clamped = resolver.resolve(
        providerInstanceId: 'anthropic-1',
        modelId: 'claude-sonnet-4-5',
        selectionId: 'max',
      );
      expect(clamped.selectionId, 'high');
      expect(
        (clamped.directive as AnthropicBudgetDirective).budgetTokens,
        16384,
      );
    },
  );

  group('exact-route capability overrides in resolver and assembler', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync(
        'thinking-resolver-override-',
      );
      setSanadHomeOverride(tempHome.path);
    });

    tearDown(() {
      setSanadHomeOverride(null);
      try {
        tempHome.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'exact-route thinking override takes precedence and builds OpenAiEffortDirective',
      () {
        File('${tempHome.path}/config.yaml').writeAsStringSync('''
model_capabilities:
  "custom-reasoner":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: low
        high: high
      default_option: low
''');
        final config = Config(environment: const {});
        final registry = buildProviderThinkingRegistry();
        final assembler = ThinkingCapabilityAssembler(registry, config);
        repo.createInstance(_instance());

        final overrideResolver = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: assembler,
          registry: registry,
          config: config,
        );

        final resolution = overrideResolver.resolve(
          providerInstanceId: 'inst-1',
          modelId: 'custom-reasoner',
          selectionId: 'high',
        );
        expect(resolution.selectionId, 'high');
        expect(
          resolution.descriptor.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(resolution.descriptor.source, 'config_override');
        expect(resolution.directive, isA<OpenAiEffortDirective>());
        expect((resolution.directive as OpenAiEffortDirective).effort, 'high');

        // The documented default stays truthful descriptor metadata but never
        // turns omission into an explicit request field: a null, empty or
        // whitespace-only selection is provider Default by omission.
        expect(resolution.descriptor.defaultOptionId, 'low');
        for (final omitted in <String?>[null, '', '   ']) {
          final defaultRes = overrideResolver.resolve(
            providerInstanceId: 'inst-1',
            modelId: 'custom-reasoner',
            selectionId: omitted,
          );
          expect(defaultRes.selectionId, isNull);
          expect(defaultRes.directive, isA<UseProviderDefault>());
        }

        // Explicitly selecting the advertised default dispatches it exactly.
        final explicitDefault = overrideResolver.resolve(
          providerInstanceId: 'inst-1',
          modelId: 'custom-reasoner',
          selectionId: 'low',
        );
        expect(explicitDefault.selectionId, 'low');
        expect(explicitDefault.directive, isA<OpenAiEffortDirective>());
        expect(
          (explicitDefault.directive as OpenAiEffortDirective).effort,
          'low',
        );

        // Invalid option rejected
        expect(
          () => overrideResolver.resolve(
            providerInstanceId: 'inst-1',
            modelId: 'custom-reasoner',
            selectionId: 'invalid-tier',
          ),
          throwsA(isA<ThinkingSelectionException>()),
        );
      },
    );

    test('exact-route toggle_effort wire builds ThinkingToggleDirective', () {
      File('${tempHome.path}/config.yaml').writeAsStringSync('''
model_capabilities:
  "custom-toggle":
    thinking_control:
      status: supported
      wire: toggle_effort
      options:
        "on": true
        "off": false
''');
      final config = Config(environment: const {});
      final registry = buildProviderThinkingRegistry();
      final assembler = ThinkingCapabilityAssembler(registry, config);
      repo.createInstance(_instance());

      final overrideResolver = ThinkingSelectionResolver(
        instances: repo,
        cacheResolver: ThinkingControlCacheResolver(repo),
        assembler: assembler,
        registry: registry,
        config: config,
      );

      final resOn = overrideResolver.resolve(
        providerInstanceId: 'inst-1',
        modelId: 'custom-toggle',
        selectionId: 'on',
      );
      expect(resOn.directive, isA<ThinkingToggleDirective>());
      expect((resOn.directive as ThinkingToggleDirective).enabled, isTrue);

      final resOff = overrideResolver.resolve(
        providerInstanceId: 'inst-1',
        modelId: 'custom-toggle',
        selectionId: 'off',
      );
      expect(resOff.directive, isA<ThinkingToggleDirective>());
      expect((resOff.directive as ThinkingToggleDirective).enabled, isFalse);
    });

    test(
      'exact-route wire incompatible with route protocol throws FormatException',
      () {
        File('${tempHome.path}/config.yaml').writeAsStringSync('''
model_capabilities:
  "custom-model":
    thinking_control:
      status: supported
      wire: anthropic_budget
      options:
        high: 5000
''');
        final config = Config(environment: const {});
        final registry = buildProviderThinkingRegistry();
        final assembler = ThinkingCapabilityAssembler(registry, config);
        repo.createInstance(_instance()); // inst-1 is openai_compatible

        final overrideResolver = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: assembler,
          registry: registry,
          config: config,
        );

        expect(
          () => overrideResolver.resolve(
            providerInstanceId: 'inst-1',
            modelId: 'custom-model',
            selectionId: 'high',
          ),
          throwsA(isA<ThinkingSelectionException>()),
        );
      },
    );

    test(
      'ThinkingRoutePolicy.isWireCompatible accepts codex_responses, chat, and messages modes',
      () {
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'codex_responses_effort',
            protocol: 'openai_compatible',
            apiMode: 'codex_responses',
          ),
          isTrue,
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'codex_responses_effort',
            protocol: 'openai-codex',
            apiMode: 'responses',
          ),
          isTrue,
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'openai_chat_effort',
            protocol: 'openai_compatible',
            apiMode: 'chat',
          ),
          isTrue,
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'anthropic_adaptive',
            protocol: 'anthropic_compatible',
            apiMode: 'messages',
          ),
          isTrue,
        );
      },
    );

    test(
      'override enabled -> removed without refetch returns raw declared original or unknown immediately',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-custom',
            templateId: 'custom-provider',
            displayName: 'Custom Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'inst-custom',
          cacheKey: 'models',
          models: [
            {
              'value': 'declared-model',
              'label': 'Declared Model',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'openai_chat_effort',
                  'options': {'fast': 'low', 'deep': 'high'},
                  'default_option': 'fast',
                },
              },
            },
            {
              'value': 'plain-model',
              'label': 'Plain Model',
              'model_metadata': <String, dynamic>{},
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        // Step 1: Config override is active
        File('${tempHome.path}/config.yaml').writeAsStringSync('''
model_capabilities:
  "declared-model":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        override_opt: low
  "plain-model":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        override_opt: medium
''');
        var config = Config(environment: const {});
        var registry = buildProviderThinkingRegistry();
        var assembler = ThinkingCapabilityAssembler(registry, config);
        var resolverWithOverride = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: assembler,
          registry: registry,
          config: config,
        );

        final resDeclaredWithOverride = resolverWithOverride.resolve(
          providerInstanceId: 'inst-custom',
          modelId: 'declared-model',
          selectionId: 'override_opt',
        );
        expect(resDeclaredWithOverride.descriptor.source, 'config_override');
        expect(
          resDeclaredWithOverride.descriptor.options.map((o) => o.id),
          contains('override_opt'),
        );

        final resPlainWithOverride = resolverWithOverride.resolve(
          providerInstanceId: 'inst-custom',
          modelId: 'plain-model',
          selectionId: 'override_opt',
        );
        expect(resPlainWithOverride.descriptor.source, 'config_override');

        // Step 2: Config override is removed WITHOUT refetching model cache
        File(
          '${tempHome.path}/config.yaml',
        ).writeAsStringSync('model_capabilities: {}\n');
        config = Config(environment: const {});
        assembler = ThinkingCapabilityAssembler(registry, config);
        final resolverWithoutOverride = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: assembler,
          registry: registry,
          config: config,
        );

        // declared-model immediately reverts to raw declared original metadata
        final resDeclaredReverted = resolverWithoutOverride.resolve(
          providerInstanceId: 'inst-custom',
          modelId: 'declared-model',
          selectionId: 'fast',
        );
        expect(resDeclaredReverted.descriptor.source, 'endpoint_declared');
        expect(
          resDeclaredReverted.descriptor.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(
          resDeclaredReverted.descriptor.options.map((o) => o.id),
          containsAll(['fast', 'deep']),
        );
        expect(resDeclaredReverted.directive, isA<OpenAiEffortDirective>());
        expect(
          (resDeclaredReverted.directive as OpenAiEffortDirective).effort,
          'low',
        );

        // plain-model immediately reverts to unknown
        final resPlainReverted = resolverWithoutOverride.resolve(
          providerInstanceId: 'inst-custom',
          modelId: 'plain-model',
          selectionId: null,
        );
        expect(
          resPlainReverted.descriptor.status,
          ThinkingCapabilityStatus.unknown,
        );
        expect(resPlainReverted.descriptor.source, 'unconfigured');
      },
    );

    test(
      'declared endpoint thinking controls validation, opaque options, budget, and wire serialization',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-anthropic-custom',
            templateId: kCustomProviderTemplateId,
            displayName: 'Anthropic Custom',
            protocol: ProviderProtocol.anthropicCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'inst-openai-custom',
            templateId: kCustomProviderTemplateId,
            displayName: 'OpenAI Custom',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.upsertModelCache(
          instanceId: 'inst-anthropic-custom',
          cacheKey: 'models',
          models: [
            {
              'value': 'claude-custom',
              'label': 'Claude Custom',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'anthropic_budget',
                  'options': {'tier_min': 2048, 'tier_max': 8192},
                  'default_option': 'tier_min',
                },
              },
            },
            {
              'value': 'claude-invalid-budget',
              'label': 'Claude Invalid Budget',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'anthropic_budget',
                  'options': {'invented': 'not_a_number', 'too_small': 500},
                },
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );
        repo.upsertModelCache(
          instanceId: 'inst-openai-custom',
          cacheKey: 'models',
          models: [
            {
              'value': 'gpt-custom',
              'label': 'GPT Custom',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'openai_chat_effort',
                  'options': {'quick': 'low', 'deep': 'high', 'off': 'none'},
                  'default_option': 'quick',
                },
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final testResolver = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: ThinkingCapabilityAssembler(
            buildProviderThinkingRegistry(),
          ),
          registry: buildProviderThinkingRegistry(),
        );

        // 1. Anthropic: budget arbitrary label -> exact integer
        final resBudget = testResolver.resolve(
          providerInstanceId: 'inst-anthropic-custom',
          modelId: 'claude-custom',
          selectionId: 'tier_max',
        );
        expect(resBudget.directive, isA<AnthropicBudgetDirective>());
        expect(
          (resBudget.directive as AnthropicBudgetDirective).budgetTokens,
          8192,
        );

        // Serializer maps budget to body
        final anthropicBody = <String, dynamic>{'max_tokens': 16384};
        AnthropicThinkingWireCodec.applyThinking(
          anthropicBody,
          resBudget.directive,
        );
        expect(anthropicBody['thinking'], {
          'type': 'enabled',
          'budget_tokens': 8192,
        });

        // 2. The declared default (`tier_min` → 2048) is descriptor metadata;
        // an omitted/empty/whitespace selection stays provider Default by
        // omission and dispatches nothing, while explicitly selecting the
        // advertised default sends its exact value.
        expect(resBudget.descriptor.defaultOptionId, 'tier_min');
        for (final omitted in <String?>[null, '', '  ']) {
          final resDefault = testResolver.resolve(
            providerInstanceId: 'inst-anthropic-custom',
            modelId: 'claude-custom',
            selectionId: omitted,
          );
          expect(resDefault.selectionId, isNull);
          expect(resDefault.directive, isA<UseProviderDefault>());
        }

        final explicitDefault = testResolver.resolve(
          providerInstanceId: 'inst-anthropic-custom',
          modelId: 'claude-custom',
          selectionId: 'tier_min',
        );
        expect(
          (explicitDefault.directive as AnthropicBudgetDirective).budgetTokens,
          2048,
        );

        // 3. Anthropic off & default wire absence
        final offBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(
          offBody,
          const ThinkingToggleDirective(enabled: false),
        );
        expect(offBody['thinking'], {'type': 'disabled'});

        final defaultBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(
          defaultBody,
          const UseProviderDefault(),
        );
        expect(defaultBody.containsKey('thinking'), isFalse);

        // 4. OpenAI: opaque option ID -> declared effort value
        final resOpaque = testResolver.resolve(
          providerInstanceId: 'inst-openai-custom',
          modelId: 'gpt-custom',
          selectionId: 'quick',
        );
        expect(resOpaque.directive, isA<OpenAiEffortDirective>());
        expect((resOpaque.directive as OpenAiEffortDirective).effort, 'low');

        final openAiBody = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyChatCompletionsReasoning(
          openAiBody,
          resOpaque.directive,
        );
        expect(openAiBody['reasoning_effort'], 'low');

        // OpenAI off option -> declared 'none'
        final resOpenAiOff = testResolver.resolve(
          providerInstanceId: 'inst-openai-custom',
          modelId: 'gpt-custom',
          selectionId: 'off',
        );
        expect(
          (resOpenAiOff.directive as OpenAiEffortDirective).effort,
          'none',
        );
        final openAiOffBody = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyChatCompletionsReasoning(
          openAiOffBody,
          resOpenAiOff.directive,
        );
        expect(openAiOffBody['reasoning_effort'], 'none');

        // OpenAI UseProviderDefault -> wire absence
        final openAiDefaultBody = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyChatCompletionsReasoning(
          openAiDefaultBody,
          const UseProviderDefault(),
        );
        expect(openAiDefaultBody.containsKey('reasoning_effort'), isFalse);

        // 5. Invalid budget options: string or < 1024 are rejected, not invented (no int.tryParse ?? 1024)
        expect(
          () => testResolver.resolve(
            providerInstanceId: 'inst-anthropic-custom',
            modelId: 'claude-invalid-budget',
            selectionId: 'invented',
          ),
          sendsNoThinkingField,
        );
        expect(
          () => testResolver.resolve(
            providerInstanceId: 'inst-anthropic-custom',
            modelId: 'claude-invalid-budget',
            selectionId: 'too_small',
          ),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'Off semantics, fake-Off rejection, and wire serialization for anthropic_adaptive, google_thinking, and toggle_effort',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'inst-anthropic-adaptive',
            templateId: kCustomProviderTemplateId,
            displayName: 'Anthropic Adaptive Instance',
            protocol: ProviderProtocol.anthropicCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'inst-google-gemini',
            templateId: kCustomProviderTemplateId,
            displayName: 'Google Gemini Instance',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'inst-toggle-effort',
            templateId: kCustomProviderTemplateId,
            displayName: 'Toggle Effort Instance',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        repo.upsertModelCache(
          instanceId: 'inst-anthropic-adaptive',
          cacheKey: 'models',
          models: [
            {
              'value': 'claude-3-7-adaptive',
              'label': 'Claude 3.7 Adaptive',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'anthropic_adaptive',
                  'options': {'off': 'off', 'low': 'low', 'high': 'high'},
                },
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        repo.upsertModelCache(
          instanceId: 'inst-google-gemini',
          cacheKey: 'models',
          models: [
            {
              'value': 'gemini-2-flash-thinking',
              'label': 'Gemini 2 Flash Thinking',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'google_thinking',
                  'options': {'off': 0, 'low': 'low', 'budget': 4096},
                },
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        repo.upsertModelCache(
          instanceId: 'inst-toggle-effort',
          cacheKey: 'models',
          models: [
            {
              'value': 'deepseek-toggle',
              'label': 'DeepSeek Toggle',
              'model_metadata': {
                'thinking_control': {
                  'status': 'supported',
                  'wire': 'toggle_effort',
                  'options': {'off': false, 'on': true},
                },
              },
            },
          ],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final testResolver = ThinkingSelectionResolver(
          instances: repo,
          cacheResolver: ThinkingControlCacheResolver(repo),
          assembler: ThinkingCapabilityAssembler(
            buildProviderThinkingRegistry(),
          ),
          registry: buildProviderThinkingRegistry(),
        );

        // 1. anthropic_adaptive: off maps to ThinkingToggleDirective(enabled: false) and body['thinking'] = {'type': 'disabled'}
        final resAdaptiveOff = testResolver.resolve(
          providerInstanceId: 'inst-anthropic-adaptive',
          modelId: 'claude-3-7-adaptive',
          selectionId: 'off',
        );
        expect(
          resAdaptiveOff.directive,
          isA<ThinkingToggleDirective>().having(
            (d) => d.enabled,
            'enabled',
            isFalse,
          ),
        );
        final adaptiveOffBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(
          adaptiveOffBody,
          resAdaptiveOff.directive,
        );
        expect(adaptiveOffBody['thinking'], {'type': 'disabled'});
        expect(adaptiveOffBody.containsKey('output_config'), isFalse);

        // 2. anthropic_adaptive: active effort maps to AnthropicAdaptiveDirective and body['thinking'] = {'type': 'adaptive'}
        final resAdaptiveLow = testResolver.resolve(
          providerInstanceId: 'inst-anthropic-adaptive',
          modelId: 'claude-3-7-adaptive',
          selectionId: 'low',
        );
        expect(resAdaptiveLow.directive, isA<AnthropicAdaptiveDirective>());
        expect(
          (resAdaptiveLow.directive as AnthropicAdaptiveDirective).effort,
          'low',
        );
        final adaptiveLowBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(
          adaptiveLowBody,
          resAdaptiveLow.directive,
        );
        expect(adaptiveLowBody['thinking'], {'type': 'adaptive'});
        expect(adaptiveLowBody['output_config'], {'effort': 'low'});

        // 3. google_thinking: declared Off preserves the documented zero budget.
        final resGoogleOff = testResolver.resolve(
          providerInstanceId: 'inst-google-gemini',
          modelId: 'gemini-2-flash-thinking',
          selectionId: 'off',
        );
        expect(
          resGoogleOff.directive,
          isA<GoogleBudgetDirective>().having((d) => d.budget, 'budget', 0),
        );
        final googleOffBody = <String, dynamic>{};
        GoogleThinkingWireCodec.applyThinkingConfig(
          googleOffBody,
          resGoogleOff.directive,
        );
        expect(googleOffBody['extra_body']['google']['thinking_config'], {
          'thinking_budget': 0,
        });

        // 4. google_thinking: budget maps to GoogleBudgetDirective
        final resGoogleBudget = testResolver.resolve(
          providerInstanceId: 'inst-google-gemini',
          modelId: 'gemini-2-flash-thinking',
          selectionId: 'budget',
        );
        expect(resGoogleBudget.directive, isA<GoogleBudgetDirective>());
        expect(
          (resGoogleBudget.directive as GoogleBudgetDirective).budget,
          4096,
        );
        final googleBudgetBody = <String, dynamic>{};
        GoogleThinkingWireCodec.applyThinkingConfig(
          googleBudgetBody,
          resGoogleBudget.directive,
        );
        expect(
          googleBudgetBody['extra_body']['google']['thinking_config']['thinking_budget'],
          4096,
        );

        // 5. toggle_effort: off maps to ThinkingToggleDirective(false) -> body['thinking'] = {'type': 'disabled'}
        final resToggleOff = testResolver.resolve(
          providerInstanceId: 'inst-toggle-effort',
          modelId: 'deepseek-toggle',
          selectionId: 'off',
        );
        expect(
          resToggleOff.directive,
          isA<ThinkingToggleDirective>().having(
            (d) => d.enabled,
            'enabled',
            isFalse,
          ),
        );
        final toggleOffBody = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(
          toggleOffBody,
          resToggleOff.directive,
        );
        expect(toggleOffBody['thinking'], {'type': 'disabled'});
        expect(toggleOffBody.containsKey('reasoning_effort'), isFalse);

        // 6. toggle_effort: on maps to ThinkingToggleDirective(true) -> body['thinking'] = {'type': 'enabled'}
        final resToggleOn = testResolver.resolve(
          providerInstanceId: 'inst-toggle-effort',
          modelId: 'deepseek-toggle',
          selectionId: 'on',
        );
        expect(
          resToggleOn.directive,
          isA<ThinkingToggleDirective>().having(
            (d) => d.enabled,
            'enabled',
            isTrue,
          ),
        );
        final toggleOnBody = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(
          toggleOnBody,
          resToggleOn.directive,
        );
        expect(toggleOnBody['thinking'], {'type': 'enabled'});
        expect(toggleOnBody.containsKey('reasoning_effort'), isFalse);

        // 7. Omitted selection (UseProviderDefault) preserves absent wire keys
        final resOmitted = testResolver.resolve(
          providerInstanceId: 'inst-anthropic-adaptive',
          modelId: 'claude-3-7-adaptive',
          selectionId: null,
        );
        expect(resOmitted.directive, const UseProviderDefault());
        final omittedBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(
          omittedBody,
          resOmitted.directive,
        );
        expect(omittedBody.containsKey('thinking'), isFalse);
        expect(omittedBody.containsKey('output_config'), isFalse);
      },
    );

    test(
      'exact model route matching using ProviderModelId.normalize preserves case and tilde',
      () {
        const customModel = 'Meta-Llama-3.1-70B~Instruct';
        final normalized = ProviderModelId.normalize(
          templateId: 'custom-template',
          protocol: ProviderProtocol.openaiCompatible,
          rawModelId: customModel,
        );
        expect(normalized, equals('Meta-Llama-3.1-70B~Instruct'));
        expect(normalized, isNot(equals('meta-llama-3.1-70b~instruct')));
        expect(normalized, isNot(equals('Meta-Llama-3.1-70B-Instruct')));

        // Strips template prefix if prefixed
        final stripped = ProviderModelId.normalize(
          templateId: 'custom-template',
          protocol: ProviderProtocol.openaiCompatible,
          rawModelId: 'custom-template/Meta-Llama-3.1-70B~Instruct',
        );
        expect(stripped, equals('Meta-Llama-3.1-70B~Instruct'));
      },
    );

    test(
      'fresh unknown custom ID containing a family name cannot gain controls solely via heuristic fallback',
      () {
        final customOpenAi = ProviderInstance(
          id: 'custom-openai-regress',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(customOpenAi);

        final unevidencedFamilyModels = [
          'o3-mini-variant',
          'grok-3',
          'kimi-k2.5',
          'deepseek-custom-7b',
          'qwen-2.5-coder',
        ];

        for (final modelId in unevidencedFamilyModels) {
          // Real assembler boundary check
          final assembled = assembler.assemble(
            instance: customOpenAi,
            model: ModelOption(value: modelId, label: modelId),
          );
          expect(
            assembled.status,
            ThinkingCapabilityStatus.unknown,
            reason: '$modelId on custom instance must fail closed to unknown',
          );
          expect(assembled.source, 'unconfigured');

          // Real resolver boundary check
          expect(
            () => resolver.resolve(
              providerInstanceId: 'custom-openai-regress',
              modelId: modelId,
              selectionId: 'high',
            ),
            sendsNoThinkingField,
            reason:
                '$modelId on custom instance must reject selection as capabilityUnknown',
          );
        }
      },
    );

    test(
      'custom routes reuse shipped model defaults; Chat Claude preserved as not native Anthropic wire',
      () {
        // 1. Custom Anthropic with claude-3-7-sonnet gets native Anthropic controls
        final customAnthropic = ProviderInstance(
          id: 'custom-anthropic-regress',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom Anthropic',
          protocol: ProviderProtocol.anthropicCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(customAnthropic);

        final assembledAnthropic = assembler.assemble(
          instance: customAnthropic,
          model: ModelOption(
            value: 'claude-3-7-sonnet',
            label: 'Claude 3.7 Sonnet',
          ),
        );
        expect(assembledAnthropic.status, ThinkingCapabilityStatus.supported);
        expect(assembledAnthropic.kind, ThinkingControlKind.tokenBudget);

        final resolvedAnthropic = resolver.resolve(
          providerInstanceId: 'custom-anthropic-regress',
          modelId: 'claude-3-7-sonnet',
          selectionId: 'high',
        );
        expect(resolvedAnthropic.directive, isA<AnthropicBudgetDirective>());

        // 2. Chat Claude on custom OpenAI route is NOT native Anthropic wire (fails closed to unknown)
        final customOpenAi = ProviderInstance(
          id: 'custom-openai-chat-claude',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom OpenAI Chat',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(customOpenAi);

        final assembledChatClaude = assembler.assemble(
          instance: customOpenAi,
          model: ModelOption(
            value: 'claude-3-7-sonnet',
            label: 'Claude 3.7 Sonnet on Chat',
          ),
        );
        expect(assembledChatClaude.status, ThinkingCapabilityStatus.unknown);
        expect(
          () => resolver.resolve(
            providerInstanceId: 'custom-openai-chat-claude',
            modelId: 'claude-3-7-sonnet',
            selectionId: 'high',
          ),
          sendsNoThinkingField,
        );

        // 3. Custom OpenAI with o3-mini gets exact OpenAI controls
        final assembledO3 = assembler.assemble(
          instance: customOpenAi,
          model: ModelOption(value: 'o3-mini', label: 'o3-mini'),
        );
        expect(assembledO3.status, ThinkingCapabilityStatus.supported);
        expect(assembledO3.kind, ThinkingControlKind.effort);
        expect(assembledO3.options.map((o) => o.id), ['low', 'medium', 'high']);

        // 4. Custom OpenAI with deepseek-v4-flash exposes only the documented
        // standard effort ladder: the family's native envelope and its disable
        // are not evidenced on a generic compatible Chat wire.
        final assembledDeepSeek = assembler.assemble(
          instance: customOpenAi,
          model: ModelOption(
            value: 'deepseek-v4-flash',
            label: 'DeepSeek V4 Flash',
          ),
        );
        expect(assembledDeepSeek.status, ThinkingCapabilityStatus.supported);
        expect(assembledDeepSeek.options.map((o) => o.id), [
          'low',
          'high',
          'max',
        ]);
        expect(assembledDeepSeek.defaultOptionId, isNull);
      },
    );

    test(
      'shipped templates without a record fail closed to unknown; shipped records resolve',
      () {
        final unconfiguredTemplates = [
          ('nvidia', 'nvidia/nemotron-3-ultra-550b-a55b'),
          ('xai', 'grok-3'),
          ('kimi', 'kimi-k2.5'),
        ];

        for (final (tpl, modelId) in unconfiguredTemplates) {
          final inst = ProviderInstance(
            id: 'inst-$tpl',
            templateId: tpl,
            displayName: tpl,
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          repo.createInstance(inst);

          final assembled = assembler.assemble(
            instance: inst,
            model: ModelOption(value: modelId, label: modelId),
          );
          expect(
            assembled.status,
            ThinkingCapabilityStatus.unknown,
            reason: '$tpl with $modelId must have status unknown',
          );

          expect(
            () => resolver.resolve(
              providerInstanceId: 'inst-$tpl',
              modelId: modelId,
              selectionId: 'low',
            ),
            sendsNoThinkingField,
            reason:
                '$tpl with $modelId must reject selection as capabilityUnknown',
          );
        }

        // Evidenced model served via NVIDIA NIM resolves exact controls
        final nvidiaInst = repo.findById('inst-nvidia')!;
        final assembledEvidenced = assembler.assemble(
          instance: nvidiaInst,
          model: ModelOption(
            value: 'deepseek-ai/deepseek-v4-flash',
            label: 'DeepSeek V4 Flash',
          ),
        );
        expect(assembledEvidenced.status, ThinkingCapabilityStatus.supported);
      },
    );

    test(
      'custom route with unrecognized model fails closed to unknown and rejects selection',
      () {
        final customInstance = ProviderInstance(
          id: 'custom-unknown-1',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom Unknown',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(customInstance);

        expect(
          () => resolver.resolve(
            providerInstanceId: 'custom-unknown-1',
            modelId: 'custom-unsupported-llama',
            selectionId: 'high',
          ),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'validated native Ollama boolean thinking declaration older than 5 minutes preserves On, Off, and default without degradation to unknown',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'ollama-1',
            templateId: 'ollama',
            displayName: 'Ollama',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final staleObservedAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 10),
        );

        final gemmaMetadata = {
          OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': [false, true],
            'default': true,
          },
        };

        final gemmaThinkingControl = {
          'status': 'supported',
          'kind': 'toggle',
          'options': [
            {
              'id': 'off',
              'label': 'Off',
              'is_off': true,
              'is_provider_default': false,
            },
            {
              'id': 'on',
              'label': 'On',
              'is_off': false,
              'is_provider_default': true,
            },
          ],
          'default_option_id': 'on',
          'capability_revision': '1:1:ollama_live:gemma4:e2b',
          'source': 'live',
          'observed_at': staleObservedAt.toIso8601String(),
        };

        repo.upsertModelCache(
          instanceId: 'ollama-1',
          cacheKey: 'models',
          models: [
            {
              'value': 'gemma4:e2b',
              'model_metadata': gemmaMetadata,
              'thinking_control': gemmaThinkingControl,
            },
          ],
          fetchedAt: staleObservedAt,
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        // Off turn (>5 minutes after observation) - reproduces and verifies the reviewer regression
        final offResolution = resolver.resolve(
          providerInstanceId: 'ollama-1',
          modelId: 'gemma4:e2b',
          selectionId: 'off',
        );
        expect(
          offResolution.descriptor.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(
          offResolution.directive,
          const ThinkingToggleDirective(enabled: false),
        );

        // Wire serialization for Off: think: false
        final offBody = <String, dynamic>{'model': 'gemma4:e2b'};
        OllamaThinkingWireCodec.applyThink(offBody, offResolution.directive);
        expect(offBody['think'], isFalse);

        // On turn (>5 minutes after observation)
        final onResolution = resolver.resolve(
          providerInstanceId: 'ollama-1',
          modelId: 'gemma4:e2b',
          selectionId: 'on',
        );
        expect(
          onResolution.descriptor.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(
          onResolution.directive,
          const ThinkingToggleDirective(enabled: true),
        );

        // Wire serialization for On: think: true
        final onBody = <String, dynamic>{'model': 'gemma4:e2b'};
        OllamaThinkingWireCodec.applyThink(onBody, onResolution.directive);
        expect(onBody['think'], isTrue);

        // Default turn (null selection) (>5 minutes after observation)
        final defaultResolution = resolver.resolve(
          providerInstanceId: 'ollama-1',
          modelId: 'gemma4:e2b',
          selectionId: null,
        );
        expect(
          defaultResolution.descriptor.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(defaultResolution.directive, isA<UseProviderDefault>());

        // Wire serialization for Default: think is omitted
        final defaultBody = <String, dynamic>{'model': 'gemma4:e2b'};
        OllamaThinkingWireCodec.applyThink(
          defaultBody,
          defaultResolution.directive,
        );
        expect(defaultBody.containsKey('think'), isFalse);
      },
    );

    test(
      'explicit probe failure marker on native model retains failure and rejects selection',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'ollama-1',
            templateId: 'ollama',
            displayName: 'Ollama',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final staleObservedAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 10),
        );

        final gemmaMetadata = {
          OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': [false, true],
            'default': true,
          },
        };

        repo.upsertModelCache(
          instanceId: 'ollama-1',
          cacheKey: 'models',
          models: [
            {
              'value': 'gemma4:e2b',
              'model_metadata': gemmaMetadata,
              'thinking_control': {
                'status': 'supported',
                'kind': 'toggle',
                'options': [
                  {'id': 'off', 'label': 'Off'},
                  {'id': 'on', 'label': 'On'},
                ],
                'default_option_id': 'on',
                'capability_revision': '1:1:ollama_live:gemma4:e2b',
                'source': 'live_probe_failed',
                'observed_at': staleObservedAt.toIso8601String(),
              },
            },
          ],
          fetchedAt: staleObservedAt,
          source: 'live_probe_failed',
          configRevision: 1,
          credentialRevision: 1,
        );

        expect(
          () => resolver.resolve(
            providerInstanceId: 'ollama-1',
            modelId: 'gemma4:e2b',
            selectionId: 'off',
          ),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'explicit cache_stale marker on native model retains invalidation and rejects selection',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'ollama-1',
            templateId: 'ollama',
            displayName: 'Ollama',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final staleObservedAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 10),
        );

        final gemmaMetadata = {
          OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': [false, true],
            'default': true,
          },
        };

        repo.upsertModelCache(
          instanceId: 'ollama-1',
          cacheKey: 'models',
          models: [
            {
              'value': 'gemma4:e2b',
              'model_metadata': gemmaMetadata,
              'thinking_control': {
                'status': 'supported',
                'kind': 'toggle',
                'options': [
                  {'id': 'off', 'label': 'Off'},
                  {'id': 'on', 'label': 'On'},
                ],
                'default_option_id': 'on',
                'capability_revision': '1:1:ollama_live:gemma4:e2b',
                'source': 'cache_stale',
                'observed_at': staleObservedAt.toIso8601String(),
              },
            },
          ],
          fetchedAt: staleObservedAt,
          source: 'cache_stale',
          configRevision: 1,
          credentialRevision: 1,
        );

        expect(
          () => resolver.resolve(
            providerInstanceId: 'ollama-1',
            modelId: 'gemma4:e2b',
            selectionId: 'off',
          ),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'malformed native declaration fails closed to unknown and rejects selection',
      () {
        repo.createInstance(
          ProviderInstance(
            id: 'ollama-1',
            templateId: 'ollama',
            displayName: 'Ollama',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 1,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final staleObservedAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 10),
        );

        repo.upsertModelCache(
          instanceId: 'ollama-1',
          cacheKey: 'models',
          models: [
            {
              'value': 'gemma4:e2b',
              // Malformed: empty values list fails parseThinkingDeclaration
              'model_metadata': {
                OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
                OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
                  'values': <dynamic>[],
                  'default': true,
                },
              },
              'thinking_control': {
                'status': 'supported',
                'kind': 'toggle',
                'options': [
                  {'id': 'off', 'label': 'Off'},
                  {'id': 'on', 'label': 'On'},
                ],
                'default_option_id': 'on',
                'capability_revision': '1:1:ollama_live:gemma4:e2b',
                'source': 'live',
                'observed_at': staleObservedAt.toIso8601String(),
              },
            },
          ],
          fetchedAt: staleObservedAt,
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        expect(
          () => resolver.resolve(
            providerInstanceId: 'ollama-1',
            modelId: 'gemma4:e2b',
            selectionId: 'off',
          ),
          sendsNoThinkingField,
        );
      },
    );

    test(
      'revision change invalidates cached descriptor and reassembles fresh revision',
      () {
        // Instance updated to configRevision 2
        repo.createInstance(
          ProviderInstance(
            id: 'ollama-1',
            templateId: 'ollama',
            displayName: 'Ollama',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            configRevision: 2,
            credentialRevision: 1,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final staleObservedAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 10),
        );

        final gemmaMetadata = {
          OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': [false, true],
            'default': true,
          },
        };

        repo.upsertModelCache(
          instanceId: 'ollama-1',
          cacheKey: 'models',
          models: [
            {
              'value': 'gemma4:e2b',
              'model_metadata': gemmaMetadata,
              'thinking_control': {
                'status': 'supported',
                'kind': 'toggle',
                'options': [
                  {'id': 'off', 'label': 'Off'},
                  {'id': 'on', 'label': 'On'},
                ],
                'default_option_id': 'on',
                'capability_revision':
                    '1:1:ollama_live:gemma4:e2b', // old rev 1:1
                'source': 'live',
                'observed_at': staleObservedAt.toIso8601String(),
              },
            },
          ],
          fetchedAt: staleObservedAt,
          source: 'live',
          configRevision: 1,
          credentialRevision: 1,
        );

        final resolution = resolver.resolve(
          providerInstanceId: 'ollama-1',
          modelId: 'gemma4:e2b',
          selectionId: null,
        );
        expect(resolution.descriptor.capabilityRevision, startsWith('2:1:'));
        expect(resolution.descriptor.status, ThinkingCapabilityStatus.unknown);

        expect(
          () => resolver.resolve(
            providerInstanceId: 'ollama-1',
            modelId: 'gemma4:e2b',
            selectionId: 'off',
          ),
          sendsNoThinkingField,
        );
      },
    );
  });
}

ProviderInstance _instance() {
  return ProviderInstance(
    id: 'inst-1',
    templateId: 'openai',
    displayName: 'OpenAI',
    protocol: ProviderProtocol.openaiCompatible,
    authMethod: ProviderAuthMethod.apiKey,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

ProviderInstance _anthropicInstance() {
  return ProviderInstance(
    id: 'anthropic-1',
    templateId: 'anthropic',
    displayName: 'Anthropic',
    protocol: ProviderProtocol.anthropicCompatible,
    authMethod: ProviderAuthMethod.apiKey,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}
