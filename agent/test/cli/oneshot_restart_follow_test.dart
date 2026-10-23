import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/cli/artifacts/run_artifacts.dart';
import 'package:sanad_agent/cli/cli.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

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

void _writeOwnerOnly(String path, String contents) {
  File(path).writeAsStringSync(contents);
  if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
}

void main() {
  useIsolatedSanadTestHome();

  group('Oneshot Restart Follow & Re-attach (Task B14)', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;
    late Directory homeDir;

    setUp(() async {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
      homeDir = await Directory.systemTemp.createTemp('sanad-restart-test-home-');
      _writeOwnerOnly(
        '${homeDir.path}/${LocalGatewayCredentials.relativePath}',
        'test-token',
      );
    });

    tearDown(() async {
      if (homeDir.existsSync()) {
        try {
          homeDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test(
      'connection drops mid-turn, daemon reclaims turn, run re-attaches and exits 0',
      () async {
        final mockSocket1 = MockWebSocket();
        final mockSocket2 = MockWebSocket();

        final client1 = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connectTimeout: const Duration(seconds: 1),
          requestTimeout: const Duration(seconds: 1),
          connector: (uri, {headers, timeout}) async => mockSocket1,
        );
        await client1.connect();

        final client2 = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connectTimeout: const Duration(seconds: 1),
          requestTimeout: const Duration(seconds: 1),
          connector: (uri, {headers, timeout}) async => mockSocket2,
        );

        var factoryCallCount = 0;
        final events = <RunLifecycleEvent>[];
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client1,
          clientFactory: ({sanadHomeOverride, urlOverride}) async {
            factoryCallCount++;
            await client2.connect();
            return client2;
          },
          eventSink: events.add,
          stdinReader: () async => null,
        );

        final runFuture = runner.run([
          'run',
          'Execute long task across restart',
          '--session',
          'sess-reclaim-1',
          '--reconnect-timeout',
          '5',
          '--execution-root',
          Directory.current.path,
        ]);

        // 1. Initial think dispatch to client1
        final sentRaw = await mockSocket1.nextSentMessage();
        final sentEnvelope = jsonDecode(sentRaw) as Map<String, dynamic>;
        expect(sentEnvelope['command'], 'think');
        final sentPayload = sentEnvelope['payload'] as Map<String, dynamic>;
        final dispatchedReqId = sentPayload['request_id'] as String;

        // Emit initial progress
        mockSocket1.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-reclaim-1',
            'event': {
              'type': 'thought_stream',
              'session_id': 'sess-reclaim-1',
              'payload': {'delta': 'Initial chunk before restart. '},
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 2. Simulate daemon restart (socket drops)
        mockSocket1.simulateClose();

        // 3. Reconnect to client2: mockSocket2 receives get_session_history
        final historyQueryRaw = await mockSocket2.nextSentMessage();
        final historyEnvelope = jsonDecode(historyQueryRaw) as Map<String, dynamic>;
        expect(historyEnvelope['command'], 'get_session_history');

        // Respond with reclaimed execution snapshot in 'resuming' state
        mockSocket2.emitFromServer(
          jsonEncode({
            'type': 'device_response',
            'request_id': historyEnvelope['request_id'],
            'payload': {
              'session_id': 'sess-reclaim-1',
              'execution_snapshot': {
                'session_id': 'sess-reclaim-1',
                'state': 'resuming',
                'request_id': dispatchedReqId,
                'work_item_id': 'work-item-42',
                'revision': 2,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // 4. Continued turn execution over reconnected socket
        mockSocket2.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-reclaim-1',
            'event': {
              'type': 'thought_stream',
              'session_id': 'sess-reclaim-1',
              'payload': {'delta': 'Final output after restart.'},
            },
          }),
        );
        mockSocket2.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-reclaim-1',
            'event': {
              'type': 'turn_complete',
              'session_id': 'sess-reclaim-1',
              'payload': {
                'text':
                    'Initial chunk before restart. Final output after restart.',
              },
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
        expect(
          stdoutBuffer.toString(),
          contains('Final output after restart.'),
        );
        expect(
          stderrBuffer.toString(),
          contains('Notice: Reconnected to Sanad daemon.'),
        );
        expect(
          stderrBuffer.toString(),
          contains('Notice: Re-attached to turn for session sess-reclaim-1.'),
        );
        expect(factoryCallCount, 1);

        // The reconnected transport must carry no second turn: following a
        // reclaimed turn never re-sends the brief.
        expect(
          mockSocket2.sentMessages.where(
            (raw) => (jsonDecode(raw) as Map<String, dynamic>)['command'] ==
                'think',
          ),
          isEmpty,
        );

        // Lifecycle transitions are visible to `--events` consumers.
        expect(
          events.map((e) => e.type),
          containsAllInOrder(<String>[
            'reconnecting',
            'reconnected',
            're_attached',
          ]),
        );
        final reattach = events.firstWhere((e) => e.type == 're_attached');
        expect(reattach.data['state'], 'resuming');
        expect(reattach.data['request_id'], dispatchedReqId);
      },
    );

    test(
      'reconnect window expires → exit 1 with reason code reconnect_window_expired',
      () async {
        final mockSocket = MockWebSocket();
        final client = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket,
        );
        await client.connect();

        final events = <RunLifecycleEvent>[];
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client,
          eventSink: events.add,
          stdinReader: () async => null,
        );

        final runFuture = runner.run([
          'run',
          'Task will lose connection',
          '--session',
          'sess-timeout-1',
          '--reconnect-timeout',
          '1',
          '--json',
          '--execution-root',
          Directory.current.path,
        ]);

        await mockSocket.nextSentMessage();
        mockSocket.simulateClose();

        final exitCode = await runFuture;
        expect(exitCode, 1);

        // Check JSON output
        final jsonResult = jsonDecode(stdoutBuffer.toString().trim())
            as Map<String, dynamic>;
        expect(jsonResult['exit_code'], 1);
        expect(jsonResult['error_code'], 'reconnect_window_expired');
        expect(
          jsonResult['error'],
          contains('Failed to reconnect to Sanad daemon within 1s'),
        );

        // Check lifecycle events
        final failedEvent = events.firstWhere((e) => e.type == 'failed');
        expect(failedEvent.data['cause'], 'reconnect_window_expired');
      },
    );

    test(
      're-dispatch onto an in-flight turn refuses with exit code 3 and cause turn_in_flight',
      () async {
        final mockSocket = MockWebSocket();
        final client = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket,
        );
        await client.connect();

        final runner = OneshotRunner(
          stdinReader: () async => null,
        );

        // Start oneshot run targeting session with active in-flight turn
        final runFuture = runner.run(
          prompt: 'New brief for busy session',
          session: 'sess-active-turn',
          client: client,
          checkInFlight: true,
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          json: true,
        );

        // The pre-dispatch check queries get_session_history
        final queryRaw = await mockSocket.nextSentMessage();
        final queryEnvelope = jsonDecode(queryRaw) as Map<String, dynamic>;
        expect(queryEnvelope['command'], 'get_session_history');
        expect(
          (queryEnvelope['payload'] as Map<String, dynamic>)['session_id'],
          'sess-active-turn',
        );

        // Return snapshot with state == 'running'
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_response',
            'request_id': queryEnvelope['request_id'],
            'payload': {
              'session_id': 'sess-active-turn',
              'execution_snapshot': {
                'session_id': 'sess-active-turn',
                'state': 'running',
                'request_id': 'req-already-running',
                'work_item_id': 'work-1',
                'revision': 1,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 3);
        expect(
          stderrBuffer.toString(),
          contains('Session sess-active-turn already has an in-flight turn'),
        );

        // Verify that NO think command was dispatched
        expect(mockSocket.sentMessages.length, 1);

        // Verify JSON error code
        final jsonResult = jsonDecode(stdoutBuffer.toString().trim())
            as Map<String, dynamic>;
        expect(jsonResult['exit_code'], 3);
        expect(jsonResult['error_code'], 'turn_in_flight');
      },
    );

    test(
      'a retryable timeout with budget left keeps following and says retrying',
      () async {
        final mockSocket = MockWebSocket();
        final client = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket,
        );
        await client.connect();

        final runner = OneshotRunner(stdinReader: () async => null);

        final runFuture = runner.run(
          prompt: 'Survive a retryable provider timeout',
          session: 'sess-retrying-turn',
          client: client,
          timeout: const Duration(seconds: 5),
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
        );

        final thinkRaw = await mockSocket.nextSentMessage();
        expect(
          (jsonDecode(thinkRaw) as Map<String, dynamic>)['command'],
          'think',
        );

        var settled = false;
        unawaited(runFuture.then((_) => settled = true));

        // The daemon published the retryable failure it is already retrying:
        // attempt 1 of 1 is scheduled, so the run keeps following instead of
        // exiting as a failed/blocked turn (2026-10-23).
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-retrying-turn',
            'event': {
              'type': 'session.runtime_notice',
              'session_id': 'sess-retrying-turn',
              'payload': {
                'session_id': 'sess-retrying-turn',
                'status': 'waiting',
                'reason': 'timeout',
                'title': 'Request timed out',
                'message': 'The request took too long to complete. Retrying '
                    'automatically in 2s (attempt 1 of 1).',
                'retry_attempt': 1,
                'retry_budget': 1,
                'retry_after_ms': 2000,
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          settled,
          isFalse,
          reason: 'a scheduled retry is not a verdict: the run keeps following',
        );
        expect(stderrBuffer.toString(), contains('retrying (1/1)'));
        expect(
          stderrBuffer.toString(),
          isNot(contains('Error:')),
          reason: 'a retry in progress is never an error line',
        );

        // The retried attempt finishes normally.
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-retrying-turn',
            'event': {
              'type': 'turn_complete',
              'session_id': 'sess-retrying-turn',
              'payload': {'text': 'Retried request completed.'},
            },
          }),
        );

        expect(await runFuture, 0);
        expect(stdoutBuffer.toString(), contains('Retried request completed.'));
      },
    );

    test(
      'an exhausted retry budget ends the run blocked',
      () async {
        final mockSocket = MockWebSocket();
        final client = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket,
        );
        await client.connect();

        final runner = OneshotRunner(stdinReader: () async => null);

        final runFuture = runner.run(
          prompt: 'Fail after the retry budget',
          session: 'sess-exhausted-turn',
          timeout: const Duration(seconds: 5),
          client: client,
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
        );

        final thinkRaw = await mockSocket.nextSentMessage();
        expect(
          (jsonDecode(thinkRaw) as Map<String, dynamic>)['command'],
          'think',
        );

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-exhausted-turn',
            'event': {
              'type': 'session.runtime_notice',
              'session_id': 'sess-exhausted-turn',
              'payload': {
                'session_id': 'sess-exhausted-turn',
                'status': 'blocked',
                'reason': 'timeout',
                'title': 'Request timed out',
                'message': 'The request took too long to complete. Automatic '
                    'retry gave up after 1 attempt; retry manually or choose '
                    'another provider.',
                'retry_attempt': 1,
                'retry_budget': 1,
              },
            },
          }),
        );

        expect(await runFuture, 1);
        expect(stderrBuffer.toString(), contains('blocked: Request timed out'));
      },
    );

    test(
      'a really blocked session does not refuse a new dispatch as in-flight',
      () async {
        final mockSocket = MockWebSocket();
        final client = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket,
        );
        await client.connect();

        final runner = OneshotRunner(stdinReader: () async => null);

        final runFuture = runner.run(
          prompt: 'Rework after a real block',
          session: 'sess-blocked-turn',
          client: client,
          checkInFlight: true,
          timeout: const Duration(seconds: 5),
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
        );

        final queryRaw = await mockSocket.nextSentMessage();
        final queryEnvelope = jsonDecode(queryRaw) as Map<String, dynamic>;
        expect(queryEnvelope['command'], 'get_session_history');

        // Blocked with no scheduled retry: parked on an intervention, so the
        // documented blocked outcome is preserved instead of a refusal.
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_response',
            'request_id': queryEnvelope['request_id'],
            'payload': {
              'session_id': 'sess-blocked-turn',
              'execution_snapshot': {
                'session_id': 'sess-blocked-turn',
                'state': 'blocked',
                'request_id': 'req-blocked-turn',
                'work_item_id': 'work-blocked',
                'revision': 2,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
              'runtime_notice': {
                'status': 'blocked',
                'message': 'Provider credentials are invalid.',
              },
            },
          }),
        );

        // The dispatch is admitted, so a `think` follows the history query.
        final thinkRaw = await mockSocket.nextSentMessage();
        expect(
          (jsonDecode(thinkRaw) as Map<String, dynamic>)['command'],
          'think',
        );

        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-blocked-turn',
            'event': {
              'type': 'turn_complete',
              'session_id': 'sess-blocked-turn',
              'payload': {'text': 'Completed the rework.'},
            },
          }),
        );

        expect(await runFuture, 0);
      },
    );

    test(
      'Home-bound guard: reconnect refuses daemon with mismatched Home identity',
      () async {
        // Spin up a fake gateway serving health for a DIFFERENT home
        final fakeOtherServer =
            await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final foreignPort = fakeOtherServer.port;
        final foreignHomeId = 'foreign-home-hash-999';

        fakeOtherServer.listen((request) async {
          if (request.uri.path == '/health') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'status': 'ok',
                'home_id': foreignHomeId,
              }),
            );
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });

        try {
          final mockSocket = MockWebSocket();
          final client = LocalGatewayCliClient(
            gatewayUri: Uri.parse('ws://127.0.0.1:$foreignPort/gateway'),
            token: 'test-token',
            autoReconnect: false,
            connector: (uri, {headers, timeout}) async => mockSocket,
          );
          await client.connect();

          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuffer,
            stderrSink: stderrBuffer,
            client: client,
            stdinReader: () async => null,
          );

          final runFuture = runner.run([
            'run',
            'Task will trigger foreign home check',
            '--session',
            'sess-home-mismatch',
            '--gateway-url',
            'ws://127.0.0.1:$foreignPort/gateway',
            '--home',
            homeDir.path,
            '--reconnect-timeout',
            '2',
            '--json',
            '--execution-root',
            Directory.current.path,
          ]);

          await mockSocket.nextSentMessage();
          mockSocket.simulateClose();

          final exitCode = await runFuture;
          expect(exitCode, 78);

          final jsonResult = jsonDecode(stdoutBuffer.toString().trim())
              as Map<String, dynamic>;
          expect(jsonResult['exit_code'], 78);
          expect(jsonResult['error_code'], 'home_identity_mismatch');
          expect(
            jsonResult['error'],
            contains('does not serve this Sanad Home'),
          );
        } finally {
          await fakeOtherServer.close(force: true);
        }
      },
    );

    test(
      'waiting under automatic recovery keeps following to completion',
      () async {
        final mockSocket1 = MockWebSocket();
        final mockSocket2 = MockWebSocket();

        final client1 = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket1,
        );
        await client1.connect();

        final client2 = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket2,
        );

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client1,
          clientFactory: ({sanadHomeOverride, urlOverride}) async {
            await client2.connect();
            return client2;
          },
          stdinReader: () async => null,
        );

        final runFuture = runner.run([
          'run',
          'Task resuming after transient rate limit',
          '--session',
          'sess-transient-1',
          '--reconnect-timeout',
          '5',
          '--execution-root',
          Directory.current.path,
        ]);

        final sentRaw = await mockSocket1.nextSentMessage();
        final sentPayload =
            (jsonDecode(sentRaw) as Map<String, dynamic>)['payload'] as Map;
        final dispatchedReqId = sentPayload['request_id'] as String;

        mockSocket1.simulateClose();

        // client2 receives get_session_history
        final historyRaw = await mockSocket2.nextSentMessage();
        final historyEnv = jsonDecode(historyRaw) as Map<String, dynamic>;

        // The reclaimed turn is waiting on provider recovery with an automatic
        // resume scheduled, so the transient state must not be terminal.
        mockSocket2.emitFromServer(
          jsonEncode({
            'type': 'device_response',
            'request_id': historyEnv['request_id'],
            'payload': {
              'session_id': 'sess-transient-1',
              'execution_snapshot': {
                'session_id': 'sess-transient-1',
                'state': 'waiting',
                'request_id': dispatchedReqId,
                'work_item_id': 'work-transient',
                'revision': 3,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
              'runtime_notice': {
                'status': 'waiting',
                'message': 'Rate limited; retry scheduled in 2s',
                'resume_at': DateTime.now()
                    .add(const Duration(seconds: 2))
                    .toUtc()
                    .toIso8601String(),
                'retry_after_ms': 2000,
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // It re-attaches and keeps following! Now emit final turn completion
        mockSocket2.emitFromServer(
          jsonEncode({
            'type': 'device_event',
            'session_id': 'sess-transient-1',
            'event': {
              'type': 'turn_complete',
              'session_id': 'sess-transient-1',
              'payload': {
                'text': 'Completed after transient recovery wait.',
              },
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 0);
        expect(
          stdoutBuffer.toString(),
          contains('Completed after transient recovery wait.'),
        );
      },
    );

    test('blocked keeps the documented blocked exit even with a retry delay', () async {
      final mockSocket1 = MockWebSocket();
      final mockSocket2 = MockWebSocket();

      final client1 = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        autoReconnect: false,
        connector: (uri, {headers, timeout}) async => mockSocket1,
      );
      await client1.connect();

      final client2 = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
        token: 'test-token',
        autoReconnect: false,
        connector: (uri, {headers, timeout}) async => mockSocket2,
      );

      final events = <RunLifecycleEvent>[];
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        client: client1,
        clientFactory: ({sanadHomeOverride, urlOverride}) async {
          await client2.connect();
          return client2;
        },
        eventSink: events.add,
        stdinReader: () async => null,
      );

      final runFuture = runner.run([
        'run',
        'Task blocked without automatic recovery',
        '--session',
        'sess-blocked-1',
        '--reconnect-timeout',
        '5',
        '--json',
        '--execution-root',
        Directory.current.path,
      ]);

      final sentRaw = await mockSocket1.nextSentMessage();
      final dispatchedReqId =
          ((jsonDecode(sentRaw) as Map<String, dynamic>)['payload']
              as Map)['request_id'] as String;

      mockSocket1.simulateClose();

      final historyRaw = await mockSocket2.nextSentMessage();
      final historyEnv = jsonDecode(historyRaw) as Map<String, dynamic>;

      mockSocket2.emitFromServer(
        jsonEncode({
          'type': 'device_response',
          'request_id': historyEnv['request_id'],
          'payload': {
            'session_id': 'sess-blocked-1',
            'execution_snapshot': {
              'session_id': 'sess-blocked-1',
              'state': 'blocked',
              'request_id': dispatchedReqId,
              'work_item_id': 'work-blocked',
              'revision': 4,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
            // The daemon only schedules automatic resume for `waiting`, so a
            // blocked notice stays parked even when it carries a delay.
            'runtime_notice': {
              'status': 'blocked',
              'message': 'Provider credentials are invalid.',
              'resume_at': DateTime.now()
                  .add(const Duration(seconds: 30))
                  .toUtc()
                  .toIso8601String(),
              'retry_after_ms': 30000,
            },
          },
        }),
      );

      final exitCode = await runFuture;
      expect(exitCode, 1);

      final jsonResult =
          jsonDecode(stdoutBuffer.toString().trim()) as Map<String, dynamic>;
      expect(jsonResult['exit_code'], 1);
      expect(jsonResult['error_code'], 'blocked');
      expect(jsonResult['error'], contains('Provider credentials are invalid.'));
      final failedEvent = events.firstWhere((e) => e.type == 'failed');
      expect(failedEvent.data['cause'], 'blocked');
      expect(events.map((e) => e.type), isNot(contains('re_attached')));
    });

    test(
      'turn lost after restart exits 1 with cause turn_lost',
      () async {
        final mockSocket1 = MockWebSocket();
        final mockSocket2 = MockWebSocket();

        final client1 = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket1,
        );
        await client1.connect();

        final client2 = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
          token: 'test-token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket2,
        );

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          client: client1,
          clientFactory: ({sanadHomeOverride, urlOverride}) async {
            await client2.connect();
            return client2;
          },
          stdinReader: () async => null,
        );

        final runFuture = runner.run([
          'run',
          'Task will be lost after restart',
          '--session',
          'sess-lost-1',
          '--reconnect-timeout',
          '5',
          '--json',
          '--execution-root',
          Directory.current.path,
        ]);

        await mockSocket1.nextSentMessage();
        mockSocket1.simulateClose();

        final historyRaw = await mockSocket2.nextSentMessage();
        final historyEnv = jsonDecode(historyRaw) as Map<String, dynamic>;

        // Return snapshot with state == 'idle' and no messages
        mockSocket2.emitFromServer(
          jsonEncode({
            'type': 'device_response',
            'request_id': historyEnv['request_id'],
            'payload': {
              'session_id': 'sess-lost-1',
              'execution_snapshot': {
                'session_id': 'sess-lost-1',
                'state': 'idle',
                'request_id': null,
                'revision': 5,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
              'messages': <Map<String, dynamic>>[],
            },
          }),
        );

        final exitCode = await runFuture;
        expect(exitCode, 1);

        final jsonResult = jsonDecode(stdoutBuffer.toString().trim())
            as Map<String, dynamic>;
        expect(jsonResult['exit_code'], 1);
        expect(jsonResult['error_code'], 'turn_lost');
        expect(
          jsonResult['error'],
          contains('finished without a recorded result after restart'),
        );
      },
    );
  });
}
