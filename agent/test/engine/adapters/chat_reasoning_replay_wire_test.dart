/// Task 116 D1–D3 — OpenAI-compatible Chat provenance and replay, observed on
/// the actual adapter HTTP wire (MockClient carrier, synthetic payloads).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:test/test.dart';

import 'projection_fixtures.dart';

const _options = LLMRequestOptions(
  providerInstanceId: goInstance,
  thinkingDirective: OpenAiEffortDirective('max'),
);

Map<String, dynamic> _toolCallMessage({Object? reasoning = _absent}) => {
  'role': 'assistant',
  'content': null,
  if (!identical(reasoning, _absent)) 'reasoning_content': reasoning,
  'tool_calls': [
    {
      'id': 'call-1',
      'type': 'function',
      'function': {'name': 'read_file', 'arguments': '{"path":"a"}'},
    },
  ],
};

const Object _absent = Object();

Future<LLMProviderState?> _syncState({Object? reasoning = _absent}) async {
  final adapter = goAdapter(
    MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': _toolCallMessage(reasoning: reasoning),
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        200,
      ),
    ),
  );
  final response = await adapter.generateResponse(
    [Message(role: MessageRole.user, content: 'go')],
    modelOverride: deepseek,
    options: _options,
  );
  return response.message.providerState;
}

Future<LLMProviderState?> _streamState(
  List<Map<String, dynamic>> deltas,
) async {
  final adapter = goAdapter(
    MockClient(
      (_) async => http.Response(
        sse([
          for (final delta in deltas)
            {
              'choices': [
                {'delta': delta},
              ],
            },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-1',
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
  );
  final responses = await adapter
      .generateStream(
        [Message(role: MessageRole.user, content: 'go')],
        modelOverride: deepseek,
        options: _options,
      )
      .toList();
  return responses
      .map((response) => response.message.providerState)
      .whereType<LLMProviderState>()
      .lastOrNull;
}

void main() {
  group('D1 records what was received on tool-call responses', () {
    test('sync string reasoning stamps model and string observation', () async {
      final state = await _syncState(reasoning: 'plan');
      expect(state!.issuer, goIssuer, reason: 'issuer string unchanged');
      expect(state.namespace, 'openai_chat_completions');
      expect(state.data['reasoning_content'], 'plan');
      expect(state.data['issuer_model'], deepseek);
      expect(state.data['reasoning_field'], 'string');
    });

    test('sync explicit null is recorded as null, not dropped', () async {
      final state = await _syncState(reasoning: null);
      expect(state, isNotNull);
      expect(state!.issuer, goIssuer);
      expect(state.data.containsKey('reasoning_content'), isFalse);
      expect(state.data['reasoning_field'], 'null');
      expect(state.data['issuer_model'], deepseek);
    });

    test('sync absent field is recorded as absent', () async {
      final state = await _syncState();
      expect(state, isNotNull);
      expect(state!.data['reasoning_field'], 'absent');
      expect(state.data.containsKey('reasoning_content'), isFalse);
    });

    test('stream empty string, null and absent stay distinct', () async {
      final empty = await _streamState([
        {'reasoning_content': ''},
      ]);
      expect(empty!.data['reasoning_content'], '');
      expect(empty.data['reasoning_field'], 'string');

      final explicitNull = await _streamState([
        {'reasoning_content': null, 'content': null},
      ]);
      expect(explicitNull!.data['reasoning_field'], 'null');
      expect(explicitNull.data.containsKey('reasoning_content'), isFalse);

      final absent = await _streamState([
        {'content': null},
      ]);
      expect(absent!.data['reasoning_field'], 'absent');
      expect(absent.data['issuer_model'], deepseek);
    });

    test('a later null delta never downgrades streamed reasoning', () async {
      final state = await _streamState([
        {'reasoning_content': 'think'},
        {'reasoning_content': null, 'content': 'x'},
      ]);
      expect(state!.data['reasoning_content'], 'think');
      expect(state.data['reasoning_field'], 'string');
    });
  });

  group('D2 replays reasoning only to the same route and model', () {
    test('Kimi reasoning on one instance never reaches DeepSeek', () async {
      final recorder = WireRecorder();
      await goAdapter(recorder.client, modelsDev: fixtureModelsDev())
          .generateResponse(
            [
              Message(role: MessageRole.user, content: 'go'),
              toolTurn('k1', state: chatState(model: kimi, reasoning: 'kimi')),
              toolResult('k1'),
              toolTurn(
                'd1',
                state: chatState(reasoning: 'deep', field: 'string'),
              ),
              toolResult('d1'),
            ],
            modelOverride: deepseek,
            options: _options,
          );
      final turns = assistantToolWire(recorder.lastMessages);
      expect(turns[0].containsKey('reasoning_content'), isFalse);
      expect(turns[1]['reasoning_content'], 'deep');
    });

    test('legacy state falls back to the stored model', () async {
      final recorder = WireRecorder();
      await goAdapter(recorder.client).generateResponse(
        [
          Message(role: MessageRole.user, content: 'go'),
          toolTurn(
            'legacy-kimi',
            state: chatState(model: null, reasoning: 'kimi'),
            metadata: {'model': kimi},
          ),
          toolResult('legacy-kimi'),
          toolTurn(
            'legacy-deep',
            state: chatState(model: null, reasoning: 'deep'),
            metadata: {
              'model': 'stale-legacy-value',
              'context_usage': {'model_id': deepseek},
            },
          ),
          toolResult('legacy-deep'),
          toolTurn(
            'legacy-unknown',
            state: chatState(model: null, reasoning: 'unknown'),
          ),
          toolResult('legacy-unknown'),
        ],
        modelOverride: deepseek,
        options: _options,
      );
      final turns = assistantToolWire(recorder.lastMessages);
      expect(turns[0].containsKey('reasoning_content'), isFalse);
      expect(turns[1]['reasoning_content'], 'deep');
      expect(
        turns[2].containsKey('reasoning_content'),
        isFalse,
        reason: 'missing provenance is foreign, never replayed',
      );
    });

    test('aggregator reasoning_details stay with the producing model', () async {
      final recorder = WireRecorder();
      const issuer =
          'or-1|openai_compatible|https://openrouter.ai/api/v1';
      await goAdapter(
        recorder.client,
        modelsDev: fixtureModelsDev(),
        instance: 'or-1',
        profileName: 'openrouter',
        baseUrl: 'https://openrouter.ai/api/v1',
      ).generateResponse(
        [
          Message(role: MessageRole.user, content: 'go'),
          toolTurn(
            'a1',
            state: chatState(
              issuer: issuer,
              model: 'vendor/model-a',
              details: [
                {'type': 'reasoning.encrypted', 'data': 'sealed-a'},
              ],
            ),
          ),
          toolResult('a1'),
          toolTurn(
            'b1',
            state: chatState(
              issuer: issuer,
              model: 'vendor/model-b',
              details: [
                {'type': 'reasoning.encrypted', 'data': 'sealed-b'},
              ],
            ),
          ),
          toolResult('b1'),
        ],
        modelOverride: 'vendor/model-b',
        options: const LLMRequestOptions(providerInstanceId: 'or-1'),
      );
      final turns = assistantToolWire(recorder.lastMessages);
      expect(turns[0].containsKey('reasoning_details'), isFalse);
      expect(turns[1]['reasoning_details'], [
        {'type': 'reasoning.encrypted', 'data': 'sealed-b'},
      ]);
    });
  });

  group('D3 conservative route policy sends exactly what was recorded', () {
    test('same-route empty string is kept verbatim', () async {
      final recorder = WireRecorder();
      await goAdapter(recorder.client, modelsDev: fixtureModelsDev())
          .generateResponse(
            [
              Message(role: MessageRole.user, content: 'go'),
              toolTurn('e1', state: chatState(reasoning: '', field: 'string')),
              toolResult('e1'),
            ],
            modelOverride: deepseek,
            options: _options,
          );
      expect(assistantToolWire(recorder.lastMessages).single, containsPair(
        'reasoning_content',
        '',
      ));
    });

    test('same-route recorded null is echoed only to an echo route', () async {
      Message turn() =>
          toolTurn('n1', state: chatState(field: 'null'));
      final echo = WireRecorder();
      await goAdapter(echo.client, modelsDev: fixtureModelsDev())
          .generateResponse(
            [Message(role: MessageRole.user, content: 'go'), turn(), toolResult('n1')],
            modelOverride: deepseek,
            options: _options,
          );
      final echoed = assistantToolWire(echo.lastMessages).single;
      expect(echoed.containsKey('reasoning_content'), isTrue);
      expect(echoed['reasoning_content'], '');

      // Without models.dev evidence the route is strict: no key is sent.
      final strict = WireRecorder();
      await goAdapter(strict.client).generateResponse(
        [Message(role: MessageRole.user, content: 'go'), turn(), toolResult('n1')],
        modelOverride: deepseek,
        options: _options,
      );
      expect(
        assistantToolWire(strict.lastMessages).single.containsKey(
          'reasoning_content',
        ),
        isFalse,
      );
    });

    test('foreign and unrecorded tool turns are never padded or relabelled',
        () async {
      final recorder = WireRecorder();
      await goAdapter(recorder.client, modelsDev: fixtureModelsDev())
          .generateResponse(
            [
              Message(role: MessageRole.user, content: 'go'),
              Message(
                role: MessageRole.assistant,
                content: '',
                reasoning: 'visible codex summary',
                toolCalls: [call('c1')],
                providerState: codexState(),
                metadata: {'model': codexModel},
              ),
              toolResult('c1'),
              toolTurn('c2', metadata: {'model': codexModel}),
              toolResult('c2'),
              Message(role: MessageRole.user, content: 'continue'),
              toolTurn('d1', state: chatState(field: 'absent')),
              toolResult('d1'),
            ],
            modelOverride: deepseek,
            options: _options,
          );
      final wire = jsonEncode(recorder.lastMessages);
      final turns = assistantToolWire(recorder.lastMessages);
      expect(turns, hasLength(3));
      expect(turns[0].containsKey('reasoning_content'), isFalse);
      expect(turns[1].containsKey('reasoning_content'), isFalse);
      expect(turns[0].containsKey('reasoning_details'), isFalse);
      expect(turns[1].containsKey('reasoning_details'), isFalse);
      expect(turns[2]['reasoning_content'], '');
      expect(wire, isNot(contains('sealed-codex')));
      expect(wire, isNot(contains('visible codex summary')));
    });

    test('minimal zero-reasoning tool sequence replays as recorded', () async {
      // Turn 1: stream a genuine same-route zero-reasoning tool call.
      final produced = goAdapter(
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
                          'id': 'z1',
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
      final responses = await produced
          .generateStream(
            [Message(role: MessageRole.user, content: 'go')],
            modelOverride: deepseek,
            options: _options,
          )
          .toList();
      final toolMessage = responses
          .map((r) => r.message)
          .singleWhere((m) => m.toolCalls?.isNotEmpty ?? false);
      expect(toolMessage.providerState!.data['reasoning_field'], 'absent');

      // Turn 2: the next request carries the recorded shape, nothing padded.
      final recorder = WireRecorder();
      await goAdapter(recorder.client, modelsDev: fixtureModelsDev())
          .generateResponse(
            [
              Message(role: MessageRole.user, content: 'go'),
              toolMessage,
              toolResult('z1'),
            ],
            modelOverride: deepseek,
            options: _options,
          );
      expect(
        assistantToolWire(recorder.lastMessages).single['reasoning_content'],
        '',
      );
    });

    test('replica of the reported 136-assistant history keeps shape counts',
        () async {
      final history = <Message>[
        Message(role: MessageRole.system, content: 'system'),
        Message(role: MessageRole.user, content: 'user 1'),
      ];
      var id = 0;
      void add(Message Function(String id) build, int count) {
        for (var i = 0; i < count; i++) {
          final callId = 'r${id++}';
          history
            ..add(build(callId))
            ..add(toolResult(callId));
        }
      }

      // Earlier user turns: foreign Codex history (58 with state, 22 without).
      add((c) => toolTurn(c, state: codexState()), 34);
      history.add(Message(role: MessageRole.user, content: 'user 2'));
      add((c) => toolTurn(c, state: codexState()), 24);
      add((c) => toolTurn(c, metadata: {'model': codexModel}), 22);
      history.add(Message(role: MessageRole.user, content: 'user 3'));
      // Current user turn: same-route DeepSeek history.
      add((c) => toolTurn(c, state: chatState(reasoning: 'r$c')), 39);
      add((c) => toolTurn(c, state: chatState(reasoning: '')), 3);
      add((c) => toolTurn(c, state: chatState(field: 'absent')), 14);
      // 136 assistant tool turns as reported (one result each here; the
      // reported dump had 160 results across parallel calls).
      expect(history.length, 2 + 136 * 2 + 2);

      final recorder = WireRecorder();
      final adapter = goAdapter(recorder.client, modelsDev: fixtureModelsDev());
      final measurement = await adapter.measureInput(
        history,
        modelOverride: deepseek,
        options: _options,
      );
      expect(measurement, isNotNull);
      await adapter.generateResponse(
        history,
        modelOverride: deepseek,
        options: _options,
      );
      final turns = assistantToolWire(recorder.lastMessages);
      expect(turns, hasLength(136));
      final withField = turns.where((t) => t.containsKey('reasoning_content'));
      expect(withField, hasLength(56));
      expect(
        withField.where((t) => t['reasoning_content'] == ''),
        hasLength(17),
      );
      expect(turns.length - withField.length, 80);
    });
  });
}
