import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/cli.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

/// In-memory mock WebSocket implementing the minimal interface required by LocalGatewayCliClient.
class MockWebSocket implements WebSocket {
  final _incomingController = StreamController<dynamic>();
  final List<String> sentMessages = [];
  final List<Completer<String>> _pendingWaiters = [];
  int _consumedCount = 0;
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
    final message = data.toString();
    sentMessages.add(message);
    if (_pendingWaiters.isNotEmpty) {
      _pendingWaiters.removeAt(0).complete(message);
    }
  }

  Future<String> nextSentMessage({
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (_consumedCount < sentMessages.length) {
      return Future.value(sentMessages[_consumedCount++]);
    }
    final completer = Completer<String>();
    _pendingWaiters.add(completer);
    _consumedCount++;
    return completer.future.timeout(timeout);
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

class FakeInProcessTurnClient extends CliTurnClientBase {
  final _events = StreamController<CliEvent>.broadcast();
  final bool completeTurn;
  AgentTurnRequest? request;
  bool disposed = false;
  int stopCount = 0;

  FakeInProcessTurnClient({this.completeTurn = true});

  @override
  Stream<CliEvent> get eventStream => _events.stream;

  @override
  Stream<CliConnectionState> get stateStream => const Stream.empty();

  @override
  Future<String> dispatchTurnRequest(AgentTurnRequest request) async {
    this.request = request;
    if (!completeTurn) return request.requestId ?? 'fake-request';
    scheduleMicrotask(() {
      _events
        ..add(
          CliAssistantChunkEvent(
            content: 'standalone response',
            sessionId: request.sessionId,
          ),
        )
        ..add(
          CliTurnCompleteEvent(
            finalMessage: 'standalone response',
            sessionId: request.sessionId,
          ),
        );
    });
    return request.requestId ?? 'fake-request';
  }

  @override
  Future<void> stop({required String sessionId, String? runId}) async {
    stopCount++;
  }

  @override
  Future<void> respondPermission({
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? answer,
    String? comment,
    String? sessionId,
  }) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

Future<int> _runTargeted(SanadCommandRunner runner, List<String> arguments) {
  return runner.run([...arguments, '--execution-root', Directory.current.path]);
}

void main() {
  useIsolatedSanadTestHome();
  group('Headless One-Shot Execution (sanad run)', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        autoReconnect: false,
        connectTimeout: const Duration(seconds: 1),
        requestTimeout: const Duration(seconds: 1),
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test('executes one-shot task and streams tokens in real time', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client,
        stdinReader: () async => null,
      );

      final runFuture = _runTargeted(runner, [
        'run',
        'Translate "hello" to French',
      ]);

      // Wait for think command to be sent over mock socket
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mockSocket.sentMessages.length, 1);
      final sentEnvelope =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      expect(sentEnvelope['command'], 'think');
      final payload = sentEnvelope['payload'] as Map<String, dynamic>;
      expect(payload['message'], 'Translate "hello" to French');
      final sessionId = payload['session_id'] as String;

      // Simulate streaming assistant chunks
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'thought_stream',
            'session_id': sessionId,
            'payload': {'delta': 'Bonjour'},
          },
        }),
      );
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'thought_stream',
            'session_id': sessionId,
            'payload': {'delta': '!'},
          },
        }),
      );

      // Simulate turn completion
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'turn_complete',
            'session_id': sessionId,
            'payload': {
              'text': 'Bonjour!',
              'usage': {'total_tokens': 12},
            },
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 0);
      final out = stdoutBuffer.toString();
      expect(out, contains('Bonjour!'));
      expect(
        out,
        contains('Sanad Agent — Executing turn for session: $sessionId'),
      );
    });

    test('passes an explicit medium thinking mode to the daemon', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client,
        stdinReader: () async => null,
      );

      final runFuture = _runTargeted(runner, [
        'run',
        'Use medium reasoning',
        '--thinking-mode',
        'medium',
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sentEnvelope =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      final payload = sentEnvelope['payload'] as Map<String, dynamic>;
      expect(payload['thinking_mode'], 'medium');
      final sessionId = payload['session_id'] as String;
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'turn_complete',
            'session_id': sessionId,
            'payload': {'text': 'Done'},
          },
        }),
      );

      expect(await runFuture, 0);
    });

    test('supports one-shot execution via top-level -p flag', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client,
        stdinReader: () async => null,
      );

      final runFuture = _runTargeted(runner, ['-p', 'List active tasks']);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mockSocket.sentMessages.length, 1);
      final sentEnvelope =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      final payload = sentEnvelope['payload'] as Map<String, dynamic>;
      expect(payload['message'], 'List active tasks');
      final sessionId = payload['session_id'] as String;

      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'final_answer',
            'session_id': sessionId,
            'payload': {'text': 'Task 1, Task 2'},
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 0);
      expect(stdoutBuffer.toString(), contains('Task 1, Task 2'));
    });

    test('supports session targeting override via --session', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client,
        stdinReader: () async => null,
      );

      final runFuture = _runTargeted(runner, [
        'run',
        'Continue previous topic',
        '--session',
        'custom-sess-777',
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sentEnvelope =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      final payload = sentEnvelope['payload'] as Map<String, dynamic>;
      expect(payload['session_id'], 'custom-sess-777');
      expect(payload['message'], 'Continue previous topic');

      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': 'custom-sess-777',
          'event': {
            'type': 'turn_complete',
            'session_id': 'custom-sess-777',
            'payload': {'text': 'Continuing topic...'},
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 0);
    });
  });

  group('Unix Pipe & Stdin Reader', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test(
      'concatenates prompt with piped input from stdin (e.g. cat file | sanad run "analyze")',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async =>
              'Error 404 at /api/data\nError 500 at /api/auth',
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Find root cause of these errors:',
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sentEnvelope =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final payload = sentEnvelope['payload'] as Map<String, dynamic>;

        expect(
          payload['message'],
          'Find root cause of these errors:\n\nError 404 at /api/data\nError 500 at /api/auth',
        );

        final sessionId = payload['session_id'] as String;
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'session_id': sessionId,
              'payload': {'text': 'Root causes identified.'},
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
      },
    );

    test(
      'uses piped input as prompt when no rest argument is provided',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => 'Generate a random UUID in Dart',
        );

        final runFuture = _runTargeted(runner, ['run']);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sentEnvelope =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final payload = sentEnvelope['payload'] as Map<String, dynamic>;
        expect(payload['message'], 'Generate a random UUID in Dart');

        final sessionId = payload['session_id'] as String;
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'session_id': sessionId,
              'payload': {'text': 'Uuid().v4()'},
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
        expect(stdoutBuffer.toString(), contains('Uuid().v4()'));
      },
    );
  });

  group('Output Modes: --quiet and --json', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test(
      '--quiet suppresses headers, tool logs, and outputs only the final assistant text',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Run doctor check',
          '--quiet',
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sentEnvelope =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        // Simulate tool call and result
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_call',
              'payload': {
                'tool_name': 'check_health',
                'tool_call_id': 'call-1',
                'arguments': {},
              },
            },
          }),
        );
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_result',
              'payload': {
                'tool_name': 'check_health',
                'tool_call_id': 'call-1',
                'result': 'All systems healthy',
              },
            },
          }),
        );

        // Assistant chunks
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'thought_stream',
              'payload': {'delta': 'System is optimal.'},
            },
          }),
        );

        // Turn complete
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'payload': {'text': 'System is optimal.'},
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);

        final output = stdoutBuffer.toString();
        // Verifies output contains ONLY the assistant text
        expect(output.trim(), 'System is optimal.');
        expect(output, isNot(contains('Sanad Agent')));
        expect(output, isNot(contains('Calling tool')));
        expect(output, isNot(contains('completed ✓')));
      },
    );

    test(
      '--json outputs structured JSON object with text, tool executions, and usage',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Inspect files',
          '--json',
          '-m',
          'gpt-4o',
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sentEnvelope =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        // Tool call
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_call',
              'payload': {
                'tool_name': 'read_file',
                'tool_call_id': 't-call-99',
                'arguments': {'path': 'pubspec.yaml'},
              },
            },
          }),
        );

        // Tool result
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_result',
              'payload': {
                'tool_name': 'read_file',
                'tool_call_id': 't-call-99',
                'result': 'name: sanad_agent',
                'is_error': false,
              },
            },
          }),
        );

        // Assistant chunks
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'thought_stream',
              'payload': {'delta': 'The package name is sanad_agent.'},
            },
          }),
        );

        // Turn complete with usage and model metadata
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'payload': {
                'text': 'The package name is sanad_agent.',
                'model': 'gpt-4o',
                'provider': 'openai',
                'usage': {
                  'prompt_tokens': 150,
                  'completion_tokens': 45,
                  'total_tokens': 195,
                },
              },
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);

        final rawOutput = stdoutBuffer.toString().trim();
        final parsed = jsonDecode(rawOutput) as Map<String, dynamic>;

        expect(parsed['exit_code'], 0);
        expect(parsed['session_id'], sessionId);
        expect(parsed['text'], 'The package name is sanad_agent.');
        expect(parsed['model'], 'gpt-4o');
        expect(parsed['provider'], 'openai');

        final tools = parsed['tool_executions'] as List;
        expect(tools.length, 1);
        final tool = tools.first as Map<String, dynamic>;
        expect(tool['tool_name'], 'read_file');
        expect(tool['tool_call_id'], 't-call-99');
        expect(tool['arguments'], {'path': 'pubspec.yaml'});
        expect(tool['result'], 'name: sanad_agent');
        expect(tool['is_error'], isFalse);

        final usage = parsed['usage'] as Map<String, dynamic>;
        expect(usage['total_tokens'], 195);
      },
    );
  });

  group('Non-Interactive Tool Permissions', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test(
      'leaves tool permission request pending under default restricted policy without auto-denying',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Execute dangerous shell script',
        ]);

        final firstMsg = await mockSocket.nextSentMessage();
        final sentEnvelope = jsonDecode(firstMsg) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        // Simulate gated permission request
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_permission_request',
              'payload': {
                'request_id': 'perm-req-42',
                'tool_name': 'run_terminal_command',
                'permission_class': 'elevated',
              },
            },
          }),
        );

        await pumpEventQueue();

        // Must NOT auto-deny; sentMessages must still only contain the initial think command
        expect(mockSocket.sentMessages.length, 1);
        expect(
          stderrBuffer.toString(),
          contains(
            'Notice: Gated tool "run_terminal_command" requires permission for session $sessionId (request perm-req-42)',
          ),
        );

        // Complete turn subsequently
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'payload': {
                'text': 'Permission pending; awaiting external resolution.',
              },
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
      },
    );

    test(
      'auto-approves tool permission request only with allow-all-tools',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Run script with full access',
          '--allow-all-tools',
        ]);

        final firstMsg = await mockSocket.nextSentMessage();
        final sentEnvelope = jsonDecode(firstMsg) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        // Simulate tool permission request
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_permission_request',
              'payload': {
                'request_id': 'perm-req-99',
                'tool_name': 'run_terminal_command',
                'permission_class': 'elevated',
              },
            },
          }),
        );

        final responseMsg =
            jsonDecode(await mockSocket.nextSentMessage())
                as Map<String, dynamic>;
        expect(responseMsg['command'], 'tool_permission_response');
        final respPayload = responseMsg['payload'] as Map<String, dynamic>;
        expect(respPayload['request_id'], 'perm-req-99');
        expect(respPayload['allowed'], isTrue);
        expect(respPayload['decision'], 'allow');

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'payload': {'text': 'Command executed.'},
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
      },
    );

    test(
      'leaves system_ask_user clarification pending without auto-approving even with allow-all-tools',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Ask clarifying question',
          '--allow-all-tools',
        ]);

        final firstMsg = await mockSocket.nextSentMessage();
        final sentEnvelope = jsonDecode(firstMsg) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        // Simulate clarification request (system_ask_user)
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'tool_permission_request',
              'payload': {
                'request_id': 'ask-req-1',
                'tool_name': 'system_ask_user',
                'questions': [
                  {'question': 'Which dialect?'},
                ],
              },
            },
          }),
        );

        await pumpEventQueue();

        // OneshotRunner must NOT have sent a tool_permission_response for system_ask_user!
        // Only the initial think command should be in sentMessages.
        expect(mockSocket.sentMessages.length, 1);
        expect(
          stderrBuffer.toString(),
          contains(
            'Clarification question pending for session $sessionId (request ask-req-1): Which dialect?',
          ),
        );

        // Turn completes subsequently
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'payload': {'text': 'Awaiting clarification.'},
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
      },
    );
  });

  group('Exit Codes & Error Handling', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test(
      'returns exit code 1 when no prompt or piped input is provided',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final exitCode = await _runTargeted(runner, ['run']);
        expect(exitCode, 1);
        expect(
          stderrBuffer.toString(),
          contains('Error: No prompt or instruction provided.'),
        );
      },
    );

    test(
      'stays attached through waiting, blocked, and resuming runtime notices',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        var completed = false;
        final runFuture = _runTargeted(runner, [
          'run',
          'Continue after provider recovery',
        ]).whenComplete(() => completed = true);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sentEnvelope =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        void emitNotice(String status, String message) {
          mockSocket.emitFromServer(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'session.runtime_notice',
                'session_id': sessionId,
                'payload': {
                  'status': status,
                  'reason': 'timeout',
                  'title': status == 'waiting'
                      ? 'Provider timeout'
                      : 'Resuming…',
                  'message': message,
                },
              },
            }),
          );
        }

        emitNotice('waiting', 'Retrying automatically.');
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        emitNotice('blocked', 'Waiting for retry or route intervention.');
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        emitNotice('resuming', 'Resuming last request with the new route.');
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'turn_complete',
              'session_id': sessionId,
              'payload': {'text': 'Recovered successfully.'},
            },
          }),
        );

        expect(await runFuture, 0);
        expect(stderrBuffer.toString(), contains('Retrying automatically.'));
        expect(
          stderrBuffer.toString(),
          contains('Resuming last request with the new route.'),
        );
      },
    );

    test('returns exit code 1 for a terminal fatal runtime notice', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client,
        stdinReader: () async => null,
      );

      final runFuture = _runTargeted(runner, ['run', 'Blocked provider turn']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sentEnvelope =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      final sessionId = sentEnvelope['payload']['session_id'] as String;

      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'session.runtime_notice',
            'session_id': sessionId,
            'payload': {
              'status': 'fatal',
              'reason': 'auth',
              'title': 'Authentication required',
              'message': 'Change provider or credentials.',
            },
          },
        }),
      );

      expect(await runFuture, 1);
      expect(stderrBuffer.toString(), contains('Authentication required'));
    });

    test('returns exit code 1 when server emits CliErrorEvent', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client,
        stdinReader: () async => null,
      );

      final runFuture = _runTargeted(runner, ['run', 'Query failed model']);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sentEnvelope =
          jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
      final sessionId = sentEnvelope['payload']['session_id'] as String;

      // Emit server error
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'session_id': sessionId,
          'event': {
            'type': 'error',
            'payload': {
              'message': 'Rate limit exceeded for provider',
              'code': 'rate_limited',
            },
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 1);
      expect(
        stderrBuffer.toString(),
        contains('Rate limit exceeded for provider'),
      );
    });

    test(
      'returns exit code 1 and formatted JSON when server error occurs in --json mode',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Failing query',
          '--json',
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sentEnvelope =
            jsonDecode(mockSocket.sentMessages.single) as Map<String, dynamic>;
        final sessionId = sentEnvelope['payload']['session_id'] as String;

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': sessionId,
            'event': {
              'type': 'error',
              'payload': {
                'message': 'Model context window exhausted',
                'code': 'context_exceeded',
              },
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 1);

        final raw = stdoutBuffer.toString().trim();
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        expect(parsed['exit_code'], 1);
        expect(parsed['error'], contains('Model context window exhausted'));
      },
    );

    test(
      'returns exit code 1 when connection is lost before turn completes',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          stdinReader: () async => null,
        );

        final runFuture = _runTargeted(runner, [
          'run',
          'Will disconnect mid-flight',
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        // Simulate socket closure
        mockSocket.simulateClose();

        final exitCode = await runFuture;
        expect(exitCode, 1);
        expect(stderrBuffer.toString(), contains('Gateway connection lost'));
      },
    );
  });

  group('Standalone one-shot runtime selection', () {
    test(
      'rejects a forced standalone run when the Home daemon is healthy',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'sanad-cli-owned-home-',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = server.listen((request) async {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write('{"status":"ok"}');
          await request.response.close();
        });
        await File(
          '${home.path}/${LocalGatewayCredentials.relativePath}',
        ).writeAsString('test-token');
        var standaloneFactoryCalled = false;
        final err = StringBuffer();

        try {
          final runner = OneshotRunner(
            stdinReader: () async => null,
            standaloneClientFactory: ({sanadHomeOverride}) async {
              standaloneFactoryCalled = true;
              return FakeInProcessTurnClient();
            },
          );

          final exitCode = await runner.run(
            prompt: 'must not execute',
            standalone: true,
            sanadHome: home.path,
            gatewayUrl: 'ws://127.0.0.1:${server.port}/gateway',
            stdoutSink: StringBuffer(),
            stderrSink: err,
          );

          expect(exitCode, 78);
          expect(standaloneFactoryCalled, isFalse);
          expect(err.toString(), contains('daemon is active'));
          expect(err.toString(), contains('omit --standalone'));
        } finally {
          await server.close(force: true);
          await requests.cancel();
          await home.delete(recursive: true);
        }
      },
    );

    test(
      'uses the in-process client and disposes it without attaching',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'sanad-cli-standalone-',
        );
        final out = StringBuffer();
        final err = StringBuffer();
        final standaloneClient = FakeInProcessTurnClient();
        var attachedFactoryCalled = false;

        try {
          final runner = OneshotRunner(
            stdinReader: () async => null,
            clientFactory: ({urlOverride, sanadHomeOverride}) async {
              attachedFactoryCalled = true;
              throw StateError('attached transport must not be selected');
            },
            standaloneClientFactory: ({sanadHomeOverride}) async {
              expect(sanadHomeOverride, home.path);
              return standaloneClient;
            },
          );

          final exitCode = await runner.run(
            prompt: 'answer locally',
            standalone: true,
            sanadHome: home.path,
            stdoutSink: out,
            stderrSink: err,
            timeout: const Duration(seconds: 2),
          );

          expect(exitCode, 0);
          expect(attachedFactoryCalled, isFalse);
          expect(standaloneClient.request?.message, 'answer locally');
          expect(standaloneClient.disposed, isTrue);
          expect(out.toString(), contains('standalone response'));
          expect(err.toString(), isEmpty);
        } finally {
          if (!standaloneClient.disposed) {
            await standaloneClient.dispose();
          }
          await home.delete(recursive: true);
        }
      },
    );

    test('timeout returns 124 and sends exactly one stop', () async {
      final client = FakeInProcessTurnClient(completeTurn: false);
      final out = StringBuffer();
      try {
        final exitCode = await OneshotRunner(stdinReader: () async => null).run(
          prompt: 'wait forever',
          client: client,
          json: true,
          timeout: const Duration(milliseconds: 10),
          stdoutSink: out,
          stderrSink: StringBuffer(),
        );

        expect(exitCode, 124);
        expect(client.stopCount, 1);
        expect(jsonDecode(out.toString())['exit_code'], 124);
      } finally {
        await client.dispose();
      }
    });

    test('ignores unsupported platform signal watchers', () async {
      final client = FakeInProcessTurnClient();
      final watchedSignals = <ProcessSignal>[];
      try {
        final exitCode = await OneshotRunner(stdinReader: () async => null).run(
          prompt: 'complete normally',
          client: client,
          quiet: true,
          timeout: const Duration(seconds: 5),
          signalWatcher: (signal) {
            watchedSignals.add(signal);
            if (signal == ProcessSignal.sigterm) {
              return Stream<ProcessSignal>.error(
                SignalException('SIGTERM is unsupported'),
              );
            }
            return const Stream<ProcessSignal>.empty();
          },
          stdoutSink: StringBuffer(),
          stderrSink: StringBuffer(),
        );

        expect(exitCode, 0);
        expect(watchedSignals, [ProcessSignal.sigint, ProcessSignal.sigterm]);
      } finally {
        await client.dispose();
      }
    });

    for (final signalCase in <(ProcessSignal, int)>[
      (ProcessSignal.sigint, 130),
      (ProcessSignal.sigterm, 143),
    ]) {
      test(
        '${signalCase.$1} returns ${signalCase.$2} and stops once',
        () async {
          final client = FakeInProcessTurnClient(completeTurn: false);
          final signals = StreamController<ProcessSignal>();
          try {
            final runFuture = OneshotRunner(stdinReader: () async => null).run(
              prompt: 'interrupt me',
              client: client,
              json: true,
              timeout: const Duration(seconds: 5),
              signalStream: signals.stream,
              stdoutSink: StringBuffer(),
              stderrSink: StringBuffer(),
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
            signals.add(signalCase.$1);

            expect(await runFuture, signalCase.$2);
            expect(client.stopCount, 1);
          } finally {
            await signals.close();
            await client.dispose();
          }
        },
      );
    }

    test('validates timeout before or after the run command', () async {
      for (final arguments in <List<String>>[
        ['--timeout', '0', 'run', 'invalid timeout'],
        ['run', '--timeout', '86401', 'invalid timeout'],
      ]) {
        final err = StringBuffer();
        final exitCode = await SanadCommandRunner(
          stdoutSink: StringBuffer(),
          stderrSink: err,
          stdinReader: () async => null,
        ).run(arguments);

        expect(exitCode, 64);
        expect(err.toString(), contains('1 to 86400'));
      }
    });

    test('run rejects the removed device routing option', () async {
      final err = StringBuffer();
      final exitCode = await SanadCommandRunner(
        stdoutSink: StringBuffer(),
        stderrSink: err,
        stdinReader: () async => null,
      ).run(['run', '--device', 'remote-1', 'do work']);

      expect(exitCode, 64);
      expect(
        err.toString(),
        contains('Could not find an option named "--device"'),
      );
    });
  });
}
