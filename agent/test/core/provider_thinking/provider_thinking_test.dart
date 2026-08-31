import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/aggregator_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/aggregator_upstream_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_live_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/codex_responses_effort_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/deepseek_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/google_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/google_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/toggle_effort_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/openai_chat_effort_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/openai_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_aliases.dart';
import 'package:sanad_agent/core/provider_thinking/unknown_thinking_policy.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

void main() {
  group('ThinkingControlDescriptor', () {
    test('roundtrips through map serialization', () {
      final descriptor = ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: const [
          ThinkingControlOption(
            id: 'off',
            label: 'Off',
            isOff: true,
          ),
          ThinkingControlOption(
            id: 'low',
            label: 'Low',
            isProviderDefault: true,
          ),
          ThinkingControlOption(id: 'medium', label: 'Medium'),
          ThinkingControlOption(id: 'high', label: 'High'),
        ],
        defaultOptionId: 'low',
        capabilityRevision: 'rev-1',
        source: 'profile',
        observedAt: DateTime.utc(2026, 1, 1),
      );

      final restored = ThinkingControlDescriptor.fromMap(descriptor.toMap());

      expect(restored.status, ThinkingCapabilityStatus.supported);
      expect(restored.kind, ThinkingControlKind.effort);
      expect(restored.options.map((option) => option.id), [
        'off',
        'low',
        'medium',
        'high',
      ]);
      expect(restored.options.first.isOff, isTrue);
      expect(restored.options[1].isProviderDefault, isTrue);
      expect(restored.defaultOptionId, 'low');
      expect(restored.capabilityRevision, 'rev-1');
      expect(restored.source, 'profile');
      expect(restored.observedAt, DateTime.utc(2026, 1, 1));
    });

    test('unknown factory is not selectable', () {
      final descriptor = ThinkingControlDescriptor.unknown();
      expect(descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(descriptor.isSupported, isFalse);
      expect(descriptor.isSelectable, isFalse);
    });

    test('unsupported factory is not selectable', () {
      final descriptor = ThinkingControlDescriptor.unsupported();
      expect(descriptor.status, ThinkingCapabilityStatus.unsupported);
      expect(descriptor.isSupported, isFalse);
      expect(descriptor.isSelectable, isFalse);
      expect(descriptor.options, isEmpty);
    });
  });

  group('legacy thinking aliases', () {
    test('maps fast to low when available', () {
      final descriptor = ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: const [
          ThinkingControlOption(id: 'low', label: 'Low'),
          ThinkingControlOption(id: 'medium', label: 'Medium'),
        ],
        capabilityRevision: 'rev-1',
        source: 'profile',
      );

      expect(
        migrateLegacyThinkingSelectionId(
          selectionId: 'fast',
          descriptor: descriptor,
        ),
        'low',
      );
      expect(isLegacyThinkingSelectionId('balanced'), isTrue);
    });

    test('returns null when mapped option is unavailable', () {
      final descriptor = ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: const [
          ThinkingControlOption(id: 'medium', label: 'Medium'),
        ],
        capabilityRevision: 'rev-1',
        source: 'profile',
      );

      expect(
        migrateLegacyThinkingSelectionId(
          selectionId: 'deep',
          descriptor: descriptor,
        ),
        isNull,
      );
    });
  });

  group('UnknownThinkingPolicy', () {
    late UnknownThinkingPolicy policy;
    late ThinkingPolicyContext context;

    setUp(() {
      policy = UnknownThinkingPolicy();
      context = const ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'custom',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'gpt-test',
      );
    });

    test('returns unknown capability', () {
      final descriptor = policy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(descriptor.options, isEmpty);
    });

    test('null selection resolves to provider default', () {
      final directive = policy.resolveDirective(context, null);
      expect(directive, isA<UseProviderDefault>());
    });

    test('explicit selection stays fail-closed without a raw map', () {
      final directive = policy.resolveDirective(context, 'high');
      expect(directive, isA<UseProviderDefault>());
      expect(directive, isNot(isA<OpenAiEffortDirective>()));
    });
  });

  group('ThinkingRoutePolicy', () {
    test('unknown template ids fail closed to unknown policy', () {
      final instance = ProviderInstance(
        id: 'inst-unknown',
        templateId: 'missing-template',
        displayName: 'Missing',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      expect(ThinkingRoutePolicy.policyIdFor(instance), 'unknown');
      expect(
        ThinkingRoutePolicy.resolveTemplate(instance).effectiveThinkingPolicyId,
        'unknown',
      );
    });

    test('assembler returns unknown descriptor for unknown template ids', () {
      final registry = buildProviderThinkingRegistry();
      final assembler = ThinkingCapabilityAssembler(registry);
      final instance = ProviderInstance(
        id: 'inst-unknown',
        templateId: 'missing-template',
        displayName: 'Missing',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      final descriptor = assembler.assemble(
        instance: instance,
        model: ModelOption(value: 'gpt-test', label: 'Test'),
      );

      expect(descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(descriptor.options, isEmpty);
    });
  });

  group('ProviderThinkingRegistry', () {
    test('registers reserved policies and falls back to unknown', () {
      final registry = buildProviderThinkingRegistry();

      expect(
        registry.registeredPolicyIds.toSet(),
        containsAll(reservedThinkingPolicyIds),
      );
      expect(registry.registeredPolicyIds, contains('openai_chat_effort'));
      expect(
        registry.policyFor('missing-policy').policyId,
        equals('unknown'),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'codex_responses_effort',
        ).policyId,
        equals('codex_responses_effort'),
      );
    });

    test('registers real OpenAI policies instead of placeholders', () {
      final registry = buildProviderThinkingRegistry();

      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'openai_chat_effort',
        ),
        isA<OpenAiChatEffortThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'codex_responses_effort',
        ),
        isA<CodexResponsesEffortThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'anthropic_thinking',
        ),
        isA<AnthropicThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'aggregator_upstream',
        ),
        isA<AggregatorUpstreamThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'ollama_live',
        ),
        isA<OllamaLiveThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'google_thinking',
        ),
        isA<GoogleThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(
          thinkingPolicyId: 'deepseek_thinking',
        ),
        isA<DeepSeekThinkingPolicy>(),
      );
    });

    test('derives thinking policy ids from provider templates', () {
      final openAi = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'openai',
      );
      final anthropic = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'anthropic',
      );
      final openRouter = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'openrouter',
      );
      final gemini = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'gemini',
      );
      final deepSeek = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'deepseek',
      );
      final kimi = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'kimi',
      );
      final nvidia = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'nvidia',
      );
      const custom = ProviderProfile(
        name: kCustomProviderTemplateId,
        apiMode: 'chat_completions',
      );

      expect(openAi.effectiveThinkingPolicyId, 'openai_chat_effort');
      expect(anthropic.effectiveThinkingPolicyId, 'anthropic_thinking');
      expect(openRouter.effectiveThinkingPolicyId, 'aggregator_upstream');
      expect(gemini.effectiveThinkingPolicyId, 'google_thinking');
      expect(deepSeek.effectiveThinkingPolicyId, 'deepseek_thinking');
      // Ambiguous chat_completions templates fail closed until a dedicated
      // first-release policy is opted in (Task 43 Gate R0/A).
      expect(kimi.effectiveThinkingPolicyId, 'unknown');
      expect(nvidia.effectiveThinkingPolicyId, 'unknown');
      expect(custom.effectiveThinkingPolicyId, 'unknown');
    });
  });

  group('Ollama thinking policy', () {
    const policy = OllamaLiveThinkingPolicy();
    const thinkingMetadata = {
      OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
    };

    test('returns unknown when live probe evidence is absent', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'ollama',
        protocol: 'ollama',
        apiMode: 'ollama',
        modelId: 'custom-local-model',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.unknown);
      expect(descriptor.source, 'live');
    });

    test('advertises level options from live probe without name heuristics', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'ollama',
        protocol: 'ollama',
        apiMode: 'ollama',
        modelId: 'custom-local-model',
        capabilityRevision: 'rev-1',
        modelMetadata: thinkingMetadata,
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.effort);
      expect(descriptor.source, 'live');
      expect(
        descriptor.options.map((option) => option.id),
        ['off', 'low', 'medium', 'high', 'max'],
      );
    });

    test('maps level selection to OllamaThinkLevelDirective', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'ollama',
        protocol: 'ollama',
        apiMode: 'ollama',
        modelId: 'custom-local-model',
        capabilityRevision: 'rev-1',
        modelMetadata: thinkingMetadata,
      );

      expect(
        policy.resolveDirective(context, 'medium'),
        isA<OllamaThinkLevelDirective>(),
      );
    });

    test('advertises level-only options for gpt-oss models', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'ollama',
        protocol: 'ollama',
        apiMode: 'ollama',
        modelId: 'gpt-oss:20b',
        capabilityRevision: 'rev-1',
        modelMetadata: thinkingMetadata,
      );

      final descriptor = policy.resolveCapability(context);
      expect(
        descriptor.options.map((option) => option.id),
        ['low', 'medium', 'high'],
      );
    });

    test('maps off selection to disabled thinking toggle', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'ollama',
        protocol: 'ollama',
        apiMode: 'ollama',
        modelId: 'qwen3:8b',
        capabilityRevision: 'rev-1',
      );

      expect(
        policy.resolveDirective(context, 'off'),
        isA<ThinkingToggleDirective>(),
      );
    });
  });

  group('OllamaThinkingWireCodec', () {
    test('maps level directive to think field', () {
      final body = <String, dynamic>{'model': 'qwen3'};
      OllamaThinkingWireCodec.applyThink(
        body,
        const OllamaThinkLevelDirective('high'),
      );

      expect(body['think'], 'high');
    });

    test('maps disabled toggle to think false', () {
      final body = <String, dynamic>{'model': 'qwen3'};
      OllamaThinkingWireCodec.applyThink(
        body,
        const ThinkingToggleDirective(enabled: false),
      );

      expect(body['think'], isFalse);
    });
  });

  group('Aggregator upstream thinking policy', () {
    final policy = AggregatorUpstreamThinkingPolicy();

    test('delegates OpenAI reasoning models to effort options', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openrouter',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'openai/o3',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(
        descriptor.options.map((option) => option.id),
        containsAll(['low', 'medium', 'high']),
      );
    });

    test('delegates Anthropic models to adaptive effort options', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openrouter',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'anthropic/claude-opus-4.7',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.adaptive);
      expect(descriptor.containsOptionId('high'), isTrue);
    });

    test('delegates Google budget models to token budget options', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openrouter',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'google/gemini-2.5-flash',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      expect(descriptor.containsOptionId('medium'), isTrue);
    });

    test('delegates DeepSeek chat fixture to toggle/effort options', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openrouter',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'deepseek/deepseek-chat',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.toggle);
      expect(descriptor.containsOptionId('off'), isTrue);
      expect(descriptor.containsOptionId('high'), isTrue);
    });

    test('keeps unresolved DeepSeek models unknown via aggregator delegate', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openrouter',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'deepseek/deepseek-v4-pro',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.unknown);
    });

    test('keeps Moonshot/Kimi aggregator models unknown until XOR policy exists', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openrouter',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'moonshotai/kimi-k2.6',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.unknown);
    });
  });

  group('Google thinking policy', () {
    const policy = GoogleThinkingPolicy();

    test('advertises budget tiers for Gemini 2.5 models', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'gemini',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'gemini-2.5-flash',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      expect(
        descriptor.options.map((option) => option.id),
        ['off', 'low', 'medium', 'high'],
      );
      expect(
        policy.resolveDirective(context, 'medium'),
        isA<GoogleBudgetDirective>(),
      );
    });

    test('advertises level tiers for Gemini 3 models', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'gemini',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'gemini-3.6-flash',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.level);
      expect(descriptor.containsOptionId('minimal'), isTrue);
      expect(
        policy.resolveDirective(context, 'medium'),
        isA<GoogleLevelDirective>(),
      );
      expect(
        policy.resolveDirective(context, 'medium'),
        isNot(isA<GoogleBudgetDirective>()),
      );
    });
  });

  group('GoogleThinkingWireCodec', () {
    test('maps budget directive to nested thinking_budget only', () {
      final body = <String, dynamic>{'model': 'gemini-2.5-flash'};
      GoogleThinkingWireCodec.applyThinkingConfig(
        body,
        const GoogleBudgetDirective(8192),
      );

      expect(body['extra_body'], {
        'google': {
          'thinking_config': {'thinking_budget': 8192},
        },
      });
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('maps level directive to nested thinking_level only', () {
      final body = <String, dynamic>{'model': 'gemini-3.6-flash'};
      GoogleThinkingWireCodec.applyThinkingConfig(
        body,
        const GoogleLevelDirective('low'),
      );

      expect(body['extra_body'], {
        'google': {
          'thinking_config': {'thinking_level': 'low'},
        },
      });
      expect(body.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('DeepSeek thinking policy', () {
    const policy = DeepSeekThinkingPolicy();

    test('returns unknown for unresolved DeepSeek models', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'deepseek',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'deepseek-v4-pro',
        capabilityRevision: 'rev-1',
      );

      expect(
        policy.resolveCapability(context).status,
        ThinkingCapabilityStatus.unknown,
      );
    });

    test('returns unsupported for fixed reasoner models', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'deepseek',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'deepseek-reasoner',
        capabilityRevision: 'rev-1',
      );

      expect(
        policy.resolveCapability(context).status,
        ThinkingCapabilityStatus.unsupported,
      );
    });

    test('maps chat fixture to toggle off or effort directives', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'deepseek',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'deepseek-chat',
        capabilityRevision: 'rev-1',
      );

      expect(
        policy.resolveDirective(context, 'off'),
        isA<ThinkingToggleDirective>(),
      );
      expect(
        policy.resolveDirective(context, 'high'),
        isA<OpenAiEffortDirective>(),
      );
    });
  });

  group('ToggleEffortThinkingWireCodec', () {
    test('applies effort without thinking toggle fields', () {
      final body = <String, dynamic>{
        'model': 'deepseek-chat',
        'thinking': {'type': 'disabled'},
      };
      ToggleEffortThinkingWireCodec.applyChatCompletions(
        body,
        const OpenAiEffortDirective('medium'),
      );

      expect(body['reasoning_effort'], 'medium');
      expect(body.containsKey('thinking'), isFalse);
    });

    test('applies off toggle without reasoning_effort', () {
      final body = <String, dynamic>{
        'model': 'deepseek-chat',
        'reasoning_effort': 'high',
      };
      ToggleEffortThinkingWireCodec.applyChatCompletions(
        body,
        const ThinkingToggleDirective(enabled: false),
      );

      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['thinking'], {'type': 'disabled'});
    });
  });

  group('AggregatorThinkingWireCodec', () {
    test('maps effort directive to nested reasoning object', () {
      final body = <String, dynamic>{'model': 'openai/o3'};
      AggregatorThinkingWireCodec.applyReasoning(
        body,
        const OpenAiEffortDirective('high'),
      );

      expect(body['reasoning'], {'enabled': true, 'effort': 'high'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('maps Anthropic budget directive to reasoning.max_tokens', () {
      final body = <String, dynamic>{'model': 'anthropic/claude-sonnet-4-5'};
      AggregatorThinkingWireCodec.applyReasoning(
        body,
        const AnthropicBudgetDirective(8192),
      );

      expect(body['reasoning'], {'enabled': true, 'max_tokens': 8192});
      expect((body['reasoning'] as Map).containsKey('effort'), isFalse);
    });

    test('maps Google budget directive to max_tokens without effort', () {
      final body = <String, dynamic>{'model': 'google/gemini-2.5-flash'};
      AggregatorThinkingWireCodec.applyReasoning(
        body,
        const GoogleBudgetDirective(8192),
      );

      expect(body['reasoning'], {'enabled': true, 'max_tokens': 8192});
      expect((body['reasoning'] as Map).containsKey('effort'), isFalse);
    });

    test('maps Google level directive to effort without max_tokens', () {
      final body = <String, dynamic>{'model': 'google/gemini-3.6-flash'};
      AggregatorThinkingWireCodec.applyReasoning(
        body,
        const GoogleLevelDirective('medium'),
      );

      expect(body['reasoning'], {'enabled': true, 'effort': 'medium'});
      expect((body['reasoning'] as Map).containsKey('max_tokens'), isFalse);
    });
  });

  group('Anthropic thinking policy', () {
    const policy = AnthropicThinkingPolicy();

    test('manual models advertise token budget tiers', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        apiMode: 'anthropic_messages',
        modelId: 'claude-sonnet-4-5',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      expect(
        descriptor.options.map((option) => option.id),
        ['off', 'low', 'medium', 'high'],
      );
      expect(
        policy.resolveDirective(context, 'medium'),
        isA<AnthropicBudgetDirective>(),
      );
    });

    test('adaptive models advertise effort tiers without manual budget shape', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        apiMode: 'anthropic_messages',
        modelId: 'claude-opus-4-7',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.kind, ThinkingControlKind.adaptive);
      expect(
        descriptor.options.map((option) => option.id),
        ['off', 'low', 'medium', 'high', 'max'],
      );
      expect(
        policy.resolveDirective(context, 'high'),
        isA<AnthropicAdaptiveDirective>(),
      );
      expect(
        policy.resolveDirective(context, 'high'),
        isNot(isA<AnthropicBudgetDirective>()),
      );
    });

    test('always-on adaptive models hide explicit off', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        apiMode: 'anthropic_messages',
        modelId: 'claude-fable-5',
        capabilityRevision: 'rev-1',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.options.any((option) => option.isOff), isFalse);
      expect(
        policy.resolveDirective(context, 'off'),
        isA<UseProviderDefault>(),
      );
    });

    test('missing budget tier resolves to provider default', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        apiMode: 'anthropic_messages',
        modelId: 'claude-sonnet-4-5',
        capabilityRevision: 'rev-1',
      );

      expect(
        policy.resolveDirective(context, 'max'),
        isA<UseProviderDefault>(),
      );
      expect(
        policy.resolveDirective(context, 'ultra'),
        isA<UseProviderDefault>(),
      );
    });

    test('manual and adaptive shapes stay mutually exclusive', () {
      const manualContext = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        apiMode: 'anthropic_messages',
        modelId: 'claude-sonnet-4-5',
        capabilityRevision: 'rev-1',
      );
      const adaptiveContext = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        apiMode: 'anthropic_messages',
        modelId: 'claude-opus-4-7',
        capabilityRevision: 'rev-1',
      );

      expect(
        policy.resolveDirective(manualContext, 'medium'),
        isA<AnthropicBudgetDirective>(),
      );
      expect(
        policy.resolveDirective(adaptiveContext, 'medium'),
        isA<AnthropicAdaptiveDirective>(),
      );
      expect(
        policy.resolveDirective(manualContext, 'medium'),
        isNot(isA<AnthropicAdaptiveDirective>()),
      );
    });
  });

  group('AnthropicThinkingWireCodec', () {
    test('maps manual directive to enabled budget_tokens', () {
      final body = <String, dynamic>{'model': 'claude-sonnet-4-5'};
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicBudgetDirective(8192),
      );

      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 8192});
      expect(body.containsKey('output_config'), isFalse);
    });

    test('maps adaptive directive to adaptive thinking and output_config.effort', () {
      final body = <String, dynamic>{'model': 'claude-opus-4-7'};
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicAdaptiveDirective('medium'),
      );

      expect(body['thinking'], {'type': 'adaptive'});
      expect(body['output_config'], {'effort': 'medium'});
    });

    test('maps explicit off to disabled thinking', () {
      final body = <String, dynamic>{'model': 'claude-sonnet-5'};
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const ThinkingToggleDirective(enabled: false),
      );

      expect(body['thinking'], {'type': 'disabled'});
    });

    test('lowers manual budget when max_tokens is smaller', () {
      final body = <String, dynamic>{
        'model': 'claude-sonnet-4-5',
        'max_tokens': 4096,
      };
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicBudgetDirective(16384),
      );

      expect(body['thinking'], {
        'type': 'enabled',
        'budget_tokens': 4095,
      });
    });

    test('preserves manual budget when max_tokens is larger', () {
      final body = <String, dynamic>{
        'model': 'claude-sonnet-4-5',
        'max_tokens': 16384,
      };
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicBudgetDirective(8192),
      );

      expect(body['thinking'], {
        'type': 'enabled',
        'budget_tokens': 8192,
      });
    });
  });

  group('OpenAI effort policies', () {
    const chatPolicy = OpenAiChatEffortThinkingPolicy();
    const codexPolicy = CodexResponsesEffortThinkingPolicy();

    test('advertises effort options for reasoning models', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'o3',
        capabilityRevision: 'rev-1',
      );

      final descriptor = chatPolicy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((option) => option.id), ['low', 'medium', 'high']);
    });

    test('reasoning output alone does not advertise thinking controls', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'gpt-test',
        supportsReasoningOutput: true,
        capabilityRevision: 'rev-1',
      );

      final descriptor = chatPolicy.resolveCapability(context);
      expect(descriptor.status, ThinkingCapabilityStatus.unsupported);
    });

    test('restricts o1 models to medium and high', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'o1-preview',
        capabilityRevision: 'rev-1',
      );

      final descriptor = chatPolicy.resolveCapability(context);
      expect(descriptor.options.map((option) => option.id), ['medium', 'high']);
    });

    test('chat and codex policies emit distinct directive shapes', () {
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openai-codex',
        protocol: 'openai_compatible',
        apiMode: 'codex_responses',
        modelId: 'gpt-5.2-codex',
        capabilityRevision: 'rev-1',
      );

      expect(
        chatPolicy.resolveDirective(context, 'high'),
        isA<OpenAiEffortDirective>(),
      );
      expect(
        codexPolicy.resolveDirective(context, 'high'),
        isA<ResponsesReasoningDirective>(),
      );
    });
  });

  group('OpenAiThinkingWireCodec', () {
    test('maps chat directive to reasoning_effort only', () {
      final body = <String, dynamic>{'model': 'o3'};
      OpenAiThinkingWireCodec.applyChatCompletionsReasoning(
        body,
        const OpenAiEffortDirective('medium'),
      );

      expect(body['reasoning_effort'], 'medium');
      expect(body.containsKey('reasoning'), isFalse);
    });

    test('maps codex directive to reasoning.effort and summary', () {
      final reasoning = <String, dynamic>{};
      OpenAiThinkingWireCodec.applyResponsesReasoning(
        reasoning,
        const ResponsesReasoningDirective(effort: 'low'),
      );

      expect(reasoning['effort'], 'low');
      expect(reasoning['summary'], 'auto');
    });

    test('does not apply responses shape to chat bodies', () {
      final body = <String, dynamic>{'model': 'o3'};
      OpenAiThinkingWireCodec.applyChatCompletionsReasoning(
        body,
        const ResponsesReasoningDirective(effort: 'high'),
      );

      expect(body.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('directive boundary', () {
    test('supported test policy resolves typed directives without raw maps', () {
      final policy = _TestEffortThinkingPolicy();
      final context = const ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'gpt-test',
      );

      final descriptor = policy.resolveCapability(context);
      expect(descriptor.options.map((option) => option.id), ['low', 'medium', 'high']);
      expect(
        policy.resolveDirective(context, 'medium'),
        isA<OpenAiEffortDirective>(),
      );
      expect(
        policy.resolveDirective(context, null),
        isA<UseProviderDefault>(),
      );
    });
  });
}

class _TestEffortThinkingPolicy implements ProviderThinkingPolicy {
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
        ThinkingControlOption(id: 'high', label: 'High'),
      ],
      capabilityRevision: 'test-rev',
      source: 'profile',
    );
  }

  @override
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  ) {
    if (selectionId == null || selectionId.trim().isEmpty) {
      return const UseProviderDefault();
    }
    return OpenAiEffortDirective(selectionId);
  }
}
