import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/cli/cli.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import '../support/isolated_sanad_test_home.dart';

/// In-memory mock WebSocket implementing the minimal interface required by LocalGatewayCliClient.
class MockWebSocket implements WebSocket {
  final _incomingController = StreamController<dynamic>();
  final List<String> sentMessages = [];
  bool _closed = false;
  final Completer<void> _doneCompleter = Completer<void>();

  void emitFromServer(dynamic data) {
    if (!_closed) {
      _incomingController.add(data);
    }
  }

  void simulateClose([int? closeCode, String? closeReason]) {
    if (!_closed) {
      _closed = true;
      _incomingController.close();
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  void simulateError(Object error) {
    if (!_closed) {
      _incomingController.addError(error);
    }
  }

  @override
  void add(dynamic data) {
    if (_closed) throw const SocketException('Socket closed');
    sentMessages.add(data.toString());
  }

  @override
  Future close([int? code, String? reason]) async {
    simulateClose(code, reason);
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incomingController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future get done => _doneCompleter.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  useIsolatedSanadTestHome();
  group('CliEvent parsing', () {
    test('parses register_success', () {
      final event = CliEvent.fromJson({
        'type': 'register_success',
        'platform_id': 'local_daemon',
        'url': 'http://127.0.0.1:58085',
      });

      expect(event, isA<CliConnectionRegisteredEvent>());
      final reg = event as CliConnectionRegisteredEvent;
      expect(reg.platformId, 'local_daemon');
      expect(reg.gatewayUrl, 'http://127.0.0.1:58085');
    });

    test('parses capabilities', () {
      final event = CliEvent.fromJson({
        'type': 'capabilities',
        'request_id': 'req-1',
        'payload': {'supports_model_change': true, 'supports_stop': true},
      });

      expect(event, isA<CliCapabilitiesEvent>());
      final cap = event as CliCapabilitiesEvent;
      expect(cap.requestId, 'req-1');
      expect(cap.capabilities['supports_stop'], isTrue);
    });

    test('parses thought_stream / assistant chunks', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'session_id': 's1',
        'run_id': 'r1',
        'event_id': 'ev1',
        'event': {
          'type': 'thought_stream',
          'session_id': 's1',
          'payload': {'delta': 'Hello world', 'is_first': true},
        },
      });

      expect(event, isA<CliAssistantChunkEvent>());
      final chunk = event as CliAssistantChunkEvent;
      expect(chunk.content, 'Hello world');
      expect(chunk.isFirstChunk, isTrue);
      expect(chunk.sessionId, 's1');
      expect(chunk.runId, 'r1');
      expect(chunk.eventId, 'ev1');
    });

    test('parses reasoning_stream', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'event': {
          'type': 'reasoning_stream',
          'payload': {'delta': 'Analyzing code...', 'is_first': true},
        },
      });

      expect(event, isA<CliReasoningDeltaEvent>());
      final reasoning = event as CliReasoningDeltaEvent;
      expect(reasoning.content, 'Analyzing code...');
      expect(reasoning.isFirstChunk, isTrue);
    });

    test('parses tool_call', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'event': {
          'type': 'tool_call',
          'payload': {
            'tool_name': 'read_file',
            'tool_call_id': 'call-123',
            'arguments': {'path': 'lib/main.dart'},
          },
        },
      });

      expect(event, isA<CliToolCallEvent>());
      final tool = event as CliToolCallEvent;
      expect(tool.toolName, 'read_file');
      expect(tool.toolCallId, 'call-123');
      expect(tool.arguments['path'], 'lib/main.dart');
    });

    test('parses tool_result', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'event': {
          'type': 'tool_result',
          'payload': {
            'tool_name': 'read_file',
            'tool_call_id': 'call-123',
            'result': 'void main() {}',
            'is_error': false,
          },
        },
      });

      expect(event, isA<CliToolResultEvent>());
      final res = event as CliToolResultEvent;
      expect(res.toolName, 'read_file');
      expect(res.toolCallId, 'call-123');
      expect(res.result, 'void main() {}');
      expect(res.isError, isFalse);
    });

    test('parses tool_permission_request with questions', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'event': {
          'type': 'tool_permission_request',
          'payload': {
            'request_id': 'perm-1',
            'tool_name': 'system_ask_user',
            'permission_class': 'interactive',
            'questions': [
              {
                'question': 'Which database?',
                'options': ['sqlite', 'postgres'],
              },
            ],
          },
        },
      });

      expect(event, isA<CliPermissionRequestEvent>());
      final perm = event as CliPermissionRequestEvent;
      expect(perm.requestId, 'perm-1');
      expect(perm.isUserQuestion, isTrue);
      expect(perm.questions.length, 1);
    });

    test('parses final_answer / turn_complete', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'event': {
          'type': 'final_answer',
          'payload': {
            'content': 'Task accomplished.',
            'model': 'gpt-4o',
            'provider': 'openai',
            'usage': {'total_tokens': 150},
          },
        },
      });

      expect(event, isA<CliTurnCompleteEvent>());
      final complete = event as CliTurnCompleteEvent;
      expect(complete.finalMessage, 'Task accomplished.');
      expect(complete.model, 'gpt-4o');
      expect(complete.provider, 'openai');
      expect(complete.usage?['total_tokens'], 150);
    });

    test('parses stopped canonical event as CliTurnCancelledEvent', () {
      final event = CliEvent.fromJson({
        'type': 'device_event',
        'event': {
          'type': 'stopped',
          'session_id': 'session-stopped-1',
          'run_id': 'run-123',
          'payload': {
            'session_id': 'session-stopped-1',
            'run_id': 'run-123',
            'reason': 'Session execution stopped',
          },
        },
      });

      expect(event, isA<CliTurnCancelledEvent>());
      final cancelled = event as CliTurnCancelledEvent;
      expect(cancelled.sessionId, 'session-stopped-1');
      expect(cancelled.runId, 'run-123');
      expect(cancelled.reason, 'Session execution stopped');
    });

    test('parses top-level stopped event as CliTurnCancelledEvent', () {
      final event = CliEvent.fromJson({
        'type': 'stopped',
        'session_id': 'session-stopped-2',
        'run_id': 'run-456',
        'payload': {
          'session_id': 'session-stopped-2',
          'reason': 'Execution stopped by user',
        },
      });

      expect(event, isA<CliTurnCancelledEvent>());
      final cancelled = event as CliTurnCancelledEvent;
      expect(cancelled.sessionId, 'session-stopped-2');
      expect(cancelled.reason, 'Execution stopped by user');
    });
  });

  group('LocalGatewayCliClient', () {
    late MockWebSocket mockSocket;
    late Map<String, dynamic> capturedHeaders;
    late Uri capturedUri;
    late Set<String> answeredHistoryIds;

    LocalGatewayCliClient createClient({
      Uri? uri,
      String token = 'test-secret-token',
      bool autoReconnect = false,
      Duration connectTimeout = const Duration(seconds: 2),
      Duration requestTimeout = const Duration(seconds: 2),
    }) {
      mockSocket = MockWebSocket();
      answeredHistoryIds = <String>{};
      return LocalGatewayCliClient(
        gatewayUri: uri ?? Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: token,
        autoReconnect: autoReconnect,
        connectTimeout: connectTimeout,
        requestTimeout: requestTimeout,
        connector: (u, {headers, timeout}) async {
          capturedUri = u;
          capturedHeaders = headers ?? {};
          return mockSocket;
        },
      );
    }

    test('connects and sends mandatory authentication headers', () async {
      final client = createClient(token: 'my-token-123');

      expect(client.isConnected, isFalse);
      expect(client.state, CliConnectionState.disconnected);

      await client.connect();

      expect(client.isConnected, isTrue);
      expect(client.state, CliConnectionState.connected);
      expect(capturedUri.path, '/gateway');
      expect(capturedHeaders['x-sanad-gateway-token'], 'my-token-123');
      expect(capturedHeaders['x-sanad-local-token'], 'my-token-123');
      expect(capturedHeaders['authorization'], 'Bearer my-token-123');

      await client.dispose();
    });

    test('dispatches think command with canonical envelope', () async {
      final client = createClient();
      await client.connect();

      final reqId = await client.think(
        sessionId: 'session-42',
        message: 'Hello, Sanad!',
        workspaceId: 'ws-root',
        model: 'claude-3-5',
        thinkingMode: 'deep',
      );

      expect(mockSocket.sentMessages.length, 1);
      final sent =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      expect(sent['type'], 'execute_command');
      expect(sent['command'], 'think');
      expect(sent['request_id'], reqId);

      final payload = sent['payload'] as Map<String, dynamic>;
      expect(payload['session_id'], 'session-42');
      expect(payload['message'], 'Hello, Sanad!');
      expect(payload['workspace_id'], 'ws-root');
      expect(payload['model'], 'claude-3-5');
      expect(payload['thinking_mode'], 'deep');

      await client.dispose();
    });

    test(
      'dispatchTurnRequest preserves independent workspace and execution root',
      () async {
        final client = createClient();
        await client.connect();

        await client.dispatchTurnRequest(
          const AgentTurnRequest(
            sessionId: 'session-workspace-precedence',
            message: 'Hello',
            workspaceId: 'ws-authoritative',
            requestId: 'request-workspace-precedence',
            metadata: {'execution_root': 'isolated-worktree'},
          ),
        );

        final sent =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final payload = sent['payload'] as Map<String, dynamic>;
        final sessionMetadata =
            payload['session_metadata'] as Map<String, dynamic>;
        expect(payload['workspace_id'], equals('ws-authoritative'));
        expect(
          sessionMetadata,
          containsPair('workspace_id', 'ws-authoritative'),
        );
        expect(
          sessionMetadata,
          containsPair('execution_root', 'isolated-worktree'),
        );

        await client.dispose();
      },
    );

    /// Answers every not-yet-answered `get_session_history` query, so each
    /// ordered state re-read of [LocalGatewayCliClient.stop] gets exactly one
    /// deterministic response.
    void answerPendingHistory(
      Map<String, dynamic> Function(Map<String, dynamic> command) payloadFor,
    ) {
      for (final raw in mockSocket.sentMessages) {
        final command = jsonDecode(raw) as Map<String, dynamic>;
        if (command['command'] != 'get_session_history') continue;
        final requestId = command['request_id']?.toString();
        if (requestId == null || !answeredHistoryIds.add(requestId)) continue;
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'request_id': requestId,
            'payload': {
              'session_id': (command['payload'] as Map)['session_id'],
              ...payloadFor(command),
            },
          }),
        );
      }
    }

    List<Map<String, dynamic>> sentCommands() => mockSocket.sentMessages
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .toList();

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 10));

    test('dispatches steer and waits for authoritative scoped stop', () async {
      final client = createClient();
      await client.connect();

      await client.steer(
        sessionId: 'session-42',
        message: 'Cancel that action',
      );
      expect(mockSocket.sentMessages.length, 1);
      final steerMsg =
          jsonDecode(mockSocket.sentMessages[0]) as Map<String, dynamic>;
      expect(steerMsg['command'], 'steer');
      expect(steerMsg['payload']['message'], 'Cancel that action');

      var stopCompleted = false;
      final stopFuture = client
          .stop(
            sessionId: 'session-42',
            runId: 'run-1',
            stopPollInterval: Duration.zero,
          )
          .then((_) => stopCompleted = true);
      await settle();

      // The stop is dispatched immediately so an interruption is never delayed
      // behind an inspection round trip.
      final stopMsg = sentCommands()[1];
      expect(stopMsg['command'], 'stop');
      expect(stopMsg['payload']['session_id'], 'session-42');
      expect(stopMsg['payload']['run_id'], 'run-1');
      expect(stopMsg['payload']['request_id'], stopMsg['request_id']);
      expect(sentCommands()[2]['command'], 'get_session_history');

      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'stopped',
          'session_id': 'another-session',
          'payload': {'session_id': 'another-session'},
        }),
      );
      await settle();
      expect(stopCompleted, isFalse);

      answerPendingHistory(
        (_) => {
          'in_flight': {'status': 'running', 'run_id': 'run-1'},
        },
      );
      await settle();
      expect(
        stopCompleted,
        isFalse,
        reason: 'a running projection is never confirmation',
      );

      answerPendingHistory((_) => {'in_flight': null});
      await settle();

      await stopFuture;
      expect(stopCompleted, isTrue);
      await client.dispose();
    });

    test('never treats a stopped event as proof that the session is idle', () async {
      final client = createClient();
      await client.connect();

      var stopCompleted = false;
      final stopFuture = client
          .stop(sessionId: 'session-42', stopPollInterval: Duration.zero)
          .then((_) => stopCompleted = true);
      await settle();
      expect(sentCommands()[0]['command'], 'stop');

      answerPendingHistory(
        (_) => {
          'in_flight': {'status': 'running', 'run_id': 'run-1'},
        },
      );
      await settle();

      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'stopped',
          'session_id': 'session-42',
          'run_id': 'run-1',
          'payload': {'session_id': 'session-42'},
        }),
      );
      await settle();
      expect(
        stopCompleted,
        isFalse,
        reason: 'the acknowledgement must be re-read from state',
      );

      answerPendingHistory((_) => {'in_flight': null});
      await settle();

      await stopFuture;
      expect(stopCompleted, isTrue);
      await client.dispose();
    });

    test('treats an already-idle scoped stop as idempotent', () async {
      final client = createClient();
      await client.connect();

      final stopFuture = client.stop(sessionId: 'session-idle');
      await settle();
      answerPendingHistory(
        (_) => {'in_flight': null, 'pending_permission_request': null},
      );

      await stopFuture;
      expect(
        sentCommands()
            .where((command) => command['command'] == 'get_session_history'),
        hasLength(1),
        reason: 'an idle session is confirmed with a single state read',
      );
      await client.dispose();
    });

    test('fails with stop_timeout while the session keeps running', () async {
      final client = createClient(
        requestTimeout: const Duration(milliseconds: 80),
      );
      await client.connect();

      final answerTimer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => answerPendingHistory(
          (_) => {
            'in_flight': {'status': 'running', 'run_id': 'run-1'},
          },
        ),
      );
      addTearDown(answerTimer.cancel);

      await expectLater(
        client.stop(
          sessionId: 'session-42',
          stopPollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(
          isA<CliClientException>().having(
            (error) => error.code,
            'code',
            'stop_timeout',
          ),
        ),
      );
      await client.dispose();
    });

    test('dispatches respondPermission command', () async {
      final client = createClient();
      await client.connect();

      await client.respondPermission(
        requestId: 'perm-99',
        allowed: true,
        scope: 'workspace',
        decision: 'allow',
      );

      expect(mockSocket.sentMessages.length, 1);
      final msg =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      expect(msg['command'], 'tool_permission_response');
      expect(msg['payload']['request_id'], 'perm-99');
      expect(msg['payload']['allowed'], isTrue);
      expect(msg['payload']['scope'], 'workspace');

      await client.dispose();
    });

    test(
      'dispatches respondAnswer query with session and request correlation',
      () async {
        final client = createClient();
        await client.connect();

        final answerFuture = client.respondAnswer(
          sessionId: 'sess-ask-1',
          requestId: 'req-ask-1',
          answer: 'Target PostgreSQL',
        );

        expect(mockSocket.sentMessages.length, 1);
        final sent =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        expect(sent['command'], equals('tool_permission_response'));
        expect(sent['payload']['session_id'], equals('sess-ask-1'));
        expect(sent['payload']['request_id'], equals('req-ask-1'));
        expect(sent['payload']['answer'], equals('Target PostgreSQL'));
        expect(sent['payload']['allowed'], isTrue);

        final rpcReqId = sent['request_id'] as String;
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'tool_permission_resolved',
            'request_id': rpcReqId,
            'payload': {
              'session_id': 'sess-ask-1',
              'outcome': 'resolved',
              'success': true,
            },
          }),
        );

        final result = await answerFuture;
        expect(result['payload']['outcome'], equals('resolved'));

        await client.dispose();
      },
    );

    test(
      'dispatches respondToolPermission query with decision and scope',
      () async {
        final client = createClient();
        await client.connect();

        final permFuture = client.respondToolPermission(
          sessionId: 'sess-perm-1',
          requestId: 'req-perm-1',
          allowed: false,
          scope: 'session',
          decision: 'deny',
          comment: 'Denied by user',
        );

        expect(mockSocket.sentMessages.length, 1);
        final sent =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        expect(sent['command'], equals('tool_permission_response'));
        expect(sent['payload']['session_id'], equals('sess-perm-1'));
        expect(sent['payload']['request_id'], equals('req-perm-1'));
        expect(sent['payload']['allowed'], isFalse);
        expect(sent['payload']['decision'], equals('deny'));
        expect(sent['payload']['scope'], equals('session'));
        expect(sent['payload']['comment'], equals('Denied by user'));

        final rpcReqId = sent['request_id'] as String;
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'tool_permission_resolved',
            'request_id': rpcReqId,
            'payload': {
              'session_id': 'sess-perm-1',
              'outcome': 'resolved',
              'success': true,
            },
          }),
        );

        final result = await permFuture;
        expect(result['payload']['outcome'], equals('resolved'));

        await client.dispose();
      },
    );

    test('compactSession dispatches query and returns payload on success', () async {
      final client = createClient();
      await client.connect();

      final compactFuture = client.compactSession(
        sessionId: 'sess-compact-1',
        resendOnTimeout: false,
      );

      expect(mockSocket.sentMessages.length, 1);
      final sent =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      expect(sent['command'], equals('session.compact'));
      expect(sent['payload']['session_id'], equals('sess-compact-1'));

      final reqId = sent['request_id'] as String;
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'event',
          'event': 'session.compact_result',
          'request_id': reqId,
          'payload': {
            'session_id': 'sess-compact-1',
            'outcome': 'accepted',
            'compaction_id': 'cmp-100',
          },
        }),
      );

      final result = await compactFuture;
      expect(result['outcome'], equals('accepted'));
      expect(result['compaction_id'], equals('cmp-100'));

      await client.dispose();
    });

    test('compactSession with resendOnTimeout: false rethrows query_timeout and does not resend', () async {
      final client = createClient();
      await client.connect();

      final compactFuture = client.compactSession(
        sessionId: 'sess-compact-timeout',
        timeout: const Duration(milliseconds: 20),
        resendOnTimeout: false,
      );

      expect(mockSocket.sentMessages.length, 1);
      final initialSent =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      expect(initialSent['command'], equals('session.compact'));

      await expectLater(
        compactFuture,
        throwsA(
          isA<CliClientException>().having(
            (e) => e.code,
            'code',
            equals('query_timeout'),
          ),
        ),
      );

      // Verify no second fire-and-forget message was dispatched
      expect(mockSocket.sentMessages.length, 1);

      await client.dispose();
    });

    test('compactSession with resendOnTimeout: true sends fire-and-forget fallback on query_timeout', () async {
      final client = createClient();
      await client.connect();

      final compactFuture = client.compactSession(
        sessionId: 'sess-compact-resend',
        timeout: const Duration(milliseconds: 20),
        resendOnTimeout: true,
      );

      final result = await compactFuture;
      expect(result['outcome'], equals('dispatched'));

      // Verify both query and fire-and-forget fallback were dispatched
      expect(mockSocket.sentMessages.length, 2);
      final secondSent =
          jsonDecode(mockSocket.sentMessages[1]) as Map<String, dynamic>;
      expect(secondSent['command'], equals('session.compact'));
      expect(secondSent['payload']['session_id'], equals('sess-compact-resend'));

      await client.dispose();
    });

    test('query correlates responses by request_id', () async {
      final client = createClient();
      await client.connect();

      final queryFuture = client.query(
        command: 'get_sessions',
        payload: const {},
      );

      expect(mockSocket.sentMessages.length, 1);
      final sent =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      final reqId = sent['request_id'] as String;

      // Simulate daemon replying with matching request_id
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'request_id': reqId,
          'payload': {
            'sessions': [
              {'session_id': 's1', 'title': 'Session One'},
            ],
          },
        }),
      );

      final result = await queryFuture;
      expect(result['payload']['sessions'], isNotEmpty);
      expect(result['payload']['sessions'][0]['title'], 'Session One');

      await client.dispose();
    });

    test(
      'streams incoming events to eventStream and typed stream filters',
      () async {
        final client = createClient();
        await client.connect();

        final events = <CliEvent>[];
        client.eventStream.listen(events.add);

        final assistantChunks = <String>[];
        client.assistantStream.listen((e) => assistantChunks.add(e.content));

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'event': {
              'type': 'thought_stream',
              'payload': {'delta': 'Chunk 1'},
            },
          }),
        );

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'event': {
              'type': 'thought_stream',
              'payload': {'delta': 'Chunk 2'},
            },
          }),
        );

        // Allow microtasks to process
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(events.length, 2);
        expect(assistantChunks, ['Chunk 1', 'Chunk 2']);

        await client.dispose();
      },
    );

    test('disconnect and dispose handle state transitions cleanly', () async {
      final client = createClient();
      await client.connect();
      expect(client.isConnected, isTrue);

      await client.disconnect();
      expect(client.isConnected, isFalse);
      expect(client.state, CliConnectionState.closed);

      await client.dispose();
    });
    group('steer acknowledgement', () {
      /// Dispatching is fire-and-forget, so wait for the outbound envelope
      /// instead of sleeping before the fake server answers it.
      Future<String> awaitSentSteer() async {
        while (sentCommands().isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        final command = sentCommands().single;
        expect(command['type'], 'execute_command');
        expect(command['command'], 'steer');
        final payload = command['payload'] as Map<String, dynamic>;
        expect(payload['session_id'], 'session-77');
        expect(payload['message'], 'Add the audit trail');
        expect(payload['request_id'], isNotEmpty);
        expect(command['request_id'], payload['request_id']);
        return payload['request_id'] as String;
      }

      test('dispatches the canonical steer envelope', () async {
        final client = createClient();
        await client.connect();

        final ackFuture = client.steerAndAwaitAck(
          sessionId: 'session-77',
          message: 'Add the audit trail',
        );
        await awaitSentSteer();

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'session.message_classified',
            'session_id': 'session-77',
            'payload': {
              'session_id': 'session-77',
              'request_id':
                  (sentCommands().single['payload'] as Map)['request_id'],
              'classification': 'steer',
            },
          }),
        );

        final ack = await ackFuture;
        expect(ack['session_id'], 'session-77');
        expect(ack['classification'], 'steer');
        expect(ack['event'], 'session.message_classified');
        await client.dispose();
      });

      test('treats a pending-steer record as the acknowledgement', () async {
        final client = createClient();
        await client.connect();

        final ackFuture = client.steerAndAwaitAck(
          sessionId: 'session-77',
          message: 'Add the audit trail',
        );
        final requestId = await awaitSentSteer();

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'session.pending_steer_changed',
            'session_id': 'session-77',
            'payload': {
              'session_id': 'session-77',
              'request_id': requestId,
              'state': 'pending',
            },
          }),
        );

        final ack = await ackFuture;
        expect(ack['classification'], 'steer');
        expect(ack['state'], 'pending');
        expect(ack['request_id'], requestId);
        await client.dispose();
      });

      test('ignores acks published for another request id', () async {
        final client = createClient(requestTimeout: const Duration(seconds: 5));
        await client.connect();

        final ackFuture = client.steerAndAwaitAck(
          sessionId: 'session-77',
          message: 'Add the audit trail',
        );
        final requestId = await awaitSentSteer();

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'session.message_classified',
            'session_id': 'session-77',
            'payload': {
              'session_id': 'session-77',
              'request_id': 'req-another-turn',
              'classification': 'queue',
            },
          }),
        );
        await settle();

        var resolved = false;
        unawaited(ackFuture.then((_) => resolved = true));
        await settle();
        expect(
          resolved,
          isFalse,
          reason: 'another turn classification must not answer this steer',
        );

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'session.message_classified',
            'session_id': 'session-77',
            'payload': {
              'session_id': 'session-77',
              'request_id': requestId,
              'classification': 'steer',
            },
          }),
        );
        final ack = await ackFuture;
        expect(ack['classification'], 'steer');
        await client.dispose();
      });

      test(
        'surfaces a typed gateway rejection as a client exception',
        () async {
          final client = createClient();
          await client.connect();

          final ackFuture = client.steerAndAwaitAck(
            sessionId: 'session-77',
            message: 'Add the audit trail',
          );
          final requestId = await awaitSentSteer();

          mockSocket.emitFromServer(
            jsonEncode({
              'type': 'error',
              'request_id': requestId,
              'payload': {
                'request_id': requestId,
                'code': 'invalid_request',
                'message': 'steer target is not steerable',
              },
            }),
          );

          await expectLater(
            ackFuture,
            throwsA(
              isA<CliClientException>()
                  .having((e) => e.code, 'code', 'invalid_request')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('not steerable'),
                  ),
            ),
          );
          await client.dispose();
        },
      );

      test('raises steer_unacknowledged instead of reporting an unconfirmed '
          'steer as sent', () async {
        final client = createClient(
          requestTimeout: const Duration(milliseconds: 20),
        );
        await client.connect();

        await expectLater(
          client.steerAndAwaitAck(
            sessionId: 'session-77',
            message: 'Add the audit trail',
          ),
          throwsA(
            isA<CliClientException>().having(
              (e) => e.code,
              'code',
              'steer_unacknowledged',
            ),
          ),
        );
        await client.dispose();
      });
    });
  });

  group('LocalGatewayDiscovery', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync(
        'sanad_cli_discovery_test_',
      );
    });

    tearDown(() {
      try {
        tempHome.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('reads token from .local_token', () async {
      final tokenFile = File(
        '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
      );
      tokenFile.writeAsStringSync('my-super-secret-token\n');

      final discovery = LocalGatewayDiscovery(sanadHomeOverride: tempHome.path);
      final token = await discovery.readToken();

      expect(token, 'my-super-secret-token');
    });

    test(
      'throws GatewayDiscoveryException when token file is missing',
      () async {
        final discovery = LocalGatewayDiscovery(
          sanadHomeOverride: tempHome.path,
        );
        expect(
          () => discovery.readToken(),
          throwsA(isA<GatewayDiscoveryException>()),
        );
      },
    );

    test(
      'discover honors urlOverride and detects non-running daemon without throwing',
      () async {
        final tokenFile = File(
          '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
        );
        tokenFile.writeAsStringSync('test-token');

        final discovery = LocalGatewayDiscovery(
          sanadHomeOverride: tempHome.path,
        );
        final result = await discovery.discover(
          urlOverride: 'ws://127.0.0.1:59999/gateway',
          probeTimeout: const Duration(milliseconds: 50),
        );

        expect(result.port, 59999);
        expect(result.isDaemonRunning, isFalse);
        expect(result.token, 'test-token');
        expect(result.gatewayWsUri.toString(), 'ws://127.0.0.1:59999/gateway');
      },
    );

    test(
      'targeted probe attaches when a healthy endpoint answers slower than the speculative deadline',
      () async {
        final tokenFile = File(
          '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
        );
        tokenFile.writeAsStringSync('test-token');

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = server.listen((request) async {
          // Healthy and authenticated, but deliberately slower than the
          // speculative discovery deadline.
          await Future<void>.delayed(const Duration(milliseconds: 450));
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write('{"status":"ok"}');
          await request.response.close();
        });

        try {
          final discovery = LocalGatewayDiscovery(
            sanadHomeOverride: tempHome.path,
          );
          final result = await discovery.discover(portOverride: server.port);

          expect(result.isDaemonRunning, isTrue);
          expect(result.port, server.port);
          expect(result.healthData?['status'], 'ok');
        } finally {
          await server.close(force: true);
          await requests.cancel();
        }
      },
    );

    test(
      'targeted probe stays bounded and fails closed when the endpoint never answers',
      () async {
        final tokenFile = File(
          '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
        );
        tokenFile.writeAsStringSync('test-token');

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // Accepts the connection but never completes the health request.
        final requests = server.listen((request) {});

        try {
          final discovery = LocalGatewayDiscovery(
            sanadHomeOverride: tempHome.path,
          );
          final stopwatch = Stopwatch()..start();
          final result = await discovery.discover(portOverride: server.port);
          stopwatch.stop();

          expect(result.isDaemonRunning, isFalse);
          expect(result.healthData, isNull);
          // The applied targeted deadline is bounded: it must be honored
          // (not the legacy 300 ms speculative bound) and must not overrun it
          // beyond a scheduling margin.
          expect(
            stopwatch.elapsed,
            greaterThanOrEqualTo(const Duration(milliseconds: 1500)),
          );
          expect(
            stopwatch.elapsed,
            lessThan(const Duration(seconds: 4)),
          );
        } finally {
          await server.close(force: true);
          await requests.cancel();
        }
      },
    );
  });

  group('StandaloneFallbackStrategy', () {
    test('resolves standalone mode when forceStandalone is true', () async {
      final strategy = StandaloneFallbackStrategy();
      final mode = await strategy.resolveMode(forceStandalone: true);
      expect(mode, CliRuntimeMode.standalone);
    });

    test('resolves standalone mode when daemon is not reachable', () async {
      final tempHome = Directory.systemTemp.createTempSync(
        'sanad_standalone_test_',
      );
      try {
        final tokenFile = File(
          '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
        );
        tokenFile.writeAsStringSync('test-token');

        final discovery = LocalGatewayDiscovery(
          sanadHomeOverride: tempHome.path,
        );
        final strategy = StandaloneFallbackStrategy(discovery: discovery);

        final mode = await strategy.resolveMode(
          portOverride: 59998,
          probeTimeout: const Duration(milliseconds: 50),
        );
        expect(mode, CliRuntimeMode.standalone);
      } finally {
        tempHome.deleteSync(recursive: true);
      }
    });

    test(
      'resolves gateway mode for a healthy daemon that answers slower than the speculative deadline',
      () async {
        final tempHome = Directory.systemTemp.createTempSync(
          'sanad_standalone_slow_test_',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = server.listen((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 450));
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write('{"status":"ok"}');
          await request.response.close();
        });
        try {
          final tokenFile = File(
            '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
          );
          tokenFile.writeAsStringSync('test-token');

          final discovery = LocalGatewayDiscovery(
            sanadHomeOverride: tempHome.path,
          );
          final strategy = StandaloneFallbackStrategy(discovery: discovery);

          // No probe override: production defaults must resolve the mode.
          final mode = await strategy.resolveMode(portOverride: server.port);

          expect(mode, CliRuntimeMode.gateway);
        } finally {
          await server.close(force: true);
          await requests.cancel();
          tempHome.deleteSync(recursive: true);
        }
      },
    );
  });
}
