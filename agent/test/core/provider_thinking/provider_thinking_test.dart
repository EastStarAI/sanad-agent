import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/aggregator_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_wire_vocabulary.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_live_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/codex_responses_effort_thinking_policy.dart';
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
          ThinkingControlOption(id: 'off', label: 'Off', isOff: true),
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
      expect(
        migrateLegacyThinkingSelectionId(
          selectionId: 'light',
          descriptor: descriptor,
        ),
        'low',
      );
      expect(isLegacyThinkingSelectionId('balanced'), isTrue);
      expect(isLegacyThinkingSelectionId('ultra'), isTrue);
      expect(isLegacyThinkingSelectionId('light'), isTrue);
      expect(isLegacyThinkingSelectionId('extra-high'), isTrue);
    });

    test('clamps ultra to nearest supported level', () {
      final descriptorXHigh = ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: const [
          ThinkingControlOption(id: 'low', label: 'Low'),
          ThinkingControlOption(id: 'medium', label: 'Medium'),
          ThinkingControlOption(id: 'high', label: 'High'),
          ThinkingControlOption(id: 'xhigh', label: 'Extra High'),
        ],
        capabilityRevision: 'rev-1',
        source: 'profile',
      );

      expect(
        migrateLegacyThinkingSelectionId(
          selectionId: 'ultra',
          descriptor: descriptorXHigh,
        ),
        'xhigh',
      );
      expect(
        migrateLegacyThinkingSelectionId(
          selectionId: 'extra-high',
          descriptor: descriptorXHigh,
        ),
        'xhigh',
      );
    });

    test('returns null when mapped option is unavailable', () {
      final descriptor = ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: const [ThinkingControlOption(id: 'medium', label: 'Medium')],
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
    test('registers only provider-reported capability policies', () {
      final registry = buildProviderThinkingRegistry();

      // Capability authorities read provider-reported item metadata only; every
      // other reserved id is a wire-dialect label and falls back to unknown.
      expect(registry.registeredPolicyIds.toSet(), {
        'unknown',
        'openai_chat_effort',
        'codex_responses_effort',
        'ollama_live',
      });
      expect(
        registry.resolveForTemplate(thinkingPolicyId: 'openai_chat_effort'),
        isA<OpenAiChatEffortThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(thinkingPolicyId: 'codex_responses_effort'),
        isA<CodexResponsesEffortThinkingPolicy>(),
      );
      expect(
        registry.resolveForTemplate(thinkingPolicyId: 'ollama_live'),
        isA<OllamaLiveThinkingPolicy>(),
      );
      for (final labelOnly in [
        'anthropic_thinking',
        'aggregator_upstream',
        'google_thinking',
        'deepseek_thinking',
        'kimi_thinking',
        'zai_thinking',
        'nim_thinking',
        'missing-policy',
      ]) {
        expect(
          registry.resolveForTemplate(thinkingPolicyId: labelOnly).policyId,
          'unknown',
          reason: labelOnly,
        );
      }
    });

    test('provider-reported OpenAI policy without item facts stays unknown', () {
      const policy = OpenAiChatEffortThinkingPolicy();
      const context = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'opencode-go',
        protocol: 'openai_compatible',
        apiMode: 'chat_completions',
        modelId: 'gpt-6-luna',
        capabilityRevision: 'rev-1',
      );
      // Absence of a table entry is not a positive `unsupported` claim.
      expect(
        policy.resolveCapability(context).status,
        ThinkingCapabilityStatus.unknown,
      );
      final withLevels = ThinkingPolicyContext(
        providerInstanceId: 'instance-1',
        templateId: 'openai-codex',
        protocol: 'openai_compatible',
        apiMode: 'codex_responses',
        modelId: 'gpt-6-luna',
        capabilityRevision: 'rev-1',
        modelMetadata: const {
          'supported_reasoning_levels': [
            {'effort': 'low'},
            {'effort': 'high'},
          ],
          'default_reasoning_level': 'low',
        },
      );
      final descriptor = const CodexResponsesEffortThinkingPolicy()
          .resolveCapability(withLevels);
      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.options.map((o) => o.id), ['low', 'high']);
      expect(descriptor.defaultOptionId, 'low');
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
      final openCodeGo = ProviderRegistry.profiles.firstWhere(
        (profile) => profile.name == 'opencode-go',
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
      expect(kimi.effectiveThinkingPolicyId, 'kimi_thinking');
      expect(openCodeGo.effectiveThinkingPolicyId, 'openai_chat_effort');
      // The shipped NVIDIA template is the hosted NIM catalog and owns its own
      // documented per-model Chat contracts.
      expect(nvidia.effectiveThinkingPolicyId, 'nim_thinking');
      expect(custom.effectiveThinkingPolicyId, 'unknown');
    });
  });

  group('Ollama thinking policy', () {
    const policy = OllamaLiveThinkingPolicy();
    const gemma4Metadata = {
      OllamaThinkingProbe.capabilitiesMetadataKey: [
        'completion',
        'vision',
        'audio',
        'tools',
        'thinking',
      ],
      OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
        'values': [false, true],
        'default': true,
      },
    };
    const levelMetadata = {
      OllamaThinkingProbe.capabilitiesMetadataKey: ['completion', 'thinking'],
      OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
        'values': ['low', 'medium', 'high'],
        'default': 'medium',
      },
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

    test(
      'returns unsupported when thinking capability is absent from capabilities',
      () {
        const context = ThinkingPolicyContext(
          providerInstanceId: 'instance-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'llama3:latest',
          capabilityRevision: 'rev-1',
          modelMetadata: {
            OllamaThinkingProbe.capabilitiesMetadataKey: [
              'completion',
              'tools',
            ],
          },
        );

        final descriptor = policy.resolveCapability(context);
        expect(descriptor.status, ThinkingCapabilityStatus.unsupported);
        expect(descriptor.source, 'live');
      },
    );

    test(
      'returns unknown when capabilities has thinking but declaration is absent or malformed',
      () {
        const context = ThinkingPolicyContext(
          providerInstanceId: 'instance-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'custom-local-model',
          capabilityRevision: 'rev-1',
          modelMetadata: {
            OllamaThinkingProbe.capabilitiesMetadataKey: [
              'completion',
              'thinking',
            ],
          },
        );

        final descriptor = policy.resolveCapability(context);
        expect(descriptor.status, ThinkingCapabilityStatus.unknown);
        expect(descriptor.source, 'live');
      },
    );

    test(
      'advertises boolean toggle and default-on for gemma4:e2b fixture without fake levels',
      () {
        const context = ThinkingPolicyContext(
          providerInstanceId: 'instance-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'gemma4:e2b',
          capabilityRevision: 'rev-1',
          modelMetadata: gemma4Metadata,
        );

        final descriptor = policy.resolveCapability(context);
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.kind, ThinkingControlKind.toggle);
        expect(descriptor.source, 'live');
        expect(descriptor.defaultOptionId, 'on');
        expect(descriptor.options.map((option) => option.id), ['off', 'on']);
        expect(
          descriptor.options.firstWhere((o) => o.id == 'on').isProviderDefault,
          isTrue,
        );
        expect(
          descriptor.options.firstWhere((o) => o.id == 'off').isOff,
          isTrue,
        );

        expect(
          policy.resolveDirective(context, null),
          isA<UseProviderDefault>(),
        );
        expect(
          policy.resolveDirective(context, 'on'),
          isA<ThinkingToggleDirective>(),
        );
        expect(
          (policy.resolveDirective(context, 'on') as ThinkingToggleDirective)
              .enabled,
          isTrue,
        );
        expect(
          policy.resolveDirective(context, 'off'),
          isA<ThinkingToggleDirective>(),
        );
        expect(
          (policy.resolveDirective(context, 'off') as ThinkingToggleDirective)
              .enabled,
          isFalse,
        );
      },
    );

    test(
      'advertises exact level options and default for native level model fixture',
      () {
        const context = ThinkingPolicyContext(
          providerInstanceId: 'instance-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'deepseek-r1:8b',
          capabilityRevision: 'rev-1',
          modelMetadata: levelMetadata,
        );

        final descriptor = policy.resolveCapability(context);
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.kind, ThinkingControlKind.effort);
        expect(descriptor.source, 'live');
        expect(descriptor.defaultOptionId, 'medium');
        expect(descriptor.options.map((option) => option.id), [
          'low',
          'medium',
          'high',
        ]);
        expect(
          descriptor.options
              .firstWhere((o) => o.id == 'medium')
              .isProviderDefault,
          isTrue,
        );

        expect(
          policy.resolveDirective(context, null),
          isA<UseProviderDefault>(),
        );
        expect(
          policy.resolveDirective(context, 'medium'),
          isA<OllamaThinkLevelDirective>(),
        );
        expect(
          (policy.resolveDirective(context, 'medium')
                  as OllamaThinkLevelDirective)
              .level,
          'medium',
        );
        expect(
          policy.resolveDirective(context, 'high'),
          isA<OllamaThinkLevelDirective>(),
        );
        expect(
          (policy.resolveDirective(context, 'high')
                  as OllamaThinkLevelDirective)
              .level,
          'high',
        );
      },
    );

    test(
      'no loose model-name heuristics: gpt-oss model without thinking declaration returns unknown',
      () {
        const context = ThinkingPolicyContext(
          providerInstanceId: 'instance-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'gpt-oss:20b',
          capabilityRevision: 'rev-1',
          modelMetadata: {
            OllamaThinkingProbe.capabilitiesMetadataKey: [
              'completion',
              'thinking',
            ],
          },
        );

        final descriptor = policy.resolveCapability(context);
        expect(descriptor.status, ThinkingCapabilityStatus.unknown);
      },
    );
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

    test('disables reasoning with the documented effort-none envelope', () {
      // The official OpenRouter guide documents `reasoning.effort: "none"` as
      // disabling reasoning and never an explicitly enabled zero budget.
      final googleOffBody = <String, dynamic>{
        'model': 'google/gemini-2.5-flash',
      };
      AggregatorThinkingWireCodec.applyReasoning(
        googleOffBody,
        const GoogleBudgetDirective(0),
      );
      expect(googleOffBody['reasoning'], {'effort': 'none'});
      expect(
        (googleOffBody['reasoning'] as Map).containsKey('enabled'),
        isFalse,
      );
      expect(
        (googleOffBody['reasoning'] as Map).containsKey('max_tokens'),
        isFalse,
      );

      final effortNoneBody = <String, dynamic>{'model': 'openai/gpt-5.6-sol'};
      AggregatorThinkingWireCodec.applyReasoning(
        effortNoneBody,
        const OpenAiEffortDirective('none'),
      );
      expect(effortNoneBody['reasoning'], {'effort': 'none'});
      expect(
        (effortNoneBody['reasoning'] as Map).containsKey('enabled'),
        isFalse,
        reason: 'a documented effort-none disable must not stay enabled',
      );

      final toggleOffBody = <String, dynamic>{'model': 'kimi/kimi-k2.6'};
      AggregatorThinkingWireCodec.applyReasoning(
        toggleOffBody,
        const ThinkingToggleDirective(enabled: false),
      );
      expect(toggleOffBody['reasoning'], {'effort': 'none'});
    });

    test('rejects a non-admitted directive before dispatch', () {
      // Only canonical admitted values may be serialized. A non-admitted
      // effort, alias string, casing/whitespace variant, negative budget or
      // non-admitted Google level fails actionably at body build time instead
      // of being silently omitted or remapped onto another value.
      for (final value in ['off', 'false', 'disabled', 'NONE', ' none ', '']) {
        expect(
          () => AggregatorThinkingWireCodec.applyReasoning(<String, dynamic>{
            'model': 'openai/o3-mini',
          }, OpenAiEffortDirective(value)),
          throwsA(isA<ThinkingWireSerializationException>()),
          reason: 'non-admitted effort "$value" must be rejected',
        );
      }

      for (final budget in [-1, -8192]) {
        expect(
          () => AggregatorThinkingWireCodec.applyReasoning(<String, dynamic>{
            'model': 'google/gemini-2.5-flash',
          }, GoogleBudgetDirective(budget)),
          throwsA(isA<ThinkingWireSerializationException>()),
          reason: 'non-admitted budget $budget must be rejected',
        );
      }

      // `off` is not an admitted native Google level.
      expect(
        () => AggregatorThinkingWireCodec.applyReasoning(<String, dynamic>{
          'model': 'google/gemini-3.6-flash',
        }, const GoogleLevelDirective('off')),
        throwsA(isA<ThinkingWireSerializationException>()),
      );

      // A non-positive Anthropic budget is not an admitted budget control.
      expect(
        () => AggregatorThinkingWireCodec.applyReasoning(<String, dynamic>{
          'model': 'anthropic/claude-3.7-sonnet',
        }, const AnthropicBudgetDirective(0)),
        throwsA(isA<ThinkingWireSerializationException>()),
      );

      // A directive the envelope cannot carry is rejected, not dropped.
      expect(
        () => AggregatorThinkingWireCodec.applyReasoning(<String, dynamic>{
          'model': 'openai/o3-mini',
        }, const ResponsesReasoningDirective(effort: 'high')),
        throwsA(isA<ThinkingWireSerializationException>()),
      );
    });

    test(
      'keeps every admitted positive tier and default omission unchanged',
      () {
        const positiveEfforts = [
          'minimal',
          'low',
          'medium',
          'high',
          'xhigh',
          'max',
        ];
        for (final effort in positiveEfforts) {
          final body = <String, dynamic>{'model': 'openai/o3-mini'};
          AggregatorThinkingWireCodec.applyReasoning(
            body,
            OpenAiEffortDirective(effort),
          );
          expect(body['reasoning'], {'enabled': true, 'effort': effort});
        }
        for (final level in ['minimal', 'low', 'medium', 'high']) {
          final body = <String, dynamic>{'model': 'google/gemini-3.6-flash'};
          AggregatorThinkingWireCodec.applyReasoning(
            body,
            GoogleLevelDirective(level),
          );
          expect(body['reasoning'], {'enabled': true, 'effort': level});
        }
        for (final budget in [1024, 8192, 24576]) {
          final body = <String, dynamic>{'model': 'google/gemini-2.5-flash'};
          AggregatorThinkingWireCodec.applyReasoning(
            body,
            GoogleBudgetDirective(budget),
          );
          expect(body['reasoning'], {'enabled': true, 'max_tokens': budget});
        }
        final defaultBody = <String, dynamic>{'model': 'openai/o3-mini'};
        AggregatorThinkingWireCodec.applyReasoning(
          defaultBody,
          const UseProviderDefault(),
        );
        expect(defaultBody.containsKey('reasoning'), isFalse);
      },
    );

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

    test(
      'maps adaptive directive to adaptive thinking and output_config.effort',
      () {
        final body = <String, dynamic>{'model': 'claude-opus-4-7'};
        AnthropicThinkingWireCodec.applyThinking(
          body,
          const AnthropicAdaptiveDirective('medium'),
        );

        expect(body['thinking'], {'type': 'adaptive'});
        expect(body['output_config'], {'effort': 'medium'});
      },
    );

    test('maps explicit off to disabled thinking', () {
      final body = <String, dynamic>{'model': 'claude-sonnet-5'};
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const ThinkingToggleDirective(enabled: false),
      );

      expect(body['thinking'], {'type': 'disabled'});
    });

    test('rejects an explicit budget the request max_tokens cannot honour', () {
      final body = <String, dynamic>{
        'model': 'claude-sonnet-4-5',
        'max_tokens': 4096,
      };

      expect(
        () => AnthropicThinkingWireCodec.applyThinking(
          body,
          const AnthropicBudgetDirective(16384),
        ),
        throwsA(isA<ThinkingWireSerializationException>()),
      );
      // The request fails before dispatch instead of shipping a smaller
      // budget than the one the user selected.
      expect(body.containsKey('thinking'), isFalse);
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

      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 8192});
    });

    test('emits the largest budget that still fits below max_tokens', () {
      final body = <String, dynamic>{
        'model': 'claude-sonnet-4-5',
        'max_tokens': 8192,
      };
      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicBudgetDirective(8191),
      );

      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 8191});

      expect(
        () => AnthropicThinkingWireCodec.applyThinking(
          <String, dynamic>{'model': 'claude-sonnet-4-5', 'max_tokens': 8192},
          const AnthropicBudgetDirective(8192),
        ),
        throwsA(isA<ThinkingWireSerializationException>()),
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
    test(
      'supported test policy resolves typed directives without raw maps',
      () {
        final policy = _TestEffortThinkingPolicy();
        final context = const ThinkingPolicyContext(
          providerInstanceId: 'instance-1',
          templateId: 'openai',
          protocol: 'openai_compatible',
          apiMode: 'chat_completions',
          modelId: 'gpt-test',
        );

        final descriptor = policy.resolveCapability(context);
        expect(descriptor.options.map((option) => option.id), [
          'low',
          'medium',
          'high',
        ]);
        expect(
          policy.resolveDirective(context, 'medium'),
          isA<OpenAiEffortDirective>(),
        );
        expect(
          policy.resolveDirective(context, null),
          isA<UseProviderDefault>(),
        );
      },
    );
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
