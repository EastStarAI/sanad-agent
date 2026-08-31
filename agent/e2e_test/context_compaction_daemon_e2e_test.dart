// Plan 53f F5 — daemon-backed compaction lifecycle and history hydration.
//
// Run with `--concurrency=1` because each case binds a local gateway port.
@Tags(<String>['e2e', 'plan-53'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

const _template = 'openai';
const _authMethod = 'api_key';
const _protocol = 'openai_compatible';

void main() {
  test(
    'F.53.1 manual compact emits lifecycle and history row over real daemon',
    () async {
      final h = await _CompactionHarness.create();
      try {
        final sessionId = 'plan53-compact-${_unique()}';
        await h.seedSession(
          sessionId: sessionId,
          providerInstanceId: h.providerInstanceId,
        );

        final client = await h.startDaemon();
        try {
          final requestId = 'compact-req-${_unique()}';
          final execution = await client.executeCompact(
            sessionId: sessionId,
            requestId: requestId,
            timeout: const Duration(seconds: 30),
          );
          expect(
            execution.result['outcome'],
            'accepted',
            reason:
                'compact failed: ${execution.result['failure_reason'] ?? execution.result}',
          );
          expect(execution.result['compaction_id'], isNotEmpty);
          expect(execution.lifecycle, ['started', 'completed']);

          final history = await client.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'history-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          final compactionRows = _compactionRows(history);
          expect(compactionRows, hasLength(1));
          expect(
            compactionRows.first['compaction_id'],
            execution.result['compaction_id'],
          );
          expect(compactionRows.first['trigger'], 'manual');
          expect(compactionRows.first['status'], 'completed');
          expect(
            compactionRows.first.containsKey('internal_summary_json'),
            isFalse,
          );
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'F.53.2 completed compaction boundary survives daemon restart hydration',
    () async {
      final h = await _CompactionHarness.create();
      try {
        final sessionId = 'plan53-restart-${_unique()}';
        await h.seedSession(
          sessionId: sessionId,
          providerInstanceId: h.providerInstanceId,
        );

        final client1 = await h.startDaemon();
        String compactionId;
        try {
          final execution = await client1.executeCompact(
            sessionId: sessionId,
            requestId: 'compact-restart-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          expect(execution.result['outcome'], 'accepted');
          compactionId = execution.result['compaction_id'] as String;
        } finally {
          await client1.close();
        }

        await h.killDaemon();
        await h.appendPostCompactionResponse(sessionId);

        final client2 = await h.startDaemon();
        try {
          final history = await client2.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'history-restart-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          final compactionRows = _compactionRows(history);
          expect(compactionRows, hasLength(1));
          expect(compactionRows.first['compaction_id'], compactionId);
          expect(compactionRows.first['status'], 'completed');
          expect(
            compactionRows.first['event_id'],
            'context_compaction:$compactionId:completed',
          );
          final messages = history['messages'] as List;
          final compactionIndex = messages.indexWhere(
            (row) => row is Map && row['compaction_id'] == compactionId,
          );
          final responseIndex = messages.indexWhere(
            (row) =>
                row is Map &&
                row['content'] == 'response produced after compaction',
          );
          expect(compactionIndex, lessThan(responseIndex));
        } finally {
          await client2.close();
        }
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'F.53.3 auto compaction preserves one follow-up through the daemon',
    () async {
      final h = await _CompactionHarness.create();
      try {
        final sessionId = 'plan53-auto-queue-${_unique()}';
        await h.seedSession(
          sessionId: sessionId,
          providerInstanceId: h.providerInstanceId,
        );

        final client = await h.startDaemon();
        try {
          final execution = await client.executeAutoWithQueuedFollowUp(
            sessionId: sessionId,
            firstRequestId: 'auto-first-${_unique()}',
            queuedRequestId: 'auto-queued-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          expect(execution.compactionIds, hasLength(1));
          expect(execution.lifecycle, ['started', 'completed']);
          expect(execution.finalAnswers, 2);
          // The deterministic summarizer can complete before the follow-up
          // frame is admitted; either way the follow-up executes exactly once.
          expect(execution.queuedClassifications, lessThanOrEqualTo(1));

          final history = await client.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'history-auto-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          expect(_compactionRows(history), hasLength(1));
          final messages = history['messages'] as List;
          expect(
            messages.where(
              (row) =>
                  row is Map && row['content'] == 'queued during compaction',
            ),
            hasLength(1),
          );
          expect(
            messages.where(
              (row) => row is Map && row['content'] == 'e2e-success',
            ),
            hasLength(2),
          );
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
  );
}

List<Map<String, dynamic>> _compactionRows(Map<String, dynamic> history) {
  return (history['messages'] as List)
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .where(
        (row) => row['type'] == CanonicalEventTypes.contextCompactionCompleted,
      )
      .toList(growable: false);
}

class _CompactionHarness {
  _CompactionHarness._({
    required this.sanadHome,
    required this.sanadStateHome,
    required this.gatewayPort,
    required this.providerInstanceId,
    required this.worktreeDir,
  });

  final Directory sanadHome;
  final Directory sanadStateHome;
  final int gatewayPort;
  final String providerInstanceId;
  final Directory worktreeDir;
  Process? _daemon;
  bool _disposed = false;

  static const _baseGatewayPort = 58980;

  static Future<_CompactionHarness> create() async {
    final worktreeDir = Directory.current;
    final sanadHome = await Directory.systemTemp.createTemp('sanad-53-home-');
    final sanadStateHome = await Directory.systemTemp.createTemp(
      'sanad-53-state-',
    );
    final gatewayPort =
        _baseGatewayPort + (DateTime.now().microsecondsSinceEpoch % 200);
    final providerInstanceId = 'plan53-inst-${_unique()}';

    final harness = _CompactionHarness._(
      sanadHome: sanadHome,
      sanadStateHome: sanadStateHome,
      gatewayPort: gatewayPort,
      providerInstanceId: providerInstanceId,
      worktreeDir: worktreeDir,
    );
    await harness._writeEnv();
    await harness._seedProviderInstance();
    return harness;
  }

  Future<void> _writeEnv() async {
    final envFile = File('${sanadHome.path}/.env');
    await envFile.writeAsString('''
SANAD_HOME=${sanadHome.path}
SANAD_STATE_HOME=${sanadStateHome.path}
SANAD_E2E_TEST_MODE=true
ENABLE_LOCAL_GATEWAY=true
ENABLE_GATEWAY=false
LOCAL_GATEWAY_PORT=$gatewayPort
LOCAL_GATEWAY_HOST=127.0.0.1
ACTIVE_PROVIDER=$_template
LLM_API_KEY=fake-plan53-test-key
OPENAI_API_KEY=fake-plan53-test-key
OPENAI_MODEL=test-model
OPENAI_API_BASE=http://127.0.0.1:9/v1
LLM_BASE_URL=http://127.0.0.1:9/v1
LLM_MODEL=test-model
LOG_LEVEL=INFO
''');
  }

  Future<void> _seedProviderInstance() async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final repo = ProviderInstanceRepository(stateDb);
      final now = DateTime.now().toUtc();
      repo.createInstance(
        ProviderInstance(
          id: providerInstanceId,
          templateId: _template,
          authMethod: _authMethod,
          protocol: _protocol,
          baseUrl: 'http://127.0.0.1:9/v1',
          displayName: 'Plan 53 E2E Provider',
          defaultModel: 'test-model',
          status: 'ready',
          isDefault: true,
          createdAt: now,
          updatedAt: now,
        ),
      );
    } finally {
      stateDb.dispose();
    }
    await _seedSecretForInstance(providerInstanceId);
  }

  Future<void> _seedSecretForInstance(String instanceId) async {
    final secretFile = File('${sanadHome.path}/provider_secrets.json');
    await secretFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'instances': <String, dynamic>{
          instanceId: <String, dynamic>{
            'instance_id': instanceId,
            'auth_method': _authMethod,
            'api_key': 'fake-plan53-test-key',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        },
      }),
    );
  }

  Future<void> seedSession({
    required String sessionId,
    required String providerInstanceId,
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final sessions = SessionDB.fromState(stateDb);
      final now = DateTime.utc(2026, 8, 29);
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          model: 'test-model',
          providerId: providerInstanceId,
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessions.replaceMessages(sessionId, [
        Message(
          role: MessageRole.user,
          content: 'goal: daemon compaction e2e validation',
        ),
        for (var i = 0; i < 80; i++)
          Message(role: MessageRole.user, content: 'filler $i ${'x' * 300}'),
      ]);
    } finally {
      stateDb.dispose();
    }
  }

  Future<void> appendPostCompactionResponse(String sessionId) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final sessions = SessionDB.fromState(stateDb);
      sessions.replaceMessages(sessionId, [
        ...sessions.getMessages(sessionId),
        Message(
          role: MessageRole.assistant,
          content: 'response produced after compaction',
        ),
      ]);
    } finally {
      stateDb.dispose();
    }
  }

  Future<_CompactionClient> startDaemon() async {
    final proc = await Process.start(
      Platform.resolvedExecutable,
      <String>['bin/daemon.dart'],
      workingDirectory: worktreeDir.path,
      environment: <String, String>{
        ...Platform.environment,
        'SANAD_HOME': sanadHome.path,
        'SANAD_STATE_HOME': sanadStateHome.path,
        'SANAD_E2E_TEST_MODE': 'true',
        'ENABLE_LOCAL_GATEWAY': 'true',
        'ENABLE_GATEWAY': 'false',
        'LOCAL_GATEWAY_PORT': '$gatewayPort',
        'LOCAL_GATEWAY_HOST': '127.0.0.1',
        'LOG_LEVEL': 'INFO',
      },
    );
    _daemon = proc;
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
    await _waitForHealth(gatewayPort, sanadHome.path);
    return _CompactionClient.connect(
      port: gatewayPort,
      sanadHomePath: sanadHome.path,
    );
  }

  Future<void> killDaemon() async {
    final proc = _daemon;
    _daemon = null;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigkill);
    try {
      await proc.exitCode.timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await killDaemon();
    if (sanadHome.existsSync()) {
      try {
        await sanadHome.delete(recursive: true);
      } catch (_) {}
    }
    if (sanadStateHome.existsSync()) {
      try {
        await sanadStateHome.delete(recursive: true);
      } catch (_) {}
    }
  }
}

class _CompactionExecution {
  const _CompactionExecution({required this.result, required this.lifecycle});

  final Map<String, dynamic> result;
  final List<String> lifecycle;
}

class _AutoQueueExecution {
  const _AutoQueueExecution({
    required this.compactionIds,
    required this.lifecycle,
    required this.finalAnswers,
    required this.queuedClassifications,
  });

  final Set<String> compactionIds;
  final List<String> lifecycle;
  final int finalAnswers;
  final int queuedClassifications;
}

class _CompactionClient {
  _CompactionClient._(this.socket, this.frames);

  final WebSocket socket;
  final StreamIterator<dynamic> frames;

  static Future<_CompactionClient> connect({
    required int port,
    required String sanadHomePath,
  }) async {
    final socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: sanadHomePath,
    );
    final frames = StreamIterator<dynamic>(socket);
    if (!await frames.moveNext()) {
      throw StateError('Local daemon did not send register_success');
    }
    final first = jsonDecode(frames.current as String) as Map<String, dynamic>;
    if (first['type'] != 'register_success') {
      throw StateError('Expected register_success, got ${first['type']}');
    }
    return _CompactionClient._(socket, frames);
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }

  void _send(Map<String, dynamic> envelope) {
    socket.add(jsonEncode(envelope));
  }

  Future<_CompactionExecution> executeCompact({
    required String sessionId,
    required String requestId,
    required Duration timeout,
  }) async {
    _send(<String, dynamic>{
      'type': 'protocol_event',
      'event': <String, dynamic>{
        'type': CanonicalEventTypes.sessionCompact,
        'session_id': sessionId,
        'payload': <String, dynamic>{
          'session_id': sessionId,
          'request_id': requestId,
        },
      },
    });

    final lifecycleById = <String, List<String>>{};
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final eventName = frame['event']?.toString();
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] != sessionId) continue;

      if (eventName == CanonicalEventTypes.contextCompactionStarted ||
          eventName == CanonicalEventTypes.contextCompactionCompleted) {
        final compactionId = payload['compaction_id']?.toString();
        if (compactionId == null || compactionId.isEmpty) continue;
        final lifecycle = lifecycleById.putIfAbsent(
          compactionId,
          () => <String>[],
        );
        lifecycle.add(
          eventName == CanonicalEventTypes.contextCompactionStarted
              ? 'started'
              : 'completed',
        );
        continue;
      }

      if (eventName == CanonicalEventTypes.sessionCompactResult &&
          payload['request_id'] == requestId) {
        final compactionId = payload['compaction_id']?.toString();
        return _CompactionExecution(
          result: payload,
          lifecycle: compactionId == null
              ? const <String>[]
              : lifecycleById[compactionId] ?? const <String>[],
        );
      }
    }
    throw TimeoutException(
      'Timed out waiting for session.compact_result on $sessionId',
      timeout,
    );
  }

  Future<_AutoQueueExecution> executeAutoWithQueuedFollowUp({
    required String sessionId,
    required String firstRequestId,
    required String queuedRequestId,
    required Duration timeout,
  }) async {
    void sendThink(
      String requestId,
      String message, {
      String deliveryIntent = 'auto',
    }) {
      _send(<String, dynamic>{
        'type': 'execute_command',
        'command': 'think',
        'payload': <String, dynamic>{
          'request_id': requestId,
          'session_id': sessionId,
          'message': message,
          'provider_instance_id': 'e2e-provider',
          'model': 'e2e-model',
          'delivery_intent': deliveryIntent,
        },
      });
    }

    sendThink(firstRequestId, 'trigger automatic compaction');
    final compactionIds = <String>{};
    final lifecycle = <String>[];
    var finalAnswers = 0;
    var queuedClassifications = 0;
    var queuedFollowUpSent = false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if ((payload['session_id'] ?? frame['session_id']) != sessionId) continue;
      final eventName = frame['event']?.toString();
      if (eventName == CanonicalEventTypes.contextCompactionStarted ||
          eventName == CanonicalEventTypes.contextCompactionCompleted ||
          eventName == CanonicalEventTypes.contextCompactionFailed) {
        final compactionId = payload['compaction_id']?.toString();
        if (compactionId != null && compactionId.isNotEmpty) {
          compactionIds.add(compactionId);
        }
        lifecycle.add(switch (eventName) {
          CanonicalEventTypes.contextCompactionStarted => 'started',
          CanonicalEventTypes.contextCompactionCompleted => 'completed',
          _ => 'failed',
        });
        if (eventName == CanonicalEventTypes.contextCompactionStarted &&
            !queuedFollowUpSent) {
          queuedFollowUpSent = true;
          sendThink(
            queuedRequestId,
            'queued during compaction',
            deliveryIntent: 'queue',
          );
        }
        continue;
      }
      if (eventName == CanonicalEventTypes.sessionMessageClassified &&
          payload['classification'] == 'queue') {
        queuedClassifications++;
      }
      if (eventName == CanonicalEventTypes.finalAnswer) {
        finalAnswers++;
        if (finalAnswers == 2) {
          return _AutoQueueExecution(
            compactionIds: compactionIds,
            lifecycle: lifecycle,
            finalAnswers: finalAnswers,
            queuedClassifications: queuedClassifications,
          );
        }
      }
    }
    throw TimeoutException(
      'Timed out waiting for auto compaction and queued follow-up on $sessionId '
      '(lifecycle=$lifecycle, finals=$finalAnswers)',
      timeout,
    );
  }

  Future<Map<String, dynamic>> sendCompact({
    required String sessionId,
    required String requestId,
    required Duration timeout,
  }) async {
    _send(<String, dynamic>{
      'type': 'protocol_event',
      'event': <String, dynamic>{
        'type': CanonicalEventTypes.sessionCompact,
        'session_id': sessionId,
        'payload': <String, dynamic>{
          'session_id': sessionId,
          'request_id': requestId,
        },
      },
    });

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != CanonicalEventTypes.sessionCompactResult) {
        continue;
      }
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] != sessionId) continue;
      if (payload['request_id'] != requestId) continue;
      return payload;
    }
    throw TimeoutException(
      'Timed out waiting for session.compact_result on $sessionId',
      timeout,
    );
  }

  Future<List<String>> waitForCompactionLifecycle({
    required String sessionId,
    required String compactionId,
    required Duration timeout,
  }) async {
    final order = <String>[];
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (order.contains('started') && order.contains('completed')) {
        return order;
      }
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final eventName = frame['event']?.toString();
      if (eventName != CanonicalEventTypes.contextCompactionStarted &&
          eventName != CanonicalEventTypes.contextCompactionCompleted) {
        continue;
      }
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] != sessionId) continue;
      if (payload['compaction_id'] != compactionId) continue;
      if (eventName == CanonicalEventTypes.contextCompactionStarted) {
        order.add('started');
      } else {
        order.add('completed');
      }
    }
    throw TimeoutException(
      'Timed out waiting for compaction lifecycle on $sessionId ($order)',
      timeout,
    );
  }

  Future<Map<String, dynamic>> loadSessionHistory({
    required String sessionId,
    required String requestId,
    required Duration timeout,
  }) async {
    _send(<String, dynamic>{
      'type': 'execute_command',
      'command': 'get_session_history',
      'payload': <String, dynamic>{
        'session_id': sessionId,
        'request_id': requestId,
      },
    });

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'session_history') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] == sessionId) {
        return payload;
      }
    }
    throw TimeoutException(
      'Timed out waiting for session_history on $sessionId',
      timeout,
    );
  }
}

int _unique() =>
    DateTime.now().microsecondsSinceEpoch ^ Random().nextInt(1 << 20);

Future<void> _waitForHealth(int port, String sanadHomePath) async {
  final client = HttpClient();
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  Object? lastError;
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/health'),
        );
        authorizeLocalGatewayTestRequest(request, sanadHomePath);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          if (decoded['status'] == 'ok') return;
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
  throw StateError(
    'Local daemon health endpoint did not become ready: $lastError',
  );
}
