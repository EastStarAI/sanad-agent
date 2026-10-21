/// DeepSeek official wire contract on OpenCode Go `deepseek-v4.1-flash`.
///
/// Restored for the 5-layer thinking authority (live-r1): the facts now come
/// from the shipped defaults (layer 3, `agent/model_capability_defaults.yaml`,
/// `native_toggle_effort`), never from a model-name table in Dart, and they
/// win over the `opencode-go` models.dev entry (which reports only
/// `low/high/max` with no Off and no default).
///
/// Grounding (official, read-only):
/// - https://www.deepseek.com/en/news/deepseek-v4-1-flash/ — V4.1-Flash is live
///   on the DeepSeek API; `deepseek-v4-flash` (and the retired vision-exp id)
///   temporarily route to V4.1-Flash; OpenCode is an official partner.
/// - https://api-docs.deepseek.com/guides/thinking_mode — OpenAI Chat control
///   is `{"thinking": {"type": "enabled/disabled"}}` plus finite
///   `{"reasoning_effort": "low/high/max"}`; thinking is enabled by default at
///   default effort `high`; `minimal`/`medium`/`xhigh`/`ultra` are documented
///   request aliases, NOT distinct UI tiers.
/// - https://opencode.ai/docs/go/ — Go lists `DeepSeek V4.1 Flash` and requires
///   the stable `x-opencode-session` header for each conversation.
///
/// This suite deliberately proves both directions: the exact id becomes
/// controllable with real finite tiers and real On-wire effort values, while
/// near-IDs stay fail-closed and keep the selector hidden.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/generated_model_capability_defaults.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

/// Exact OpenCode Go model id for DeepSeek V4.1 Flash.
const v41FlashModelId = 'deepseek-v4.1-flash';

/// Real finite tiers only. Documented request aliases are never UI options.
const realV41Tiers = ['off', 'low', 'high', 'max'];

/// Near-IDs that must never be treated as the exact V4.1 Flash route control.
const v41NearIds = [
  'deepseek-v4.1-flash-x',
  'deepseek-v4.1-flash-thinking',
  'deepseek-v41-flash',
  'deepseek-v4-1-flash',
  'deepseek-v4.1',
  'DEEPSEEK-V4.1-FLASH',
];

void main() {
  group('OpenCode Go exact deepseek-v4.1-flash thinking controls', () {
    late Directory tempHome;
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late ThinkingCapabilityAssembler assembler;
    late ThinkingSelectionResolver resolver;
    late Config isolatedConfig;
    late ProviderInstance goInstance;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('sanad_v41_flash_home_');
      setSanadHomeOverride(tempHome.path);

      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      if (getIt.isRegistered<ProviderInstanceRepository>()) {
        getIt.unregister<ProviderInstanceRepository>();
      }
      getIt.registerSingleton<ProviderInstanceRepository>(repo);

      isolatedConfig = Config(environment: {'SANAD_HOME': tempHome.path});
      expect(getSanadHome(), tempHome.path);

      final registry = buildProviderThinkingRegistry();
      // The real Test Home `opencode-go` models.dev entry for this model.
      assembler = ThinkingCapabilityAssembler(
        registry,
        isolatedConfig,
        (templateId, modelId) =>
            templateId == 'opencode-go' && modelId == v41FlashModelId
            ? const {
                'reasoning': true,
                'interleaved': {'field': 'reasoning_content'},
                'reasoning_options': [
                  {
                    'type': 'effort',
                    'values': ['low', 'high', 'max'],
                  },
                ],
              }
            : null,
      );
      resolver = ThinkingSelectionResolver(
        instances: repo,
        cacheResolver: ThinkingControlCacheResolver(repo),
        assembler: assembler,
        registry: registry,
        config: isolatedConfig,
      );

      goInstance = ProviderInstance(
        id: 'inst-v41-go',
        templateId: 'opencode-go',
        displayName: 'OpenCode Go',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(goInstance);
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

    test(
      'exact V4.1 Flash resolves the shipped DeepSeek toggle/effort over models.dev',
      () {
        final shipped = modelCapabilityDefaults[v41FlashModelId]!;
        expect(shipped.source, startsWith('https://'));
        expect(shipped.thinkingControl['wire'], 'native_toggle_effort');
        expect(
          ThinkingRoutePolicy.policyIdFor(goInstance, modelId: v41FlashModelId),
          'openai_chat_effort',
          reason: 'the policy id is a route label; it never reads the model id',
        );

        final descriptor = assembler.assemble(
          instance: goInstance,
          model: ModelOption(
            value: v41FlashModelId,
            label: 'DeepSeek V4.1 Flash',
          ),
        );
        expect(descriptor.status, ThinkingCapabilityStatus.supported);
        expect(descriptor.kind, ThinkingControlKind.effort);
        expect(descriptor.isSelectable, isTrue);
        expect(
          descriptor.options.map((option) => option.id).toList(),
          realV41Tiers,
        );
        expect(descriptor.options.map((option) => option.label).toList(), [
          'Off',
          'Low',
          'High',
          'Max',
        ]);
        expect(descriptor.defaultOptionId, 'high');
        expect(
          descriptor.options
              .where((option) => option.isProviderDefault)
              .map((option) => option.id)
              .toList(),
          ['high'],
        );
        expect(
          descriptor.options
              .where((option) => option.isOff)
              .map((option) => option.id)
              .toList(),
          ['off'],
        );

        // Documented request aliases are remaps, never distinct visible tiers.
        for (final alias in [
          'minimal',
          'medium',
          'xhigh',
          'ultra',
          'none',
          'on',
        ]) {
          expect(
            descriptor.containsOptionId(alias),
            isFalse,
            reason: '$alias must not be exposed as a distinct V4.1 tier',
          );
        }
      },
    );

    test(
      'serialized V4.1 descriptor matches the client visibility contract',
      () {
        final descriptor = assembler.assemble(
          instance: goInstance,
          model: ModelOption(
            value: v41FlashModelId,
            label: 'DeepSeek V4.1 Flash',
          ),
        );

        final wire = descriptor.toMap();
        expect(wire['status'], 'supported');
        expect(wire['kind'], 'effort');
        expect(wire['default_option_id'], 'high');
        expect(wire['options'], [
          {
            'id': 'off',
            'label': 'Off',
            'is_off': true,
            'is_provider_default': false,
          },
          {
            'id': 'low',
            'label': 'Low',
            'is_off': false,
            'is_provider_default': false,
          },
          {
            'id': 'high',
            'label': 'High',
            'is_off': false,
            'is_provider_default': true,
          },
          {
            'id': 'max',
            'label': 'Max',
            'is_off': false,
            'is_provider_default': false,
          },
        ]);
        expect(wire['capability_revision'], contains('shipped_'));
        expect(wire['source'], 'shipped_default');
      },
    );

    test(
      'pre-fix cached unsupported descriptor heals to supported delivery',
      () {
        // Reproduce the reported delivered state: the model cache carried
        // `supports_reasoning_output: true` with an unsupported `profile`
        // descriptor produced by the generic OpenCode Go policy.
        repo.upsertModelCache(
          instanceId: goInstance.id,
          cacheKey: 'models',
          models: [
            {
              'value': v41FlashModelId,
              'label': 'DeepSeek V4.1 Flash',
              'supports_reasoning_output': true,
              'thinking_control': <String, dynamic>{
                'status': 'unsupported',
                'options': <dynamic>[],
                'capability_revision':
                    '${goInstance.configRevision}:'
                    '${goInstance.credentialRevision}:'
                    'openai_chat_effort:$v41FlashModelId',
                'source': 'profile',
              },
            },
          ],
          fetchedAt: DateTime.now().toUtc(),
          source: 'live',
          configRevision: goInstance.configRevision,
          credentialRevision: goInstance.credentialRevision,
        );

        // The cached pre-fix descriptor is faithfully readable...
        final cached = ThinkingControlCacheResolver(repo).resolve(
          providerInstanceId: goInstance.id,
          modelId: v41FlashModelId,
          templateId: 'opencode-go',
          protocol: ProviderProtocol.openaiCompatible,
          configRevision: goInstance.configRevision,
          credentialRevision: goInstance.credentialRevision,
        );
        expect(cached?['status'], 'unsupported');

        // ...but resolution must not keep serving it: the fresh model-owned
        // revision wins, so an existing route recovers without a manual
        // refresh and without erasing the user's saved selection.
        final resolved = resolver.resolve(
          providerInstanceId: goInstance.id,
          modelId: v41FlashModelId,
          selectionId: 'high',
        );
        expect(resolved.descriptor.status, ThinkingCapabilityStatus.supported);
        expect(
          resolved.descriptor.options.map((o) => o.id).toList(),
          realV41Tiers,
        );
        expect(resolved.descriptor.defaultOptionId, 'high');
        expect(
          (resolved.directive as NativeThinkingEffortDirective).effort,
          'high',
        );
      },
    );

    test('exact V4.1 Flash selections resolve to real native directives', () {
      final off = resolver.resolve(
        providerInstanceId: goInstance.id,
        modelId: v41FlashModelId,
        selectionId: 'off',
      );
      expect(off.directive, const ThinkingToggleDirective(enabled: false));

      final none = resolver.resolve(
        providerInstanceId: goInstance.id,
        modelId: v41FlashModelId,
        selectionId: null,
      );
      expect(none.directive, isA<UseProviderDefault>());
      expect(none.selectionId, isNull);

      for (final effort in ['low', 'high', 'max']) {
        final resolved = resolver.resolve(
          providerInstanceId: goInstance.id,
          modelId: v41FlashModelId,
          selectionId: effort,
        );
        expect(
          resolved.directive,
          isA<NativeThinkingEffortDirective>(),
          reason: '$effort must enable thinking with the exact effort',
        );
        expect(
          (resolved.directive as NativeThinkingEffortDirective).effort,
          effort,
        );
      }

      // A documented request alias is never a distinct tier: an unoffered
      // `medium` clamps down to the nearest lower real tier, `low`.
      final clamped = resolver.resolve(
        providerInstanceId: goInstance.id,
        modelId: v41FlashModelId,
        selectionId: 'medium',
      );
      expect(clamped.selectionId, 'low');
      expect(
        (clamped.directive as NativeThinkingEffortDirective).effort,
        'low',
      );
      // `none` is never a clamp target and is not an offered option.
      expect(
        () => resolver.resolve(
          providerInstanceId: goInstance.id,
          modelId: v41FlashModelId,
          selectionId: 'none',
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

    test('near-IDs stay unknown and never send a thinking field on Go', () {
      for (final nearId in v41NearIds) {
        expect(
          modelCapabilityDefaults.containsKey(nearId),
          isFalse,
          reason: '$nearId must not be a shipped DeepSeek record',
        );
        expect(
          ThinkingRoutePolicy.policyIdFor(goInstance, modelId: nearId),
          'openai_chat_effort',
          reason: '$nearId must keep the registered Go template policy',
        );
        final descriptor = assembler.assemble(
          instance: goInstance,
          model: ModelOption(value: nearId, label: nearId),
        );
        expect(
          descriptor.status,
          ThinkingCapabilityStatus.unknown,
          reason: '$nearId has no reported set on OpenCode Go',
        );
        expect(descriptor.isSelectable, isFalse);
        expect(descriptor.options, isEmpty);
        expect(
          resolver
              .resolve(
                providerInstanceId: goInstance.id,
                modelId: nearId,
                selectionId: 'high',
              )
              .directive,
          isA<UseProviderDefault>(),
          reason: '$nearId must never put a thinking field on the wire',
        );
      }
    });

    test(
      'production Go Chat wire: default omission, Off and each real effort',
      () async {
        final goProfile = ProviderRegistry.findByNameOrAlias('opencode-go')!;
        final capturedBodies = <Map<String, dynamic>>[];
        final mockClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          capturedBodies.add(body);
          return http.Response(
            jsonEncode({
              'id': 'chatcmpl-v41',
              'object': 'chat.completion',
              'created': 123456789,
              'model': body['model'],
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final adapter = BaseOpenAIAdapter(
          isolatedConfig,
          goProfile,
          client: mockClient,
          providerInstanceId: goInstance.id,
        );

        Future<void> send(String? selectionId) async {
          final resolved = resolver.resolve(
            providerInstanceId: goInstance.id,
            modelId: v41FlashModelId,
            selectionId: selectionId,
          );
          await adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'Hello')],
            modelOverride: v41FlashModelId,
            options: LLMRequestOptions(
              thinkingDirective: resolved.directive,
              providerInstanceId: goInstance.id,
            ),
          );
        }

        // 1. Provider default: no selection -> clean omission, real model id.
        await send(null);
        final defaultBody = capturedBodies.last;
        expect(defaultBody['model'], v41FlashModelId);
        expect(defaultBody.containsKey('thinking'), isFalse);
        expect(defaultBody.containsKey('reasoning_effort'), isFalse);
        expect(defaultBody.containsKey('thinking_config'), isFalse);
        expect(defaultBody.containsKey('reasoning'), isFalse);

        // 2. Explicit Off -> typed disable, no effort field.
        await send('off');
        expect(capturedBodies.last['model'], v41FlashModelId);
        expect(capturedBodies.last['thinking'], {'type': 'disabled'});
        expect(capturedBodies.last.containsKey('reasoning_effort'), isFalse);

        // 3. Each real effort -> enabled thinking plus the exact effort value.
        for (final effort in ['low', 'high', 'max']) {
          await send(effort);
          final body = capturedBodies.last;
          expect(body['model'], v41FlashModelId);
          expect(body['thinking'], {
            'type': 'enabled',
          }, reason: '$effort must enable thinking on the DeepSeek Chat wire');
          expect(
            body['reasoning_effort'],
            effort,
            reason: '$effort must reach the wire unchanged',
          );
          expect(body.containsKey('thinking_config'), isFalse);
          expect(body.containsKey('reasoning'), isFalse);
        }

        // No control-free request may be polluted by thinking fields.
        expect(capturedBodies, hasLength(5));

        // 4. A near-ID selection carries no thinking directive at all.
        expect(
          resolver
              .resolve(
                providerInstanceId: goInstance.id,
                modelId: 'deepseek-v4.1-flash-x',
                selectionId: 'high',
              )
              .directive,
          isA<UseProviderDefault>(),
        );
      },
    );
  });
}
