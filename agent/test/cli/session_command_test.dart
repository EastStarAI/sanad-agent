import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/client/local_gateway_cli_client.dart';
import 'package:sanad_agent/cli/runner/commands/session_command.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/core/constants.dart';
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
  String? lastStoppedRunId;
  Object? historyErrorToThrow;
  String? lastAnswerSessionId;
  String? lastAnswerRequestId;
  String? lastAnswer;
  String? lastPermissionSessionId;
  String? lastPermissionRequestId;
  bool? lastPermissionAllowed;
  String? lastPermissionDecision;
  String? lastPermissionScope;
  String? lastPermissionComment;
  String? lastCompactSessionId;
  Duration? lastCompactTimeout;
  bool? lastCompactResendOnTimeout;
  Map<String, dynamic>? compactResultToReturn;
  int compactCallCount = 0;
  bool isDisposed = false;
  Object? errorToThrow;

  FakeSessionGatewayClient()
    : super(gatewayUri: Uri.parse('ws://127.0.0.1:58085'), token: 'fake-token');

  @override
  Future<Map<String, dynamic>> compactSession({
    required String sessionId,
    Duration? timeout,
    bool resendOnTimeout = true,
  }) async {
    compactCallCount++;
    lastCompactSessionId = sessionId;
    lastCompactTimeout = timeout;
    lastCompactResendOnTimeout = resendOnTimeout;
    if (errorToThrow != null) throw errorToThrow!;
    return compactResultToReturn ??
        {
          'session_id': sessionId,
          'outcome': 'accepted',
          'compaction_id': 'cmp-fake-123',
        };
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await super.dispose();
  }

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
    if (historyErrorToThrow != null) throw historyErrorToThrow!;
    if (errorToThrow != null) throw errorToThrow!;
    return historyToReturn ?? {'messages': []};
  }

  @override
  Future<void> stop({
    required String sessionId,
    String? runId,
    Duration? timeout,
    Duration stopPollInterval = LocalGatewayCliClient.defaultStopPollInterval,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    lastStoppedSessionId = sessionId;
    lastStoppedRunId = runId;
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

      test(
        'surfaces the latest compaction lifecycle so a slow compact can be polled',
        () async {
          client.historyToReturn = {
            'payload': {
              'session_id': 'sess-poll',
              'messages': [
                {'type': 'user_message', 'content': 'hello'},
                {
                  'type': 'context_compaction.completed',
                  'compaction_id': 'cmp-old',
                  'trigger': 'auto',
                  'status': 'completed',
                },
                {
                  'type': 'context_compaction.started',
                  'compaction_id': 'cmp-live',
                  'trigger': 'manual',
                  'status': 'started',
                },
              ],
            },
          };

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'show',
            'sess-poll',
            '--json',
          ]);
          expect(exitCode, equals(0));
          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['compaction'], {
            'compaction_id': 'cmp-live',
            'status': 'started',
            'trigger': 'manual',
          });
        },
      );

      test(
        'is bounded by default and omits the full messages payload',
        () async {
          client.historyToReturn = {
            'payload': {
              'session_id': 'sess-bounded',
              'in_flight': {'run_id': 'run-200', 'type': 'thinking'},
              'execution_snapshot': {
                'state': 'running',
                'work_item_id': 'wi-200',
                'request_id': 'req-200',
                'revision': 7,
              },
              'model': 'deepseek-v4-flash',
              'provider_instance_id': 'OpenCode Go',
              'model_provider': 'OpenCode Go',
              'route_revision': 3,
              'thinking_mode': 'medium',
              'created_at': '2026-09-22T00:00:00.000Z',
              'updated_at': '2026-09-22T00:00:05.000Z',
              'last_user_message_at': '2026-09-22T00:00:01.000Z',
              'messages': [
                {'type': 'user_message', 'content': 'build the feature'},
                {'type': 'tool_use', 'tool': 'shell_execute', 'content': 'x'},
                {
                  'type': 'tool_result',
                  'tool': 'shell_execute',
                  'content': 'ok',
                },
                {'type': 'final_answer', 'content': 'done'},
              ],
            },
          };

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'show',
            'sess-bounded',
            '--json',
          ]);
          expect(exitCode, equals(0));

          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['session_id'], equals('sess-bounded'));
          expect(decoded['status'], equals('running'));
          // The full conversation payload must NOT be embedded by default.
          expect(decoded.containsKey('messages'), isFalse);
          expect(decoded['message_count'], equals(4));
          expect(decoded['model'], equals('deepseek-v4-flash'));
          expect(decoded['provider_instance_id'], equals('OpenCode Go'));
          expect(decoded['thinking_mode'], equals('medium'));
          expect(decoded['created_at'], isNotNull);
          expect(decoded['updated_at'], isNotNull);
          expect(decoded['last_user_message_at'], isNotNull);
          // Owner identities from execution state are surfaced.
          final identities = decoded['identities'] as Map<String, dynamic>;
          expect(identities['session_id'], equals('sess-bounded'));
          expect(identities['run_id'], equals('run-200'));
          expect(identities['work_item_id'], equals('wi-200'));
          expect(identities['request_id'], equals('req-200'));
          // Bounded summary counts include message and tool breakdowns.
          final summary = decoded['summary'] as Map<String, dynamic>;
          expect(summary['message_count'], equals(4));
          expect(summary['user_messages'], equals(1));
          expect(summary['tool_calls'], equals(1));
          expect(summary['tool_results'], equals(1));
          expect(summary['final_answers'], equals(1));
        },
      );

      test(
        'embeds full messages only with the --include-messages opt-in flag',
        () async {
          client.historyToReturn = {
            'payload': {
              'session_id': 'sess-full',
              'in_flight': {'run_id': 'run-300', 'type': 'thinking'},
              'model': 'deepseek-v4-flash',
              'messages': [
                {'type': 'user_message', 'content': 'refactor the module'},
                {'type': 'final_answer', 'content': 'refactored'},
              ],
            },
          };

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'show',
            'sess-full',
            '--json',
            '--include-messages',
          ]);
          expect(exitCode, equals(0));

          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['status'], equals('running'));
          final messages = decoded['messages'] as List;
          expect(messages, hasLength(2));
          expect(messages.first['content'], equals('refactor the module'));
          expect(decoded['summary'], isNotNull);
          expect((decoded['summary'] as Map)['message_count'], equals(2));
        },
      );

      test('fails with exit code 1 when session ID is omitted', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'show']);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Session ID is required'));
      });

      test(
        'reports idle instead of a stale in-flight snapshot when no run owns '
        'the durable execution',
        () async {
          client.historyToReturn = {
            'payload': {
              'session_id': 'sess-stale',
              'in_flight': {
                'run_id': 'run-stale',
                'type': 'thought_stream',
                'status': 'running',
                'updated_at': 1792632757780,
              },
              'execution_snapshot': {
                'session_id': 'sess-stale',
                'state': 'idle',
                'revision': 4,
              },
            },
          };

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'show',
            'sess-stale',
            '--json',
          ]);
          expect(exitCode, equals(0));

          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(
            decoded['status'],
            equals('idle'),
            reason:
                'an idle durable projection means no run is publishing, so a '
                'leftover partial-stream snapshot is stale',
          );
          expect((decoded['identities'] as Map)['run_id'], isNull);
        },
      );
    });

    group('session stop', () {
      test('stops targeted session and outputs confirmation', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'stop', 'sess-to-stop']);
        expect(exitCode, equals(0));
        expect(client.lastStoppedSessionId, equals('sess-to-stop'));
        expect(stdoutBuf.toString(), contains('Session sess-to-stop stopped.'));
      });

      test('names the in-flight run id from session state', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-running',
            'in_flight': {
              'run_id': 'run-inflight-1',
              'type': 'thought_stream',
              'status': 'running',
            },
          },
        };
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'stop',
          'sess-running',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastStoppedSessionId, equals('sess-running'));
        expect(
          client.lastStoppedRunId,
          equals('run-inflight-1'),
          reason:
              'the CLI stop must name the execution the operator observed',
        );
      });

      test('still dispatches the stop when session state cannot be read', () async {
        client.historyErrorToThrow = const CliClientException(
          'state unavailable',
          code: 'query_timeout',
        );
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'stop',
          'sess-unknown',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastStoppedSessionId, equals('sess-unknown'));
        expect(client.lastStoppedRunId, isNull);
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

    group('session compact', () {
      test('subcommand is registered in session command and prints help cleanly', () async {
        final runner = buildRunner();
        final sessionCmd = runner.commands['session'] as SessionCommand;
        expect(sessionCmd.subcommands.containsKey('compact'), isTrue);
        expect(sessionCmd.usage, contains('compact'));
        expect(
          sessionCmd.usage,
          contains('Request context compaction admission for a specific session'),
        );

        final exitCode = await runner.run(['session', '--help']);
        expect(exitCode, equals(0));
      });

      test('routes compact subcommand metadata and handles --help flag cleanly', () async {
        final runner = buildRunner();
        final sessionCmd = runner.commands['session'] as SessionCommand;
        final compactCmd = sessionCmd.subcommands['compact'] as SessionCompactCommand;
        expect(compactCmd.name, equals('compact'));
        expect(
          compactCmd.description,
          contains('Request context compaction admission for a specific session'),
        );
        expect(compactCmd.invocation, equals('sanad session compact <session-id>'));
        expect(
          compactCmd.usage,
          contains('Request context compaction admission for a specific session'),
        );
        expect(compactCmd.usage, contains('sanad session compact <session-id>'));
        expect(compactCmd.argParser.options.keys, contains('timeout'));
        expect(compactCmd.argParser.options.keys, contains('json'));

        final exitCode = await runner.run(['session', 'compact', '--help']);
        expect(exitCode, equals(0));
      });

      test('requires explicit session ID (fails when missing)', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'compact']);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Session ID is required'));
        expect(client.compactCallCount, equals(0));
      });

      test('requires explicit session ID in --json mode (returns JSON error)', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'compact', '--json']);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Session ID is required'));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['exit_code'], equals(1));
        expect(decoded['error'], contains('Session ID is required'));
        expect(client.compactCallCount, equals(0));
      });

      test('compacts session by positional ID and returns admission message', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'compact', 'sess-pos-1']);
        expect(exitCode, equals(0));
        expect(client.lastCompactSessionId, equals('sess-pos-1'));
        expect(client.lastCompactResendOnTimeout, isFalse);
        expect(
          stdoutBuf.toString(),
          contains(
            'Compaction request accepted for session sess-pos-1 (compaction_id: cmp-fake-123).',
          ),
        );
      });

      test('compacts session via --session option', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          '--session',
          'sess-opt-1',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastCompactSessionId, equals('sess-opt-1'));
        expect(client.lastCompactResendOnTimeout, isFalse);
      });

      test('returns structured JSON in --json mode for accepted admission', () async {
        client.compactResultToReturn = {
          'session_id': 'sess-accepted-1',
          'request_id': 'req-cmp-1',
          'outcome': 'accepted',
          'compaction_id': 'cmp-999',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-accepted-1',
          '--json',
        ]);
        expect(exitCode, equals(0));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-accepted-1'));
        expect(decoded['request_id'], equals('req-cmp-1'));
        expect(decoded['outcome'], equals('accepted'));
        expect(decoded['compaction_id'], equals('cmp-999'));
      });

      test('returns structured JSON in --json mode for dispatched admission', () async {
        client.compactResultToReturn = {
          'session_id': 'sess-disp-1',
          'outcome': 'dispatched',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-disp-1',
          '--json',
        ]);
        expect(exitCode, equals(0));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-disp-1'));
        expect(decoded['outcome'], equals('dispatched'));
      });

      test('handles no_op outcome with exit code 0', () async {
        client.compactResultToReturn = {
          'session_id': 'sess-noop-1',
          'outcome': 'no_op',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-noop-1',
        ]);
        expect(exitCode, equals(0));
        expect(
          stdoutBuf.toString(),
          contains('No compaction needed for session sess-noop-1.'),
        );
      });

      test('returns structured JSON and exit code 1 for failed outcome', () async {
        client.compactResultToReturn = {
          'session_id': 'sess-fail-1',
          'outcome': 'failed',
          'failure_reason': 'session_busy',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-fail-1',
          '--json',
        ]);
        expect(exitCode, equals(1));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-fail-1'));
        expect(decoded['outcome'], equals('failed'));
        expect(decoded['failure_reason'], equals('session_busy'));
        expect(decoded['exit_code'], equals(1));
      });

      test('propagates --timeout option as Duration', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-timeout-1',
          '--timeout',
          '15',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastCompactTimeout, equals(const Duration(seconds: 15)));
        expect(client.lastCompactResendOnTimeout, isFalse);
      });

      test(
        'waits by default for the configured compaction pass timeout, not 5 s',
        () async {
          File('${getSanadHome()}/config.yaml').writeAsStringSync(
            'compaction:\n  passTimeoutSeconds: 42\n',
          );
          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'compact',
            'sess-default-bound',
          ]);
          expect(exitCode, equals(0));
          expect(
            client.lastCompactTimeout,
            equals(const Duration(seconds: 42)),
          );
          expect(client.lastCompactResendOnTimeout, isFalse);
        },
      );

      test('an invalid --timeout falls back to the configured bound', () async {
        File('${getSanadHome()}/config.yaml').writeAsStringSync(
          'compaction:\n  passTimeoutSeconds: 37\n',
        );
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-bad-timeout',
          '--timeout',
          'soon',
        ]);
        expect(exitCode, equals(0));
        expect(client.lastCompactTimeout, equals(const Duration(seconds: 37)));
      });

      test(
        'an exhausted wait reports unconfirmed with exit 124, never failed',
        () async {
          client.errorToThrow = const CliClientException(
            'Gateway query "session.compact" timed out after 42s',
            code: 'query_timeout',
          );

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'compact',
            'sess-slow-1',
            '--json',
          ]);
          expect(exitCode, equals(124));
          expect(client.compactCallCount, equals(1));
          expect(client.lastCompactResendOnTimeout, isFalse);
          expect(stderrBuf.toString(), contains('may still be compacting'));
          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['session_id'], equals('sess-slow-1'));
          expect(decoded['outcome'], equals('unconfirmed'));
          expect(decoded['exit_code'], equals(124));
          expect(decoded.containsKey('failure_reason'), isFalse);
          expect(decoded['poll'], equals('sanad session show sess-slow-1'));
        },
      );

      test('handles gateway error with exit code 1 and error JSON', () async {
        client.errorToThrow = const CliClientException(
          'Gateway connection failed',
          code: 'gateway_error',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-err-1',
          '--json',
        ]);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Gateway connection failed'));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-err-1'));
        expect(decoded['exit_code'], equals(1));
        expect(decoded['error'], contains('Gateway connection failed'));
      });

      test('handles missing or malformed outcome with failed outcome and exit code 1', () async {
        client.compactResultToReturn = <String, dynamic>{};

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-malformed-1',
          '--json',
        ]);
        expect(exitCode, equals(1));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-malformed-1'));
        expect(decoded['outcome'], equals('failed'));
        expect(decoded['failure_reason'], equals('missing_outcome'));
        expect(decoded['exit_code'], equals(1));
      });

      test('handles real daemon outcome session_busy with exit code 1', () async {
        client.compactResultToReturn = {
          'session_id': 'sess-busy-1',
          'outcome': 'session_busy',
          'failure_reason': 'session_busy',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-busy-1',
          '--json',
        ]);
        expect(exitCode, equals(1));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-busy-1'));
        expect(decoded['outcome'], equals('session_busy'));
        expect(decoded['failure_reason'], equals('session_busy'));
        expect(decoded['exit_code'], equals(1));
      });

      test('handles real daemon outcome compaction_in_progress with exit code 1', () async {
        client.compactResultToReturn = {
          'session_id': 'sess-in-prog-1',
          'outcome': 'compaction_in_progress',
          'failure_reason': 'compaction_in_progress',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-in-prog-1',
          '--json',
        ]);
        expect(exitCode, equals(1));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['session_id'], equals('sess-in-prog-1'));
        expect(decoded['outcome'], equals('compaction_in_progress'));
        expect(decoded['failure_reason'], equals('compaction_in_progress'));
        expect(decoded['exit_code'], equals(1));
      });

      test('propagates --home and --gateway-url overrides and disposes client', () async {
        String? capturedUrl;
        String? capturedHome;
        final factoryClient = FakeSessionGatewayClient();

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          clientFactory: ({urlOverride, sanadHomeOverride}) async {
            capturedUrl = urlOverride;
            capturedHome = sanadHomeOverride;
            return factoryClient;
          },
        );

        final exitCode = await runner.run([
          'session',
          'compact',
          'sess-prop-1',
          '--home',
          '/custom/sanad/home',
          '--gateway-url',
          'ws://127.0.0.1:59999/ws',
        ]);

        expect(exitCode, equals(0));
        expect(capturedUrl, equals('ws://127.0.0.1:59999/ws'));
        expect(capturedHome, equals('/custom/sanad/home'));
        expect(factoryClient.lastCompactSessionId, equals('sess-prop-1'));
        expect(factoryClient.isDisposed, isTrue);
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
