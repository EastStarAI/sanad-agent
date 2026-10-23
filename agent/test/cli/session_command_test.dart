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
  String? lastSteerSessionId;
  String? lastSteerMessage;
  String? lastSteerRequestId;
  bool? lastSteerOnly;
  Duration? lastSteerAckTimeout;
  int steerCallCount = 0;
  Map<String, dynamic>? steerAckToReturn;
  Object? steerErrorToThrow;
  String? lastRetrySessionId;
  String? lastRetryRequestId;
  String? lastRetryProviderInstanceId;
  String? lastRetryModelId;
  Duration? lastRetryAckTimeout;
  int retryCallCount = 0;
  Map<String, dynamic>? retryAckToReturn;
  Object? retryErrorToThrow;
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
  Future<Map<String, dynamic>> steerAndAwaitAck({
    required String sessionId,
    required String message,
    String? workspaceId,
    String? model,
    String? requestId,
    bool steerOnly = false,
    Duration? timeout,
  }) async {
    steerCallCount++;
    lastSteerSessionId = sessionId;
    lastSteerMessage = message;
    lastSteerRequestId = requestId;
    lastSteerOnly = steerOnly;
    lastSteerAckTimeout = timeout;
    if (steerErrorToThrow != null) throw steerErrorToThrow!;
    return steerAckToReturn ??
        {
          'session_id': sessionId,
          'request_id': requestId ?? 'req-steer-fake-1',
          'event': 'session.message_classified',
          'classification': 'steer',
        };
  }

  @override
  Future<Map<String, dynamic>> retryRuntimeAndAwaitAck({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    Duration? timeout,
  }) async {
    retryCallCount++;
    lastRetrySessionId = sessionId;
    lastRetryRequestId = requestId;
    lastRetryProviderInstanceId = providerInstanceId;
    lastRetryModelId = modelId;
    lastRetryAckTimeout = timeout;
    if (retryErrorToThrow != null) throw retryErrorToThrow!;
    return retryAckToReturn ??
        {
          'session_id': sessionId,
          'request_id': requestId ?? 'req-retry-fake-1',
          'event': 'session.runtime_notice',
          'status': 'resuming',
          'notice_request_id': 'req-turn-fake-1',
          'correlated': false,
        };
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
            // The daemon always projects the session's own identity; a
            // projection without it is the not-found answer.
            'title': 'Ask session',
            'created_at': '2026-09-22T00:00:00.000Z',
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
            'title': 'Permission session',
            'created_at': '2026-09-22T00:00:00.000Z',
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
            'title': 'JSON session',
            'created_at': '2026-09-22T00:00:00.000Z',
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
              'title': 'Poll session',
              'created_at': '2026-09-22T00:00:00.000Z',
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
              'title': 'Full session',
              'created_at': '2026-09-22T00:00:00.000Z',
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
              'title': 'Stale session',
              'created_at': '2026-09-22T00:00:00.000Z',
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
      test(
        'a retryable failure with budget left reports retrying, not idle or blocked',
        () async {
          // The 2026-10-23 shape: the daemon published a retryable provider
          // timeout it was already retrying. The projection must carry the
          // authoritative execution state, the notice, and its counters.
          client.historyToReturn = {
            'payload': {
              'session_id': 'sess-retrying',
              'title': 'Retrying session',
              'created_at': '2026-10-23T06:57:00.000Z',
              'execution_snapshot': {
                'session_id': 'sess-retrying',
                'state': 'waiting',
                'work_item_id': 'wi-retrying',
                'request_id': 'req-turn-retrying',
                'revision': 9,
                'updated_at': '2026-10-23T06:57:01.000Z',
              },
              'runtime_notice': {
                'session_id': 'sess-retrying',
                'request_id': 'req-turn-retrying',
                'status': 'waiting',
                'reason': 'timeout',
                'severity': 'warning',
                'title': 'Request timed out',
                'message': 'The request took too long to complete. Retrying '
                    'automatically in 2s (attempt 1 of 1).',
                'retry_attempt': 1,
                'retry_budget': 1,
                'retry_after_ms': 2000,
                'resume_at': '2026-10-23T06:57:03.000Z',
                'actions': ['stop', 'change_provider'],
              },
              'messages': [
                {'type': 'user_message', 'content': 'build the feature'},
              ],
            },
          };

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'show',
            'sess-retrying',
            '--json',
          ]);
          expect(exitCode, equals(0));

          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['status'], equals('retrying'));
          expect(decoded['execution_state'], equals('waiting'));
          expect(decoded['runtime_notice'], isNotNull);
          expect((decoded['runtime_notice'] as Map)['status'], equals('waiting'));
          expect(
            (decoded['runtime_notice'] as Map)['retry_attempt'],
            equals(1),
          );
          expect(
            (decoded['runtime_notice'] as Map)['retry_budget'],
            equals(1),
          );
          final retry = decoded['retry'] as Map<String, dynamic>;
          expect(retry['pending'], isTrue);
          expect(retry['stopped'], isFalse);
          expect(retry['attempt'], equals(1));
          expect(retry['budget'], equals(1));
          expect(retry['reason'], equals('timeout'));
          expect(retry['label'], equals('retrying (1/1)'));
        },
      );

      test('a retryable failure with budget left is reported in text mode', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-retrying-text',
            'title': 'Retrying session',
            'created_at': '2026-10-23T06:57:00.000Z',
            'execution_snapshot': {
              'session_id': 'sess-retrying-text',
              'state': 'blocked',
              'revision': 9,
            },
            'runtime_notice': {
              'session_id': 'sess-retrying-text',
              'status': 'blocked',
              'reason': 'timeout',
              'retry_attempt': 1,
              'retry_budget': 3,
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        expect(
          await runner.run(['session', 'show', 'sess-retrying-text']),
          equals(0),
        );
        final out = stdoutBuf.toString();
        expect(out, contains('Status: retrying'));
        expect(out, contains('Execution: blocked'));
        expect(out, contains('Recovery: retrying (1/3)'));
      });

      test('an exhausted retry budget reports a stopped turn', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-stopped',
            'title': 'Stopped session',
            'created_at': '2026-10-23T06:57:00.000Z',
            'execution_snapshot': {
              'session_id': 'sess-stopped',
              'state': 'blocked',
              'revision': 11,
            },
            'runtime_notice': {
              'session_id': 'sess-stopped',
              'status': 'blocked',
              'reason': 'timeout',
              'retry_attempt': 1,
              'retry_budget': 1,
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        expect(
          await runner.run(['session', 'show', 'sess-stopped', '--json']),
          equals(0),
        );
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['status'], equals('blocked'));
        final retry = decoded['retry'] as Map<String, dynamic>;
        expect(retry['pending'], isFalse);
        expect(retry['stopped'], isTrue);
        expect(retry['label'], equals('needs_intervention'));
      });

      test('a non-retryable failure reports a stopped turn', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-auth',
            'title': 'Auth session',
            'created_at': '2026-10-23T06:57:00.000Z',
            'execution_snapshot': {
              'session_id': 'sess-auth',
              'state': 'blocked',
              'revision': 3,
            },
            'runtime_notice': {
              'session_id': 'sess-auth',
              'status': 'blocked',
              'reason': 'auth',
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        expect(
          await runner.run(['session', 'show', 'sess-auth', '--json']),
          equals(0),
        );
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['status'], equals('blocked'));
        final retry = decoded['retry'] as Map<String, dynamic>;
        expect(retry['pending'], isFalse);
        expect(retry['stopped'], isTrue);
        expect(retry['attempt'], isNull);
        expect(retry['budget'], isNull);
      });

      test('an unknown session id is a not-found error, never idle', () async {
        // The daemon omits the session's own identity fields when it does not
        // know the id; reporting that projection as `idle` with exit 0 made an
        // unknown id indistinguishable from a stopped turn (Task 141).
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-missing',
            'messages': [],
            'execution_snapshot': {
              'session_id': 'sess-missing',
              'state': 'idle',
              'revision': 0,
            },
            'pending_permission_request': null,
            'in_flight': null,
          },
        };

        final runner = buildRunner();
        expect(
          await runner.run(['session', 'show', 'sess-missing', '--json']),
          equals(1),
        );
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('session_not_found'));
        expect(decoded['session_id'], equals('sess-missing'));
        expect(decoded['status'], isNull);
        expect(stderrBuf.toString(), contains('was not found'));
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
        final exitCode = await runner.run(['session', 'stop', 'sess-running']);
        expect(exitCode, equals(0));
        expect(client.lastStoppedSessionId, equals('sess-running'));
        expect(
          client.lastStoppedRunId,
          equals('run-inflight-1'),
          reason: 'the CLI stop must name the execution the operator observed',
        );
      });

      test(
        'still dispatches the stop when session state cannot be read',
        () async {
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
        },
      );

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
      test(
        'subcommand is registered in session command and prints help cleanly',
        () async {
          final runner = buildRunner();
          final sessionCmd = runner.commands['session'] as SessionCommand;
          expect(sessionCmd.subcommands.containsKey('compact'), isTrue);
          expect(sessionCmd.usage, contains('compact'));
          expect(
            sessionCmd.usage,
            contains(
              'Request context compaction admission for a specific session',
            ),
          );

          final exitCode = await runner.run(['session', '--help']);
          expect(exitCode, equals(0));
        },
      );

      test(
        'routes compact subcommand metadata and handles --help flag cleanly',
        () async {
          final runner = buildRunner();
          final sessionCmd = runner.commands['session'] as SessionCommand;
          final compactCmd =
              sessionCmd.subcommands['compact'] as SessionCompactCommand;
          expect(compactCmd.name, equals('compact'));
          expect(
            compactCmd.description,
            contains(
              'Request context compaction admission for a specific session',
            ),
          );
          expect(
            compactCmd.invocation,
            equals('sanad session compact <session-id>'),
          );
          expect(
            compactCmd.usage,
            contains(
              'Request context compaction admission for a specific session',
            ),
          );
          expect(
            compactCmd.usage,
            contains('sanad session compact <session-id>'),
          );
          expect(compactCmd.argParser.options.keys, contains('timeout'));
          expect(compactCmd.argParser.options.keys, contains('json'));

          final exitCode = await runner.run(['session', 'compact', '--help']);
          expect(exitCode, equals(0));
        },
      );

      test('requires explicit session ID (fails when missing)', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'compact']);
        expect(exitCode, equals(1));
        expect(stderrBuf.toString(), contains('Session ID is required'));
        expect(client.compactCallCount, equals(0));
      });

      test(
        'requires explicit session ID in --json mode (returns JSON error)',
        () async {
          final runner = buildRunner();
          final exitCode = await runner.run(['session', 'compact', '--json']);
          expect(exitCode, equals(1));
          expect(stderrBuf.toString(), contains('Session ID is required'));
          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['exit_code'], equals(1));
          expect(decoded['error'], contains('Session ID is required'));
          expect(client.compactCallCount, equals(0));
        },
      );

      test(
        'compacts session by positional ID and returns admission message',
        () async {
          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'compact',
            'sess-pos-1',
          ]);
          expect(exitCode, equals(0));
          expect(client.lastCompactSessionId, equals('sess-pos-1'));
          expect(client.lastCompactResendOnTimeout, isFalse);
          expect(
            stdoutBuf.toString(),
            contains(
              'Compaction request accepted for session sess-pos-1 (compaction_id: cmp-fake-123).',
            ),
          );
        },
      );

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

      test(
        'returns structured JSON in --json mode for accepted admission',
        () async {
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
        },
      );

      test(
        'returns structured JSON in --json mode for dispatched admission',
        () async {
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
        },
      );

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

      test(
        'returns structured JSON and exit code 1 for failed outcome',
        () async {
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
        },
      );

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
          File(
            '${getSanadHome()}/config.yaml',
          ).writeAsStringSync('compaction:\n  passTimeoutSeconds: 42\n');
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
        File(
          '${getSanadHome()}/config.yaml',
        ).writeAsStringSync('compaction:\n  passTimeoutSeconds: 37\n');
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

      test(
        'handles missing or malformed outcome with failed outcome and exit code 1',
        () async {
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
        },
      );

      test(
        'handles real daemon outcome session_busy with exit code 1',
        () async {
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
        },
      );

      test(
        'handles real daemon outcome compaction_in_progress with exit code 1',
        () async {
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
        },
      );

      test(
        'propagates --home and --gateway-url overrides and disposes client',
        () async {
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
        },
      );
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
    group('session steer', () {
      /// A session projection that proves a run currently owns the session, so
      /// the steer pre-check is satisfied.
      void useRunningSession({String sessionId = 'sess-live'}) {
        client.historyToReturn = {
          'payload': {
            'session_id': sessionId,
            'execution_snapshot': {
              'state': 'running',
              'work_item_id': 'wi-live',
              'request_id': 'req-turn-live',
            },
            'in_flight': {'run_id': 'run-live', 'type': 'thought_stream'},
            'messages': [],
          },
        };
      }

      test('steers the active turn and reports the request id', () async {
        useRunningSession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          '  Add an audit trail to the endpoint  ',
        ]);

        expect(exitCode, equals(0));
        expect(client.lastSteerSessionId, equals('sess-live'));
        expect(
          client.lastSteerMessage,
          equals('Add an audit trail to the endpoint'),
          reason: 'the delivered text is the trimmed message payload',
        );
        expect(
          client.lastSteerOnly,
          isTrue,
          reason:
              'every CLI steer is `steer_only`, so the daemon can never turn '
              'the text into a turn or a queued turn',
        );
        expect(client.lastSteerRequestId, isNotNull);
        expect(
          stdoutBuf.toString().trim(),
          equals(
            'Steer sent to session sess-live '
            '(request ${client.lastSteerRequestId}).',
          ),
        );
      });

      test('returns the documented JSON envelope in --json mode', () async {
        useRunningSession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add an audit trail',
          '--json',
        ]);

        expect(exitCode, equals(0));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded, {
          'session_id': 'sess-live',
          'request_id': client.lastSteerRequestId,
          'status': 'steer_sent',
        });
      });

      test('reads the steer text from --message-file', () async {
        useRunningSession();
        final file = File('${tempDir.path}/steer.txt')
          ..writeAsStringSync('\n  Prefer the repository helper.  \n');

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message-file',
          file.path,
        ]);

        expect(exitCode, equals(0));
        expect(
          client.lastSteerMessage,
          equals('Prefer the repository helper.'),
        );
        expect(
          stdoutBuf.toString(),
          contains('Steer sent to session sess-live'),
        );
      });

      test('rejects an empty --message-file', () async {
        final file = File('${tempDir.path}/empty.txt')
          ..writeAsStringSync('   \n');

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message-file',
          file.path,
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUsage));
        expect(stderrBuf.toString(), contains('is empty'));
        expect(client.steerCallCount, isZero);
      });

      test('rejects a missing --message-file', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message-file',
          '${tempDir.path}/absent.txt',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUsage));
        expect(stderrBuf.toString(), contains('does not exist'));
        expect(client.steerCallCount, isZero);
      });

      test('requires exactly one of --message and --message-file', () async {
        final file = File('${tempDir.path}/steer.txt')
          ..writeAsStringSync('both');

        for (final argv in [
          ['session', 'steer', 'sess-live'],
          [
            'session',
            'steer',
            'sess-live',
            '--message',
            'text',
            '--message-file',
            file.path,
          ],
        ]) {
          stdoutBuf.clear();
          stderrBuf.clear();
          final runner = buildRunner();
          final exitCode = await runner.run(argv);
          expect(exitCode, equals(SessionSteerCommand.exitUsage));
          expect(stderrBuf.toString(), isNotEmpty);
        }
        expect(client.steerCallCount, isZero);
      });

      test('rejects an empty or whitespace-only message', () async {
        useRunningSession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          '   ',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUsage));
        expect(stderrBuf.toString(), contains('Message cannot be empty.'));
        expect(client.steerCallCount, isZero);
      });

      test('requires a session id', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          '--message',
          'text',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUsage));
        expect(stderrBuf.toString(), contains('Session ID is required.'));
      });

      test('reports no_active_turn and never dispatches when nothing owns '
          'the session', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-idle',
            'execution_snapshot': {'state': 'idle'},
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-idle',
          '--message',
          'Add scope',
          '--json',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitNoActiveTurn));
        expect(
          client.steerCallCount,
          isZero,
          reason:
              'the daemon would admit the steer as a fresh turn and create it',
        );
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('no_active_turn'));
        expect(decoded['status'], equals('error'));
        expect(
          decoded['exit_code'],
          equals(SessionSteerCommand.exitNoActiveTurn),
        );
      });

      test(
        'does not read a stale in_flight projection as an active turn',
        () async {
          client.historyToReturn = {
            'payload': {
              'session_id': 'sess-stale',
              'execution_snapshot': {'state': 'idle'},
              'in_flight': {'run_id': 'run-stale', 'type': 'thought_stream'},
              'messages': [],
            },
          };

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'steer',
            'sess-stale',
            '--message',
            'Add scope',
          ]);

          expect(exitCode, equals(SessionSteerCommand.exitNoActiveTurn));
          expect(client.steerCallCount, isZero);
        },
      );

      test('maps a gateway that queued the text to queued_as_turn', () async {
        useRunningSession();
        client.steerAckToReturn = {
          'session_id': 'sess-live',
          'request_id': 'req-steer-queued',
          'event': 'session.message_classified',
          'classification': 'queue',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--json',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitQueuedAsTurn));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('queued_as_turn'));
        expect(decoded['request_id'], equals('req-steer-queued'));
        expect(
          decoded['error'],
          contains('a turn is now queued'),
          reason: 'the message must say a turn is queued, not that it steered',
        );
        expect(stdoutBuf.toString(), isNot(contains('Add scope')));
      });

      test('maps a steer admitted as a new turn to admitted_as_turn', () async {
        useRunningSession();
        client.steerAckToReturn = {
          'session_id': 'sess-live',
          'request_id': 'req-steer-turned-into-turn',
          'event': 'session.message_classified',
          'classification': 'think',
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--json',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitAdmittedAsTurn));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(
          decoded['error_code'],
          equals('admitted_as_turn'),
          reason:
              'an older daemon that admitted the text as a turn is not the '
              'same condition as having no active turn',
        );
        expect(
          decoded['error'],
          contains('a turn is now running'),
          reason: 'the message must say a turn is running, not that it steered',
        );
        expect(
          decoded['request_id'],
          equals('req-steer-turned-into-turn'),
        );
      });

      test('reports the daemon steer_only rejection as no_active_turn', () async {
        useRunningSession();
        client.steerErrorToThrow = const CliClientException(
          'No run currently owns session sess-live, so the steer was rejected.',
          code: 'no_active_turn',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--json',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitNoActiveTurn));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('no_active_turn'));
        expect(
          decoded['error'],
          contains('no turn was started'),
          reason: 'the daemon guarantees nothing was queued or admitted',
        );
      });

      test('maps an unacknowledged steer to its own exit code', () async {
        useRunningSession();
        client.steerErrorToThrow = const CliClientException(
          'Gateway did not acknowledge the steer within 15s; it may still be '
          'dispatched.',
          code: 'steer_unacknowledged',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--json',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUnacknowledged));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('steer_unacknowledged'));
      });

      test('maps a typed gateway rejection to a distinct exit code', () async {
        useRunningSession();
        client.steerErrorToThrow = const CliClientException(
          'steer target is not steerable',
          code: 'invalid_request',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--json',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitNotSteerable));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('invalid_request'));
        expect(
          decoded['exit_code'],
          equals(SessionSteerCommand.exitNotSteerable),
        );
      });

      test('maps a transport failure to the generic failure code', () async {
        useRunningSession();
        client.steerErrorToThrow = const CliClientException(
          'Cannot send command: client is not connected to gateway.',
          code: 'not_connected',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitFailed));
      });

      test(
        'maps an unreachable daemon to exit 1, never to "Gateway rejected"',
        () async {
          useRunningSession();
          // The two connect-time codes an unreachable daemon actually raises.
          for (final code in ['connection_failed', 'disposed']) {
            stdoutBuf.clear();
            stderrBuf.clear();
            client.steerCallCount = 0;
            client.steerErrorToThrow = CliClientException(
              'Failed to connect to gateway at ws://127.0.0.1:1/gateway',
              code: code,
            );

            final runner = buildRunner();
            final exitCode = await runner.run([
              'session',
              'steer',
              'sess-live',
              '--message',
              'Add scope',
              '--json',
            ]);

            expect(
              exitCode,
              equals(SessionSteerCommand.exitFailed),
              reason: '$code is a transport failure, not a gateway verdict',
            );
            final decoded =
                jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
            expect(decoded['error_code'], equals(code));
            expect(stderrBuf.toString(), isNot(contains('Gateway rejected')));
          }
        },
      );

      test('fails closed when the session projection cannot be read', () async {
        client.historyErrorToThrow = const CliClientException(
          'state unavailable',
          code: 'query_timeout',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitFailed));
        expect(
          client.steerCallCount,
          isZero,
          reason: 'a steer is never dispatched without the ownership read',
        );
      });

      test(
        'reports a typed session-state read failure as its own condition',
        () async {
          client.historyErrorToThrow = const CliClientException(
            'cursor is stale',
            code: 'stale_cursor',
          );

          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'steer',
            'sess-live',
            '--message',
            'Add scope',
            '--json',
          ]);

          expect(
            exitCode,
            equals(SessionSteerCommand.exitStateUnreadable),
            reason: 'no steer was sent, so this is not a steer rejection',
          );
          expect(
            client.steerCallCount,
            isZero,
            reason: 'the pre-check never dispatches after a failed read',
          );
          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          expect(decoded['error_code'], equals('session_state_unreadable'));
          expect(decoded['error'], contains('no steer was sent'));
          expect(
            decoded['request_id'],
            isA<String>(),
            reason: 'the request identity is allocated before the read',
          );
          expect(decoded['request_id'], isNotEmpty);
        },
      );

      test('reads the daemon execution-snapshot payload as the ownership '
          'proof', () async {
        // Exactly the fields `SessionExecutionSnapshot.toPayload` projects. The
        // payload carries no in-memory stop flag, so steerability is decided on
        // the durable state alone and an extra unknown field changes nothing.
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-live',
            'execution_snapshot': {
              'session_id': 'sess-live',
              'state': 'running',
              'work_item_id': 'wi-1',
              'request_id': 'req-1',
              'revision': 3,
              'updated_at': '2026-10-22T20:00:00.000Z',
              'turn_started_at': '2026-10-22T19:59:00.000Z',
              'elapsed_ms': 60000,
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitAccepted));
        expect(client.steerCallCount, equals(1));
      });

      test('treats the durable stopping state as not steerable', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-stopping',
            'execution_snapshot': {
              'session_id': 'sess-stopping',
              'state': 'stopping',
              'work_item_id': 'wi-1',
              'request_id': 'req-1',
              'revision': 4,
              'updated_at': '2026-10-22T20:00:00.000Z',
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-stopping',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitNoActiveTurn));
        expect(client.steerCallCount, isZero);
      });

      test('treats a waiting runtime recovery notice as not steerable', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-waiting',
            'execution_snapshot': {'state': 'running'},
            'runtime_notice': {
              'status': 'waiting',
              'reason': 'rate_limited',
              'title': 'Rate limited',
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-waiting',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitNoActiveTurn));
        expect(client.steerCallCount, isZero);
      });

      test('steers a running session whose notice is resuming', () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-resuming',
            'execution_snapshot': {'state': 'running'},
            'runtime_notice': {'status': 'resuming', 'reason': 'recovered'},
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-resuming',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(0));
        expect(client.lastSteerSessionId, equals('sess-resuming'));
      });

      test('names the request id in every outcome, including a timeout', () async {
        useRunningSession();
        client.steerErrorToThrow = const CliClientException(
          'Gateway did not acknowledge the steer within 15s; it may still be '
          'dispatched.',
          code: 'steer_unacknowledged',
        );

        final plainRunner = buildRunner();
        final plainExit = await plainRunner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
        ]);
        expect(plainExit, equals(SessionSteerCommand.exitUnacknowledged));
        expect(
          stderrBuf.toString(),
          contains('(request ${client.lastSteerRequestId})'),
        );

        stdoutBuf.clear();
        stderrBuf.clear();
        final jsonRunner = buildRunner();
        final jsonExit = await jsonRunner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--json',
        ]);
        expect(jsonExit, equals(SessionSteerCommand.exitUnacknowledged));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['request_id'], equals(client.lastSteerRequestId));
        expect(decoded['error_code'], equals('steer_unacknowledged'));
      });

      test('rejects an unusable --timeout as a usage error', () async {
        useRunningSession();
        for (final value in ['0', '-5', 'abc', '86401']) {
          stdoutBuf.clear();
          stderrBuf.clear();
          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'steer',
            'sess-live',
            '--message',
            'Add scope',
            '--timeout',
            value,
          ]);

          expect(
            exitCode,
            equals(SessionSteerCommand.exitUsage),
            reason: '--timeout $value must not silently fall back',
          );
          expect(stderrBuf.toString(), contains('--timeout must be'));
        }
        expect(client.steerCallCount, isZero);
      });

      test('rejects a directory passed to --message-file', () async {
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message-file',
          tempDir.path,
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUsage));
        expect(stderrBuf.toString(), contains('is a directory'));
        expect(client.steerCallCount, isZero);
      });

      test('uses the --message-file path verbatim, without trimming', () async {
        useRunningSession();
        final file = File('${tempDir.path}/ steer body .txt')
          ..writeAsStringSync('Prefer the repository helper.');

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message-file',
          // A quoted path keeps exactly the bytes the caller passed.
          ' ${file.path} ',
        ]);

        expect(
          exitCode,
          equals(SessionSteerCommand.exitUsage),
          reason: 'the untrimmed path does not name the file on disk',
        );
        expect(stderrBuf.toString(), contains('does not exist'));

        stdoutBuf.clear();
        stderrBuf.clear();
        final exactRunner = buildRunner();
        final exactExit = await exactRunner.run([
          'session',
          'steer',
          'sess-live',
          '--message-file',
          file.path,
        ]);
        expect(exactExit, equals(0));
        expect(client.lastSteerMessage, equals('Prefer the repository helper.'));
      });

      test('rejects --message together with --message-file even when one is '
          'blank', () async {
        final file = File('${tempDir.path}/steer.txt')
          ..writeAsStringSync('body');

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          '',
          '--message-file',
          file.path,
        ]);

        expect(exitCode, equals(SessionSteerCommand.exitUsage));
        expect(
          stderrBuf.toString(),
          contains('cannot be combined with --message-file'),
        );
        expect(client.steerCallCount, isZero);
      });

      test('resolves the target from the positional id when --message consumes '
          'a leading -s', () async {
        useRunningSession(sessionId: 'sess-B');
        final runner = buildRunner();
        // `args` consumes `-s` as the value of `--message`, so the Agent target
        // is the positional `sess-B`, never `sess-A`.
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-B',
          '--message',
          '-s',
          'sess-A',
        ]);

        expect(exitCode, equals(0));
        expect(client.lastSteerSessionId, equals('sess-B'));
        expect(client.lastSteerMessage, equals('-s'));
      });

      test('never prints the steer body on a rejected steer', () async {
        useRunningSession();
        client.steerErrorToThrow = const CliClientException(
          'rejected',
          code: 'invalid_request',
        );

        const body = 'SECRET-STEER-BODY-42';
        final runner = buildRunner();
        await runner.run(['session', 'steer', 'sess-live', '--message', body]);

        expect(stdoutBuf.toString(), isNot(contains(body)));
        expect(stderrBuf.toString(), isNot(contains(body)));
      });

      test('honours --timeout as the acknowledgement bound', () async {
        useRunningSession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          'sess-live',
          '--message',
          'Add scope',
          '--timeout',
          '7',
        ]);

        expect(exitCode, equals(0));
        expect(client.lastSteerAckTimeout, equals(const Duration(seconds: 7)));
      });

      test('resolves the target session from --session so a relayed steer '
          'reuses an approved session', () async {
        useRunningSession(sessionId: 'sess-option');
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'steer',
          '--session',
          'sess-option',
          '--message',
          'Add scope',
        ]);

        expect(exitCode, equals(0));
        expect(client.lastSteerSessionId, equals('sess-option'));
      });
    });

    group('session retry', () {
      /// Exactly the fields `SessionExecutionSnapshot.toPayload` plus the
      /// recovery notice `session show` projects.
      void useRecoverySession({
        String sessionId = 'sess-blocked',
        String? noticeStatus = 'blocked',
        String snapshotState = 'blocked',
      }) {
        client.historyToReturn = {
          'payload': {
            'session_id': sessionId,
            'execution_snapshot': {
              'session_id': sessionId,
              'state': snapshotState,
              'work_item_id': 'wi-blocked',
              'request_id': 'req-turn-blocked',
              'revision': 7,
              'updated_at': '2026-10-22T20:00:00.000Z',
            },
            if (noticeStatus != null)
              'runtime_notice': {
                'session_id': sessionId,
                'request_id': 'req-turn-blocked',
                'status': noticeStatus,
                'reason': 'timeout',
                'severity': 'error',
                'title': 'Request timed out',
                'message': 'The request to OpenCode Go took too long to '
                    'complete.',
              },
            'messages': [],
          },
        };
      }

      test('dispatches one retry and reports the daemon acceptance', () async {
        useRecoverySession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--json',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.retryCallCount, equals(1));
        expect(client.lastRetrySessionId, equals('sess-blocked'));
        expect(
          client.lastRetryRequestId,
          isNotNull,
          reason: 'the request id is allocated before the dispatch',
        );
        expect(client.lastRetryProviderInstanceId, isNull);
        expect(client.lastRetryModelId, isNull);

        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['status'], equals('retrying'));
        expect(decoded['session_id'], equals('sess-blocked'));
        expect(decoded['request_id'], equals(client.lastRetryRequestId));
        expect(decoded['notice_request_id'], equals('req-turn-fake-1'));
        expect(stdoutBuf.toString(), isNot(contains('error')));
      });

      test('refuses to dispatch when the session is not blocked or waiting',
          () async {
        client.historyToReturn = {
          'payload': {
            'session_id': 'sess-idle',
            'execution_snapshot': {
              'session_id': 'sess-idle',
              'state': 'running',
              'work_item_id': 'wi-live',
              'request_id': 'req-turn-live',
              'revision': 2,
              'updated_at': '2026-10-22T20:00:00.000Z',
            },
            'messages': [],
          },
        };

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-idle',
          '--json',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitNotBlocked));
        expect(
          client.retryCallCount,
          isZero,
          reason: 'nothing is sent for a session that is not in recovery',
        );
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('not_blocked'));
        expect(decoded['request_id'], isNotNull);
      });

      test('treats a waiting notice as retryable', () async {
        useRecoverySession(noticeStatus: 'waiting', snapshotState: 'waiting');
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'retry', 'sess-blocked']);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.retryCallCount, equals(1));
        expect(
          stdoutBuf.toString(),
          contains('Retry accepted for session sess-blocked'),
        );
      });

      test('treats restored blocked work without a notice as retryable',
          () async {
        useRecoverySession(noticeStatus: null);
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'retry', 'sess-blocked']);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.retryCallCount, equals(1));
      });

      test('maps --provider and --model onto the payload fields', () async {
        useRecoverySession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--provider',
          'inst-openai-1',
          '--model',
          'gpt-5.1',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.lastRetryProviderInstanceId, equals('inst-openai-1'));
        expect(client.lastRetryModelId, equals('gpt-5.1'));
      });

      test('treats a blank --provider and --model as absent', () async {
        useRecoverySession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--provider',
          '',
          '--model',
          '  ',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.lastRetryProviderInstanceId, isNull);
        expect(client.lastRetryModelId, isNull);
      });

      test('reports a typed rejection with exit 4', () async {
        useRecoverySession();
        client.retryErrorToThrow = const CliClientException(
          'The interrupted provider request has no recognized checkpoint.',
          code: 'retry_rejected',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--json',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitRejected));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('retry_rejected'));
        expect(decoded['error'], contains('no recognized checkpoint'));
        expect(decoded['request_id'], equals(client.lastRetryRequestId));
      });

      test('reports an unacknowledged retry with exit 5 and its request id',
          () async {
        useRecoverySession();
        client.retryErrorToThrow = const CliClientException(
          'Gateway did not acknowledge the retry within 15s',
          code: 'retry_unacknowledged',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--json',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitUnacknowledged));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('retry_unacknowledged'));
        expect(decoded['request_id'], isNotEmpty);
        expect(
          stderrBuf.toString(),
          contains('(request ${decoded['request_id']})'),
          reason: 'a caller can correlate a late acknowledgement',
        );
      });

      test('reports a transport failure with exit 1', () async {
        useRecoverySession();
        client.retryErrorToThrow = const CliClientException(
          'socket is gone',
          code: 'connection_failed',
        );

        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'retry', 'sess-blocked']);

        expect(exitCode, equals(SessionRetryCommand.exitFailed));
        expect(stderrBuf.toString(), isNot(contains('Gateway rejected')));
      });

      test('reports an unreadable session projection with exit 8', () async {
        client.historyErrorToThrow = const CliClientException(
          'cursor is stale',
          code: 'stale_cursor',
        );

        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--json',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitStateUnreadable));
        expect(
          client.retryCallCount,
          isZero,
          reason: 'no retry is dispatched after a failed read',
        );
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('session_state_unreadable'));
      });

      test('requires a session id', () async {
        final runner = buildRunner();
        final exitCode = await runner.run(['session', 'retry', '--json']);

        expect(exitCode, equals(SessionRetryCommand.exitUsage));
        expect(client.retryCallCount, isZero);
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['error_code'], equals('invalid_arguments'));
      });

      test('rejects an unusable --timeout as a usage error', () async {
        useRecoverySession();
        for (final value in ['0', '-1', 'soon', '86401']) {
          final runner = buildRunner();
          final exitCode = await runner.run([
            'session',
            'retry',
            'sess-blocked',
            '--timeout',
            value,
          ]);

          expect(
            exitCode,
            equals(SessionRetryCommand.exitUsage),
            reason: '--timeout $value',
          );
        }
        expect(client.retryCallCount, isZero);
      });

      test('honours --timeout as the acknowledgement bound', () async {
        useRecoverySession();
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          'sess-blocked',
          '--timeout',
          '9',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.lastRetryAckTimeout, equals(const Duration(seconds: 9)));
      });

      test('resolves the target from --session so a relayed retry reuses an '
          'approved session', () async {
        useRecoverySession(sessionId: 'sess-option');
        final runner = buildRunner();
        final exitCode = await runner.run([
          'session',
          'retry',
          '--session',
          'sess-option',
        ]);

        expect(exitCode, equals(SessionRetryCommand.exitAccepted));
        expect(client.lastRetrySessionId, equals('sess-option'));
      });
    });

    group('selected Home endpoint resolution', () {
      test('fails closed when the Home has no live runtime record', () async {
        final home = Directory.systemTemp.createTempSync('sanad-home-cli-');
        addTearDown(() {
          if (home.existsSync()) home.deleteSync(recursive: true);
        });
        File(
          '${home.path}${Platform.pathSeparator}.local_token',
        ).writeAsStringSync('home-token');

        // No client override: this exercises real discovery, whose Home branch
        // must resolve the endpoint from the record and never probe a default
        // port that another Home's runtime may own.
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );
        final exitCode = await runner.run([
          'session',
          'list',
          '--home',
          home.path,
        ]);

        expect(stderrBuf.toString(), contains('No live runtime record'));
        expect(stderrBuf.toString(), contains(home.path));
        expect(exitCode, equals(78));
      });

      test(
        '--json reports the endpoint failure in the result envelope',
        () async {
          final home = Directory.systemTemp.createTempSync('sanad-home-cli-');
          addTearDown(() {
            if (home.existsSync()) home.deleteSync(recursive: true);
          });
          File(
            '${home.path}${Platform.pathSeparator}.local_token',
          ).writeAsStringSync('home-token');

          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
          );
          final exitCode = await runner.run([
            'session',
            'list',
            '--json',
            '--home',
            home.path,
          ]);

          expect(exitCode, equals(78));
          final decoded =
              jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
          // The one-shot result envelope, not the removed
          // `{"exit_code": 1, "error": …}` command-local shape.
          expect(decoded['exit_code'], 78);
          expect(decoded['session_id'], isEmpty);
          expect(decoded['text'], isEmpty);
          expect(decoded['tool_executions'], isEmpty);
          expect(decoded['error'], contains('No live runtime record'));
          // A machine consumer branches on the code, not on English prose.
          expect(decoded['error_code'], equals('home_runtime_missing'));
          expect(stderrBuf.toString(), contains('Error: '));
        },
      );

      test('--json names the credential failure code', () async {
        // No `.local_token` in the selected Home: the envelope must carry
        // `token_not_found` rather than only the sentence that explains it.
        final home = Directory.systemTemp.createTempSync('sanad-home-cli-');
        addTearDown(() {
          if (home.existsSync()) home.deleteSync(recursive: true);
        });

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );
        final exitCode = await runner.run([
          'session',
          'list',
          '--json',
          '--home',
          home.path,
        ]);

        expect(exitCode, equals(78));
        final decoded =
            jsonDecode(stdoutBuf.toString().trim()) as Map<String, dynamic>;
        expect(decoded['exit_code'], 78);
        expect(decoded['error_code'], equals('token_not_found'));
        expect(decoded['error'], contains('token file not found'));
      });
    });
  });
}
