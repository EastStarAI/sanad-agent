/// Task 116 D5 — Anthropic Messages thinking signatures and tool pairing on
/// the actual adapter HTTP wire (MockClient carrier, synthetic payloads).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_history_projection_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

import 'projection_fixtures.dart';

const _anthropicUrl = 'https://api.anthropic.com';
const _instance = 'anth-1';
const _model = 'claude-fixture-1';
const _options = LLMRequestOptions(
  providerInstanceId: _instance,
  maxOutputTokens: 16384,
  thinkingDirective: AnthropicBudgetDirective(8192),
);

class _Recorder {
  final bodies = <Map<String, dynamic>>[];
  final String response;
  _Recorder(this.response);

  http.Client get client => MockClient((request) async {
    bodies.add((jsonDecode(request.body) as Map).cast<String, dynamic>());
    return http.Response(response, 200);
  });
}

String _final(String text) => jsonEncode({
  'content': [
    {'type': 'text', 'text': text},
  ],
  'stop_reason': 'end_turn',
  'usage': {'input_tokens': 1, 'output_tokens': 1},
});

BaseAnthropicAdapter _adapter(http.Client client, {String instance = _instance}) =>
    BaseAnthropicAdapter(
      FixedRouteConfig(_anthropicUrl),
      ProviderRegistry.findByNameOrAlias('anthropic')!,
      client: client,
      providerInstanceId: instance,
    );

Future<Message> _syncToolTurn() async {
  final recorder = _Recorder(
    jsonEncode({
      'content': [
        {'type': 'thinking', 'thinking': 'plan', 'signature': 'sig-1'},
        {'type': 'redacted_thinking', 'data': 'redacted-1'},
        {'type': 'thinking', 'thinking': 'unsigned'},
        {
          'type': 'tool_use',
          'id': 'tu-1',
          'name': 'read_file',
          'input': {'path': 'a'},
        },
      ],
      'stop_reason': 'tool_use',
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    }),
  );
  final response = await _adapter(recorder.client).generateResponse(
    [Message(role: MessageRole.user, content: 'go')],
    modelOverride: _model,
    options: _options,
  );
  return response.message;
}

void main() {
  test('sync captures only signed thinking with issuer and model', () async {
    final message = await _syncToolTurn();
    final state = message.providerState!;
    expect(state.namespace, 'anthropic_messages');
    expect(state.issuer, '$_instance|anthropic_compatible|$_anthropicUrl');
    expect(state.data['issuer_model'], _model);
    expect(state.data['thinking_blocks'], [
      {'type': 'thinking', 'thinking': 'plan', 'signature': 'sig-1'},
      {'type': 'redacted_thinking', 'data': 'redacted-1'},
    ]);
    expect(message.reasoning, contains('plan'));
  });

  test('stream captures signature deltas and redacted blocks', () async {
    final events = [
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'plan'},
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': 'sig-s'},
      },
      {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {'type': 'redacted_thinking', 'data': 'red-s'},
      },
      {
        'type': 'content_block_start',
        'index': 2,
        'content_block': {'type': 'tool_use', 'id': 'tu-s', 'name': 'read_file'},
      },
      {
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'input_json_delta', 'partial_json': '{}'},
      },
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use'},
      },
    ];
    final adapter = _adapter(
      MockClient(
        (_) async => http.Response(
          events.map((e) => 'data: ${jsonEncode(e)}').join('\n\n'),
          200,
        ),
      ),
    );
    final responses = await adapter
        .generateStream(
          [Message(role: MessageRole.user, content: 'go')],
          modelOverride: _model,
          options: _options,
        )
        .toList();
    final toolMessage = responses
        .map((r) => r.message)
        .singleWhere((m) => m.toolCalls?.isNotEmpty ?? false);
    expect(toolMessage.providerState!.data['thinking_blocks'], [
      {'type': 'thinking', 'thinking': 'plan', 'signature': 'sig-s'},
      {'type': 'redacted_thinking', 'data': 'red-s'},
    ]);
  });

  test('signed thinking replays first to the same issuer and model', () async {
    final turn = await _syncToolTurn();
    final recorder = _Recorder(_final('done'));
    await _adapter(recorder.client).generateResponse(
      [
        Message(role: MessageRole.user, content: 'go'),
        turn,
        toolResult('tu-1'),
      ],
      modelOverride: _model,
      options: _options,
    );
    final assistant = (recorder.bodies.single['messages'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((m) => m['role'] == 'assistant');
    final blocks = (assistant['content'] as List).cast<Map>();
    expect(blocks.map((b) => b['type']), [
      'thinking',
      'redacted_thinking',
      'tool_use',
    ]);
    expect(blocks.first['signature'], 'sig-1');
  });

  test('foreign issuer or model never receives signed thinking', () async {
    final turn = await _syncToolTurn();
    final history = [
      Message(role: MessageRole.user, content: 'go'),
      turn,
      toolResult('tu-1'),
    ];
    final otherInstance = _Recorder(_final('done'));
    await _adapter(otherInstance.client, instance: 'anth-2').generateResponse(
      history,
      modelOverride: _model,
      options: const LLMRequestOptions(providerInstanceId: 'anth-2'),
    );
    final otherModel = _Recorder(_final('done'));
    await _adapter(otherModel.client).generateResponse(
      history,
      modelOverride: 'claude-fixture-2',
      options: const LLMRequestOptions(providerInstanceId: _instance),
    );
    for (final body in [...otherInstance.bodies, ...otherModel.bodies]) {
      final wire = jsonEncode(body);
      expect(wire, isNot(contains('sig-1')));
      expect(wire, isNot(contains('redacted-1')));
      expect(wire, contains('tu-1'), reason: 'tool pairing is kept');
    }
  });

  test('Chat reasoning state never crosses into Anthropic thinking', () async {
    final recorder = _Recorder(_final('done'));
    await _adapter(recorder.client).generateResponse(
      [
        Message(role: MessageRole.user, content: 'go'),
        toolTurn(
          'chat-1',
          state: chatState(reasoning: 'deepseek reasoning'),
        ),
        toolResult('chat-1'),
        toolTurn('codex-1', state: codexState()),
        toolResult('codex-1'),
      ],
      modelOverride: _model,
      options: _options,
    );
    final wire = jsonEncode(recorder.bodies.single);
    expect(wire, isNot(contains('deepseek reasoning')));
    expect(wire, isNot(contains('sealed-codex')));
    expect(wire, isNot(contains('"thinking":"')));
    expect(wire, contains('chat-1'));
    expect(wire, contains('codex-1'));
  });

  test('unpaired tool_use fails before HTTP instead of being stripped',
      () async {
    final recorder = _Recorder(_final('done'));
    await expectLater(
      _adapter(recorder.client).generateResponse(
        [
          Message(role: MessageRole.user, content: 'go'),
          toolTurn('paired'),
          toolResult('paired'),
          toolTurn('orphan'),
        ],
        modelOverride: _model,
        options: _options,
      ),
      throwsA(
        isA<ProviderHistoryProjectionException>()
            .having(
              (e) => e.reasonCode,
              'reasonCode',
              ProviderHistoryProjectionException.unpairedToolCall,
            )
            .having((e) => e.affectedCount, 'affectedCount', 1)
            .having((e) => e.route, 'route', '$_instance/$_model'),
      ),
    );
    expect(recorder.bodies, isEmpty);
  });

  test('state without signed blocks is not replayed', () async {
    final recorder = _Recorder(_final('done'));
    await _adapter(recorder.client).generateResponse(
      [
        Message(role: MessageRole.user, content: 'go'),
        toolTurn(
          'tu-x',
          state: const LLMProviderState(
            namespace: 'anthropic_messages',
            issuer: '$_instance|anthropic_compatible|$_anthropicUrl',
            data: {
              'issuer_model': _model,
              'thinking_blocks': [
                {'type': 'thinking', 'thinking': 'no signature'},
              ],
            },
          ),
        ),
        toolResult('tu-x'),
      ],
      modelOverride: _model,
      options: _options,
    );
    expect(jsonEncode(recorder.bodies.single), isNot(contains('no signature')));
  });
}
