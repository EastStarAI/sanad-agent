import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/cli.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

/// In-memory mock WebSocket for testing LocalGatewayCliClient interactions.
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

  @override
  void add(dynamic data) {
    if (_closed) throw const SocketException('Socket closed');
    sentMessages.add(data.toString());
    try {
      final json = jsonDecode(data.toString());
      if (json is Map) {
        final reqId = json['request_id'];
        final command = json['command'];

        if (command == 'list_workspaces') {
          scheduleMicrotask(() {
            emitFromServer(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'workspaces': [
                    {
                      'id': 'ws-1',
                      'name': 'Alpha',
                      'path': '/workspaces/alpha',
                    },
                    {'id': 'ws-2', 'name': 'Beta', 'path': '/workspaces/beta'},
                  ],
                },
              }),
            );
          });
        } else if (command == 'session.compact') {
          scheduleMicrotask(() {
            emitFromServer(
              jsonEncode({
                'type': 'session.compact_result',
                'request_id': reqId,
                'payload': {
                  'request_id': reqId,
                  'outcome': 'success',
                  'compaction_id': 'compact-101',
                },
              }),
            );
          });
        } else if (command == 'get_sessions') {
          scheduleMicrotask(() {
            emitFromServer(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'sessions': [
                    {
                      'id': 'sess-1',
                      'title': 'Planning session',
                      'updated_at': '2026-09-03',
                    },
                  ],
                },
              }),
            );
          });
        } else if (command == 'get_session_history') {
          scheduleMicrotask(() {
            emitFromServer(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'messages': [
                    {'role': 'user', 'content': 'Hello'},
                    {'role': 'assistant', 'content': 'Hi there'},
                  ],
                },
              }),
            );
          });
        } else if (command == 'list_mcp_servers') {
          scheduleMicrotask(() {
            emitFromServer(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'servers': [
                    {
                      'name': 'filesystem',
                      'transport': 'stdio',
                      'command':
                          'npx -y @modelcontextprotocol/server-filesystem',
                      'status': 'connected',
                    },
                  ],
                },
              }),
            );
          });
        } else if (command == 'list_skills') {
          scheduleMicrotask(() {
            emitFromServer(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'skills': [
                    {
                      'name': 'web-browser',
                      'description': 'Browse web pages',
                      'active': true,
                    },
                  ],
                },
              }),
            );
          });
        }
      }
    } catch (_) {}
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
  group('CliSlashCommandHandler — isSlashCommand', () {
    test('identifies slash commands and exit keywords', () {
      expect(CliSlashCommandHandler.isSlashCommand('/help'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/workspace'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/ws'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/ws list'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/model'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/model gpt-4o'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/session'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/session new'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/skills'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/mcp'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/compact'), isTrue);
      expect(
        CliSlashCommandHandler.isSlashCommand('/steer change direction'),
        isTrue,
      );
      expect(CliSlashCommandHandler.isSlashCommand('/queue next task'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/stop'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/clear'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/history'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/exit'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/quit'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('exit'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('quit'), isTrue);
      expect(CliSlashCommandHandler.isSlashCommand('/unknown_cmd'), isTrue);

      // Non-slash commands (LLM user prompts)
      expect(
        CliSlashCommandHandler.isSlashCommand('what is the capital of France?'),
        isFalse,
      );
      expect(
        CliSlashCommandHandler.isSlashCommand('build the flutter app'),
        isFalse,
      );
      expect(CliSlashCommandHandler.isSlashCommand(''), isFalse);
      expect(CliSlashCommandHandler.isSlashCommand('   '), isFalse);
    });
  });

  group('CliSlashCommandHandler — Basic Commands', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;
    late ReplHistory history;

    setUp(() {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
      history = ReplHistory(
        initialEntries: ['/help', 'how are you?', '/history'],
      );
    });

    CliSlashCommandHandler createHandler({
      bool isTurnRunning = false,
      void Function()? onStopRequested,
      LocalGatewayCliClient? client,
    }) {
      return CliSlashCommandHandler.create(
        sessionId: 'session-test-1',
        currentModel: 'claude-3-7-sonnet',
        currentWorkspaceId: 'ws-1',
        currentWorkspaceName: 'Alpha',
        currentWorkspacePath: '/workspaces/alpha',
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
        history: history,
        isTurnRunning: isTurnRunning,
        onStopRequested: onStopRequested,
        client: client,
      );
    }

    test('/help prints available commands reference', () async {
      final handler = createHandler();
      final result = await handler.handle('/help');

      expect(result.handled, isTrue);
      expect(result.shouldExit, isFalse);

      final out = stdoutBuf.toString();
      expect(out, contains('Available REPL Commands:'));
      expect(out, contains('/help'));
      expect(out, contains('/workspace, /ws'));
      expect(out, contains('/model'));
      expect(out, contains('/session'));
      expect(out, contains('/skills'));
      expect(out, contains('/mcp'));
      expect(out, contains('/compact'));
      expect(out, contains('/steer'));
      expect(out, contains('/queue'));
      expect(out, contains('/stop'));
      expect(out, contains('/clear'));
      expect(out, contains('/history'));
    });

    test('/clear clears the screen', () async {
      final handler = createHandler();
      final result = await handler.handle('/clear');

      expect(result.handled, isTrue);
      expect(stdoutBuf.toString(), contains('Screen Cleared'));
    });

    test('/history prints recent entries', () async {
      final handler = createHandler();
      final result = await handler.handle('/history');

      expect(result.handled, isTrue);
      final out = stdoutBuf.toString();
      expect(out, contains('Command History:'));
      expect(out, contains('/help'));
      expect(out, contains('how are you?'));
    });

    test('/thinking toggles thinking mode', () async {
      final handler = createHandler();
      expect(handler.context.thinking, isFalse);

      await handler.handle('/thinking');
      expect(handler.context.thinking, isTrue);
      expect(stdoutBuf.toString(), contains('Thinking mode: enabled'));

      await handler.handle('/thinking');
      expect(handler.context.thinking, isFalse);
      expect(stdoutBuf.toString(), contains('Thinking mode: disabled'));
    });

    test('/exit and /quit return shouldExit: true', () async {
      final handler = createHandler();

      final res1 = await handler.handle('/exit');
      expect(res1.shouldExit, isTrue);
      expect(stdoutBuf.toString(), contains('Goodbye!'));

      final res2 = await handler.handle('/quit');
      expect(res2.shouldExit, isTrue);

      final res3 = await handler.handle('exit');
      expect(res3.shouldExit, isTrue);

      final res4 = await handler.handle('quit');
      expect(res4.shouldExit, isTrue);
    });

    test(
      'unknown slash command outputs error and does not pass to LLM',
      () async {
        final handler = createHandler();
        final result = await handler.handle('/foobar');

        expect(result.handled, isTrue);
        expect(result.shouldExit, isFalse);
        expect(
          stderrBuf.toString(),
          contains('Unknown slash command: /foobar'),
        );
        expect(stderrBuf.toString(), contains('/help'));
      },
    );
  });

  group('CliSlashCommandHandler — Model Commands', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;

    setUp(() {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
    });

    test('/model displays active model', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'test-sess',
        currentModel: 'claude-3-7-sonnet',
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      final result = await handler.handle('/model');
      expect(result.handled, isTrue);
      expect(stdoutBuf.toString(), contains('Active Model: claude-3-7-sonnet'));
    });

    test('/model list displays model matrix', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'test-sess',
        currentModel: 'claude-3-7-sonnet',
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      final result = await handler.handle('/model list');
      expect(result.handled, isTrue);
      final out = stdoutBuf.toString();
      expect(out, contains('claude-3-7-sonnet'));
      expect(out, contains('gpt-4o'));
      expect(out, contains('gemini-2.5-pro'));
      expect(out, contains('llama3.3:70b'));
    });

    test(
      '/model <name> and /model switch <name> switch active model',
      () async {
        final handler = CliSlashCommandHandler.create(
          sessionId: 'test-sess',
          currentModel: 'claude-3-7-sonnet',
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          enableAnsi: false,
        );

        await handler.handle('/model gpt-4o');
        expect(handler.context.currentModel, 'gpt-4o');
        expect(
          stdoutBuf.toString(),
          contains('Switched active model to: gpt-4o'),
        );

        await handler.handle('/model switch gemini-2.5-pro');
        expect(handler.context.currentModel, 'gemini-2.5-pro');
        expect(
          stdoutBuf.toString(),
          contains('Switched active model to: gemini-2.5-pro'),
        );
      },
    );

    test('/model switch without target reports error', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'test-sess',
        currentModel: 'claude-3-7-sonnet',
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/model switch');
      expect(
        stderrBuf.toString(),
        contains('Usage: /model switch <model-name>'),
      );
    });
  });

  group('CliSlashCommandHandler — Session Commands', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;

    setUp(() {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
    });

    test('/session shows active session details', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-abc-123',
        currentModel: 'gpt-4o',
        currentWorkspaceName: 'Alpha',
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/session');
      final out = stdoutBuf.toString();
      expect(out, contains('Active Session'));
      expect(out, contains('sess-abc-123'));
      expect(out, contains('gpt-4o'));
      expect(out, contains('Alpha'));
    });

    test('/session new generates a fresh session ID', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-old',
        currentModel: 'gpt-4o',
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/session new');
      expect(handler.context.sessionId, isNot('sess-old'));
      expect(handler.context.sessionId, startsWith('session-'));
      expect(stdoutBuf.toString(), contains('Started new session:'));
    });
  });

  group('CliSlashCommandHandler — Gateway Integrated Commands', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        autoReconnect: false,
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test('/workspace and /ws list registered workspaces and switch', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-1',
        currentModel: 'claude-3-7-sonnet',
        currentWorkspaceId: 'ws-1',
        currentWorkspaceName: 'Alpha',
        client: client,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/ws list');
      final listOut = stdoutBuf.toString();
      expect(listOut, contains('Alpha'));
      expect(listOut, contains('Beta'));
      expect(listOut, contains('/workspaces/alpha'));

      // Switch to Beta
      await handler.handle('/ws switch Beta');
      expect(handler.context.currentWorkspaceId, 'ws-2');
      expect(handler.context.currentWorkspaceName, 'Beta');
      expect(handler.context.currentWorkspacePath, '/workspaces/beta');
      expect(stdoutBuf.toString(), contains('Switched workspace to: Beta'));
    });

    test('/mcp queries and renders configured MCP servers', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-1',
        currentModel: 'claude-3-7-sonnet',
        currentWorkspaceId: 'ws-1',
        client: client,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/mcp');
      final out = stdoutBuf.toString();
      expect(out, contains('filesystem'));
      expect(out, contains('stdio'));
      expect(out, contains('connected'));
    });

    test('/skills queries and renders available skills', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-1',
        currentModel: 'claude-3-7-sonnet',
        currentWorkspaceId: 'ws-1',
        client: client,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/skills');
      final out = stdoutBuf.toString();
      expect(out, contains('web-browser'));
      expect(out, contains('Browse web pages'));
    });

    test('/compact triggers context compaction on gateway', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-compact-test',
        currentModel: 'claude-3-7-sonnet',
        client: client,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/compact');
      expect(
        mockSocket.sentMessages.any((m) => m.contains('"session.compact"')),
        isTrue,
      );
      expect(stdoutBuf.toString(), contains('Context compacted successfully'));
    });

    test('/steer sends steer command to client with notice', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-steer-test',
        currentModel: 'claude-3-7-sonnet',
        client: client,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
        isTurnRunning: true,
      );

      await handler.handle('/steer Focus only on unit tests');
      expect(mockSocket.sentMessages.any((m) => m.contains('"steer"')), isTrue);
      final steerMsg = mockSocket.sentMessages.firstWhere(
        (m) => m.contains('"steer"'),
      );
      final json = jsonDecode(steerMsg) as Map<String, dynamic>;
      expect(json['payload']['message'], 'Focus only on unit tests');
      expect(json['payload']['session_id'], 'sess-steer-test');

      expect(
        stdoutBuf.toString(),
        contains('Steer signal dispatched mid-flight'),
      );
    });

    test('/queue sends queued prompt to client', () async {
      final handler = CliSlashCommandHandler.create(
        sessionId: 'sess-queue-test',
        currentModel: 'claude-3-7-sonnet',
        client: client,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      await handler.handle('/queue Run analysis next');
      expect(mockSocket.sentMessages.any((m) => m.contains('"think"')), isTrue);
      final thinkMsg = mockSocket.sentMessages.firstWhere(
        (m) => m.contains('"think"'),
      );
      final json = jsonDecode(thinkMsg) as Map<String, dynamic>;
      expect(json['payload']['message'], 'Run analysis next');
      expect(json['payload']['delivery_intent'], 'queue');
      expect(
        stdoutBuf.toString(),
        contains('Prompt queued for subsequent turn'),
      );
    });

    test(
      '/stop cleanly interrupts active turn and sends stop command',
      () async {
        bool stopCalled = false;
        final handler = CliSlashCommandHandler.create(
          sessionId: 'sess-stop-test',
          currentModel: 'claude-3-7-sonnet',
          client: client,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          enableAnsi: false,
          isTurnRunning: true,
          onStopRequested: () {
            stopCalled = true;
          },
        );

        await handler.handle('/stop');
        expect(stopCalled, isTrue);
        expect(
          mockSocket.sentMessages.any((m) => m.contains('"stop"')),
          isTrue,
        );
        expect(
          stdoutBuf.toString(),
          contains('Stop signal dispatched. Active turn interrupted cleanly.'),
        );
      },
    );
  });

  group('InteractiveReplSession — Slash Commands Integration', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;
    late MockWebSocket mockSocket;
    late LocalGatewayCliClient client;

    setUp(() async {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
      mockSocket = MockWebSocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        autoReconnect: false,
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test(
      'intercepts /model and /steer without dispatching think turns',
      () async {
        final mockReader = MockReplLineReader([
          '/model gpt-4o',
          '/steer Keep answers short',
          'exit',
        ]);

        final session = InteractiveReplSession(
          clientOverride: client,
          lineReaderOverride: mockReader,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          workspace: 'test-ws',
          enableAnsi: false,
        );

        final exitCode = await session.run();
        expect(exitCode, 0);

        // Verify think command was NOT sent
        expect(
          mockSocket.sentMessages.any((m) => m.contains('"think"')),
          isFalse,
        );

        // Verify steer command WAS sent
        expect(
          mockSocket.sentMessages.any((m) => m.contains('"steer"')),
          isTrue,
        );
        final steerMsg = mockSocket.sentMessages.firstWhere(
          (m) => m.contains('"steer"'),
        );
        final steerJson = jsonDecode(steerMsg) as Map<String, dynamic>;
        expect(steerJson['payload']['message'], 'Keep answers short');

        final out = stdoutBuf.toString();
        expect(out, contains('Switched active model to: gpt-4o'));
        expect(out, contains('Steer signal dispatched'));
      },
    );

    test('updates dynamic prompt when /model is switched', () async {
      final mockReader = MockReplLineReader(['/model gpt-4o', 'exit']);

      final session = InteractiveReplSession(
        clientOverride: client,
        lineReaderOverride: mockReader,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        workspace: 'test-ws',
        model: 'initial-model',
        enableAnsi: false,
      );

      final exitCode = await session.run();
      expect(exitCode, 0);

      expect(mockReader.promptsShown[0], contains('test-ws : initial-model'));
      expect(mockReader.promptsShown[1], contains('test-ws : gpt-4o'));
    });
  });
}
