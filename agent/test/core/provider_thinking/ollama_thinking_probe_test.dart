import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_live_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:test/test.dart';

void main() {
  group('OllamaThinkingProbe capability detection', () {
    test('parses thinking capability from /api/show fixture', () {
      final metadata = OllamaThinkingProbe.metadataFromShowResponse({
        'capabilities': ['completion', 'tools', 'thinking'],
        'parameters': 'think',
      });

      expect(OllamaThinkingProbe.hasThinkingCapability(metadata), isTrue);
    });

    test('returns unsupported when thinking capability is absent', () {
      final metadata = OllamaThinkingProbe.metadataFromShowResponse({
        'capabilities': ['completion', 'tools'],
      });

      expect(OllamaThinkingProbe.hasThinkingCapability(metadata), isFalse);
    });

    test('returns null when probe evidence is missing', () {
      expect(OllamaThinkingProbe.hasThinkingCapability(const {}), isNull);
    });

    test(
      'capability detection ignores model name and uses show fixture only',
      () {
        final withThinking = OllamaThinkingProbe.metadataFromShowResponse({
          'model': 'custom-local-model',
          'capabilities': ['completion', 'thinking'],
        });
        final withoutThinking = OllamaThinkingProbe.metadataFromShowResponse({
          'model': 'gpt-oss:20b',
          'capabilities': ['completion'],
        });

        expect(OllamaThinkingProbe.hasThinkingCapability(withThinking), isTrue);
        expect(
          OllamaThinkingProbe.hasThinkingCapability(withoutThinking),
          isFalse,
        );
      },
    );

    test(
      'strict capability list validation: invalid element types return null',
      () {
        expect(OllamaThinkingProbe.parseCapabilities([1, 2, 3]), isNull);
        expect(OllamaThinkingProbe.parseCapabilities(['']), isNull);
        expect(OllamaThinkingProbe.parseCapabilities('not-a-list'), isNull);
        expect(
          OllamaThinkingProbe.hasThinkingCapability({
            OllamaThinkingProbe.capabilitiesMetadataKey: [123],
          }),
          isNull,
        );
      },
    );
  });

  group('OllamaThinkingProbe and OllamaLiveThinkingPolicy declarations', () {
    const policy = OllamaLiveThinkingPolicy();

    test('boolean declaration rejects default not belonging to values', () {
      final malformed = OllamaThinkingProbe.parseThinkingDeclaration({
        OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
          'values': [true],
          'default': false,
        },
      });
      expect(malformed, isNull);

      const context = ThinkingPolicyContext(
        providerInstanceId: 'inst-1',
        templateId: 'ollama',
        protocol: 'ollama',
        apiMode: 'ollama',
        modelId: 'test-model',
        modelMetadata: {
          OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': [true],
            'default': false,
          },
        },
      );
      final desc = policy.resolveCapability(context);
      expect(desc.status, ThinkingCapabilityStatus.unknown);
    });

    test(
      'boolean declaration honors finite single-value declaration without fabricating Off',
      () {
        final decl = OllamaThinkingProbe.parseThinkingDeclaration({
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': [true],
            'default': true,
          },
        });
        expect(decl, isA<OllamaBooleanThinkingDeclaration>());
        expect((decl as OllamaBooleanThinkingDeclaration).values, [true]);

        const context = ThinkingPolicyContext(
          providerInstanceId: 'inst-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'test-model',
          modelMetadata: {
            OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
            OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
              'values': [true],
              'default': true,
            },
          },
        );
        final desc = policy.resolveCapability(context);
        expect(desc.status, ThinkingCapabilityStatus.supported);
        expect(desc.kind, ThinkingControlKind.toggle);
        expect(desc.options.map((o) => o.id), ['on']);
        expect(desc.defaultOptionId, 'on');

        // Selection of undeclared 'off' falls back to default
        final dirOff = policy.resolveDirective(context, 'off');
        expect(dirOff, isA<UseProviderDefault>());
        final dirOn = policy.resolveDirective(context, 'on');
        expect(dirOn, isA<ThinkingToggleDirective>());
        expect((dirOn as ThinkingToggleDirective).enabled, isTrue);
      },
    );

    test(
      'level defaults require proper native String type, rejecting boolean/numeric defaults',
      () {
        final boolDefault = OllamaThinkingProbe.parseThinkingDeclaration({
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': ['low', 'medium', 'high'],
            'default': false,
          },
        });
        expect(boolDefault, isNull);

        final numDefault = OllamaThinkingProbe.parseThinkingDeclaration({
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': ['low', 'medium', 'high'],
            'default': 1,
          },
        });
        expect(numDefault, isNull);

        final missingDefault = OllamaThinkingProbe.parseThinkingDeclaration({
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': ['low', 'medium', 'high'],
            'default': 'extreme',
          },
        });
        expect(missingDefault, isNull);
      },
    );

    test(
      'level values off and none preserve native string wire type instead of converting to boolean',
      () {
        final decl = OllamaThinkingProbe.parseThinkingDeclaration({
          OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
            'values': ['off', 'low', 'medium', 'high'],
            'default': 'medium',
          },
        });
        expect(decl, isA<OllamaLevelThinkingDeclaration>());

        const context = ThinkingPolicyContext(
          providerInstanceId: 'inst-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'test-model',
          modelMetadata: {
            OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
            OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
              'values': ['off', 'low', 'medium', 'high'],
              'default': 'medium',
            },
          },
        );

        final desc = policy.resolveCapability(context);
        expect(desc.status, ThinkingCapabilityStatus.supported);
        expect(desc.kind, ThinkingControlKind.effort);
        expect(desc.options.firstWhere((o) => o.id == 'off').isOff, isTrue);

        final dirOff = policy.resolveDirective(context, 'off');
        expect(dirOff, isA<OllamaThinkLevelDirective>());
        expect((dirOff as OllamaThinkLevelDirective).level, 'off');

        // None option also preserves string
        const noneContext = ThinkingPolicyContext(
          providerInstanceId: 'inst-1',
          templateId: 'ollama',
          protocol: 'ollama',
          apiMode: 'ollama',
          modelId: 'test-model',
          modelMetadata: {
            OllamaThinkingProbe.capabilitiesMetadataKey: ['thinking'],
            OllamaThinkingProbe.thinkingDeclarationMetadataKey: {
              'values': ['none', 'low', 'high'],
              'default': 'low',
            },
          },
        );
        final dirNone = policy.resolveDirective(noneContext, 'none');
        expect(dirNone, isA<OllamaThinkLevelDirective>());
        expect((dirNone as OllamaThinkLevelDirective).level, 'none');
      },
    );
  });

  group('OllamaAdapter sync and stream HTTP wire body tests', () {
    late Config config;
    late ProviderProfile profile;

    setUp(() {
      config = Config(
        environment: {
          'LLM_MODEL': 'qwen3:latest',
          'AGENT_NAME': 'TestAgent',
          'LLM_BASE_URL': 'http://127.0.0.1:11434',
        },
      );
      profile = const ProviderProfile(
        name: 'ollama',
        displayName: 'Ollama',
        apiMode: 'ollama',
      );
    });

    test(
      'sync generateResponse serializes boolean toggle, native level string, and default omission',
      () async {
        Map<String, dynamic>? capturedBody;
        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/api/chat')) {
            capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'message': {'role': 'assistant', 'content': 'hello'},
                'done': true,
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final adapter = OllamaAdapter(config, profile, client: mockClient);

        // 1. Boolean true
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: ThinkingToggleDirective(enabled: true),
          ),
        );
        expect(capturedBody?['think'], isTrue);

        // 2. Boolean false
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: ThinkingToggleDirective(enabled: false),
          ),
        );
        expect(capturedBody?['think'], isFalse);

        // 3. Native level string 'off' (preserved wire string, not boolean false)
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: OllamaThinkLevelDirective('off'),
          ),
        );
        expect(capturedBody?['think'], equals('off'));

        // 4. Native level string 'high'
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: OllamaThinkLevelDirective('high'),
          ),
        );
        expect(capturedBody?['think'], equals('high'));

        // 5. Default omission (no think field)
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: UseProviderDefault(),
          ),
        );
        expect(capturedBody?.containsKey('think'), isFalse);
      },
    );

    test(
      'stream generateStream serializes boolean toggle and native level wire types identically',
      () async {
        Map<String, dynamic>? capturedBody;
        final mockClient = MockClient.streaming((request, bodyStream) async {
          final bodyBytes = await bodyStream.toBytes();
          capturedBody =
              jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
          final responseText =
              '${jsonEncode({
                'message': {'content': 'streamed'},
                'done': true,
              })}\n';
          return http.StreamedResponse(
            Stream.value(utf8.encode(responseText)),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final adapter = OllamaAdapter(config, profile, client: mockClient);

        // Stream with level string 'none'
        final streamResponse = adapter.generateStream(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: OllamaThinkLevelDirective('none'),
          ),
        );
        await for (final _ in streamResponse) {}
        expect(capturedBody?['think'], equals('none'));
        expect(capturedBody?['stream'], isTrue);

        // Stream with boolean false
        final streamFalse = adapter.generateStream(
          [Message(role: MessageRole.user, content: 'hi')],
          options: const LLMRequestOptions(
            thinkingDirective: ThinkingToggleDirective(enabled: false),
          ),
        );
        await for (final _ in streamFalse) {}
        expect(capturedBody?['think'], isFalse);
      },
    );
  });
}
