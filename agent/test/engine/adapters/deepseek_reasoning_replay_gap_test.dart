/// Task 131 — same-route thinking-mode tool turns must always replay a
/// `reasoning_content` key on an echo-required Chat route.
///
/// The reported live shape (OpenCode Go `deepseek-v4.1-flash`, thinking `max`):
/// 27 assistant messages, all with `tool_calls`; 24 replayed
/// `reasoning_content` (12 of them `""`) and 3 replayed no key at all, so the
/// provider rejected the whole request with "The reasoning_content in the
/// thinking mode must be passed back to the API".
///
/// Every payload here is synthetic and observed on the actual adapter HTTP body
/// through a mock carrier; no live provider, credential or Home is involved.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/context/compaction_tail_selector.dart';
import 'package:sanad_agent/engine/context/compaction_tool_pruner.dart';
import 'package:test/test.dart';

import 'projection_fixtures.dart';

const _thinkingMax = LLMRequestOptions(
  providerInstanceId: goInstance,
  thinkingDirective: OpenAiEffortDirective('max'),
);

const _thinkingOff = LLMRequestOptions(
  providerInstanceId: goInstance,
  thinkingDirective: ThinkingToggleDirective(enabled: false),
);

const _absent = Object();

Map<String, dynamic> _toolCallPayload({Object? reasoning = _absent}) => {
  'role': 'assistant',
  'content': null,
  if (!identical(reasoning, _absent)) 'reasoning_content': reasoning,
  'tool_calls': [
    {
      'id': 'c-1',
      'type': 'function',
      'function': {'name': 'read_file', 'arguments': '{"path":"a"}'},
    },
  ],
};

/// One produced assistant tool message, exactly as the adapter returns it.
Future<Message> _producedSync({Object? reasoning = _absent}) async {
  final adapter = goAdapter(
    MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': _toolCallPayload(reasoning: reasoning),
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        200,
      ),
    ),
    modelsDev: fixtureModelsDev(),
  );
  final response = await adapter.generateResponse(
    [Message(role: MessageRole.user, content: 'go')],
    modelOverride: deepseek,
    options: _thinkingMax,
  );
  return response.message;
}

/// A streamed tool-call-only turn: no reasoning delta is ever delivered.
Future<Message> _producedStream() async {
  final adapter = goAdapter(
    MockClient(
      (_) async => http.Response(
        sse([
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'c-1',
                      'function': {'name': 'read_file', 'arguments': '{}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          },
        ]),
        200,
      ),
    ),
    modelsDev: fixtureModelsDev(),
  );
  final responses = await adapter
      .generateStream(
        [Message(role: MessageRole.user, content: 'go')],
        modelOverride: deepseek,
        options: _thinkingMax,
      )
      .toList();
  return responses
      .map((response) => response.message)
      .singleWhere((message) => message.toolCalls?.isNotEmpty ?? false);
}

/// Dispatches [history] and returns the actual Chat `messages` array.
Future<List<Map<String, dynamic>>> _dispatch(
  List<Message> history, {
  String model = deepseek,
  LLMRequestOptions options = _thinkingMax,
  bool echoRoute = true,
}) async {
  final recorder = WireRecorder();
  final adapter = BaseOpenAIAdapter(
    FixedRouteConfig(goBaseUrl),
    ProviderRegistry.findByNameOrAlias('opencode-go')!,
    client: recorder.client,
    modelsDevService: echoRoute ? fixtureModelsDev() : null,
    providerInstanceId: goInstance,
  );
  await adapter.generateResponse(
    history,
    modelOverride: model,
    options: options,
  );
  return recorder.lastMessages;
}

void main() {
  group('the reported 27-assistant history', () {
    test('every same-route tool turn replays a reasoning_content key', () async {
      final history = <Message>[
        Message(role: MessageRole.system, content: 'system'),
        Message(role: MessageRole.user, content: 'start'),
      ];
      final expected = <String>[];
      var id = 0;
      void add(String reasoning, int count, {required bool hasField}) {
        for (var i = 0; i < count; i++) {
          final callId = 'r${id++}';
          history
            ..add(
              toolTurn(
                callId,
                state: hasField
                    ? chatState(reasoning: reasoning, field: 'string')
                    : chatState(field: 'absent'),
              ),
            )
            ..add(toolResult(callId));
          expected.add(hasField ? reasoning : '');
        }
      }

      // 12 reasoning strings, 12 empty strings, 3 with no field at all — the
      // shape counts reported from the rejected request body.
      add('thinking', 12, hasField: true);
      add('', 12, hasField: true);
      add('', 3, hasField: false);
      history.add(Message(role: MessageRole.user, content: 'continue'));

      final messages = await _dispatch(history);
      final turns = assistantToolWire(messages);
      expect(turns, hasLength(27));
      for (var index = 0; index < turns.length; index++) {
        expect(
          turns[index].containsKey('reasoning_content'),
          isTrue,
          reason: 'assistant turn $index must carry the key',
        );
        expect(turns[index]['reasoning_content'], isA<String>());
        expect(turns[index]['reasoning_content'], expected[index]);
      }
    });

    test('wire measurement builds the same projection as dispatch', () async {
      final history = <Message>[
        Message(role: MessageRole.user, content: 'start'),
      ];
      for (var i = 0; i < 3; i++) {
        history
          ..add(toolTurn('m$i', state: chatState(field: 'absent')))
          ..add(toolResult('m$i'));
      }
      final adapter = goAdapter(
        WireRecorder().client,
        modelsDev: fixtureModelsDev(),
      );
      final measured = await adapter.buildRequestBody(
        history,
        resolvedModel: deepseek,
        options: _thinkingMax,
        enforceProjection: false,
      );
      final dispatched = await adapter.buildRequestBody(
        history,
        resolvedModel: deepseek,
        options: _thinkingMax,
      );
      final measuredTurns = assistantToolWire(
        (measured['messages'] as List).cast<Map<String, dynamic>>(),
      );
      expect(measuredTurns, hasLength(3));
      for (final turn in measuredTurns) {
        expect(turn['reasoning_content'], '');
      }
      expect(
        jsonEncode(measured['messages']),
        jsonEncode(dispatched['messages']),
        reason: 'measurement must price the wire that will be dispatched',
      );
    });
  });

  group('producing shapes', () {
    test('sync response without the field replays an empty key', () async {
      final message = await _producedSync();
      expect(message.providerState!.data['reasoning_field'], 'absent');

      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          message,
          toolResult('c-1'),
        ]),
      );
      expect(turns.single.containsKey('reasoning_content'), isTrue);
      expect(turns.single['reasoning_content'], '');
    });

    test('streamed tool-call-only deltas replay an empty key', () async {
      final message = await _producedStream();
      expect(message.providerState!.data['reasoning_field'], 'absent');

      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          message,
          toolResult('c-1'),
        ]),
      );
      expect(turns.single['reasoning_content'], '');
    });

    test('explicit null replays the string shape, never a JSON null', () async {
      final message = await _producedSync(reasoning: null);
      expect(message.providerState!.data['reasoning_field'], 'null');

      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          message,
          toolResult('c-1'),
        ]),
      );
      expect(turns.single.containsKey('reasoning_content'), isTrue);
      expect(turns.single['reasoning_content'], isA<String>());
      expect(turns.single['reasoning_content'], '');
    });

    test('reasoning_details-only response still replays the key', () async {
      final adapter = goAdapter(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    ..._toolCallPayload(),
                    'reasoning_details': [
                      {'type': 'reasoning.text', 'text': 'plans'},
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            }),
            200,
          ),
        ),
        modelsDev: fixtureModelsDev(),
      );
      final response = await adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'go')],
        modelOverride: deepseek,
        options: _thinkingMax,
      );
      final message = response.message;
      expect(
        message.providerState!.data.containsKey('reasoning_content'),
        isFalse,
      );

      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          message,
          toolResult('c-1'),
        ]),
      );
      expect(turns.single['reasoning_content'], '');
      expect(turns.single['reasoning_details'], [
        {'type': 'reasoning.text', 'text': 'plans'},
      ]);
    });

    test('persisted history round trip keeps the guarantee', () async {
      final message = await _producedSync();
      final restored = Message.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          restored,
          toolResult('c-1'),
        ]),
      );
      expect(turns.single['reasoning_content'], '');
    });

    test('compaction projection keeps the guarantee', () async {
      final message = await _producedSync();
      final pruned = const CompactionToolPruner().pruneOversizedForProjection([
        IndexedConversationMessage(rowId: 1, message: message),
        IndexedConversationMessage(rowId: 2, message: toolResult('c-1')),
      ]);
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          pruned.first.message,
          pruned.last.message,
        ]),
      );
      expect(turns.single['reasoning_content'], '');
    });
  });

  group('unchanged boundaries (Task 116)', () {
    test('a recorded string is still replayed verbatim', () async {
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          toolTurn('s1', state: chatState(reasoning: 'kept', field: 'string')),
          toolResult('s1'),
          toolTurn('s2', state: chatState(reasoning: '', field: 'string')),
          toolResult('s2'),
        ]),
      );
      expect(turns[0]['reasoning_content'], 'kept');
      expect(turns[1]['reasoning_content'], '');
    });

    test('thinking explicitly off sends only what was recorded', () async {
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          toolTurn('o1', state: chatState(field: 'absent')),
          toolResult('o1'),
          toolTurn('o2', state: chatState(field: 'null')),
          toolResult('o2'),
        ], options: _thinkingOff),
      );
      expect(turns[0].containsKey('reasoning_content'), isFalse);
      expect(turns[1].containsKey('reasoning_content'), isFalse);
    });

    test('a strict route without an echo declaration stays unpadded', () async {
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          toolTurn('s1', state: chatState(field: 'absent')),
          toolResult('s1'),
        ], echoRoute: false),
      );
      expect(turns.single.containsKey('reasoning_content'), isFalse);
    });

    test('a plain assistant text turn keeps its recorded shape', () async {
      final messages = await _dispatch([
        Message(role: MessageRole.user, content: 'go'),
        Message(
          role: MessageRole.assistant,
          content: 'answer',
          providerState: chatState(field: 'absent'),
        ),
        Message(role: MessageRole.user, content: 'next'),
      ]);
      final textTurn = messages.singleWhere(
        (message) => message['role'] == 'assistant',
      );
      expect(textTurn.containsKey('reasoning_content'), isFalse);
    });

    test('another model on the same instance is never padded', () async {
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          toolTurn('k1', state: chatState(model: kimi, field: 'absent')),
          toolResult('k1'),
        ]),
      );
      expect(turns.single.containsKey('reasoning_content'), isFalse);
    });

    test('another endpoint on the same model is never padded', () async {
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          toolTurn(
            'x1',
            state: chatState(
              issuer: 'go-2|openai_compatible|https://opencode.ai/zen/go/v1',
              field: 'absent',
            ),
          ),
          toolResult('x1'),
        ]),
      );
      expect(turns.single.containsKey('reasoning_content'), isFalse);
    });

    test('foreign protocol state and unrecorded turns stay unpadded', () async {
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          toolTurn('c1', state: codexState()),
          toolResult('c1'),
          toolTurn('u1', metadata: {'model': codexModel}),
          toolResult('u1'),
          toolTurn('n1'),
          toolResult('n1'),
        ]),
      );
      for (final turn in turns) {
        expect(turn.containsKey('reasoning_content'), isFalse);
      }
    });

    test('the same history on another route is not padded either', () async {
      final message = await _producedSync();
      final turns = assistantToolWire(
        await _dispatch([
          Message(role: MessageRole.user, content: 'go'),
          message,
          toolResult('c-1'),
        ], model: kimi),
      );
      expect(turns.single.containsKey('reasoning_content'), isFalse);
    });
  });
}
