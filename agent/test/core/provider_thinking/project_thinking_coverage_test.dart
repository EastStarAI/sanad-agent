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
import 'package:sanad_agent/core/provider_thinking/aggregator_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/google_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/kimi_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/openai_thinking_wire_codec.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/toggle_effort_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/unknown_thinking_policy.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

void main() {
  group('Project-wide Registry-Derived Thinking Coverage', () {
    late Directory tempHome;
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late ThinkingCapabilityAssembler assembler;
    late ThinkingSelectionResolver resolver;
    late Config isolatedConfig;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('sanad_coverage_test_home_');
      setSanadHomeOverride(tempHome.path);

      // Write distinctive disposable config fixture to prove Config loaded from this test-owned Home
      final fixtureConfigFile = File(p.join(tempHome.path, 'config.yaml'));
      fixtureConfigFile.writeAsStringSync('''
model_capabilities:
  disposable-fixture-marker:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        high: high
''');

      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      if (getIt.isRegistered<ProviderInstanceRepository>()) {
        getIt.unregister<ProviderInstanceRepository>();
      }
      getIt.registerSingleton<ProviderInstanceRepository>(repo);

      isolatedConfig = Config(environment: {'SANAD_HOME': tempHome.path});

      // Assert that Home is truly isolated and distinctive fixture loaded
      expect(getSanadHome(), tempHome.path);
      expect(
        isolatedConfig.modelAwarePolicy.capabilityOverrideFor('disposable-fixture-marker'),
        isNotNull,
        reason: 'Config must load from the disposable test Home and never the real user Home',
      );

      final registry = buildProviderThinkingRegistry();
      assembler = ThinkingCapabilityAssembler(registry, isolatedConfig);
      resolver = ThinkingSelectionResolver(
        instances: repo,
        cacheResolver: ThinkingControlCacheResolver(repo),
        assembler: assembler,
        registry: registry,
        config: isolatedConfig,
      );
    });

    tearDown(() {
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
    });

    test('shipped template policy mapping covers every registered template without omission', () {
      final registeredTemplateNames =
          ProviderRegistry.profiles.map((p) => p.name).toSet();
      final expectedMapping = <String, String>{
        'openai-codex': 'codex_responses_effort',
        'kimi': 'kimi_thinking',
        'anthropic': 'anthropic_thinking',
        'nvidia': 'unknown',
        'openai': 'openai_chat_effort',
        'openrouter': 'aggregator_upstream',
        'gemini': 'google_thinking',
        'deepseek': 'deepseek_thinking',
        'opencode-go': 'openai_chat_effort',
        'ollama': 'ollama_live',
        'lm-studio': 'unknown',
        'llama-cpp': 'unknown',
        'xai': 'unknown',
        'zai': 'unknown',
        'zai-coding': 'unknown',
        kCustomProviderTemplateId: 'unknown',
      };

      expect(
        expectedMapping.keys.toSet(),
        equals(registeredTemplateNames),
        reason:
            'The coverage mapping keys must dynamically match all registered template names in ProviderRegistry.profiles',
      );

      for (final profile in ProviderRegistry.profiles) {
        final expectedPolicyId = expectedMapping[profile.name];
        expect(
          expectedPolicyId,
          isNotNull,
          reason: 'Template ${profile.name} must be accounted for in coverage mapping',
        );
        expect(
          profile.effectiveThinkingPolicyId,
          expectedPolicyId,
          reason: 'Template ${profile.name} must have effective policy $expectedPolicyId',
        );
      }
    });

    test('ProviderThinkingRegistry registers all foundational policies', () {
      final registry = buildProviderThinkingRegistry();
      expect(registry.resolveForTemplate(thinkingPolicyId: 'unknown'), isA<UnknownThinkingPolicy>());
      expect(registry.resolveForTemplate(thinkingPolicyId: 'openai_chat_effort').policyId, 'openai_chat_effort');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'codex_responses_effort').policyId, 'codex_responses_effort');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'anthropic_thinking').policyId, 'anthropic_thinking');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'aggregator_upstream').policyId, 'aggregator_upstream');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'google_thinking').policyId, 'google_thinking');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'deepseek_thinking').policyId, 'deepseek_thinking');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'ollama_live').policyId, 'ollama_live');
      expect(registry.resolveForTemplate(thinkingPolicyId: 'kimi_thinking').policyId, 'kimi_thinking');
      expect(registry.registeredPolicyIds.toSet(), containsAll(reservedThinkingPolicyIds));
    });

    group('Validated Model-Only Finite Declarations & Wire Codecs', () {
      test('openai-codex: o1 finite declaration, effort directive, wire serialization', () {
        final inst = ProviderInstance(
          id: 'inst-codex',
          templateId: 'openai-codex',
          displayName: 'ChatGPT Plus',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.deviceCode,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // 1. Supported finite model o1
        final resO1 = resolver.resolve(
          providerInstanceId: 'inst-codex',
          modelId: 'o1',
          selectionId: 'high',
        );
        expect(resO1.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resO1.descriptor.kind, ThinkingControlKind.effort);
        expect(resO1.directive, isA<ResponsesReasoningDirective>());
        expect((resO1.directive as ResponsesReasoningDirective).effort, 'high');

        final wireBody = <String, dynamic>{};
        final reasoning = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyResponsesReasoning(reasoning, resO1.directive);
        if (reasoning.isNotEmpty) wireBody['reasoning'] = reasoning;
        expect(wireBody['reasoning'], {'effort': 'high', 'summary': 'auto'});

        // 2. Default omission
        final resOmit = resolver.resolve(
          providerInstanceId: 'inst-codex',
          modelId: 'o1',
          selectionId: null,
        );
        expect(resOmit.directive, isA<UseProviderDefault>());
        final defaultReasoning = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyResponsesReasoning(defaultReasoning, resOmit.directive);
        expect(defaultReasoning.containsKey('effort'), isFalse);

        // 3. Unsupported model gpt-4o
        final descGpt4 = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'gpt-4o', label: 'GPT-4o'),
        );
        expect(descGpt4.status, ThinkingCapabilityStatus.unsupported);
      });

      test('anthropic: claude-3-7-sonnet token budget, claude-opus-4-7 adaptive, claude-3-5 unsupported', () {
        final inst = ProviderInstance(
          id: 'inst-anthropic',
          templateId: 'anthropic',
          displayName: 'Anthropic Claude',
          protocol: ProviderProtocol.anthropicCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // 1. Manual budget on claude-3-7-sonnet
        final resSonnet = resolver.resolve(
          providerInstanceId: 'inst-anthropic',
          modelId: 'claude-3-7-sonnet',
          selectionId: 'high',
        );
        expect(resSonnet.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resSonnet.descriptor.kind, ThinkingControlKind.tokenBudget);
        expect(resSonnet.directive, isA<AnthropicBudgetDirective>());
        expect((resSonnet.directive as AnthropicBudgetDirective).budgetTokens, 16384);

        final budgetBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(budgetBody, resSonnet.directive);
        expect(budgetBody['thinking'], {'type': 'enabled', 'budget_tokens': 16384});

        // 2. Adaptive effort on claude-opus-4-7
        final resAdaptive = resolver.resolve(
          providerInstanceId: 'inst-anthropic',
          modelId: 'claude-opus-4-7',
          selectionId: 'high',
        );
        expect(resAdaptive.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resAdaptive.descriptor.kind, ThinkingControlKind.adaptive);
        expect(resAdaptive.directive, isA<AnthropicAdaptiveDirective>());

        final adaptiveBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(adaptiveBody, resAdaptive.directive);
        expect(adaptiveBody['thinking'], {'type': 'adaptive'});
        expect(adaptiveBody['output_config'], {'effort': 'high'});

        // 3. Omission
        final resOmit = resolver.resolve(
          providerInstanceId: 'inst-anthropic',
          modelId: 'claude-3-7-sonnet',
          selectionId: null,
        );
        expect(resOmit.directive, isA<UseProviderDefault>());
        final omitBody = <String, dynamic>{};
        AnthropicThinkingWireCodec.applyThinking(omitBody, resOmit.directive);
        expect(omitBody.containsKey('thinking'), isFalse);

        // 4. Claude 3 Haiku is unsupported for thinking in Anthropic
        final descClaudeHaiku = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'claude-3-haiku', label: 'Claude 3 Haiku'),
        );
        expect(descClaudeHaiku.status, ThinkingCapabilityStatus.unsupported);
      });

      test('openai: o3-mini effort directive, wire serialization, gpt-4o unsupported', () {
        final inst = ProviderInstance(
          id: 'inst-openai',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        final resO3 = resolver.resolve(
          providerInstanceId: 'inst-openai',
          modelId: 'o3-mini',
          selectionId: 'high',
        );
        expect(resO3.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resO3.descriptor.kind, ThinkingControlKind.effort);
        expect(resO3.directive, isA<OpenAiEffortDirective>());
        expect((resO3.directive as OpenAiEffortDirective).effort, 'high');

        final openAiBody = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyChatCompletionsReasoning(openAiBody, resO3.directive);
        expect(openAiBody['reasoning_effort'], 'high');

        // Omission
        final resOmit = resolver.resolve(
          providerInstanceId: 'inst-openai',
          modelId: 'o3-mini',
          selectionId: null,
        );
        expect(resOmit.directive, isA<UseProviderDefault>());
        final omitBody = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyChatCompletionsReasoning(omitBody, resOmit.directive);
        expect(omitBody.containsKey('reasoning_effort'), isFalse);

        // gpt-4o unsupported
        final descGpt4 = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'gpt-4o', label: 'GPT-4o'),
        );
        expect(descGpt4.status, ThinkingCapabilityStatus.unsupported);
      });

      test('openrouter: aggregator upstream prefix delegation and serialization', () {
        final inst = ProviderInstance(
          id: 'inst-openrouter',
          templateId: 'openrouter',
          displayName: 'OpenRouter',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // OpenAI upstream prefix
        final resOpenAi = resolver.resolve(
          providerInstanceId: 'inst-openrouter',
          modelId: 'openai/o3-mini',
          selectionId: 'low',
        );
        expect(resOpenAi.descriptor.status, ThinkingCapabilityStatus.supported);
        final orBody = <String, dynamic>{};
        AggregatorThinkingWireCodec.applyReasoning(orBody, resOpenAi.directive);
        expect(orBody['reasoning'], {'enabled': true, 'effort': 'low'});

        // Unsupported vendor prefix
        final descLlama = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'meta-llama/llama-3', label: 'Llama 3'),
        );
        expect(descLlama.status, ThinkingCapabilityStatus.unsupported);
      });

      test('gemini: gemini-2.5-flash budget, gemini-3 level, gemini-1.5 unsupported', () {
        final inst = ProviderInstance(
          id: 'inst-gemini',
          templateId: 'gemini',
          displayName: 'Google Gemini',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // 1. Budget on gemini-2.5-flash
        final resBudget = resolver.resolve(
          providerInstanceId: 'inst-gemini',
          modelId: 'gemini-2.5-flash',
          selectionId: 'high',
        );
        expect(resBudget.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resBudget.descriptor.kind, ThinkingControlKind.tokenBudget);
        final budgetBody = <String, dynamic>{};
        GoogleThinkingWireCodec.applyThinkingConfig(budgetBody, resBudget.directive);
        expect(budgetBody['extra_body']['google']['thinking_config']['thinking_budget'], 24576);

        // 2. Level on gemini-3-pro-preview
        final resLevel = resolver.resolve(
          providerInstanceId: 'inst-gemini',
          modelId: 'gemini-3-pro-preview',
          selectionId: 'medium',
        );
        expect(resLevel.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resLevel.descriptor.kind, ThinkingControlKind.level);
        final levelBody = <String, dynamic>{};
        GoogleThinkingWireCodec.applyThinkingConfig(levelBody, resLevel.directive);
        expect(levelBody['extra_body']['google']['thinking_config']['thinking_level'], 'medium');

        // 3. Gemini 1.5 is unsupported
        final descGemini15 = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'gemini-1.5-pro', label: 'Gemini 1.5 Pro'),
        );
        expect(descGemini15.status, ThinkingCapabilityStatus.unsupported);
      });

      test('deepseek: deepseek-chat toggle supported, deepseek-reasoner unsupported for runtime toggle', () {
        final inst = ProviderInstance(
          id: 'inst-deepseek',
          templateId: 'deepseek',
          displayName: 'DeepSeek',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // Toggle on deepseek-chat
        final resChat = resolver.resolve(
          providerInstanceId: 'inst-deepseek',
          modelId: 'deepseek-chat',
          selectionId: 'off',
        );
        expect(resChat.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resChat.descriptor.kind, ThinkingControlKind.toggle);
        final toggleBody = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(toggleBody, resChat.directive);
        expect(toggleBody['thinking'], {'type': 'disabled'});

        // deepseek-reasoner has intrinsic reasoning, runtime toggle unsupported
        final descReasoner = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'deepseek-reasoner', label: 'DeepSeek Reasoner'),
        );
        expect(descReasoner.status, ThinkingCapabilityStatus.unsupported);
      });

      test('opencode-go: recognized reasoning models resolve effort; non-reasoning unsupported', () {
        final inst = ProviderInstance(
          id: 'inst-opencode-go',
          templateId: 'opencode-go',
          displayName: 'OpenCode Go',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        final resDeepseek = resolver.resolve(
          providerInstanceId: 'inst-opencode-go',
          modelId: 'deepseek-v4-flash',
          selectionId: 'low',
        );
        expect(resDeepseek.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resDeepseek.descriptor.kind, ThinkingControlKind.effort);
        final opencodeBody = <String, dynamic>{};
        OpenAiThinkingWireCodec.applyChatCompletionsReasoning(opencodeBody, resDeepseek.directive);
        expect(opencodeBody['reasoning_effort'], 'low');

        // Kimi K2.7 Code has always-on thinking and resolves unsupported on opencode-go
        final descKimiK27 = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'kimi-k2.7-code', label: 'Kimi K2.7 Code'),
        );
        expect(descKimiK27.status, ThinkingCapabilityStatus.unsupported);

        // Kimi K3 on opencode-go resolves exact Kimi effort options (low, high, max; no medium/xhigh)
        final resKimiK3 = resolver.resolve(
          providerInstanceId: 'inst-opencode-go',
          modelId: 'kimi-k3',
          selectionId: 'max',
        );
        expect(resKimiK3.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resKimiK3.descriptor.kind, ThinkingControlKind.effort);
        expect(resKimiK3.descriptor.options.map((o) => o.id), ['low', 'high', 'max']);
        expect((resKimiK3.directive as OpenAiEffortDirective).effort, 'max');

        // Kimi K2.6 on opencode-go resolves exact toggle (on, off; not effort)
        final resKimiK26 = resolver.resolve(
          providerInstanceId: 'inst-opencode-go',
          modelId: 'kimi-k2.6',
          selectionId: 'on',
        );
        expect(resKimiK26.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resKimiK26.descriptor.kind, ThinkingControlKind.toggle);
        expect(resKimiK26.descriptor.options.map((o) => o.id), ['on', 'off']);

        final descPlain = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'plain-coder', label: 'Plain Coder'),
        );
        expect(descPlain.status, ThinkingCapabilityStatus.unsupported);
      });

      test('kimi: kimi-k3 effort directive, kimi-k2.6 toggle, kimi-k2.7-code unsupported', () {
        final inst = ProviderInstance(
          id: 'inst-kimi',
          templateId: 'kimi',
          displayName: 'Kimi Moonshot',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        // 1. kimi-k3 supports effort (low, high, max; default max, no off)
        final resK3 = resolver.resolve(
          providerInstanceId: 'inst-kimi',
          modelId: 'kimi-k3',
          selectionId: 'high',
        );
        expect(resK3.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resK3.descriptor.kind, ThinkingControlKind.effort);
        expect(resK3.descriptor.defaultOptionId, 'max');
        expect(resK3.descriptor.options.map((o) => o.id), ['low', 'high', 'max']);
        expect(resK3.descriptor.options.any((o) => o.isOff), isFalse);
        expect(resK3.directive, isA<OpenAiEffortDirective>());
        expect((resK3.directive as OpenAiEffortDirective).effort, 'high');

        final wireBodyK3 = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(wireBodyK3, resK3.directive);
        expect(wireBodyK3['reasoning_effort'], 'high');
        expect(wireBodyK3.containsKey('thinking'), isFalse);

        // Default omission on kimi-k3
        final resK3Omit = resolver.resolve(
          providerInstanceId: 'inst-kimi',
          modelId: 'kimi-k3',
          selectionId: null,
        );
        expect(resK3Omit.directive, isA<UseProviderDefault>());
        final wireBodyK3Omit = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(wireBodyK3Omit, resK3Omit.directive);
        expect(wireBodyK3Omit.containsKey('reasoning_effort'), isFalse);
        expect(wireBodyK3Omit.containsKey('thinking'), isFalse);

        // Invalid selection 'off' or 'medium' on kimi-k3 throws optionUnavailable
        expect(
          () => resolver.resolve(
            providerInstanceId: 'inst-kimi',
            modelId: 'kimi-k3',
            selectionId: 'off',
          ),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.optionUnavailable,
            ),
          ),
        );
        expect(
          () => resolver.resolve(
            providerInstanceId: 'inst-kimi',
            modelId: 'kimi-k3',
            selectionId: 'medium',
          ),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.optionUnavailable,
            ),
          ),
        );

        // 2. kimi-k2.6 supports toggle (on, off; default on)
        final resK26On = resolver.resolve(
          providerInstanceId: 'inst-kimi',
          modelId: 'kimi-k2.6',
          selectionId: 'on',
        );
        expect(resK26On.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(resK26On.descriptor.kind, ThinkingControlKind.toggle);
        expect(resK26On.descriptor.defaultOptionId, 'on');
        expect(resK26On.descriptor.options.map((o) => o.id), ['on', 'off']);
        expect(resK26On.directive, isA<ThinkingToggleDirective>());
        expect((resK26On.directive as ThinkingToggleDirective).enabled, isTrue);

        final wireBodyK26On = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(wireBodyK26On, resK26On.directive);
        expect(wireBodyK26On['thinking'], {'type': 'enabled'});
        expect(wireBodyK26On.containsKey('reasoning_effort'), isFalse);

        final resK26Off = resolver.resolve(
          providerInstanceId: 'inst-kimi',
          modelId: 'kimi-k2.6',
          selectionId: 'off',
        );
        expect(resK26Off.directive, isA<ThinkingToggleDirective>());
        expect((resK26Off.directive as ThinkingToggleDirective).enabled, isFalse);

        final wireBodyK26Off = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(wireBodyK26Off, resK26Off.directive);
        expect(wireBodyK26Off['thinking'], {'type': 'disabled'});
        expect(wireBodyK26Off.containsKey('reasoning_effort'), isFalse);

        // Default omission on kimi-k2.6
        final resK26Omit = resolver.resolve(
          providerInstanceId: 'inst-kimi',
          modelId: 'kimi-k2.6',
          selectionId: null,
        );
        expect(resK26Omit.directive, isA<UseProviderDefault>());
        final wireBodyK26Omit = <String, dynamic>{};
        ToggleEffortThinkingWireCodec.applyChatCompletions(wireBodyK26Omit, resK26Omit.directive);
        expect(wireBodyK26Omit.containsKey('thinking'), isFalse);
        expect(wireBodyK26Omit.containsKey('reasoning_effort'), isFalse);

        // Invalid selection 'high' on kimi-k2.6 throws optionUnavailable
        expect(
          () => resolver.resolve(
            providerInstanceId: 'inst-kimi',
            modelId: 'kimi-k2.6',
            selectionId: 'high',
          ),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.optionUnavailable,
            ),
          ),
        );

        // 3. kimi-k2.7-code is always-on; runtime adjustment unsupported
        final descK27 = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'kimi-k2.7-code', label: 'Kimi K2.7 Code'),
        );
        expect(descK27.status, ThinkingCapabilityStatus.unsupported);

        final descK27Highspeed = assembler.assemble(
          instance: inst,
          model: ModelOption(
            value: 'kimi-k2.7-code-highspeed',
            label: 'Kimi K2.7 Code Highspeed',
          ),
        );
        expect(descK27Highspeed.status, ThinkingCapabilityStatus.unsupported);

        // 4. Legacy Moonshot models are unsupported
        final descMoonshot8k = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'moonshot-v1-8k', label: 'Moonshot v1 8K'),
        );
        expect(descMoonshot8k.status, ThinkingCapabilityStatus.unsupported);

        // 5. Unknown Kimi model fails closed to unknown
        final descUnknown = assembler.assemble(
          instance: inst,
          model: ModelOption(value: 'kimi-k2.5', label: 'Kimi K2.5'),
        );
        expect(descUnknown.status, ThinkingCapabilityStatus.unknown);
      });

      test('kimi model recognition exactness and negative assertions', () {
        // Assert exact evidenced IDs are recognized
        expect(KimiThinkingPolicy.isEvidencedModel('kimi-k3'), isTrue);
        expect(KimiThinkingPolicy.isEvidencedModel('kimi-k2.6'), isTrue);
        expect(KimiThinkingPolicy.isEvidencedModel('kimi-k2.7-code'), isTrue);
        expect(KimiThinkingPolicy.isEvidencedModel('kimi-k2.7-code-highspeed'), isTrue);
        expect(KimiThinkingPolicy.isEvidencedModel('moonshot-v1-8k'), isTrue);
        expect(KimiThinkingPolicy.isEvidencedModel('moonshot-v1-32k'), isTrue);
        expect(KimiThinkingPolicy.isEvidencedModel('moonshot-v1-128k'), isTrue);

        // Required negative assertions: cannot gain copied control declarations
        final negatives = [
          'KIMI-K3',
          'unknown-vendor/kimi-k3',
          'moonshotai/kimi-k3',
          'moonshotai/kimi-k2.6',
          'moonshotai/kimi-k2.7-code',
          'moonshotai/kimi-k2.7-code-highspeed',
          'kimi-k3-custom',
          'unknown/moonshot-v1-8k',
          'kimi-k2.5',
          'moonshot-v1-fake',
        ];

        for (final neg in negatives) {
          expect(
            KimiThinkingPolicy.isEvidencedModel(neg),
            isFalse,
            reason: '$neg must NOT match exact evidenced Kimi model knowledge',
          );
          expect(
            KimiThinkingPolicy.thinkingKindForModel(neg),
            KimiRouteThinkingKind.unknown,
            reason: '$neg must resolve to unknown kind',
          );
        }

        final inst = ProviderInstance(
          id: 'inst-kimi-negatives',
          templateId: 'kimi',
          displayName: 'Kimi Moonshot',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(inst);

        for (final neg in negatives) {
          final assembled = assembler.assemble(
            instance: inst,
            model: ModelOption(value: neg, label: neg),
          );
          expect(
            assembled.status,
            ThinkingCapabilityStatus.unknown,
            reason: '$neg must assemble to unknown status',
          );
          expect(
            () => resolver.resolve(
              providerInstanceId: 'inst-kimi-negatives',
              modelId: neg,
              selectionId: 'high',
            ),
            throwsA(
              isA<ThinkingSelectionException>().having(
                (e) => e.code,
                'code',
                ThinkingSelectionErrorCode.capabilityUnknown,
              ),
            ),
            reason: '$neg must reject selection with capabilityUnknown',
          );
        }
      });

      test('model-only resolution across representative templates (kimi, custom, nvidia, openai, opencode-go, gemini, openrouter); persists across rename and recreate; mode-incompatible rejection', () {
        // 1. Evidence resolves identically across representative templates
        final instances = <String, ProviderInstance>{
          'kimi': ProviderInstance(
            id: 'inst-multi-kimi',
            templateId: 'kimi',
            displayName: 'Kimi Dedicated',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          'custom': ProviderInstance(
            id: 'inst-multi-custom',
            templateId: kCustomProviderTemplateId,
            displayName: 'Custom OpenAI-Compatible',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          'nvidia': ProviderInstance(
            id: 'inst-multi-nvidia',
            templateId: 'nvidia',
            displayName: 'NVIDIA NIM Endpoint',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          'openai': ProviderInstance(
            id: 'inst-multi-openai',
            templateId: 'openai',
            displayName: 'OpenAI Endpoint',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          'opencode-go': ProviderInstance(
            id: 'inst-multi-opencode-go',
            templateId: 'opencode-go',
            displayName: 'OpenCode Go Endpoint',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          'gemini': ProviderInstance(
            id: 'inst-multi-gemini',
            templateId: 'gemini',
            displayName: 'Google Gemini Endpoint',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          'openrouter': ProviderInstance(
            id: 'inst-multi-openrouter',
            templateId: 'openrouter',
            displayName: 'OpenRouter Gateway',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        };

        for (final entry in instances.entries) {
          repo.createInstance(entry.value);

          // 1. kimi-k3 resolves to effort (low, high, max; default max)
          final resK3 = resolver.resolve(
            providerInstanceId: entry.value.id,
            modelId: 'kimi-k3',
            selectionId: 'high',
          );
          expect(
            resK3.descriptor.status,
            ThinkingCapabilityStatus.supported,
            reason: '${entry.key} must resolve kimi-k3 to supported',
          );
          expect(resK3.descriptor.kind, ThinkingControlKind.effort);
          expect(
            resK3.descriptor.options.map((o) => o.id),
            ['low', 'high', 'max'],
            reason: '${entry.key} must expose exact Kimi options low, high, max, never OpenAI effort tiers',
          );
          expect(resK3.descriptor.defaultOptionId, 'max');
          expect(resK3.directive, isA<OpenAiEffortDirective>());
          expect((resK3.directive as OpenAiEffortDirective).effort, 'high');

          final bodyK3 = <String, dynamic>{};
          ToggleEffortThinkingWireCodec.applyChatCompletions(bodyK3, resK3.directive);
          expect(bodyK3['reasoning_effort'], 'high');
          expect(bodyK3.containsKey('thinking'), isFalse);

          // Default omission on kimi-k3
          final resK3Omit = resolver.resolve(
            providerInstanceId: entry.value.id,
            modelId: 'kimi-k3',
            selectionId: null,
          );
          expect(resK3Omit.directive, isA<UseProviderDefault>());
          final bodyK3Omit = <String, dynamic>{};
          ToggleEffortThinkingWireCodec.applyChatCompletions(bodyK3Omit, resK3Omit.directive);
          expect(bodyK3Omit.containsKey('reasoning_effort'), isFalse);
          expect(bodyK3Omit.containsKey('thinking'), isFalse);

          // Rejection of invalid selections on kimi-k3 (medium, xhigh, off)
          for (final invalid in ['medium', 'xhigh', 'off']) {
            expect(
              () => resolver.resolve(
                providerInstanceId: entry.value.id,
                modelId: 'kimi-k3',
                selectionId: invalid,
              ),
              throwsA(
                isA<ThinkingSelectionException>().having(
                  (e) => e.code,
                  'code',
                  ThinkingSelectionErrorCode.optionUnavailable,
                ),
              ),
              reason: '${entry.key} must reject invalid selection $invalid for kimi-k3',
            );
          }

          // 2. kimi-k2.6 resolves to toggle (on, off; default on)
          final resK26 = resolver.resolve(
            providerInstanceId: entry.value.id,
            modelId: 'kimi-k2.6',
            selectionId: 'on',
          );
          expect(
            resK26.descriptor.status,
            ThinkingCapabilityStatus.supported,
            reason: '${entry.key} must resolve kimi-k2.6 to supported',
          );
          expect(resK26.descriptor.kind, ThinkingControlKind.toggle);
          expect(
            resK26.descriptor.options.map((o) => o.id),
            ['on', 'off'],
            reason: '${entry.key} must expose exact Kimi toggle on, off, never effort tiers',
          );
          expect(resK26.descriptor.defaultOptionId, 'on');
          expect(resK26.directive, isA<ThinkingToggleDirective>());
          expect((resK26.directive as ThinkingToggleDirective).enabled, isTrue);

          final bodyK26 = <String, dynamic>{};
          ToggleEffortThinkingWireCodec.applyChatCompletions(bodyK26, resK26.directive);
          expect(bodyK26['thinking'], {'type': 'enabled'});
          expect(bodyK26.containsKey('reasoning_effort'), isFalse);

          // Default omission on kimi-k2.6
          final resK26Omit = resolver.resolve(
            providerInstanceId: entry.value.id,
            modelId: 'kimi-k2.6',
            selectionId: null,
          );
          expect(resK26Omit.directive, isA<UseProviderDefault>());
          final bodyK26Omit = <String, dynamic>{};
          ToggleEffortThinkingWireCodec.applyChatCompletions(bodyK26Omit, resK26Omit.directive);
          expect(bodyK26Omit.containsKey('thinking'), isFalse);
          expect(bodyK26Omit.containsKey('reasoning_effort'), isFalse);

          // Rejection of invalid selections on kimi-k2.6 (high, medium, low, max)
          for (final invalid in ['high', 'medium', 'low', 'max']) {
            expect(
              () => resolver.resolve(
                providerInstanceId: entry.value.id,
                modelId: 'kimi-k2.6',
                selectionId: invalid,
              ),
              throwsA(
                isA<ThinkingSelectionException>().having(
                  (e) => e.code,
                  'code',
                  ThinkingSelectionErrorCode.optionUnavailable,
                ),
              ),
              reason: '${entry.key} must reject invalid selection $invalid for kimi-k2.6',
            );
          }

          // 3. kimi-k2.7-code is always-on; runtime adjustment unsupported
          final descK27 = assembler.assemble(
            instance: entry.value,
            model: ModelOption(value: 'kimi-k2.7-code', label: 'Kimi K2.7 Code'),
          );
          expect(
            descK27.status,
            ThinkingCapabilityStatus.unsupported,
            reason: '${entry.key} must evaluate kimi-k2.7-code as unsupported',
          );
          expect(
            () => resolver.resolve(
              providerInstanceId: entry.value.id,
              modelId: 'kimi-k2.7-code',
              selectionId: 'high',
            ),
            throwsA(
              isA<ThinkingSelectionException>().having(
                (e) => e.code,
                'code',
                ThinkingSelectionErrorCode.capabilityUnsupported,
              ),
            ),
            reason: '${entry.key} must reject selection for kimi-k2.7-code with capabilityUnsupported',
          );
        }

        // 2. Persistence across rename
        final customInst = instances['custom']!;
        final renamedCustom = customInst.copyWith(
          displayName: 'Renamed Custom Chat Route',
          updatedAt: DateTime.now(),
        );
        repo.update(renamedCustom);

        final resRenamed = resolver.resolve(
          providerInstanceId: customInst.id,
          modelId: 'kimi-k3',
          selectionId: 'max',
        );
        expect(resRenamed.descriptor.status, ThinkingCapabilityStatus.supported);
        expect((resRenamed.directive as OpenAiEffortDirective).effort, 'max');

        // 3. Persistence across delete and recreate
        repo.delete(customInst.id);
        final recreatedCustom = ProviderInstance(
          id: 'inst-multi-custom-recreated',
          templateId: kCustomProviderTemplateId,
          displayName: 'Recreated Custom Route',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(recreatedCustom);

        final resRecreated = resolver.resolve(
          providerInstanceId: recreatedCustom.id,
          modelId: 'kimi-k3',
          selectionId: 'low',
        );
        expect(resRecreated.descriptor.status, ThinkingCapabilityStatus.supported);
        expect((resRecreated.directive as OpenAiEffortDirective).effort, 'low');

        // 4. Mode-incompatible routes do not get Chat fields and reject wire serialization
        // A. anthropic_messages route
        final anthropicCustomInst = ProviderInstance(
          id: 'inst-incompatible-anthropic',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom Anthropic Route',
          protocol: ProviderProtocol.anthropicCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(anthropicCustomInst);

        final assembledAnthropic = assembler.assemble(
          instance: anthropicCustomInst,
          model: ModelOption(value: 'kimi-k3', label: 'kimi-k3'),
        );
        expect(
          assembledAnthropic.status,
          ThinkingCapabilityStatus.unknown,
          reason: 'anthropic_messages route must fail closed to unknown for kimi-k3',
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'openai_chat_effort',
            protocol: ProviderProtocol.anthropicCompatible,
            apiMode: 'anthropic_messages',
          ),
          isFalse,
          reason: 'Chat effort wire must be incompatible with anthropic_messages mode',
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'toggle_effort',
            protocol: ProviderProtocol.anthropicCompatible,
            apiMode: 'anthropic_messages',
          ),
          isFalse,
        );

        // B. codex_responses route cannot receive Chat fields or Chat wires
        final codexInst = ProviderInstance(
          id: 'inst-incompatible-codex',
          templateId: 'openai-codex',
          displayName: 'ChatGPT Plus',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.deviceCode,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(codexInst);

        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'toggle_effort',
            protocol: ProviderProtocol.openaiCompatible,
            apiMode: 'codex_responses',
          ),
          isFalse,
          reason: 'Chat toggle_effort wire must be incompatible with codex_responses mode',
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'openai_chat_effort',
            protocol: ProviderProtocol.openaiCompatible,
            apiMode: 'codex_responses',
          ),
          isFalse,
          reason: 'Chat openai_chat_effort wire must be incompatible with codex_responses mode',
        );

        // On codex, kimi-k3 is unsupported (not an OpenAI model and codex is not chat_completions)
        final assembledCodex = assembler.assemble(
          instance: codexInst,
          model: ModelOption(value: 'kimi-k3', label: 'kimi-k3'),
        );
        expect(
          assembledCodex.status,
          ThinkingCapabilityStatus.unsupported,
          reason: 'codex_responses route must evaluate kimi-k3 as unsupported without OpenAI heuristic match',
        );
        expect(
          () => resolver.resolve(
            providerInstanceId: codexInst.id,
            modelId: 'kimi-k3',
            selectionId: 'high',
          ),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.capabilityUnsupported,
            ),
          ),
        );

        // When a real codex reasoning model (o1) is resolved under codex, directive is ResponsesReasoningDirective, never Chat fields
        final resCodex = resolver.resolve(
          providerInstanceId: codexInst.id,
          modelId: 'o1',
          selectionId: 'high',
        );
        expect(resCodex.directive, isA<ResponsesReasoningDirective>());
        expect(resCodex.directive, isNot(isA<OpenAiEffortDirective>()));
        expect(resCodex.directive, isNot(isA<ThinkingToggleDirective>()));
      });

      test('Production BaseOpenAIAdapter HTTP dispatch across representative templates (kimi, openai, opencode-go, gemini, openrouter, nvidia, custom)', () async {
        final dispatchTemplates = <String, ProviderProfile>{
          'kimi': ProviderRegistry.findByNameOrAlias('kimi')!,
          'openai': ProviderRegistry.findByNameOrAlias('openai')!,
          'opencode-go': ProviderRegistry.findByNameOrAlias('opencode-go')!,
          'gemini': ProviderRegistry.findByNameOrAlias('gemini')!,
          'openrouter': ProviderRegistry.findByNameOrAlias('openrouter')!,
          'nvidia': ProviderRegistry.findByNameOrAlias('nvidia')!,
          'custom': const ProviderProfile(
            name: kCustomProviderTemplateId,
            displayName: 'Custom OpenAI-Compatible',
            protocol: ProviderProtocol.openaiCompatible,
            apiMode: 'chat_completions',
          ),
        };

        for (final entry in dispatchTemplates.entries) {
          final templateKey = entry.key;
          final profile = entry.value;

          final inst = ProviderInstance(
            id: 'http-dispatch-$templateKey',
            templateId: profile.name,
            displayName: 'HTTP Test $templateKey',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          repo.createInstance(inst);

          late Map<String, dynamic> capturedBody;
          final mockClient = MockClient((request) async {
            capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'chatcmpl-test',
                'object': 'chat.completion',
                'created': 123456789,
                'model': capturedBody['model'],
                'choices': [
                  {
                    'index': 0,
                    'message': {
                      'role': 'assistant',
                      'content': 'Test response from $templateKey',
                    },
                    'finish_reason': 'stop',
                  }
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          });

          final adapter = BaseOpenAIAdapter(
            isolatedConfig,
            profile,
            client: mockClient,
            providerInstanceId: inst.id,
          );

          // 1. kimi-k3 with selection 'high' -> reasoning_effort: 'high'
          final resK3High = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'kimi-k3',
            selectionId: 'high',
          );
          await adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'Hello')],
            modelOverride: 'kimi-k3',
            options: LLMRequestOptions(
              thinkingDirective: resK3High.directive,
              providerInstanceId: inst.id,
            ),
          );
          expect(capturedBody['model'], 'kimi-k3');
          expect(
            capturedBody['reasoning_effort'],
            'high',
            reason: '$templateKey must serialize kimi-k3 reasoning_effort via mode-owned Chat wire authority',
          );
          expect(
            capturedBody.containsKey('thinking'),
            isFalse,
            reason: '$templateKey must not pollute kimi-k3 body with thinking toggle',
          );
          expect(
            capturedBody.containsKey('thinking_config'),
            isFalse,
            reason: '$templateKey must not pollute kimi-k3 body with Google thinking_config',
          );
          expect(
            capturedBody.containsKey('reasoning'),
            isFalse,
            reason: '$templateKey must not pollute kimi-k3 body with aggregator reasoning map',
          );

          // 2. kimi-k3 with default omission -> clean absence
          final resK3Omit = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'kimi-k3',
            selectionId: null,
          );
          await adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'Hello')],
            modelOverride: 'kimi-k3',
            options: LLMRequestOptions(
              thinkingDirective: resK3Omit.directive,
              providerInstanceId: inst.id,
            ),
          );
          expect(capturedBody['model'], 'kimi-k3');
          expect(
            capturedBody.containsKey('reasoning_effort'),
            isFalse,
            reason: '$templateKey must cleanly omit reasoning_effort for default omission on kimi-k3',
          );
          expect(capturedBody.containsKey('thinking'), isFalse);

          // 3. Pre-dispatch rejection of invalid selections on kimi-k3
          for (final invalid in ['medium', 'xhigh', 'off']) {
            expect(
              () => resolver.resolve(
                providerInstanceId: inst.id,
                modelId: 'kimi-k3',
                selectionId: invalid,
              ),
              throwsA(
                isA<ThinkingSelectionException>().having(
                  (e) => e.code,
                  'code',
                  ThinkingSelectionErrorCode.optionUnavailable,
                ),
              ),
              reason: '$templateKey must reject invalid selection $invalid for kimi-k3 pre-dispatch',
            );
          }

          // 4. kimi-k2.6 with selection 'on' -> thinking: {'type': 'enabled'}
          final resK26On = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'kimi-k2.6',
            selectionId: 'on',
          );
          await adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'Hello')],
            modelOverride: 'kimi-k2.6',
            options: LLMRequestOptions(
              thinkingDirective: resK26On.directive,
              providerInstanceId: inst.id,
            ),
          );
          expect(capturedBody['model'], 'kimi-k2.6');
          expect(
            capturedBody['thinking'],
            {'type': 'enabled'},
            reason: '$templateKey must serialize kimi-k2.6 thinking toggle via mode-owned wire authority',
          );
          expect(capturedBody.containsKey('reasoning_effort'), isFalse);
          expect(capturedBody.containsKey('thinking_config'), isFalse);

          // 5. kimi-k2.6 with selection 'off' -> thinking: {'type': 'disabled'}
          final resK26Off = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'kimi-k2.6',
            selectionId: 'off',
          );
          await adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'Hello')],
            modelOverride: 'kimi-k2.6',
            options: LLMRequestOptions(
              thinkingDirective: resK26Off.directive,
              providerInstanceId: inst.id,
            ),
          );
          expect(capturedBody['model'], 'kimi-k2.6');
          expect(
            capturedBody['thinking'],
            {'type': 'disabled'},
            reason: '$templateKey must serialize kimi-k2.6 disabled toggle via mode-owned wire authority',
          );
          expect(capturedBody.containsKey('reasoning_effort'), isFalse);

          // 6. kimi-k2.6 with default omission -> clean absence
          final resK26Omit = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'kimi-k2.6',
            selectionId: null,
          );
          await adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'Hello')],
            modelOverride: 'kimi-k2.6',
            options: LLMRequestOptions(
              thinkingDirective: resK26Omit.directive,
              providerInstanceId: inst.id,
            ),
          );
          expect(capturedBody['model'], 'kimi-k2.6');
          expect(
            capturedBody.containsKey('thinking'),
            isFalse,
            reason: '$templateKey must cleanly omit thinking for default omission on kimi-k2.6',
          );
          expect(capturedBody.containsKey('reasoning_effort'), isFalse);

          // 7. Pre-dispatch rejection of invalid selections on kimi-k2.6
          for (final invalid in ['high', 'medium', 'low', 'max']) {
            expect(
              () => resolver.resolve(
                providerInstanceId: inst.id,
                modelId: 'kimi-k2.6',
                selectionId: invalid,
              ),
              throwsA(
                isA<ThinkingSelectionException>().having(
                  (e) => e.code,
                  'code',
                  ThinkingSelectionErrorCode.optionUnavailable,
                ),
              ),
              reason: '$templateKey must reject invalid selection $invalid for kimi-k2.6 pre-dispatch',
            );
          }
        }
      });
    });

    group('Open Evidence Gaps (7 Shipped Templates Fail Closed to Unknown)', () {
      final openGapTemplates = [
        ('nvidia', 'deepseek-ai/deepseek-v4-flash'),
        ('xai', 'grok-3'),
        ('zai', 'glm-5.1'),
        ('zai-coding', 'glm-5-turbo'),
        ('lm-studio', 'deepseek-r1-qwen-7b'),
        ('llama-cpp', 'custom-model'),
        (kCustomProviderTemplateId, 'arbitrary-reasoner'),
      ];

      for (final (templateId, sampleModel) in openGapTemplates) {
        test('$templateId fails closed to unknown and rejects selection without wire mutation', () {
          final inst = ProviderInstance(
            id: 'gap-$templateId',
            templateId: templateId,
            displayName: templateId,
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          repo.createInstance(inst);

          final assembled = assembler.assemble(
            instance: inst,
            model: ModelOption(value: sampleModel, label: sampleModel),
          );
          expect(
            assembled.status,
            ThinkingCapabilityStatus.unknown,
            reason: '$templateId with $sampleModel must evaluate to unknown',
          );

          expect(
            () => resolver.resolve(
              providerInstanceId: 'gap-$templateId',
              modelId: sampleModel,
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
        });
      }
    });

    group('Wire Compatibility Validation & Route Isolation', () {
      test('ThinkingRoutePolicy.isWireCompatible enforces strict protocol and mode pairing', () {
        // OpenAI Chat Effort
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'openai_chat_effort',
            protocol: 'openai_compatible',
            apiMode: 'chat_completions',
          ),
          isTrue,
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'openai_chat_effort',
            protocol: 'anthropic_compatible',
            apiMode: 'anthropic_messages',
          ),
          isFalse,
        );

        // Anthropic Budget & Adaptive
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'anthropic_budget',
            protocol: 'anthropic_compatible',
            apiMode: 'anthropic_messages',
          ),
          isTrue,
        );
        expect(
          ThinkingRoutePolicy.isWireCompatible(
            wire: 'anthropic_adaptive',
            protocol: 'openai_compatible',
            apiMode: 'chat_completions',
          ),
          isFalse,
        );

        // Codex Responses
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
            protocol: 'openai_compatible',
            apiMode: 'chat_completions',
          ),
          isFalse,
        );
      });

      test('route isolation: instances and cache revisions do not leak across routes', () {
        final instA = ProviderInstance(
          id: 'inst-iso-a',
          templateId: 'openai',
          displayName: 'OpenAI A',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        final instB = ProviderInstance(
          id: 'inst-iso-b',
          templateId: 'kimi',
          displayName: 'Kimi B',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        repo.createInstance(instA);
        repo.createInstance(instB);

        // Inst A resolves o3-mini as supported effort
        final resA = resolver.resolve(
          providerInstanceId: 'inst-iso-a',
          modelId: 'o3-mini',
          selectionId: 'high',
        );
        expect(resA.descriptor.status, ThinkingCapabilityStatus.supported);

        // Inst B with same model string o3-mini fails closed to unknown
        final assembledB = assembler.assemble(
          instance: instB,
          model: ModelOption(value: 'o3-mini', label: 'o3-mini'),
        );
        expect(assembledB.status, ThinkingCapabilityStatus.unknown);
        expect(
          () => resolver.resolve(
            providerInstanceId: 'inst-iso-b',
            modelId: 'o3-mini',
            selectionId: 'high',
          ),
          throwsA(isA<ThinkingSelectionException>()),
        );
      });
    });

    group('Parameterized Explicit Finite Model Declarations Across All Shipped Kinds', () {
      final testedTemplateNames = <String>{};

      for (final profile in ProviderRegistry.profiles) {
        test('${profile.name}: explicit finite declaration, assembler, resolver, serializer, omission, and incompatible wire rejection', () {
          testedTemplateNames.add(profile.name);

          final inst = ProviderInstance(
            id: 'fixture-${profile.name}',
            templateId: profile.name,
            displayName: profile.displayName,
            protocol: profile.protocol ?? ProviderProtocol.openaiCompatible,
            authMethod: profile.authMethods.firstOrNull ?? ProviderAuthMethod.apiKey,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          repo.createInstance(inst);

          final isCodex = profile.apiMode == 'codex_responses';
          final isAnthropic = profile.protocol == ProviderProtocol.anthropicCompatible || profile.apiMode == 'anthropic_messages';
          final isCompatibleMode = isCodex || isAnthropic || profile.apiMode == 'chat_completions';

          if (!isCompatibleMode) {
            // Incompatible mode (e.g. ollama with apiMode: 'ollama') must reject declared wires
            final incompatibleModelId = 'fixture-incompatible-mode-model';
            final incompatibleMetadata = {
              'thinking_control': {
                'status': 'supported',
                'wire': 'openai_chat_effort',
                'options': {'high': 'high'},
              },
            };

            repo.upsertModelCache(
              instanceId: inst.id,
              cacheKey: 'models',
              models: [
                {
                  'value': incompatibleModelId,
                  'label': 'Incompatible Mode Model',
                  'model_metadata': incompatibleMetadata,
                },
              ],
              fetchedAt: DateTime.now(),
              source: 'remote',
              configRevision: inst.configRevision,
              credentialRevision: inst.credentialRevision,
            );

            final assembledIncompatibleMode = assembler.assemble(
              instance: inst,
              model: ModelOption(
                value: incompatibleModelId,
                label: 'Incompatible Mode Model',
                modelMetadata: incompatibleMetadata,
              ),
            );
            expect(
              assembledIncompatibleMode.status,
              ThinkingCapabilityStatus.unsupported,
              reason: 'Incompatible mode ${profile.apiMode} on ${profile.name} must reject declared wire',
            );
            expect(
              assembledIncompatibleMode.capabilityRevision,
              contains('declared_incompatible'),
            );

            expect(
              () => resolver.resolve(
                providerInstanceId: inst.id,
                modelId: incompatibleModelId,
                selectionId: 'high',
              ),
              throwsA(
                isA<ThinkingSelectionException>().having(
                  (e) => e.code,
                  'code',
                  ThinkingSelectionErrorCode.capabilityUnsupported,
                ),
              ),
            );
            return;
          }

          // 1. Compatible explicit finite declaration
          final compatibleWire = isCodex
              ? 'codex_responses_effort'
              : (isAnthropic ? 'anthropic_budget' : 'openai_chat_effort');
          final compatibleOptions = isAnthropic
              ? {'low': 1024, 'high': 8192}
              : {'low': 'low', 'high': 'high'};

          final declaredModelId = 'fixture-declared-model';
          final declaredModelMetadata = {
            'thinking_control': {
              'status': 'supported',
              'wire': compatibleWire,
              'options': compatibleOptions,
              // Omit default_option so selectionId == null tests default omission (UseProviderDefault)
            },
          };

          // Save to model cache so resolver can read model metadata
          repo.upsertModelCache(
            instanceId: inst.id,
            cacheKey: 'models',
            models: [
              {
                'value': declaredModelId,
                'label': 'Fixture Declared Model',
                'model_metadata': declaredModelMetadata,
              },
            ],
            fetchedAt: DateTime.now(),
            source: 'remote',
            configRevision: inst.configRevision,
            credentialRevision: inst.credentialRevision,
          );

          // A. Assembler produces supported descriptor
          final assembled = assembler.assemble(
            instance: inst,
            model: ModelOption(
              value: declaredModelId,
              label: 'Fixture Declared Model',
              modelMetadata: declaredModelMetadata,
            ),
          );
          expect(assembled.status, ThinkingCapabilityStatus.supported);
          expect(assembled.options.map((o) => o.id).toList(), ['low', 'high']);

          // B. Resolver resolves selection 'high'
          final resolvedHigh = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: declaredModelId,
            selectionId: 'high',
          );
          expect(resolvedHigh.descriptor.status, ThinkingCapabilityStatus.supported);

          // C. Serializer emits expected wire fields
          final wireBody = <String, dynamic>{};
          if (isCodex) {
            final reasoning = <String, dynamic>{};
            OpenAiThinkingWireCodec.applyResponsesReasoning(reasoning, resolvedHigh.directive);
            if (reasoning.isNotEmpty) wireBody['reasoning'] = reasoning;
            expect(wireBody['reasoning'], {'effort': 'high', 'summary': 'auto'});
          } else if (isAnthropic) {
            AnthropicThinkingWireCodec.applyThinking(wireBody, resolvedHigh.directive);
            expect(wireBody['thinking'], {'type': 'enabled', 'budget_tokens': 8192});
          } else {
            OpenAiThinkingWireCodec.applyChatCompletionsReasoning(wireBody, resolvedHigh.directive);
            expect(wireBody['reasoning_effort'], 'high');
          }

          // D. Default omission
          final resolvedOmit = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: declaredModelId,
            selectionId: null,
          );
          expect(resolvedOmit.directive, isA<UseProviderDefault>());
          final omitBody = <String, dynamic>{};
          if (isCodex) {
            final reasoning = <String, dynamic>{};
            OpenAiThinkingWireCodec.applyResponsesReasoning(reasoning, resolvedOmit.directive);
            expect(reasoning.containsKey('effort'), isFalse);
          } else if (isAnthropic) {
            AnthropicThinkingWireCodec.applyThinking(omitBody, resolvedOmit.directive);
            expect(omitBody.containsKey('thinking'), isFalse);
          } else {
            OpenAiThinkingWireCodec.applyChatCompletionsReasoning(omitBody, resolvedOmit.directive);
            expect(omitBody.containsKey('reasoning_effort'), isFalse);
          }

          // E. Incompatible wire rejection
          final incompatibleWire = isAnthropic ? 'openai_chat_effort' : 'anthropic_budget';
          final incompatibleOptions = isAnthropic
              ? {'high': 'high'}
              : {'high': 8192};
          final incompatibleModelId = 'fixture-incompatible-model';
          final incompatibleMetadata = {
            'thinking_control': {
              'status': 'supported',
              'wire': incompatibleWire,
              'options': incompatibleOptions,
            },
          };

          repo.upsertModelCache(
            instanceId: inst.id,
            cacheKey: 'models',
            models: [
              {
                'value': declaredModelId,
                'label': 'Fixture Declared Model',
                'model_metadata': declaredModelMetadata,
              },
              {
                'value': incompatibleModelId,
                'label': 'Fixture Incompatible Model',
                'model_metadata': incompatibleMetadata,
              },
            ],
            fetchedAt: DateTime.now(),
            source: 'remote',
            configRevision: inst.configRevision,
            credentialRevision: inst.credentialRevision,
          );

          final assembledIncompatible = assembler.assemble(
            instance: inst,
            model: ModelOption(
              value: incompatibleModelId,
              label: 'Fixture Incompatible Model',
              modelMetadata: incompatibleMetadata,
            ),
          );
          expect(
            assembledIncompatible.status,
            ThinkingCapabilityStatus.unsupported,
            reason: 'Incompatible wire $incompatibleWire must be rejected on ${profile.name}',
          );
          expect(assembledIncompatible.capabilityRevision, contains('declared_incompatible'));

          expect(
            () => resolver.resolve(
              providerInstanceId: inst.id,
              modelId: incompatibleModelId,
              selectionId: 'high',
            ),
            throwsA(
              isA<ThinkingSelectionException>().having(
                (e) => e.code,
                'code',
                ThinkingSelectionErrorCode.capabilityUnsupported,
              ),
            ),
          );
        });
      }

      test('all registered profiles are covered by the parameterized explicit declaration fixtures', () {
        expect(
          testedTemplateNames,
          equals(ProviderRegistry.profiles.map((p) => p.name).toSet()),
          reason: 'Dynamic coverage of all 16 registered profiles must be exact',
        );
      });
    });
  });
}
