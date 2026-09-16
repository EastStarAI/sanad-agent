import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/cli.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:test/test.dart';
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

  @override
  void add(dynamic data) {
    if (_closed) throw const SocketException('Socket closed');
    sentMessages.add(data.toString());
    try {
      final json = jsonDecode(data.toString());
      if (json is Map && json['command'] == 'list_workspaces') {
        final reqId = json['request_id'];
        scheduleMicrotask(() {
          emitFromServer(
            jsonEncode({
              'type': 'command_response',
              'request_id': reqId,
              'payload': {
                'workspaces': [
                  {
                    'id': 'test-ws',
                    'name': 'test-ws',
                    'path': '/workspaces/test-ws',
                  },
                ],
              },
            }),
          );
        });
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
  group('ReplHistory', () {
    late Directory tempDir;
    late String historyFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'sanad_repl_history_test_',
      );
      historyFile = '${tempDir.path}/cli_history';
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('adds non-empty commands and ignores immediate duplicates', () {
      final history = ReplHistory(historyFilePath: historyFile);
      history.add('help');
      history.add('help');
      history.add('  ');
      history.add('status');

      expect(history.length, 2);
      expect(history.entries, ['help', 'status']);
    });

    test('navigates history with previous() and next() preserving draft', () {
      final history = ReplHistory(
        historyFilePath: historyFile,
        initialEntries: ['first', 'second', 'third'],
      );

      expect(history.previous('my draft'), 'third');
      expect(history.previous('my draft'), 'second');
      expect(history.previous('my draft'), 'first');
      // Clamped at oldest
      expect(history.previous('my draft'), 'first');

      expect(history.next(), 'second');
      expect(history.next(), 'third');
      // Restores draft at bottom
      expect(history.next(), 'my draft');
      // When at bottom, returns null
      expect(history.next(), isNull);
    });

    test('persists and loads history to and from disk', () async {
      final history1 = ReplHistory(historyFilePath: historyFile);
      history1.add('cmd1');
      history1.add('cmd2');
      history1.add('cmd3');
      await history1.save();

      expect(File(historyFile).existsSync(), isTrue);

      final history2 = ReplHistory(historyFilePath: historyFile);
      await history2.load();
      expect(history2.entries, ['cmd1', 'cmd2', 'cmd3']);
    });

    test('enforces maxEntries boundary', () async {
      final history = ReplHistory(historyFilePath: historyFile, maxEntries: 3);
      history.add('1');
      history.add('2');
      history.add('3');
      history.add('4');

      expect(history.entries, ['2', '3', '4']);
    });
  });

  group('ReplPrompt', () {
    test('formats prompt with workspace and model', () {
      final prompt = ReplPrompt.format(
        workspace: 'my-project',
        model: 'gemini-2.5-pro',
        ansi: false,
      );
      expect(prompt, 'sanad [my-project : gemini-2.5-pro] > ');
    });

    test('formats prompt with default workspace when not provided', () {
      final prompt = ReplPrompt.format(model: 'claude-3-7-sonnet', ansi: false);
      expect(prompt, 'sanad [default : claude-3-7-sonnet] > ');
    });

    test('formats continuation prompt', () {
      expect(ReplPrompt.formatContinuation(ansi: false), '... ');
    });

    test('generates banner containing version and instructions', () {
      final banner = ReplPrompt.banner(version: '1.0.7', ansi: false);
      expect(banner, contains('Sanad Agent CLI (v1.0.7)'));
      expect(banner, contains('Ctrl+C'));
      expect(banner, contains('Ctrl+D'));
    });
  });

  group('TerminalReplLineReader & Line Editing', () {
    test('reads simple line when Enter is pressed', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        enableAnsi: false,
        isTerminal: false,
      );

      final future = reader.readLine(prompt: '> ');
      inputController.add(utf8.encode('hello world\n'));

      final result = await future;
      expect(result, 'hello world');
      expect(outBuffer.toString(), contains('> '));
      await reader.dispose();
      await inputController.close();
    });

    test('handles backspace editing', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        enableAnsi: false,
        isTerminal: false,
      );

      final future = reader.readLine();
      // 'h', 'e', 'l', 'x', backspace (127), 'l', 'o', enter
      inputController.add([104, 101, 108, 120, 127, 108, 111, 10]);

      final result = await future;
      expect(result, 'hello');
      await reader.dispose();
      await inputController.close();
    });

    test('handles left arrow and insertion in middle of line', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        enableAnsi: false,
        isTerminal: false,
      );

      final future = reader.readLine();
      // 'h', 'e', 'l', 'o', Left Arrow (\x1b[D), 'l', enter
      inputController.add(utf8.encode('helo\x1b[Dl\n'));

      final result = await future;
      expect(result, 'hello');
      await reader.dispose();
      await inputController.close();
    });

    test('navigates history with Up arrow and Down arrow', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final history = ReplHistory(initialEntries: ['git status', 'sanad run']);
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        history: history,
        enableAnsi: false,
        isTerminal: false,
      );

      final future = reader.readLine();
      // Up arrow (\x1b[A) retrieves 'sanad run', enter
      inputController.add(utf8.encode('\x1b[A\n'));

      final result = await future;
      expect(result, 'sanad run');
      await reader.dispose();
      await inputController.close();
    });

    test(
      'handles multi-line input continuation with trailing backslash',
      () async {
        final inputController = StreamController<List<int>>();
        final outBuffer = StringBuffer();
        final reader = TerminalReplLineReader(
          inputByteStream: inputController.stream,
          output: outBuffer,
          enableAnsi: false,
          isTerminal: false,
        );

        final future = reader.readLine(prompt: '> ');
        inputController.add(utf8.encode('line 1 \\\nline 2\n'));

        final result = await future;
        expect(result, 'line 1\nline 2');
        await reader.dispose();
        await inputController.close();
      },
    );

    test('returns empty string on Ctrl+C at prompt', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        enableAnsi: false,
        isTerminal: false,
      );

      final future = reader.readLine();
      // 'some input' followed by Ctrl+C (3)
      inputController.add([115, 111, 109, 101, 3]);

      final result = await future;
      expect(result, '');
      expect(outBuffer.toString(), contains('^C'));
      await reader.dispose();
      await inputController.close();
    });

    test('returns null on Ctrl+D with empty buffer (EOF)', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        enableAnsi: false,
        isTerminal: false,
      );

      final future = reader.readLine();
      // Ctrl+D (4)
      inputController.add([4]);

      final result = await future;
      expect(result, isNull);
      await reader.dispose();
      await inputController.close();
    });

    test(
      'handles CRLF (\\r\\n) cleanly without leaving ghost Enter for next prompt',
      () async {
        final inputController = StreamController<List<int>>();
        final outBuffer = StringBuffer();
        final reader = TerminalReplLineReader(
          inputByteStream: inputController.stream,
          output: outBuffer,
          enableAnsi: false,
          isTerminal: false,
        );

        final future1 = reader.readLine(prompt: '> ');
        inputController.add(utf8.encode('first message\r\n'));

        final result1 = await future1;
        expect(result1, 'first message');

        // Next prompt should NOT immediately complete with empty string
        final future2 = reader.readLine(prompt: '> ');
        final completedPrematurely = await Future.any([
          future2.then((v) => true),
          Future.delayed(const Duration(milliseconds: 50), () => false),
        ]);
        expect(completedPrematurely, isFalse);

        // Now send input and enter
        inputController.add(utf8.encode('second\r\n'));
        final result2 = await future2;
        expect(result2, 'second');

        await reader.dispose();
        await inputController.close();
      },
    );

    test(
      'supports bracketed paste mode for multi-line pasted content without premature submission',
      () async {
        final inputController = StreamController<List<int>>();
        final outBuffer = StringBuffer();
        final reader = TerminalReplLineReader(
          inputByteStream: inputController.stream,
          output: outBuffer,
          enableAnsi: false,
          isTerminal: false,
        );

        final future = reader.readLine(prompt: '> ');
        // Terminal pastes text wrapped in \x1b[200~ and \x1b[201~
        inputController.add(
          utf8.encode('\x1b[200~line one\nline two\nline three\x1b[201~'),
        );

        // Verify that future is still waiting for explicit user Enter
        final completedOnPaste = await Future.any([
          future.then((v) => true),
          Future.delayed(const Duration(milliseconds: 50), () => false),
        ]);
        expect(completedOnPaste, isFalse);

        // User hits Enter on keyboard
        inputController.add(utf8.encode('\r\n'));
        final result = await future;
        expect(result, 'line one\nline two\nline three');

        await reader.dispose();
        await inputController.close();
      },
    );

    test('flush() clears any queued keystrokes before next readLine', () async {
      final inputController = StreamController<List<int>>();
      final outBuffer = StringBuffer();
      final reader = TerminalReplLineReader(
        inputByteStream: inputController.stream,
        output: outBuffer,
        enableAnsi: false,
        isTerminal: false,
      );

      // Queue some keystrokes while no readLine is active (e.g. during turn execution)
      inputController.add(utf8.encode('stray input\r\n'));
      await Future.delayed(const Duration(milliseconds: 20));

      // Flush reader
      reader.flush();

      // Now start readLine: should NOT see the stray input
      final future = reader.readLine(prompt: '> ');
      final completed = await Future.any([
        future.then((v) => true),
        Future.delayed(const Duration(milliseconds: 50), () => false),
      ]);
      expect(completed, isFalse);

      inputController.add(utf8.encode('clean input\r\n'));
      final result = await future;
      expect(result, 'clean input');

      await reader.dispose();
      await inputController.close();
    });
  });

  group('InteractiveAskUserHandler', () {
    test('handles question with options and picks by number', () async {
      final out = StringBuffer();
      final mockReader = MockReplLineReader(['2']);

      final event = CliPermissionRequestEvent(
        requestId: 'req-ask-1',
        toolName: 'system_ask_user',
        permissionClass: 'interactive',
        questions: [
          {
            'question': 'Which database?',
            'options': ['SQLite', 'PostgreSQL', 'MySQL'],
          },
        ],
      );

      final answer = await InteractiveAskUserHandler.prompt(
        event: event,
        lineReader: mockReader,
        output: out,
        ansi: false,
      );

      expect(answer, 'PostgreSQL');
      expect(out.toString(), contains('Which database?'));
      expect(out.toString(), contains('[1] SQLite'));
      expect(out.toString(), contains('[2] PostgreSQL'));
      expect(out.toString(), contains('[3] MySQL'));
    });

    test('handles question with custom write-in via w option', () async {
      final out = StringBuffer();
      final mockReader = MockReplLineReader(['w', 'MongoDB']);

      final event = CliPermissionRequestEvent(
        requestId: 'req-ask-2',
        toolName: 'system_ask_user',
        permissionClass: 'interactive',
        questions: [
          {
            'question': 'Preferred storage engine?',
            'options': ['Local File', 'In-Memory'],
          },
        ],
      );

      final answer = await InteractiveAskUserHandler.prompt(
        event: event,
        lineReader: mockReader,
        output: out,
        ansi: false,
      );

      expect(answer, 'MongoDB');
    });

    test('handles direct free-form answer when typing text directly', () async {
      final out = StringBuffer();
      final mockReader = MockReplLineReader(['Custom Text Direct']);

      final event = CliPermissionRequestEvent(
        requestId: 'req-ask-3',
        toolName: 'system_ask_user',
        permissionClass: 'interactive',
        questions: [
          {
            'question': 'Target architecture?',
            'options': ['x86_64', 'arm64'],
          },
        ],
      );

      final answer = await InteractiveAskUserHandler.prompt(
        event: event,
        lineReader: mockReader,
        output: out,
        ansi: false,
      );

      expect(answer, 'Custom Text Direct');
    });
  });

  group('InteractivePermissionHandler', () {
    test(
      'prompts and grants permission Once by default (y or empty)',
      () async {
        final out = StringBuffer();
        final mockReader = MockReplLineReader(['y']);

        final event = CliPermissionRequestEvent(
          requestId: 'req-perm-1',
          toolName: 'shell_execute',
          permissionClass: 'dangerous',
          workspaceName: 'sanad-agent',
        );

        final result = await InteractivePermissionHandler.prompt(
          event: event,
          lineReader: mockReader,
          output: out,
          ansi: false,
        );

        expect(result.allowed, isTrue);
        expect(result.scope, 'once');
        expect(result.decision, 'allow');
        expect(out.toString(), contains('Tool:        shell_execute'));
        expect(out.toString(), contains('Permission:  dangerous'));
      },
    );

    test('prompts and grants Session scope when user chooses s', () async {
      final out = StringBuffer();
      final mockReader = MockReplLineReader(['s']);

      final event = CliPermissionRequestEvent(
        requestId: 'req-perm-2',
        toolName: 'file_write',
        permissionClass: 'filesystem',
      );

      final result = await InteractivePermissionHandler.prompt(
        event: event,
        lineReader: mockReader,
        output: out,
        ansi: false,
      );

      expect(result.allowed, isTrue);
      expect(result.scope, 'session');
      expect(result.decision, 'allow');
    });

    test('prompts and grants Workspace scope when user chooses w', () async {
      final out = StringBuffer();
      final mockReader = MockReplLineReader(['w']);

      final event = CliPermissionRequestEvent(
        requestId: 'req-perm-3',
        toolName: 'execute_command',
        permissionClass: 'execution',
      );

      final result = await InteractivePermissionHandler.prompt(
        event: event,
        lineReader: mockReader,
        output: out,
        ansi: false,
      );

      expect(result.allowed, isTrue);
      expect(result.scope, 'workspace');
      expect(result.decision, 'allow');
    });

    test('prompts and denies when user chooses n', () async {
      final out = StringBuffer();
      final mockReader = MockReplLineReader(['n']);

      final event = CliPermissionRequestEvent(
        requestId: 'req-perm-4',
        toolName: 'format_drive',
        permissionClass: 'critical',
      );

      final result = await InteractivePermissionHandler.prompt(
        event: event,
        lineReader: mockReader,
        output: out,
        ansi: false,
      );

      expect(result.allowed, isFalse);
      expect(result.decision, 'deny');
    });
  });

  group('InteractiveReplSession E2E', () {
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
        connectTimeout: const Duration(seconds: 1),
        requestTimeout: const Duration(seconds: 1),
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
    });

    test('executes turn, streams chunks and exits on exit command', () async {
      final mockReader = MockReplLineReader([
        'Explain quantum computing',
        'exit',
      ]);

      final session = InteractiveReplSession(
        clientOverride: client,
        lineReaderOverride: mockReader,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        workspace: 'test-ws',
        model: 'mock-model',
        enableAnsi: false,
      );

      final runFuture = session.run();

      // Wait for think request to be sent
      await Future.delayed(const Duration(milliseconds: 50));
      expect(mockSocket.sentMessages.any((m) => m.contains('"think"')), isTrue);

      final thinkMsg = mockSocket.sentMessages.firstWhere(
        (m) => m.contains('"think"'),
      );
      final sentPayload = jsonDecode(thinkMsg) as Map<String, dynamic>;
      expect(sentPayload['command'], 'think');
      expect(sentPayload['payload']['message'], 'Explain quantum computing');

      // Simulate streaming tokens from server
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'event': {
            'type': 'assistant',
            'payload': {'text': 'Quantum computing uses qubits.'},
          },
        }),
      );

      // Simulate turn completion
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'event': {
            'type': 'turn_complete',
            'payload': {
              'content': 'Quantum computing uses qubits.',
              'model': 'mock-model-v2',
            },
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 0);

      final output = stdoutBuf.toString();
      expect(output, contains('Sanad Agent CLI'));
      expect(output, contains('Quantum computing uses qubits.'));
      expect(output, contains('Goodbye!'));
    });

    test('interactively handles system_ask_user and resumes turn', () async {
      final mockReader = MockReplLineReader([
        'Build my backend',
        '1', // User selects option 1: SQLite
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

      final runFuture = session.run();

      await Future.delayed(const Duration(milliseconds: 50));
      expect(mockSocket.sentMessages.any((m) => m.contains('"think"')), isTrue);

      // Server emits system_ask_user
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'event': {
            'type': 'tool_permission_request',
            'payload': {
              'request_id': 'ask-req-10',
              'tool_name': 'system_ask_user',
              'permission_class': 'interactive',
              'questions': [
                {
                  'question': 'Which database do you prefer?',
                  'options': ['SQLite', 'PostgreSQL'],
                },
              ],
            },
          },
        }),
      );

      // Give event loop time to process prompt and send response
      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        mockSocket.sentMessages.any(
          (m) => m.contains('tool_permission_response'),
        ),
        isTrue,
      );
      final permMsg = mockSocket.sentMessages.lastWhere(
        (m) => m.contains('tool_permission_response'),
      );
      final responseMsg = jsonDecode(permMsg) as Map<String, dynamic>;
      expect(responseMsg['command'], 'tool_permission_response');
      expect(responseMsg['payload']['request_id'], 'ask-req-10');
      expect(responseMsg['payload']['allowed'], isTrue);
      expect(responseMsg['payload']['answer'], 'SQLite');

      // Server finishes turn
      mockSocket.emitFromServer(
        jsonEncode({
          'type': 'device_event',
          'event': {
            'type': 'turn_complete',
            'payload': {'content': 'Configured SQLite!'},
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 0);
      expect(stdoutBuf.toString(), contains('Response submitted.'));
    });

    test(
      'interactively handles tool permission request with session scope',
      () async {
        final mockReader = MockReplLineReader([
          'Run command',
          's', // Allow for this Session
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

        final runFuture = session.run();

        await Future.delayed(const Duration(milliseconds: 50));
        expect(
          mockSocket.sentMessages.any((m) => m.contains('"think"')),
          isTrue,
        );

        // Server requests tool permission
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'event': {
              'type': 'tool_permission_request',
              'payload': {
                'request_id': 'perm-req-20',
                'tool_name': 'shell_execute',
                'permission_class': 'execution',
                'workspace_name': 'sanad-agent',
              },
            },
          }),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          mockSocket.sentMessages.any(
            (m) => m.contains('tool_permission_response'),
          ),
          isTrue,
        );
        final permMsg = mockSocket.sentMessages.lastWhere(
          (m) => m.contains('tool_permission_response'),
        );
        final permResponse = jsonDecode(permMsg) as Map<String, dynamic>;
        expect(permResponse['command'], 'tool_permission_response');
        expect(permResponse['payload']['request_id'], 'perm-req-20');
        expect(permResponse['payload']['allowed'], isTrue);
        expect(permResponse['payload']['scope'], 'session');
        expect(permResponse['payload']['decision'], 'allow');

        // Server finishes turn
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'event': {
              'type': 'turn_complete',
              'payload': {'content': 'Shell command executed.'},
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
        expect(stdoutBuf.toString(), contains('Decision: allow (session)'));
      },
    );

    test('handles /help and /history built-in commands', () async {
      final mockReader = MockReplLineReader(['/help', '/history', 'exit']);

      final session = InteractiveReplSession(
        clientOverride: client,
        lineReaderOverride: mockReader,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        enableAnsi: false,
      );

      final exitCode = await session.run();
      expect(exitCode, 0);

      final out = stdoutBuf.toString();
      expect(out, contains('Available REPL Commands:'));
      expect(out, contains('/help'));
      expect(out, contains('/history'));
    });
  });

  group('ChatCommand Integration', () {
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
      'SanadCommandRunner defaults to ChatCommand and exits cleanly',
      () async {
        final mockReader = MockReplLineReader(['exit']);

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          client: client,
          lineReader: mockReader,
        );

        final exitCode = await runner.run([]);
        expect(exitCode, 0);
        expect(stdoutBuf.toString(), contains('Sanad Agent CLI'));
        expect(stdoutBuf.toString(), contains('Goodbye!'));
      },
    );

    test(
      'sanad chat command launches REPL session with custom options',
      () async {
        final mockReader = MockReplLineReader(['exit']);

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          client: client,
          lineReader: mockReader,
        );

        final exitCode = await runner.run([
          'chat',
          '--workspace',
          'my-ws',
          '--model',
          'my-model',
        ]);
        expect(exitCode, 0);
        expect(mockReader.promptsShown.first, contains('my-ws : my-model'));
      },
    );
  });
}
