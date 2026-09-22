import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/cli/cli.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

/// In-memory mock WebSocket implementing the Gateway contract for E2E testing.
class MockGatewaySocket implements WebSocket {
  final _incomingController = StreamController<dynamic>();
  final _outgoingController = StreamController<String>.broadcast(sync: true);
  final List<String> sentMessages = [];

  Future<String> nextSentMessageWhere(bool Function(String) predicate) {
    return _outgoingController.stream
        .firstWhere(predicate)
        .timeout(const Duration(seconds: 5));
  }

  bool _closed = false;
  final Completer<void> _doneCompleter = Completer<void>();
  String currentPolicyMode = 'default';

  void emit(dynamic data) {
    if (!_closed) {
      _incomingController.add(data);
    }
  }

  void simulateClose([int? closeCode, String? closeReason]) {
    if (!_closed) {
      _closed = true;
      unawaited(_incomingController.close());
      unawaited(_outgoingController.close());
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  @override
  void add(dynamic data) {
    if (_closed) throw const SocketException('Socket is closed');
    final message = data.toString();
    sentMessages.add(message);
    _outgoingController.add(message);

    try {
      final json = jsonDecode(message);
      if (json is Map) {
        final reqId = json['request_id'];
        final command = json['command'];

        if (command == 'list_workspaces') {
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'workspaces': [
                    {
                      'id': 'ws-primary',
                      'name': 'primary-project',
                      'path': '/mock/workspaces/primary-project',
                    },
                    {
                      'id': 'ws-secondary',
                      'name': 'secondary-app',
                      'path': '/mock/workspaces/secondary-app',
                    },
                  ],
                },
              }),
            );
          });
        } else if (command == 'get_sessions') {
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'sessions': [
                    {
                      'id': 'session-alpha-1',
                      'title': 'E2E Architecture Session',
                      'updated_at': '2026-09-03',
                    },
                  ],
                },
              }),
            );
          });
        } else if (command == 'list_mcp_servers') {
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'effective': {
                    'servers': [
                      {
                        'name': 'filesystem',
                        'transport': 'stdio',
                        'command':
                            'npx @modelcontextprotocol/server-filesystem',
                        'status': 'connected',
                      },
                      {
                        'name': 'git-tool',
                        'transport': 'stdio',
                        'command': 'uvx mcp-server-git',
                        'status': 'connected',
                      },
                    ],
                  },
                },
              }),
            );
          });
        } else if (command == 'list_skills') {
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'skills': [
                    {'name': 'skill-creator', 'active': true},
                    {'name': 'find-skills', 'active': true},
                    {'name': 'agent-browser', 'active': true},
                  ],
                },
              }),
            );
          });
        } else if (command == 'session.compact') {
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'session.compact_result',
                'request_id': reqId,
                'payload': {
                  'outcome': 'success',
                  'compaction_id': 'compact-e2e-89h',
                },
              }),
            );
          });
        } else if (command == 'workspace.get_policy') {
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {
                  'permissionMode': currentPolicyMode,
                  'permission_mode': currentPolicyMode,
                  'permissions': {'allow': [], 'deny': [], 'ask': []},
                },
              }),
            );
          });
        } else if (command == 'workspace.set_permission_mode') {
          final mode = (json['payload']?['permission_mode'] ?? 'default')
              .toString();
          currentPolicyMode = mode;
          scheduleMicrotask(() {
            emit(
              jsonEncode({
                'type': 'command_response',
                'request_id': reqId,
                'payload': {'status': 'success', 'permission_mode': mode},
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
  group('Sanad CLI E2E Integration Suite', () {
    late Directory tempHome;
    late MockGatewaySocket mockSocket;
    late LocalGatewayCliClient client;
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;

    setUp(() async {
      tempHome = Directory.systemTemp.createTempSync('sanad_cli_e2e_test_');
      setSanadHomeOverride(tempHome.path);

      final tokenFile = File(
        '${tempHome.path}/${LocalGatewayCredentials.relativePath}',
      );
      tokenFile.createSync(recursive: true);
      tokenFile.writeAsStringSync('secret-test-token-89h');

      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
      mockSocket = MockGatewaySocket();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'secret-test-token-89h',
        autoReconnect: false,
        requestTimeout: const Duration(seconds: 2),
        connectTimeout: const Duration(seconds: 2),
        connector: (uri, {headers, timeout}) async => mockSocket,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
      setSanadHomeOverride(null);
      try {
        tempHome.deleteSync(recursive: true);
      } catch (_) {}
    });

    // ------------------------------------------------------------------------
    // 1. Headless Execution, Pipes, and Output Formats
    // ------------------------------------------------------------------------
    group('Headless Execution & Unix Pipes', () {
      test(
        'runs one-shot task via top-level -p flag and completes lifecycle',
        () async {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            client: client,
            stdinReader: () async => null,
          );

          final sentFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('"think"'),
          );
          final runFuture = runner.run(['-p', 'Calculate 40 + 2']);

          final sent = jsonDecode(await sentFuture) as Map<String, dynamic>;
          expect(sent['command'], 'think');
          expect(sent['payload']['message'], 'Calculate 40 + 2');
          final sessionId = sent['payload']['session_id'] as String;

          // Server streams chunks and completes turn
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'thought_stream',
                'payload': {'delta': 'The answer is 42.'},
              },
            }),
          );
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'turn_complete',
                'payload': {
                  'text': 'The answer is 42.',
                  'model': 'claude-3-7-sonnet',
                  'provider': 'anthropic',
                },
              },
            }),
          );

          final exitCode = await runFuture;
          expect(exitCode, 0);
          expect(stdoutBuf.toString(), contains('The answer is 42.'));
        },
      );

      test(
        'processes piped stdin concatenated with prompt (cat log | sanad run)',
        () async {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            client: client,
            stdinReader: () async => 'PANIC: NullPointerException at index 4',
          );

          final sentFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('"think"'),
          );
          final runFuture = runner.run(['run', 'Analyze stacktrace:']);

          final sent = jsonDecode(await sentFuture) as Map<String, dynamic>;
          expect(
            sent['payload']['message'],
            'Analyze stacktrace:\n\nPANIC: NullPointerException at index 4',
          );

          final sessionId = sent['payload']['session_id'] as String;
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'turn_complete',
                'payload': {
                  'text': 'Root cause: Uninitialized pointer dereference.',
                },
              },
            }),
          );

          final exitCode = await runFuture;
          expect(exitCode, 0);
          expect(
            stdoutBuf.toString(),
            contains('Root cause: Uninitialized pointer dereference.'),
          );
        },
      );

      test(
        'supports --json mode with structured tool calls and token counts',
        () async {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            client: client,
            stdinReader: () async => null,
          );

          final sentFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('"think"'),
          );
          final runFuture = runner.run(['run', 'Inspect project', '--json']);

          final sent = jsonDecode(await sentFuture) as Map<String, dynamic>;
          final sessionId = sent['payload']['session_id'] as String;

          // Tool call
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'tool_call',
                'payload': {
                  'tool_name': 'scan_dir',
                  'tool_call_id': 'call-e2e-1',
                  'arguments': {'depth': 2},
                },
              },
            }),
          );

          // Tool result
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'tool_result',
                'payload': {
                  'tool_name': 'scan_dir',
                  'tool_call_id': 'call-e2e-1',
                  'result': 'Found 12 files',
                  'is_error': false,
                },
              },
            }),
          );

          // Turn complete
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'turn_complete',
                'payload': {
                  'text': 'Project scan complete.',
                  'model': 'gpt-4o',
                  'provider': 'openai',
                  'usage': {'total_tokens': 320},
                },
              },
            }),
          );

          final exitCode = await runFuture;
          expect(exitCode, 0);

          final jsonOut =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(jsonOut['exit_code'], 0);
          expect(jsonOut['text'], 'Project scan complete.');
          expect(jsonOut['model'], 'gpt-4o');
          expect(jsonOut['provider'], 'openai');
          expect(jsonOut['usage']['total_tokens'], 320);

          final tools = jsonOut['tool_executions'] as List;
          expect(tools.length, 1);
          expect(tools.first['tool_name'], 'scan_dir');
          expect(tools.first['result'], 'Found 12 files');
        },
      );

      test(
        'supports --quiet mode suppressing banners and tool telemetry',
        () async {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            client: client,
            stdinReader: () async => null,
          );

          final sentFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('"think"'),
          );
          final runFuture = runner.run(['run', 'Quick ping', '--quiet']);

          final sent = jsonDecode(await sentFuture) as Map<String, dynamic>;
          final sessionId = sent['payload']['session_id'] as String;

          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'session_id': sessionId,
              'event': {
                'type': 'turn_complete',
                'payload': {'text': 'pong'},
              },
            }),
          );

          final exitCode = await runFuture;
          expect(exitCode, 0);
          expect(stdoutBuf.toString().trim(), 'pong');
          expect(stdoutBuf.toString(), isNot(contains('Sanad Agent')));
        },
      );
    });

    // ------------------------------------------------------------------------
    // 2. Interactive REPL, Mid-Flight Steering, Approvals & Clarifications
    // ------------------------------------------------------------------------
    group('Interactive REPL Comprehensive Workflow', () {
      test(
        'executes conversational turn with interactive tool permission grant',
        () async {
          final mockReader = MockReplLineReader([
            'Modify config file',
            'y', // Approve permission once
            'exit',
          ]);

          final session = InteractiveReplSession(
            clientOverride: client,
            lineReaderOverride: mockReader,
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            workspace: 'primary-project',
            enableAnsi: false,
          );

          final thinkFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('"think"'),
          );
          final runFuture = session.run();
          await thinkFuture;

          final permissionResponseFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('tool_permission_response'),
          );
          // Server requests sensitive tool permission
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'event': {
                'type': 'tool_permission_request',
                'payload': {
                  'request_id': 'perm-req-e2e',
                  'tool_name': 'write_file',
                  'permission_class': 'filesystem',
                  'workspace_name': 'primary-project',
                },
              },
            }),
          );

          // Verify response sent back to server.
          final permMsg = await permissionResponseFuture;
          final permJson = jsonDecode(permMsg) as Map<String, dynamic>;
          expect(permJson['payload']['request_id'], 'perm-req-e2e');
          expect(permJson['payload']['allowed'], isTrue);
          expect(permJson['payload']['scope'], 'once');

          // Stream assistant completion chunk
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'event': {
                'type': 'thought_stream',
                'payload': {'delta': 'File updated successfully.\n'},
              },
            }),
          );

          // Finish turn
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'event': {
                'type': 'turn_complete',
                'payload': {'content': 'File updated successfully.'},
              },
            }),
          );

          final exitCode = await runFuture;
          expect(exitCode, 0);
          expect(stdoutBuf.toString(), contains('Decision: allow (once)'));
          expect(stdoutBuf.toString(), contains('File updated successfully.'));
        },
      );

      test(
        'interactively handles clarification question (system_ask_user)',
        () async {
          final mockReader = MockReplLineReader([
            'Set up testing framework',
            '2', // User picks option 2: Testify suite
            'exit',
          ]);

          final session = InteractiveReplSession(
            clientOverride: client,
            lineReaderOverride: mockReader,
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            enableAnsi: false,
          );

          final thinkFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('"think"'),
          );
          final runFuture = session.run();
          await thinkFuture;

          final answerFuture = mockSocket.nextSentMessageWhere(
            (message) => message.contains('tool_permission_response'),
          );
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'event': {
                'type': 'tool_permission_request',
                'payload': {
                  'request_id': 'ask-req-e2e',
                  'tool_name': 'system_ask_user',
                  'permission_class': 'interactive',
                  'questions': [
                    {
                      'question': 'Choose test runner:',
                      'options': [
                        'Standard testing',
                        'Testify suite',
                        'Ginkgo BDD',
                      ],
                    },
                  ],
                },
              },
            }),
          );

          final answerMsg = await answerFuture;
          final answerJson = jsonDecode(answerMsg) as Map<String, dynamic>;
          expect(answerJson['payload']['request_id'], 'ask-req-e2e');
          expect(answerJson['payload']['answer'], 'Testify suite');

          // Stream assistant response
          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'event': {
                'type': 'thought_stream',
                'payload': {'delta': 'Configured Testify suite!\n'},
              },
            }),
          );

          mockSocket.emit(
            jsonEncode({
              'type': 'device_event',
              'event': {
                'type': 'turn_complete',
                'payload': {'content': 'Configured Testify suite!'},
              },
            }),
          );

          final exitCode = await runFuture;
          expect(exitCode, 0);
          expect(stdoutBuf.toString(), contains('Response submitted.'));
          expect(stdoutBuf.toString(), contains('Configured Testify suite!'));
        },
      );

      test(
        'executes in-flight /steer mid-turn and dispatches steer payload',
        () async {
          final mockReader = MockReplLineReader([
            '/steer Skip documentation files',
            'exit',
          ]);

          final session = InteractiveReplSession(
            clientOverride: client,
            lineReaderOverride: mockReader,
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            enableAnsi: false,
          );

          final exitCode = await session.run();
          expect(exitCode, 0);

          expect(
            mockSocket.sentMessages.any((m) => m.contains('"steer"')),
            isTrue,
          );
          final steerMsg = mockSocket.sentMessages.firstWhere(
            (m) => m.contains('"steer"'),
          );
          final steerJson = jsonDecode(steerMsg) as Map<String, dynamic>;
          expect(steerJson['payload']['message'], 'Skip documentation files');
          expect(stdoutBuf.toString(), contains('Steer signal dispatched'));
        },
      );

      test('executes /stop to interrupt active turn cleanly', () async {
        final mockReader = MockReplLineReader(['/stop', 'exit']);

        final session = InteractiveReplSession(
          clientOverride: client,
          lineReaderOverride: mockReader,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          enableAnsi: false,
        );

        final exitCode = await session.run();
        expect(exitCode, 0);

        expect(
          mockSocket.sentMessages.any((m) => m.contains('"stop"')),
          isTrue,
        );
        expect(stdoutBuf.toString(), contains('Stop signal'));
      });

      test('handles model switching and prompt reflection mid-REPL', () async {
        final mockReader = MockReplLineReader([
          '/model list',
          '/model switch gpt-4o',
          'exit',
        ]);

        final session = InteractiveReplSession(
          clientOverride: client,
          lineReaderOverride: mockReader,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          workspace: 'primary-project',
          model: 'claude-3-7-sonnet',
          enableAnsi: false,
        );

        final exitCode = await session.run();
        expect(exitCode, 0);

        final out = stdoutBuf.toString();
        expect(out, contains('claude-3-7-sonnet'));
        expect(out, contains('gpt-4o'));
        expect(out, contains('gemini-2.5-pro'));
        expect(out, contains('Switched active model to: gpt-4o'));
        expect(mockReader.promptsShown[2], contains('gpt-4o'));
      });

      test(
        'handles /compact context compaction and /ws list commands',
        () async {
          final mockReader = MockReplLineReader([
            '/compact',
            '/ws list',
            'exit',
          ]);

          final session = InteractiveReplSession(
            clientOverride: client,
            lineReaderOverride: mockReader,
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            enableAnsi: false,
          );

          final exitCode = await session.run();
          expect(exitCode, 0);

          expect(
            mockSocket.sentMessages.any((m) => m.contains('"session.compact"')),
            isTrue,
          );
          final out = stdoutBuf.toString();
          expect(out, contains('Context compacted successfully'));
          expect(out, contains('primary-project'));
          expect(out, contains('secondary-app'));
        },
      );
    });

    // ------------------------------------------------------------------------
    // 3. Workspace Auto-Discovery & Management
    // ------------------------------------------------------------------------
    group('Workspace Auto-Discovery & Management', () {
      late Directory tempWorkspaceDir;
      late Directory subDir;

      setUp(() {
        tempWorkspaceDir = Directory.systemTemp.createTempSync('sanad_e2e_ws_');
        subDir = Directory(p.join(tempWorkspaceDir.path, 'src', 'features'))
          ..createSync(recursive: true);
      });

      tearDown(() {
        try {
          tempWorkspaceDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test(
        'WorkspaceLocator auto-discovers enclosing parent workspace from nested directory',
        () async {
          final locator = WorkspaceLocator();
          final knownWorkspaces = [
            {
              'id': 'ws-parent',
              'name': 'enclosing-parent',
              'path': tempWorkspaceDir.path,
            },
          ];

          final match = await locator.autoDiscover(
            cwd: subDir.path,
            knownWorkspaces: knownWorkspaces,
          );

          expect(match, isNotNull);
          expect(match!.workspace['id'], 'ws-parent');
          expect(match.isExact, isFalse);
          expect(match.relativeSubpath, p.join('src', 'features'));
        },
      );

      test(
        'workspace switch mutates local state and reflects in workspace current',
        () async {
          final stateStore = CliWorkspaceStateStore(
            sanadHomeOverride: tempHome.path,
          );
          final wsService = WorkspaceCliService(
            gatewayClient: client,
            stateStore: stateStore,
            sanadHome: tempHome.path,
          );

          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            workspaceService: wsService,
          );

          // Switch to secondary-app
          final switchCode = await runner.run([
            'workspace',
            'switch',
            'secondary-app',
          ]);
          expect(switchCode, 0);
          expect(
            stdoutBuf.toString(),
            contains('Switched active workspace to: secondary-app'),
          );

          // Verify local state persisted
          final activeWsId = await stateStore.getActiveWorkspaceId();
          expect(activeWsId, 'ws-secondary');

          // Verify workspace current reflects it
          stdoutBuf.clear();
          final currentCode = await runner.run(['workspace', 'current']);
          expect(currentCode, 0);
          expect(stdoutBuf.toString(), contains('Name:        secondary-app'));
          expect(stdoutBuf.toString(), contains('ID:          ws-secondary'));
        },
      );

      test(
        'workspace policy command views and toggles security mode',
        () async {
          final stateStore = CliWorkspaceStateStore(
            sanadHomeOverride: tempHome.path,
          );
          await stateStore.setActiveWorkspace(
            workspaceId: 'ws-primary',
            workspacePath: tempWorkspaceDir.path,
            workspaceName: 'primary-project',
          );

          final wsService = WorkspaceCliService(
            gatewayClient: client,
            stateStore: stateStore,
            sanadHome: tempHome.path,
          );

          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            workspaceService: wsService,
          );

          // View policy
          final viewCode = await runner.run(['workspace', 'policy']);
          expect(viewCode, 0);
          expect(stdoutBuf.toString(), contains('Permission Mode: default'));

          // Change policy to full_access
          stdoutBuf.clear();
          final updateCode = await runner.run([
            'workspace',
            'policy',
            'full_access',
          ]);
          expect(updateCode, 0);
          expect(
            stdoutBuf.toString(),
            contains(
              'Updated security policy for "primary-project" to full_access',
            ),
          );

          // Verify updated policy
          stdoutBuf.clear();
          await runner.run(['workspace', 'policy']);
          expect(
            stdoutBuf.toString(),
            contains('Permission Mode: full_access'),
          );
        },
      );

      test('workspace tree renders directory hierarchy', () async {
        File(
          p.join(tempWorkspaceDir.path, 'README.md'),
        ).writeAsStringSync('# Test');
        File(
          p.join(tempWorkspaceDir.path, 'main.dart'),
        ).writeAsStringSync('void main() {}');

        final stateStore = CliWorkspaceStateStore(
          sanadHomeOverride: tempHome.path,
        );
        await stateStore.setActiveWorkspace(
          workspaceId: 'ws-tree',
          workspacePath: tempWorkspaceDir.path,
          workspaceName: 'tree-ws',
        );

        final wsService = WorkspaceCliService(
          stateStore: stateStore,
          sanadHome: tempHome.path,
        );

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          workspaceService: wsService,
        );

        final treeCode = await runner.run([
          'workspace',
          'tree',
          tempWorkspaceDir.path,
        ]);
        expect(treeCode, 0);
        final out = stdoutBuf.toString();
        expect(out, contains('src/'));
        expect(out, contains('README.md'));
        expect(out, contains('main.dart'));
      });
    });

    // ------------------------------------------------------------------------
    // 4. Doctor System Diagnostics
    // ------------------------------------------------------------------------
    group('Doctor Command Diagnostics', () {
      test(
        'sanad doctor prints full system checklist and detects platform & home',
        () async {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
          );

          final exitCode = await runner.run(['doctor']);
          expect(exitCode, 0);

          final out = stdoutBuf.toString();
          expect(out, contains('=== ⚕ Sanad Agent Doctor ==='));
          expect(out, contains('Platform: ${Platform.operatingSystem}'));
          expect(out, contains('Agent Version:'));
          expect(out, contains('Sanad Home:'));
          expect(out, contains('Daemon Status:'));
          expect(out, contains('Doctor inspection completed.'));
        },
      );
    });

    // ------------------------------------------------------------------------
    // 5. Models and Providers Integration
    // ------------------------------------------------------------------------
    group('Models & Providers Command Integration', () {
      test(
        'sanad models command lists supported and available AI models',
        () async {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
          );

          final exitCode = await runner.run(['models']);
          expect(exitCode, 0);

          final out = stdoutBuf.toString();
          expect(
            out.contains('Configured Providers & Available Models:') ||
                out.contains('No local state database found') ||
                out.contains('No AI providers configured.'),
            isTrue,
          );
        },
      );

      test('sanad providers command routes to ProvidersCommand', () async {
        var providersCalled = false;
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          customHandlers: {
            'providers': (cmd) {
              providersCalled = true;
              return 0;
            },
          },
        );

        final exitCode = await runner.run(['providers']);
        expect(exitCode, 0);
        expect(providersCalled, isTrue);
      });
    });

    // ------------------------------------------------------------------------
    // 6. Cross-Platform Formatting & Resource Leak Prevention
    // ------------------------------------------------------------------------
    group('Cross-Platform Compatibility & Socket Resource Safety', () {
      test(
        'TerminalRenderer honors enableAnsi: false for piped and non-ANSI terminals',
        () {
          final buf = StringBuffer();
          final renderer = TerminalRenderer(
            stdoutSink: buf,
            enableColor: false,
            isTerminal: false,
          );

          final rendered = renderer.renderMarkdown(
            '**Bold Text** and `inline_code`',
            printToStdout: true,
          );

          // ANSI escape codes start with \x1B[
          expect(rendered.contains('\x1B['), isFalse);
          expect(rendered, contains('Bold Text'));
          expect(rendered, contains('inline_code'));
          expect(buf.toString(), contains('Bold Text'));
        },
      );

      test(
        'socket closure triggers clean client disconnection without hanging futures',
        () async {
          expect(client.isConnected, isTrue);

          final closedFuture = client.stateStream
              .firstWhere((state) => state == CliConnectionState.closed)
              .timeout(const Duration(seconds: 5));
          // Simulate abrupt server termination.
          mockSocket.simulateClose(1006, 'Connection dropped abnormally');
          await closedFuture;

          expect(client.isConnected, isFalse);
          expect(client.state, CliConnectionState.closed);

          // Ensure disposing already-closed client does not throw or leak
          await expectLater(client.dispose(), completes);
        },
      );
    });
  });
}
