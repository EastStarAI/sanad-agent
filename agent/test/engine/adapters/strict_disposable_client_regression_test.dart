import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/adapters/provider_request_cancelled_exception.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:test/test.dart';

class _TestConfig extends Config {
  @override
  String get llmApiKey => 'test-key';
  @override
  String get llmBaseUrl => 'https://api.example.com/v1';
  @override
  String get llmModel => 'claude-haiku-4.5';
  @override
  String apiKeyFor(ProviderProfile profile) => 'test-key';
  @override
  String baseUrlFor(ProviderProfile profile) => 'https://api.example.com/v1';
}

/// A strict HTTP client that throws ClientException if send() is called after close()
/// or if close() is called while a request is in flight.
class StrictDisposableClient extends http.BaseClient {
  final http.Client _inner;
  final Completer<void> _closed = Completer<void>();
  bool isClosed = false;
  int closeCount = 0;
  int requestCount = 0;

  StrictDisposableClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (isClosed) {
      throw http.ClientException('Client is closed; cannot send request', request.url);
    }
    requestCount++;
    final completer = Completer<http.StreamedResponse>();
    _inner.send(request).then((response) {
      if (!completer.isCompleted) {
        completer.complete(response);
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    });

    _closed.future.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          http.ClientException('Client was closed during request', request.url),
        );
      }
    });

    return completer.future;
  }

  @override
  void close() {
    isClosed = true;
    closeCount++;
    if (!_closed.isCompleted) {
      _closed.complete();
    }
    _inner.close();
  }
}

void main() {
  group('StrictDisposableClient & Adapter Transport Ownership Regression', () {
    late Config config;
    late ProviderProfile profile;

    setUp(() {
      config = _TestConfig();
      profile = ProviderRegistry.findByNameOrAlias('openai')!;
    });

    test('requestClientFactory supplies fresh request-owned clients that close upon request completion', () async {
      final createdClients = <StrictDisposableClient>[];

      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        requestClientFactory: () {
          final client = StrictDisposableClient(
            MockClient((request) async {
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'role': 'assistant', 'content': 'From factory'},
                    }
                  ]
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          createdClients.add(client);
          return client;
        },
      );

      final scope1 = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-1',
        workItemId: 'work-1',
        generation: 1,
      );

      final resp1 = await adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'msg 1')],
        options: LLMRequestOptions(cancellationScope: scope1),
      );
      expect(resp1.message.content, 'From factory');
      expect(createdClients, hasLength(1));
      expect(createdClients[0].isClosed, isTrue, reason: 'request-owned client is closed upon completion');
      expect(createdClients[0].requestCount, 1);

      final scope2 = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-2',
        workItemId: 'work-2',
        generation: 2,
      );

      final resp2 = await adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'msg 2')],
        options: LLMRequestOptions(cancellationScope: scope2),
      );
      expect(resp2.message.content, 'From factory');
      expect(createdClients, hasLength(2));
      expect(createdClients[1].isClosed, isTrue, reason: 'second request-owned client is closed upon completion');
      expect(createdClients[1].requestCount, 1);
    });

    test('requestClientFactory supplies fresh clients across streaming & tool continuation without interference', () async {
      final createdClients = <StrictDisposableClient>[];
      var callIndex = 0;

      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        requestClientFactory: () {
          callIndex++;
          final currentCall = callIndex;
          final client = StrictDisposableClient(
            MockClient.streaming((request, bodyStream) async {
              if (currentCall == 1) {
                // Stream 1: returns tool call
                final sseData = [
                  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_time","arguments":"{}"}}]}}]}\n\n',
                  'data: [DONE]\n\n',
                ].join();
                return http.StreamedResponse(
                  Stream.value(utf8.encode(sseData)),
                  200,
                  headers: {'content-type': 'text/event-stream'},
                );
              } else {
                // Stream 2: tool continuation, returns final answer
                final sseData = [
                  'data: {"choices":[{"delta":{"content":"The time is 12:00 PM"}}]}\n\n',
                  'data: [DONE]\n\n',
                ].join();
                return http.StreamedResponse(
                  Stream.value(utf8.encode(sseData)),
                  200,
                  headers: {'content-type': 'text/event-stream'},
                );
              }
            }),
          );
          createdClients.add(client);
          return client;
        },
      );

      final scope = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-1',
        workItemId: 'work-1',
        generation: 1,
      );

      // First stream: tool call
      final stream1Chunks = await adapter.generateStream(
        [Message(role: MessageRole.user, content: 'what time is it?')],
        options: LLMRequestOptions(cancellationScope: scope),
      ).toList();

      expect(stream1Chunks, isNotEmpty);
      expect(createdClients, hasLength(1));
      expect(createdClients[0].isClosed, isTrue, reason: 'first streamed client closed on completion');

      // Second stream: tool continuation turn
      final stream2Chunks = await adapter.generateStream(
        [
          Message(role: MessageRole.user, content: 'what time is it?'),
          Message(role: MessageRole.assistant, content: '', toolCalls: [
            ToolCall(id: 'call_1', name: 'get_time', arguments: {}),
          ]),
          Message(role: MessageRole.tool, content: '12:00 PM', toolCallId: 'call_1'),
        ],
        options: LLMRequestOptions(cancellationScope: scope),
      ).toList();

      expect(stream2Chunks.any((c) => c.message.content?.contains('The time is 12:00 PM') ?? false), isTrue);
      expect(createdClients, hasLength(2));
      expect(createdClients[1].isClosed, isTrue, reason: 'continuation streamed client closed on completion');
    });

    test('cancelling scope 1 closes client 1, while scope 2 gets a fresh client from factory and succeeds', () async {
      final createdClients = <StrictDisposableClient>[];
      final pendingCompleter = Completer<http.Response>();

      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        requestClientFactory: () {
          final clientIndex = createdClients.length + 1;
          final client = StrictDisposableClient(
            MockClient((request) async {
              if (clientIndex == 1) {
                return pendingCompleter.future;
              }
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'role': 'assistant', 'content': 'Scope 2 success'},
                    }
                  ]
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          createdClients.add(client);
          return client;
        },
      );

      final scope1 = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-1',
        workItemId: 'work-1',
        generation: 1,
      );

      final future1 = adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'prompt 1')],
        options: LLMRequestOptions(cancellationScope: scope1),
      );

      final responseExpectation = expectLater(
        future1,
        throwsA(isA<ProviderRequestCancelledException>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(createdClients, hasLength(1));
      expect(createdClients[0].isClosed, isFalse);

      final report = await scope1.cancel();
      await responseExpectation;

      expect(report.finalState, RunCancellationState.cancelled);
      expect(createdClients[0].isClosed, isTrue, reason: 'cancelling scope 1 closes client 1');

      // Scope 2 gets a fresh client from the factory and succeeds cleanly
      final scope2 = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-2',
        workItemId: 'work-2',
        generation: 2,
      );

      final resp2 = await adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'prompt 2')],
        options: LLMRequestOptions(cancellationScope: scope2),
      );

      expect(resp2.message.content, 'Scope 2 success');
      expect(createdClients, hasLength(2));
      expect(createdClients[1].isClosed, isTrue, reason: 'client 2 closed after completion');

      if (!pendingCompleter.isCompleted) {
        pendingCompleter.complete(http.Response('{}', 200));
      }
    });

    test('unscoped adapter calls reuse client unowned without closing it', () async {
      final strictClient = StrictDisposableClient(
        MockClient((request) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'Unscoped success'},
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        client: strictClient,
      );

      // First unscoped request
      final resp1 = await adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'unscoped 1')],
        options: const LLMRequestOptions(),
      );
      expect(resp1.message.content, 'Unscoped success');
      expect(strictClient.isClosed, isFalse, reason: 'shared client not closed after unscoped call 1');
      expect(strictClient.requestCount, 1);

      // Second unscoped request on same adapter and client
      final resp2 = await adapter.generateResponse(
        [Message(role: MessageRole.user, content: 'unscoped 2')],
        options: const LLMRequestOptions(),
      );
      expect(resp2.message.content, 'Unscoped success');
      expect(strictClient.isClosed, isFalse, reason: 'shared client still open after unscoped call 2');
      expect(strictClient.requestCount, 2);
    });
  });
}
