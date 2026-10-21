/// Task 116 D6 — cross-family projection on the actual adapter HTTP wire:
/// native Ollama, Codex Responses and the other OpenAI-compatible Chat route
/// policies never receive foreign reasoning or opaque state, and keep tool
/// call/result pairing. Synthetic payloads only.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_codec.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

import 'projection_fixtures.dart';

const _anthropicState = LLMProviderState(
  namespace: 'anthropic_messages',
  issuer: 'anth-1|anthropic_compatible|https://api.anthropic.com',
  data: {
    'issuer_model': 'claude-fixture-1',
    'thinking_blocks': [
      {'type': 'thinking', 'thinking': 'claude plan', 'signature': 'sig-a'},
    ],
  },
);

/// One history mixing every family's state: DeepSeek Chat (same instance as
/// the Go fixtures), Codex Responses and Anthropic signed thinking.
List<Message> _mixedHistory() => [
  Message(role: MessageRole.user, content: 'start'),
  toolTurn('chat-1', state: chatState(reasoning: 'deepseek reasoning')),
  toolResult('chat-1'),
  toolTurn('codex-1', state: codexState()),
  toolResult('codex-1'),
  toolTurn('anth-1', state: _anthropicState),
  toolResult('anth-1'),
  Message(role: MessageRole.user, content: 'next'),
];

void _expectNoForeignState(String wire) {
  for (final secret in [
    'deepseek reasoning',
    'sealed-codex',
    'claude plan',
    'sig-a',
    'reasoning_content',
    'reasoning_details',
    'encrypted_content',
  ]) {
    expect(wire, isNot(contains(secret)), reason: secret);
  }
}

void main() {
  test('native Ollama emits only portable fields with paired tools', () async {
    final bodies = <Map<String, dynamic>>[];
    final adapter = OllamaAdapter(
      Config(environment: const {}),
      ProviderRegistry.findByNameOrAlias('ollama')!,
      client: MockClient((request) async {
        bodies.add((jsonDecode(request.body) as Map).cast<String, dynamic>());
        return http.Response(
          jsonEncode({
            'message': {'role': 'assistant', 'content': 'ok'},
            'done': true,
          }),
          200,
        );
      }),
    );
    await adapter.generateResponse(
      _mixedHistory(),
      modelOverride: 'llama-fixture',
    );
    final wire = jsonEncode(bodies.single);
    _expectNoForeignState(wire);
    final messages = (bodies.single['messages'] as List).cast<Map>();
    final toolResults = messages.where((m) => m['role'] == 'tool').toList();
    expect(toolResults.map((m) => m['tool_call_id']), [
      'chat-1',
      'codex-1',
      'anth-1',
    ]);
    expect(
      messages.where((m) => m['tool_calls'] != null),
      hasLength(3),
    );
  });

  group('Codex Responses', () {
    late Config config;
    const profile = ProviderProfile(
      name: 'openai-codex',
      defaultBaseUrl: 'https://chatgpt.com/backend-api/codex',
      fallbackModels: [codexModel],
      apiMode: 'codex_responses',
    );

    setUp(() {
      config = Config(
        environment: {
          'ACTIVE_PROVIDER': 'openai-codex',
          'LLM_API_KEY': 'fixture-key',
          'LLM_MODEL': codexModel,
          'CHATGPT_MODEL': codexModel,
          'LLM_BASE_URL': 'https://chatgpt.com/backend-api/codex',
        },
      );
    });

    CodexResponsesAdapter adapter(List<Map<String, dynamic>> bodies) =>
        CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming((request, _) async {
            bodies.add(
              (jsonDecode((request as http.Request).body) as Map)
                  .cast<String, dynamic>(),
            );
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  'data: ${jsonEncode({
                    'type': 'response.completed',
                    'response': {
                      'status': 'completed',
                      'output': [
                        {
                          'type': 'message',
                          'role': 'assistant',
                          'status': 'completed',
                          'content': [
                            {'type': 'output_text', 'text': 'ok'},
                          ],
                        },
                      ],
                    },
                  })}\n\n',
                ),
              ),
              200,
            );
          }),
        );

    test('Chat and Anthropic history reach Codex as portable pairs', () async {
      final bodies = <Map<String, dynamic>>[];
      final mixed = _mixedHistory()
        ..removeWhere(
          (m) => m.providerState?.namespace == 'codex_responses' ||
              m.toolCallId == 'codex-1',
        );
      await adapter(bodies).generateResponse(
        mixed,
        options: const LLMRequestOptions(providerInstanceId: 'codex-1'),
      );
      // `include: [reasoning.encrypted_content]` is Codex's own request
      // option; only the projected input must be free of foreign state.
      _expectNoForeignState(jsonEncode(bodies.single['input']));
      final input = (bodies.single['input'] as List).cast<Map>();
      final calls = input.where((i) => i['type'] == 'function_call').toList();
      final outputs = input
          .where((i) => i['type'] == 'function_call_output')
          .toList();
      expect(calls.map((c) => c['call_id']), ['chat-1', 'anth-1']);
      expect(outputs.map((o) => o['call_id']), ['chat-1', 'anth-1']);
    });

    test('Codex -> Chat -> Codex returns only its own reasoning items',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final ownState = LLMProviderState(
        namespace: CodexResponsesCodec.providerStateNamespace,
        issuer: codexIssuer,
        data: codexState().data,
      );
      await adapter(bodies).generateResponse(
        [
          Message(role: MessageRole.user, content: 'start'),
          toolTurn('own', state: ownState),
          toolResult('own'),
          toolTurn('chat-1', state: chatState(reasoning: 'deepseek reasoning')),
          toolResult('chat-1'),
          toolTurn(
            'other-codex',
            state: const LLMProviderState(
              namespace: 'codex_responses',
              issuer: 'codex-2|codex_responses|https://chatgpt.com/backend-api/codex',
              data: {
                'reasoning_items': [
                  {'type': 'reasoning', 'encrypted_content': 'other-instance'},
                ],
              },
            ),
          ),
          toolResult('other-codex'),
        ],
        options: const LLMRequestOptions(providerInstanceId: 'codex-1'),
      );
      final wire = jsonEncode(bodies.single);
      expect(wire, contains('sealed-codex'), reason: 'own issuer replays');
      expect(wire, isNot(contains('other-instance')));
      expect(wire, isNot(contains('deepseek reasoning')));
      expect(wire, isNot(contains('reasoning_content')));
    });
  });

  group('other OpenAI-compatible Chat route policies', () {
    for (final template in [
      'openai',
      'deepseek',
      'zai',
      'xai',
      'gemini',
      'lm-studio',
      'nvidia',
    ]) {
      test('$template never receives foreign reasoning keys', () async {
        final recorder = WireRecorder();
        await goAdapter(
          recorder.client,
          instance: '$template-1',
          profileName: template,
          baseUrl: 'https://$template.invalid/v1',
        ).generateResponse(
          _mixedHistory(),
          modelOverride: 'fixture-model',
          options: LLMRequestOptions(providerInstanceId: '$template-1'),
        );
        final wire = jsonEncode(recorder.bodies.single);
        _expectNoForeignState(wire);
        final turns = assistantToolWire(recorder.lastMessages);
        expect(
          turns.map((t) => (t['tool_calls'] as List).single['id']),
          ['chat-1', 'codex-1', 'anth-1'],
        );
        expect(
          turns.map(
            (t) => (t['tool_calls'] as List).single['function']['arguments'],
          ),
          everyElement(contains('.txt')),
        );
      });
    }
  });
}
