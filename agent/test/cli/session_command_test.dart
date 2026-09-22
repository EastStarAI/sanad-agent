import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/client/local_gateway_cli_client.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

class MockWebSocket implements WebSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSessionGatewayClient extends LocalGatewayCliClient {
  List<Map<String, dynamic>> sessionsToReturn = [];
  Map<String, dynamic>? historyToReturn;
  String? lastStoppedSessionId;
  String? lastAnswerSessionId;
  String? lastAnswerRequestId;
  String? lastAnswer;
  String? lastPermissionSessionId;
  String? lastPermissionRequestId;
  bool? lastPermissionAllowed;
  String? lastPermissionDecision;
  String? lastPermissionScope;
  String? lastPermissionComment;
  Object? errorToThrow;

  FakeSessionGatewayClient()
    : super(gatewayUri: Uri.parse('ws://127.0.0.1:58085'), token: 'fake-token');

  @override
  Future<List<Map<String, dynamic>>> getSessions({Duration? timeout}) async {
    if (errorToThrow != null) throw errorToThrow!;
    return sessionsToReturn;
  }

  @override
  Future<Map<String, dynamic>> getSessionHistory({
    required String sessionId,
    Duration? timeout,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    return historyToReturn ?? {'messages': []};
  }

  @override
  Future<void> stop({required String sessionId, String? runId}) async {
    if (errorToThrow != null) throw errorToThrow!;
    lastStoppedSessionId = sessionId;
  }

  @override
  Future<Map<String, dynamic>> respondAnswer({
    required String sessionId,
    required String requestId,
    required String answer,
    Duration? timeout,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    lastAnswerSessionId = sessionId;
    lastAnswerRequestId = requestId;
    lastAnswer = answer;
    return {
      'payload': {'outcome': 'resolved'},
    };
  }

  @override
  Future<Map<String, dynamic>> respondToolPermission({
    required String sessionId,
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? comment,
    Duration? timeout,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    lastPermissionSessionId = sessionId;
    lastPermissionRequestId = requestId;
    lastPermissionAllowed = allowed;
    lastPermissionDecision = decision;
    lastPermissionScope = scope;
    lastPermissionComment = comment;
    return {
      'payload': {'outcome': 'resolved'},
    };
  }
}

void main() {
  useIsolatedSanadTestHome();

  group('SessionCommand CLI Tests', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;
    late FakeSessionGatewayClient client;
    late Directory tempDir;

    setUp(() {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
      client = FakeSessionGatewayClient();
      tempDir = Directory.systemTemp.createTempSync('sanad_session_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    SanadCommandRunner buildRunner() {
      return SanadCommandRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        client: client,
      );
    }

    group('session list', () {
      test('lists sessions with pending intervention indicator', () async {
        client.sessionsToReturn = [
          {
            'session_id': 'sess-1',
            'title': 'Feature Alpha',
            'model': 'deepseek-v4-flash',
            'has_pending_permission_request': false,
          },
          {
            'session_id': 'sess-2',
            'title': 'Refactor DB',
            'model': 'kimi-k2.7-code',
            'has_pending_permission_request': true,
          },
        ];

        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'list']);
        expect(exitCode, equals(0));

        final out = stdoutBuf.toString();
        expect(out, contains('sess-1 (Feature Alpha) - deepseek-v4-flash'));
        expect(
          out,
          contains(
            'sess-2 (Refactor DB) - kimi-k2.7-code [Pending intervention]',
          ),
        );
      });

      test('returns JSON array in --json mode', () async {
        client.sessionsToReturn = [
          {
            'session_id': 'sess-1',
            'title': 'Alpha',
            'has_pending_permission_request': false,
          },
        ];

        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'list', '--json']);
        expect(exitCode, equals(0));

        final decoded = jsonDecode(stdoutBuf.toString().trim());
        expect(decoded, isA<List>());
        expect((decoded as List).first['session_id'], equals('sess-1'));
      });

      test('handles empty sessions list', () async {
        client.sessionsToReturn = [];

        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'list']);
        expect(exitCode, equals(0));
        expect(stdoutBuf.toString(), contains('(No cached sessions found)'));
      });
    });

    group('session show', () {
      test('shows needs_input when clarification is pending', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-ask',
            'model': 'deepseek-v4-flash',
            'pending_permission_request': {
              'request_id': 'req-ask-99',
              'tool_name': 'system_ask_user',
              'questions': [
                {
                  'question': 'Which database dialect should we target?',
                  'options': ['PostgreSQL', 'SQLite', 'MySQL'],
                },
              ],
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'show', 'sess-ask']);
        expect(exitCode, equals(0));

        final out = stdoutBuf.toString();
        expect(out, contains('Status: needs_input'));
        expect(
          out,
          contains('Question: Which database dialect should we target?'),
        );
        expect(out, contains('Options: PostgreSQL, SQLite, MySQL'));
        expect(out, contains('sanad session answer sess-ask -r req-ask-99'));
      });

      test('shows needs_permission when gated tool is pending', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-perm',
            'model': 'glm-5.2',
            'pending_permission_request': {
              'request_id': 'req-perm-42',
              'tool_name': 'shell_execute',
              'tool_input': {'command': 'rm -rf /tmp/test'},
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'show', 'sess-perm']);
        expect(exitCode, equals(0));

        final out = stdoutBuf.toString();
        expect(out, contains('Status: needs_permission'));
        expect(out, contains('Tool Name: shell_execute'));
        expect(out, contains('Tool Input: {"command":"rm -rf /tmp/test"}'));
        expect(
          out,
          contains('sanad session permission sess-perm -r req-perm-42'),
        );
      });

      test('exposes authoritative fields in --json mode', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-json',
            'in_flight': {'run_id': 'run-100', 'type': 'thinking'},
            'pending_permission_request': {
              'request_id': 'req-100',
              'tool_name': 'system_ask_user',
              'questions': [
                {'question': 'Confirm deployment?'},
              ],
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'show',
          'sess-json',
          '--json',
        ]);
        expect(exitCode, equals(0));

        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-json'));
        expect(decoded['status'], equals('needs_input'));
        expect(decoded['in_flight'], isNotNull);
        expect(decoded['in_flight']['run_id'], equals('run-100'));
        expect(decoded['pending_permission_request'], isNotNull);
        expect(
          decoded['pending_permission_request']['request_id'],
          equals('req-100'),
        );
      });

      test('fails with exit code 1 when session ID is omitted', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'show']);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Session ID is required'));
      });
    });

    group('session stop', () {
      test('stops targeted session and outputs confirmation', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'stop', 'sess-to-stop']);
        expect(exitCode, equals(0));
        expect(client.lastStoppedSessionId, equals('sess-to-stop'));
        expect(stdoutBuf.toString(), contains('Session sess-to-stop stopped.'));
      });

      test('returns structured JSON in --json mode', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'stop',
          'sess-to-stop',
          '--json',
        ]);
        expect(exitCode, equals(0));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-to-stop'));
        expect(decoded['status'], equals('stopped'));
      });

      test('fails when session ID is missing', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'stop']);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Session ID is required'));
      });
    });

    group('session answer', () {
      test('submits direct clarification answer successfully', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'answer',
          'sess-1',
          '-r',
          'req-1',
          '--answer',
          'PostgreSQL',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastAnswerSessionId, equals('sess-1'));
        expect(client.lastAnswerRequestId, equals('req-1'));
        expect(client.lastAnswer, equals('PostgreSQL'));
        expect(stdoutBuf.toString(), contains('Answer submitted successfully'));
      });

      test('supports --file with raw text', () async {
        final file = File('${tempDir.path}/raw_answer.txt');
        file.writeAsStringSync('SQLite 3');

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'answer',
          'sess-1',
          '-r',
          'req-2',
          '--file',
          file.path,
        ]);
        expect(exitCode, equals(0));
        expect(client.lastAnswer, equals('SQLite 3'));
      });

      test('supports --file with JSON payload', () async {
        final file = File('${tempDir.path}/json_answer.json');
        file.writeAsStringSync(jsonEncode({'answer': 'MySQL 8.0'}));

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'answer',
          'sess-1',
          '-r',
          'req-3',
          '--file',
          file.path,
        ]);
        expect(exitCode, equals(0));
        expect(client.lastAnswer, equals('MySQL 8.0'));
      });

      test('rejects empty answer', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'answer',
          'sess-1',
          '-r',
          'req-1',
          '--answer',
          '   ',
        ]);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Answer cannot be empty'));
      });

      test('returns structured JSON in --json mode', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'answer',
          'sess-1',
          '-r',
          'req-1',
          '--answer',
          'Valid answer',
          '--json',
        ]);
        expect(exitCode, equals(0));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-1'));
        expect(decoded['request_id'], equals('req-1'));
        expect(decoded['status'], equals('resolved'));
      });
    });

    group('session permission', () {
      test('submits allow permission decision', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'permission',
          'sess-1',
          '-r',
          'req-1',
          '--allow',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastPermissionSessionId, equals('sess-1'));
        expect(client.lastPermissionRequestId, equals('req-1'));
        expect(client.lastPermissionAllowed, isTrue);
        expect(client.lastPermissionDecision, equals('allow'));
      });

      test('submits deny permission decision with comment and scope', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'permission',
          'sess-1',
          '-r',
          'req-2',
          '--deny',
          '--scope',
          'session',
          '--comment',
          'Destructive operation forbidden',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastPermissionAllowed, isFalse);
        expect(client.lastPermissionDecision, equals('deny'));
        expect(client.lastPermissionScope, equals('session'));
        expect(
          client.lastPermissionComment,
          equals('Destructive operation forbidden'),
        );
      });

      test('supports --file with JSON payload', () async {
        final file = File('${tempDir.path}/perm_decision.json');
        file.writeAsStringSync(
          jsonEncode({
            'allowed': true,
            'decision': 'allow',
            'scope': 'workspace',
          }),
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'permission',
          'sess-1',
          '-r',
          'req-3',
          '--file',
          file.path,
        ]);
        expect(exitCode, equals(0));
        expect(client.lastPermissionAllowed, isTrue);
        expect(client.lastPermissionDecision, equals('allow'));
        expect(client.lastPermissionScope, equals('workspace'));
      });

      test('rejects invocation when decision is missing', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'permission',
          'sess-1',
          '-r',
          'req-1',
        ]);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Decision must specify either'));
      });

      test('returns structured JSON in --json mode', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'permission',
          'sess-1',
          '-r',
          'req-1',
          '--allow',
          '--json',
        ]);
        expect(exitCode, equals(0));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-1'));
        expect(decoded['request_id'], equals('req-1'));
        expect(decoded['decision'], equals('allow'));
        expect(decoded['status'], equals('resolved'));
      });
    });
  });
}
