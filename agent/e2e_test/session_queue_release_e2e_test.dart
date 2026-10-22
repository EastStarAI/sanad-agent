// Task 125 (G2) — daemon-backed proof that a pre-start failure releases the
// session queue, and that the real `sanad run` and `sanad session compact`
// commands report the daemon's real terminal state instead of a timeout.
//
// Run with `--concurrency=1`: each case spawns a daemon on a local port.
@Tags(<String>['e2e', 'task-125'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/engine/adapters/e2e_fixture_adapter.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import '../test/support/ephemeral_loopback_port.dart';
import 'support/local_gateway_test_support.dart';

const _providerInstanceId = 'e2e-provider';
const _modelId = 'e2e-model';

void main() {
  test(
    'G2.1 a pre-start failure is terminal and the next message runs at once',
    () async {
      final h = await _Harness.create();
      try {
        final sessionId = 'g2-release-${_unique()}';
        await h.seedSession(sessionId: sessionId, fillerCount: 0);
        final gone = Directory('${h.root.path}/deleted-execution-root')
          ..createSync();
        gone.deleteSync();

        final client = await h.startDaemon();
        try {
          client.think(
            sessionId: sessionId,
            requestId: 'req-fails',
            message: 'this turn cannot start',
            sessionMetadata: {'execution_root': gone.path},
          );
          final failed = await client.waitForFinalAnswer(sessionId);
          expect(failed['error_code'], 'turn_failed');
          expect(
            failed['request_id'],
            'req-fails',
            reason: 'the refusal must answer the send that is waiting for it',
          );
          expect(failed['content'], startsWith('Error:'));
          expect(
            client.noticeStatuses(sessionId),
            isNot(contains('blocked')),
            reason: 'no blocked notice advertises a Retry that cannot work',
          );

          client.think(
            sessionId: sessionId,
            requestId: 'req-next',
            message: 'hello after the failure',
          );
          final next = await client.waitForFinalAnswer(sessionId);
          expect(next['error_code'], isNull);
          expect(next['content'], isNotEmpty);
          expect(client.classification('req-next'), 'think');
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'G2.2 the real sanad run exits at once when the daemon blocks the turn',
    () async {
      final h = await _Harness.create();
      try {
        final client = await h.startDaemon();
        await client.close();
        final executionRoot = Directory('${h.root.path}/run-root')
          ..createSync();
        const runTimeoutSeconds = 120;

        final stopwatch = Stopwatch()..start();
        final result = await h.runCli([
          'run',
          '--json',
          '--timeout',
          '$runTimeoutSeconds',
          '--execution-root',
          executionRoot.path,
          E2eFixtureAdapter.runtimeFailurePrompt,
        ]);
        stopwatch.stop();

        expect(result.exitCode, 1, reason: '${result.stderr}');
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: runTimeoutSeconds ~/ 2)),
          reason: 'the run must not wait for its own timeout',
        );
        final lines = const LineSplitter()
            .convert('${result.stdout}')
            .where((line) => line.trim().isNotEmpty)
            .toList();
        expect(lines, hasLength(1));
        final json = jsonDecode(lines.single) as Map<String, dynamic>;
        expect(json['exit_code'], 1);
        expect(json['error'], isNot(contains('timed out')));
        expect(json['error'], isNotEmpty);
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'G2.3 the real sanad session compact waits for a slow compaction result',
    () async {
      final h = await _Harness.create();
      try {
        // Longer than the former fixed 5 s CLI wait.
        const delaySeconds = 8;
        final sessionId = 'g2-compact-${_unique()}';
        await h.seedSession(
          sessionId: sessionId,
          initialUserContent:
              'goal: slow compaction '
              '${E2eFixtureAdapter.compactionDelayPromptPrefix}$delaySeconds',
        );
        final client = await h.startDaemon();
        await client.close();

        final stopwatch = Stopwatch()..start();
        final result = await h.runCli([
          'session',
          'compact',
          sessionId,
          '--json',
        ]);
        stopwatch.stop();

        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final json =
            jsonDecode('${result.stdout}'.trim()) as Map<String, dynamic>;
        expect(json['outcome'], 'accepted');
        expect(json['compaction_id'], isNotEmpty);
        expect(
          stopwatch.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: delaySeconds)),
        );

        final show = await h.runCli(['session', 'show', sessionId, '--json']);
        expect(show.exitCode, 0, reason: '${show.stderr}');
        final shown =
            jsonDecode('${show.stdout}'.trim()) as Map<String, dynamic>;
        expect(shown['compaction'], {
          'compaction_id': json['compaction_id'],
          'status': 'completed',
          'trigger': 'manual',
        });
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

int _unique() =>
    DateTime.now().microsecondsSinceEpoch ^ Random().nextInt(1 << 20);

class _Harness {
  _Harness._(this.root, this.sanadHome, this.sanadStateHome);

  final Directory root;
  final Directory sanadHome;
  final Directory sanadStateHome;
  Process? _daemon;
  int? _port;

  static const _startAttempts = defaultPortReservationAttempts;

  static Future<_Harness> create() async {
    final root = Directory(
      (await Directory.systemTemp.createTemp(
        'sanad-g2-',
      )).resolveSymbolicLinksSync(),
    );
    final home = Directory('${root.path}/home')..createSync();
    final state = Directory('${root.path}/state')..createSync();
    final harness = _Harness._(root, home, state);
    // The harness seeds provider and session rows from the test isolate before
    // it starts the daemon. On-disk state owners refuse to open from a Dart
    // test without explicit isolation, and both roots here are temporary.
    setSanadHomeOverride(home.path);
    setSanadStateHomeOverride(state.path);
    harness._seedProviderInstance();
    return harness;
  }

  Map<String, String> get _environment => <String, String>{
    ...Platform.environment,
    'SANAD_HOME': sanadHome.path,
    'SANAD_STATE_HOME': sanadStateHome.path,
    'SANAD_E2E_TEST_MODE': 'true',
    'ENABLE_LOCAL_GATEWAY': 'true',
    'ENABLE_GATEWAY': 'false',
    'LOCAL_GATEWAY_HOST': '127.0.0.1',
    'LOG_LEVEL': 'INFO',
  };

  void _seedProviderInstance() {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final now = DateTime.now().toUtc();
      ProviderInstanceRepository(stateDb).createInstance(
        ProviderInstance(
          id: _providerInstanceId,
          templateId: 'openai',
          authMethod: 'api_key',
          protocol: 'openai_compatible',
          baseUrl: 'http://127.0.0.1:9/v1',
          displayName: 'G2 E2E Provider',
          defaultModel: _modelId,
          status: 'ready',
          isDefault: true,
          createdAt: now,
          updatedAt: now,
        ),
      );
    } finally {
      stateDb.dispose();
    }
  }

  Future<void> seedSession({
    required String sessionId,
    int fillerCount = 500,
    int fillerLength = 300,
    String initialUserContent = 'goal: g2 e2e validation',
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final sessions = SessionDB.fromState(stateDb);
      final now = DateTime.utc(2026, 10, 21);
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          model: _modelId,
          providerId: _providerInstanceId,
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessions.replaceMessages(sessionId, [
        Message(role: MessageRole.user, content: initialUserContent),
        for (var i = 0; i < fillerCount; i++)
          Message(
            role: MessageRole.user,
            content: 'filler $i ${'x' * fillerLength}',
          ),
      ]);
    } finally {
      stateDb.dispose();
    }
  }

  /// Starts the daemon on a freshly reserved loopback port, re-reserving when
  /// another process took the port before the daemon bound it.
  Future<_GatewayClient> startDaemon() async {
    Object? lastError;
    for (var attempt = 0; attempt < _startAttempts; attempt++) {
      final port = await reserveFreeLoopbackPort();
      final proc = await Process.start(
        Platform.resolvedExecutable,
        <String>['bin/daemon.dart'],
        workingDirectory: Directory.current.path,
        environment: {..._environment, 'LOCAL_GATEWAY_PORT': '$port'},
      );
      unawaited(
        proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) => stderr.writeln('[daemon] $line'))
            .asFuture<void>(),
      );
      unawaited(
        proc.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) => stderr.writeln('[daemon!] $line'))
            .asFuture<void>(),
      );
      try {
        await _waitForHealth(port, proc);
        _daemon = proc;
        _port = port;
        return await _GatewayClient.connect(
          port: port,
          sanadHomePath: sanadHome.path,
        );
      } catch (error) {
        lastError = error;
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(
          const Duration(seconds: 6),
          onTimeout: () => -1,
        );
      }
    }
    throw StateError('Daemon did not start: $lastError');
  }

  Future<void> _waitForHealth(int port, Process proc) async {
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));
    final client = HttpClient();
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    Object? lastError;
    try {
      while (DateTime.now().isBefore(deadline) && !exited) {
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$port/health'),
          );
          authorizeLocalGatewayTestRequest(request, sanadHome.path);
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode == 200 &&
              (jsonDecode(body) as Map<String, dynamic>)['status'] == 'ok') {
            return;
          }
          lastError = StateError('Unexpected health response: $body');
        } catch (error) {
          lastError = error;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      client.close(force: true);
    }
    throw StateError('Daemon health did not become ready: $lastError');
  }

  /// Runs the real `sanad` CLI from source, attached to this harness daemon
  /// only: the explicit Home and Gateway URL keep it off every other runtime.
  Future<ProcessResult> runCli(List<String> arguments) {
    return Process.run(
      Platform.resolvedExecutable,
      <String>[
        'bin/sanad_agent.dart',
        ...arguments,
        '--home',
        sanadHome.path,
        '--gateway-url',
        'ws://127.0.0.1:$_port/ws',
      ],
      workingDirectory: Directory.current.path,
      environment: _environment,
    ).timeout(const Duration(minutes: 3));
  }

  Future<void> dispose() async {
    final proc = _daemon;
    _daemon = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode.timeout(
        const Duration(seconds: 6),
        onTimeout: () => -1,
      );
    }
    if (root.existsSync()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
  }
}

class _GatewayClient {
  _GatewayClient._(this._socket) {
    _subscription = _socket.listen((data) {
      final frame = jsonDecode(data as String) as Map<String, dynamic>;
      _frames.add(frame);
      _changed.add(null);
    });
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final List<Map<String, dynamic>> _frames = [];
  final StreamController<void> _changed = StreamController.broadcast();
  int _consumedFinals = 0;

  static Future<_GatewayClient> connect({
    required int port,
    required String sanadHomePath,
  }) async {
    final socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: sanadHomePath,
    );
    final client = _GatewayClient._(socket);
    await client._waitFor(
      (frame) => frame['type'] == 'register_success',
      const Duration(seconds: 20),
    );
    return client;
  }

  Iterable<Map<String, dynamic>> _events(String eventName) => _frames
      .where(
        (frame) =>
            frame['type'] == 'device_event' && frame['event'] == eventName,
      )
      .map(
        (frame) => frame['payload'] is Map
            ? Map<String, dynamic>.from(frame['payload'] as Map)
            : <String, dynamic>{},
      );

  Future<Map<String, dynamic>> _waitFor(
    bool Function(Map<String, dynamic> frame) match,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final frame in _frames) {
        if (match(frame)) return frame;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('No matching gateway frame', timeout);
      }
      await _changed.stream.first.timeout(remaining, onTimeout: () {});
    }
  }

  void think({
    required String sessionId,
    required String requestId,
    required String message,
    Map<String, dynamic>? sessionMetadata,
  }) {
    _socket.add(
      jsonEncode(<String, dynamic>{
        'type': 'execute_command',
        'command': 'think',
        'payload': <String, dynamic>{
          'request_id': requestId,
          'session_id': sessionId,
          'message': message,
          'provider_instance_id': _providerInstanceId,
          'model': _modelId,
          'delivery_intent': 'auto',
          'session_metadata': ?sessionMetadata,
        },
      }),
    );
  }

  /// The next not-yet-consumed `final_answer` for [sessionId].
  Future<Map<String, dynamic>> waitForFinalAnswer(String sessionId) async {
    final target = _consumedFinals;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final finals = _events(CanonicalEventTypes.finalAnswer)
          .where(
            (payload) =>
                payload['session_id'] == null ||
                payload['session_id'] == sessionId,
          )
          .toList();
      if (finals.length > target) {
        _consumedFinals = target + 1;
        return finals[target];
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('No final_answer for $sessionId');
      }
      await _changed.stream.first.timeout(remaining, onTimeout: () {});
    }
  }

  List<String> noticeStatuses(String sessionId) =>
      _events('session.runtime_notice')
          .where((p) => p['session_id'] == sessionId)
          .map((p) => '${p['status']}')
          .toList();

  String? classification(String requestId) =>
      _events(CanonicalEventTypes.sessionMessageClassified)
          .where((p) => p['request_id'] == requestId)
          .map((p) => '${p['classification']}')
          .firstOrNull;

  Future<void> close() async {
    await _subscription.cancel();
    await _changed.close();
    try {
      await _socket.close();
    } catch (_) {}
  }
}
