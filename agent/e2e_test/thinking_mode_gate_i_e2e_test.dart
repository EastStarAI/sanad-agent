// Gate I — daemon-backed end-to-end proof for provider-aware thinking mode.
//
// Proves the full path:
//   canonical thinking_mode → turn admission → runner options → policy resolution
//   → adapter payload (captured on the fake OpenAI-compatible LLM).
//
// Run with `--concurrency=1` because each test binds gateway and fake LLM ports.
@Tags(<String>['e2e', 'gate-i'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

const _template = 'openai';
const _authMethod = 'api_key';
const _protocol = 'openai_compatible';

void main() {
  test(
    'I.1 supported selection reaches provider payload with reasoning_effort',
    () async {
      final h = await _ThinkingHarness.create();
      try {
        h.fakeLlm.enqueueText('gate-i-supported');
        final client = await h.startDaemon();
        try {
          final sessionId = 'gate-i-supported-${_unique()}';
          await client.sendThink(
            sessionId: sessionId,
            requestId: 'i1-${_unique()}',
            message: 'hello',
            model: 'o3',
            providerInstanceId: h.instanceId,
            thinkingMode: 'high',
          );
          final answer = await client.waitForFinalAnswer(
            sessionId: sessionId,
            timeout: const Duration(seconds: 45),
          );
          expect(answer, 'gate-i-supported');
          expect(h.fakeLlm.requestCount, 1);
          expect(h.fakeLlm.lastRequestBody?['reasoning_effort'], 'high');
          expect(h.fakeLlm.lastRequestBody?['model'], 'o3');
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'I.2 unsupported explicit selection skips provider HTTP call',
    () async {
      final h = await _ThinkingHarness.create();
      try {
        final client = await h.startDaemon();
        try {
          final sessionId = 'gate-i-unsupported-${_unique()}';
          await client.sendThink(
            sessionId: sessionId,
            requestId: 'i2-${_unique()}',
            message: 'hello',
            model: 'gpt-test',
            providerInstanceId: h.instanceId,
            thinkingMode: 'deep',
          );
          final outcome = await client.waitForTurnTerminal(
            sessionId: sessionId,
            timeout: const Duration(seconds: 45),
          );
          expect(outcome.blocked, isTrue);
          expect(h.fakeLlm.requestCount, 0);
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'I.3 model switch revalidates stale thinking selection via daemon',
    () async {
      final h = await _ThinkingHarness.create();
      try {
        h.fakeLlm.enqueueText('first-high');
        h.fakeLlm.enqueueText('title-fallback');
        h.fakeLlm.enqueueText('after-switch');
        final client = await h.startDaemon();
        try {
          final sessionId = 'gate-i-switch-${_unique()}';
          await client.sendThink(
            sessionId: sessionId,
            requestId: 'i3a-${_unique()}',
            message: 'first',
            model: 'o3',
            providerInstanceId: h.instanceId,
            thinkingMode: 'high',
          );
          await client.waitForFinalAnswer(
            sessionId: sessionId,
            timeout: const Duration(seconds: 45),
          );
          expect(h.fakeLlm.lastRequestBody?['reasoning_effort'], 'high');

          await client.sendThink(
            sessionId: sessionId,
            requestId: 'i3b-${_unique()}',
            message: 'second',
            model: 'gpt-test',
            providerInstanceId: h.instanceId,
            thinkingMode: 'high',
          );
          final switched = await client.waitForFinalAnswer(
            sessionId: sessionId,
            timeout: const Duration(seconds: 45),
          );
          expect(switched, 'after-switch');

          expect(h.fakeLlm.requestCount, 3);
          expect(
            h.fakeLlm.capturedBodies.last.containsKey('reasoning_effort'),
            isFalse,
            reason: 'unsupported route must not emit reasoning_effort',
          );
          expect(
            h.readSessionThinkingMode(sessionId),
            isNull,
            reason: 'model switch must clear invalid persisted thinking',
          );
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'I.4 daemon restart revalidates persisted thinking on restore',
    () async {
      final h = await _ThinkingHarness.create();
      try {
        h.fakeLlm.enqueueText('restored-turn');
        final sessionId = 'gate-i-restart-${_unique()}';
        await h.seedPersistedSession(
          sessionId: sessionId,
          model: 'gpt-test',
          thinkingMode: 'high',
          queuedMessage: 'resume after restart',
        );

        final client = await h.startDaemon();
        try {
          await client.waitForFinalAnswer(
            sessionId: sessionId,
            timeout: const Duration(seconds: 60),
          );
          expect(h.readSessionThinkingMode(sessionId), isNull);
          expect(h.fakeLlm.requestCount, 1);
          expect(
            h.fakeLlm.lastRequestBody?.containsKey('reasoning_effort'),
            isFalse,
          );
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _ThinkingHarness {
  _ThinkingHarness._({
    required this.sanadHome,
    required this.sanadStateHome,
    required this.gatewayPort,
    required this.fakeLlm,
    required this.instanceId,
    required this.worktreeDir,
  });

  final Directory sanadHome;
  final Directory sanadStateHome;
  final int gatewayPort;
  final _CapturingFakeLlmServer fakeLlm;
  final String instanceId;
  final Directory worktreeDir;

  Process? _daemon;
  bool _disposed = false;

  static Future<_ThinkingHarness> create() async {
    final worktreeDir = Directory.current;
    final sanadHome = await Directory.systemTemp.createTemp('sanad-i-home-');
    final sanadStateHome = await Directory.systemTemp.createTemp(
      'sanad-i-state-',
    );
    final gatewayPort = await _allocateLoopbackPort();
    final fake = await _CapturingFakeLlmServer.start();
    final instanceId = 'gate-i-inst-${_unique()}';

    final h = _ThinkingHarness._(
      sanadHome: sanadHome,
      sanadStateHome: sanadStateHome,
      gatewayPort: gatewayPort,
      fakeLlm: fake,
      instanceId: instanceId,
      worktreeDir: worktreeDir,
    );

    await h._writeEnv();
    await h._seedProviderInstance(
      instanceId: instanceId,
      fakePort: fake.port,
    );
    await h._seedModelCache(instanceId);
    await h._seedSecret(instanceId);
    return h;
  }

  Future<void> _writeEnv() async {
    final envFile = File('${sanadHome.path}/.env');
    await envFile.writeAsString('''
SANAD_HOME=${sanadHome.path}
SANAD_STATE_HOME=${sanadStateHome.path}
ENABLE_LOCAL_GATEWAY=true
ENABLE_GATEWAY=false
LOCAL_GATEWAY_PORT=$gatewayPort
LOCAL_GATEWAY_HOST=127.0.0.1
ACTIVE_PROVIDER=$_template
LLM_API_KEY=fake-gate-i-test-key
OPENAI_API_KEY=fake-gate-i-test-key
OPENAI_MODEL=o3
OPENAI_API_BASE=http://127.0.0.1:${fakeLlm.port}/v1
LLM_BASE_URL=http://127.0.0.1:${fakeLlm.port}/v1
LLM_MODEL=o3
LOG_LEVEL=INFO
PROVIDER_AUTO_FAILOVER=false
''');
  }

  Future<void> _seedProviderInstance({
    required String instanceId,
    required int fakePort,
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final repo = ProviderInstanceRepository(stateDb);
      final now = DateTime.now();
      repo.createInstance(
        ProviderInstance(
          id: instanceId,
          templateId: _template,
          displayName: 'Gate I OpenAI',
          protocol: _protocol,
          authMethod: _authMethod,
          baseUrl: 'http://127.0.0.1:$fakePort/v1',
          defaultModel: 'o3',
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

  Future<void> _seedModelCache(String instanceId) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final repo = ProviderInstanceRepository(stateDb);
      repo.upsertModelCache(
        instanceId: instanceId,
        cacheKey: 'models',
        models: [
          {
            'value': 'o3',
            'supports_reasoning_output': true,
            'thinking_control': {
              'status': 'supported',
              'kind': 'effort',
              'options': [
                {'id': 'low', 'label': 'Low'},
                {'id': 'medium', 'label': 'Medium'},
                {'id': 'high', 'label': 'High'},
              ],
              'capability_revision': '1:1:openai_chat_effort:o3',
              'source': 'profile',
            },
          },
          {
            'value': 'gpt-test',
            'thinking_control': {
              'status': 'unsupported',
              'capability_revision': '1:1:openai_chat_effort:gpt-test',
              'source': 'profile',
            },
          },
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
    } finally {
      stateDb.dispose();
    }
  }

  Future<void> _seedSecret(String instanceId) async {
    final secretFile = File('${sanadHome.path}/provider_secrets.json');
    await secretFile.writeAsString(jsonEncode({
      'instances': {
        instanceId: {
          'instance_id': instanceId,
          'auth_method': _authMethod,
          'api_key': 'fake-gate-i-test-key',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      },
    }));
  }

  Future<void> seedPersistedSession({
    required String sessionId,
    required String model,
    required String? thinkingMode,
    required String queuedMessage,
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final repo = PersistedRuntimeStateRepository(stateDb.db);
      final now = DateTime.now();
      stateDb.db.execute(
        '''INSERT OR REPLACE INTO sessions (
          session_id, model, title, workspace_id, metadata,
          provider_id, thinking_mode, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          sessionId,
          model,
          'Gate I Restart',
          null,
          '{}',
          instanceId,
          thinkingMode,
          now.toUtc().toIso8601String(),
          now.toUtc().toIso8601String(),
        ],
      );
      repo.enqueueWorkItem(
        workItemId: 'wi-$sessionId-1',
        sessionId: sessionId,
        requestId: 'req-$sessionId-1',
        providerInstanceId: instanceId,
        modelId: model,
        payload: <String, dynamic>{
          'message': queuedMessage,
          'eventMetadata': <String, dynamic>{},
          'runId': 'run-$sessionId',
        },
        state: SessionWorkState.queued,
      );
    } finally {
      stateDb.dispose();
    }
  }

  String? readSessionThinkingMode(String sessionId) {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final rows = stateDb.db.select(
        'SELECT thinking_mode FROM sessions WHERE session_id = ?',
        <Object?>[sessionId],
      );
      if (rows.isEmpty) return null;
      return rows.first['thinking_mode'] as String?;
    } finally {
      stateDb.dispose();
    }
  }

  Future<_ThinkingTestClient> startDaemon() async {
    final environment = <String, String>{
      ...Platform.environment,
      'SANAD_HOME': sanadHome.path,
      'SANAD_STATE_HOME': sanadStateHome.path,
      'ENABLE_LOCAL_GATEWAY': 'true',
      'ENABLE_GATEWAY': 'false',
      'LOCAL_GATEWAY_PORT': '$gatewayPort',
      'LOCAL_GATEWAY_HOST': '127.0.0.1',
      'LLM_API_KEY': 'fake-gate-i-test-key',
      'OPENAI_API_KEY': 'fake-gate-i-test-key',
      'LLM_MODEL': 'o3',
      'OPENAI_MODEL': 'o3',
      'OPENAI_API_BASE': 'http://127.0.0.1:${fakeLlm.port}/v1',
      'LLM_BASE_URL': 'http://127.0.0.1:${fakeLlm.port}/v1',
      'LOG_LEVEL': 'INFO',
    };
    final proc = await Process.start(
      Platform.resolvedExecutable,
      <String>['bin/daemon.dart'],
      workingDirectory: worktreeDir.path,
      environment: environment,
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
    return _ThinkingTestClient.connect(
      port: gatewayPort,
      sanadHomePath: sanadHome.path,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final proc = _daemon;
    _daemon = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      try {
        await proc.exitCode.timeout(
          const Duration(seconds: 6),
          onTimeout: () {
            proc.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    }
    await fakeLlm.stop();
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

class _CapturingFakeLlmServer {
  _CapturingFakeLlmServer._(this.port, this._server);

  final int port;
  final HttpServer _server;
  final List<String> _responses = [];
  int _requestCount = 0;
  final List<Map<String, dynamic>> capturedBodies = [];

  int get requestCount => _requestCount;
  Map<String, dynamic>? get lastRequestBody =>
      capturedBodies.isEmpty ? null : capturedBodies.last;

  static Future<_CapturingFakeLlmServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _CapturingFakeLlmServer._(server.port, server);
    unawaited(fake._serve());
    return fake;
  }

  void enqueueText(String content) {
    _responses.add(content);
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      if (request.method != 'POST' ||
          !request.uri.path.endsWith('/chat/completions')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      _requestCount++;
      final rawBody = await utf8.decoder.bind(request).join();
      capturedBodies.add(
        Map<String, dynamic>.from(jsonDecode(rawBody) as Map),
      );

      if (_responses.isEmpty) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        continue;
      }

      final content = _responses.removeAt(0);
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      final chunks = _openAiChunks(content: content);
      for (final chunk in chunks) {
        request.response.write(chunk);
      }
      await request.response.close();
    }
  }

  List<String> _openAiChunks({required String content}) {
    final id = 'chatcmpl-${_unique()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String encode(Map<String, dynamic> data) => 'data: ${jsonEncode(data)}\n\n';
    return [
      encode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': 'fake-gate-i',
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant'},
            'finish_reason': null,
          },
        ],
      }),
      encode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': 'fake-gate-i',
        'choices': [
          {
            'index': 0,
            'delta': {'content': content},
            'finish_reason': null,
          },
        ],
      }),
      encode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': 'fake-gate-i',
        'choices': [
          {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
        ],
      }),
      encode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': 'fake-gate-i',
        'choices': [
          {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
        ],
      }),
      'data: [DONE]\n\n',
    ];
  }

  Future<void> stop() async {
    try {
      await _server.close(force: true);
    } catch (_) {}
  }
}

class _TurnTerminalOutcome {
  const _TurnTerminalOutcome({
    this.finalAnswer,
    this.blocked = false,
  });

  final String? finalAnswer;
  final bool blocked;
}

class _ThinkingTestClient {
  _ThinkingTestClient._(this.socket, this.frames);

  final WebSocket socket;
  final StreamIterator<dynamic> frames;

  static Future<_ThinkingTestClient> connect({
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
    return _ThinkingTestClient._(socket, frames);
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }

  void _send(Map<String, dynamic> envelope) {
    socket.add(jsonEncode(envelope));
  }

  Future<void> sendThink({
    required String sessionId,
    required String requestId,
    required String message,
    required String model,
    required String providerInstanceId,
    String? thinkingMode,
  }) async {
    final payload = <String, dynamic>{
      'request_id': requestId,
      'session_id': sessionId,
      'message': message,
      'model': model,
      'provider_instance_id': providerInstanceId,
      'thinking_mode': ?thinkingMode,
    };
    _send(<String, dynamic>{
      'type': 'execute_command',
      'command': 'think',
      'payload': payload,
    });
  }

  Future<_TurnTerminalOutcome> waitForTurnTerminal({
    required String sessionId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final eventName = frame['event'] as String?;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId != sessionId) continue;

      if (eventName == 'final_answer') {
        final content = payload['content']?.toString() ?? '';
        if (content.trim().isNotEmpty) {
          return _TurnTerminalOutcome(finalAnswer: content.trim());
        }
      }
      if (eventName == 'session.runtime_notice') {
        final status = payload['status']?.toString() ?? '';
        if (status == 'blocked') {
          return const _TurnTerminalOutcome(blocked: true);
        }
      }
    }
    throw TimeoutException(
      'Timed out waiting for terminal turn outcome on $sessionId',
      timeout,
    );
  }

  Future<String> waitForFinalAnswer({
    required String sessionId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'final_answer') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId != sessionId) continue;
      final content = payload['content']?.toString() ?? '';
      if (content.trim().isNotEmpty) return content.trim();
    }
    throw TimeoutException(
      'Timed out waiting for final_answer on $sessionId',
      timeout,
    );
  }

  Future<List<Map<String, dynamic>>> loadSessions({
    required String requestId,
  }) async {
    _send(<String, dynamic>{
      'type': 'execute_command',
      'command': 'get_sessions',
      'payload': {'request_id': requestId},
    });
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'sessions_list') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      return (payload['sessions'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
    }
    throw TimeoutException('Timed out waiting for sessions_list');
  }
}

int _unique() =>
    DateTime.now().microsecondsSinceEpoch ^ Random().nextInt(1 << 20);

Future<int> _allocateLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitForHealth(int port, String sanadHomePath) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(seconds: 2));
      authorizeLocalGatewayTestRequest(request, sanadHomePath);
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        if (decoded['status'] == 'ok') return;
      }
      lastError = StateError(
        'Unexpected health response (${response.statusCode}): $body',
      );
    } catch (error) {
      lastError = error;
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError(
    'Local daemon health endpoint did not become ready: $lastError',
  );
}
