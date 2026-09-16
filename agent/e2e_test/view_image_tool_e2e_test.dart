import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/engine/adapters/e2e_fixture_adapter.dart';
import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  test(
    'daemon-backed view_image derives its answer from pixels and keeps events text-only',
    () async {
      final harness = await _ViewImageHarness.start();
      addTearDown(harness.close);
      final image = await harness.writeMagentaImage(
        harness.workspace,
        name: 'opaque-input.bin',
      );

      final sessionId = harness.nextSessionId('rich');
      harness.sendViewImage(
        sessionId: sessionId,
        imagePath: image.uri.pathSegments.last,
      );
      final answer = await harness.probe.waitForDeviceEvent(
        sessionId: sessionId,
        eventType: 'final_answer',
      );

      expect(
        answer['payload']['content'],
        E2eFixtureAdapter.viewImagePixelResponseText,
      );
      expect(
        harness.serializedSessionFrames(sessionId),
        isNot(contains('dataBase64')),
      );
      expect(
        harness.serializedSessionFrames(sessionId),
        isNot(contains('base64')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'local attachment admission stays binary-free until the model chooses view_image',
    () async {
      final harness = await _ViewImageHarness.start();
      addTearDown(harness.close);
      final image = await harness.writeMagentaImage(
        harness.external,
        name: 'opaque-attachment.bin',
      );
      final bytes = await image.readAsBytes();
      final sessionId = harness.nextSessionId('attachment');
      await harness.createSession(sessionId);
      final requestId = 'attachment-$sessionId';
      final attachmentIds = await harness.admitAttachments(
        sessionId: sessionId,
        requestId: requestId,
        attachments: [
          {
            'name': 'opaque-payload.bin',
            'size_bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'data_base64': base64Encode(bytes),
          },
        ],
      );
      expect(attachmentIds, hasLength(1));

      harness.sendAdmittedAttachment(
        sessionId: sessionId,
        requestId: requestId,
        attachmentIds: attachmentIds,
      );
      final userEvent = await harness.probe.waitForDeviceEvent(
        sessionId: sessionId,
        eventType: 'user_message',
      );
      final userPayload = jsonEncode(userEvent['payload']);
      expect(userPayload, contains('opaque-payload.bin'));
      expect(userPayload, isNot(contains('data_base64')));
      expect(userPayload, isNot(contains(image.path)));
      expect(userPayload, isNot(contains('agent_local_reference')));

      final answer = await harness.probe
          .waitForDeviceEvent(sessionId: sessionId, eventType: 'final_answer')
          .onError((error, stackTrace) {
            throw StateError(
              'Final answer missing. Frames: ${harness.serializedSessionFrames(sessionId)}',
            );
          });
      expect(
        answer['payload']['content'],
        E2eFixtureAdapter.viewImagePixelResponseText,
        reason: harness.serializedSessionFrames(sessionId),
      );
      final frames = harness.serializedSessionFrames(sessionId);
      expect(frames, isNot(contains('data_base64')));
      expect(frames, isNot(contains('iVBOR')));
      expect(frames, isNot(contains(image.path)));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'attachment admission rejects receiver boundaries and cleans partial staging',
    () async {
      final harness = await _ViewImageHarness.start();
      addTearDown(harness.close);
      final sessionId = harness.nextSessionId('attachment-rejection');
      await harness.createSession(sessionId);
      final bytes = utf8.encode('valid-first-payload');
      final valid = {
        'name': 'valid.bin',
        'size_bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'data_base64': base64Encode(bytes),
      };

      final partialFailure = await harness.requestAttachmentAdmission(
        sessionId: sessionId,
        requestId: 'partial-$sessionId',
        attachments: [
          valid,
          {
            ...valid,
            'name': 'invalid.bin',
            'sha256': List.filled(64, '0').join(),
          },
        ],
      );
      expect(partialFailure['outcome'], 'admission_failed');

      final oversized = await harness.requestAttachmentAdmission(
        sessionId: sessionId,
        requestId: 'oversized-$sessionId',
        attachments: [
          {...valid, 'size_bytes': 5 * 1024 * 1024 + 1},
        ],
      );
      expect(oversized['outcome'], 'admission_failed');

      final tooMany = await harness.requestAttachmentAdmission(
        sessionId: sessionId,
        requestId: 'count-$sessionId',
        attachments: List<Map<String, dynamic>>.generate(
          5,
          (index) => {...valid, 'name': 'file-$index.bin'},
        ),
      );
      expect(tooMany['outcome'], 'invalid_request');

      final attachmentRoot = Directory(
        '${harness.sanadStateHome.path}/attachments',
      );
      final ownedDirectories = attachmentRoot
          .listSync()
          .whereType<Directory>()
          .where((entry) => !entry.path.endsWith('/.partial'));
      expect(ownedDirectories, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'external view_image obeys deny, allow-once, and full-access policy',
    () async {
      final harness = await _ViewImageHarness.start();
      addTearDown(harness.close);
      final image = await harness.writeMagentaImage(
        harness.external,
        name: 'opaque-external.bin',
      );

      final deniedSession = harness.nextSessionId('deny');
      harness.sendViewImage(sessionId: deniedSession, imagePath: image.path);
      final deniedRequest = await harness.probe.waitForDeviceEvent(
        sessionId: deniedSession,
        eventType: 'tool_permission_request',
      );
      harness.respondToPermission(
        sessionId: deniedSession,
        requestId: deniedRequest['payload']['request_id'] as String,
        allowed: false,
      );
      final deniedAnswer = await harness.probe.waitForDeviceEvent(
        sessionId: deniedSession,
        eventType: 'final_answer',
      );
      expect(
        deniedAnswer['payload']['content'],
        E2eFixtureAdapter.viewImageInvalidResponseText,
      );

      final allowedSession = harness.nextSessionId('allow');
      harness.sendViewImage(sessionId: allowedSession, imagePath: image.path);
      final allowedRequest = await harness.probe.waitForDeviceEvent(
        sessionId: allowedSession,
        eventType: 'tool_permission_request',
      );
      harness.respondToPermission(
        sessionId: allowedSession,
        requestId: allowedRequest['payload']['request_id'] as String,
        allowed: true,
      );
      final allowedAnswer = await harness.probe.waitForDeviceEvent(
        sessionId: allowedSession,
        eventType: 'final_answer',
      );
      expect(
        allowedAnswer['payload']['content'],
        E2eFixtureAdapter.viewImagePixelResponseText,
      );

      await const WorkspacePolicyStore().savePermissionMode(
        harness.workspace.path,
        WorkspacePermissionMode.fullAccess,
      );
      final fullAccessSession = harness.nextSessionId('full-access');
      harness.sendViewImage(
        sessionId: fullAccessSession,
        imagePath: image.path,
      );
      final fullAccessAnswer = await harness.probe.waitForDeviceEvent(
        sessionId: fullAccessSession,
        eventType: 'final_answer',
      );
      expect(
        fullAccessAnswer['payload']['content'],
        E2eFixtureAdapter.viewImagePixelResponseText,
      );
      expect(
        harness.probe.deviceEventCount(
          fullAccessSession,
          'tool_permission_request',
        ),
        0,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'completed view_image survives restart and source deletion exactly once',
    () async {
      final harness = await _ViewImageHarness.start(pauseAfterResult: true);
      addTearDown(harness.close);
      final image = await harness.writeMagentaImage(
        harness.workspace,
        name: 'ephemeral-source.bin',
      );
      final sessionId = harness.nextSessionId('restart');
      harness.sendViewImage(
        sessionId: sessionId,
        imagePath: image.uri.pathSegments.last,
      );

      await harness.waitForPausedToolResult();
      await image.delete();
      await harness.restartWithoutPause();
      harness.retrySession(sessionId);

      final answer = await harness.probe.waitForDeviceEvent(
        sessionId: sessionId,
        eventType: 'final_answer',
      );
      expect(
        answer['payload']['content'],
        E2eFixtureAdapter.viewImagePixelResponseText,
      );

      harness.requestSessionHistory(sessionId);
      final history = await harness.probe.waitForDeviceEvent(
        sessionId: sessionId,
        eventType: 'session_history',
      );
      final serialized = jsonEncode(history['payload']);
      expect(serialized, contains(E2eFixtureAdapter.viewImageToolCallId));
      expect(
        RegExp(E2eFixtureAdapter.viewImageToolCallId).allMatches(serialized),
        hasLength(2),
        reason: 'One assistant tool call and one matching result are expected.',
      );
      expect(serialized, isNot(contains('dataBase64')));
      expect(serialized, isNot(contains('iVBOR')));
      expect(serialized, isNot(contains(image.path)));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'text-only provider receives the safe view_image fallback through the daemon',
    () async {
      final harness = await _ViewImageHarness.start(textOnly: true);
      addTearDown(harness.close);
      final image = await harness.writeMagentaImage(
        harness.workspace,
        name: 'opaque-fallback.bin',
      );

      final sessionId = harness.nextSessionId('text-only');
      harness.sendViewImage(
        sessionId: sessionId,
        imagePath: image.uri.pathSegments.last,
      );
      final answer = await harness.probe.waitForDeviceEvent(
        sessionId: sessionId,
        eventType: 'final_answer',
      );

      expect(
        answer['payload']['content'],
        E2eFixtureAdapter.viewImageTextFallbackResponseText,
      );
      final frames = harness.serializedSessionFrames(sessionId);
      expect(frames, isNot(contains('dataBase64')));
      expect(frames, isNot(contains('iVBOR')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

final class _ViewImageHarness {
  _ViewImageHarness._({
    required this.sanadHome,
    required this.sanadStateHome,
    required this.workspace,
    required this.external,
    required this.port,
    required this.daemon,
    required this.socket,
    required this.probe,
    required this.deviceId,
    required this.pauseFile,
  });

  final Directory sanadHome;
  final Directory sanadStateHome;
  final Directory workspace;
  final Directory external;
  final int port;
  Process daemon;
  WebSocket socket;
  _FrameProbe probe;
  final String deviceId;
  final File? pauseFile;
  var _sessionCounter = 0;

  static Future<_ViewImageHarness> start({
    bool textOnly = false,
    bool pauseAfterResult = false,
  }) async {
    final sanadHome = await Directory.systemTemp.createTemp(
      'sanad-view-image-e2e-home-',
    );
    final sanadStateHome = await Directory.systemTemp.createTemp(
      'sanad-view-image-e2e-state-',
    );
    final workspace = Directory('${sanadHome.path}/workspace')
      ..createSync(recursive: true);
    final external = Directory('${sanadHome.path}/external')
      ..createSync(recursive: true);
    await File('${workspace.path}/AGENTS.md').writeAsString(
      'Workspace owned by the daemon-backed view_image E2E fixture.',
    );
    final port = await _reserveFreePort();
    final pauseFile = pauseAfterResult
        ? File('${sanadStateHome.path}/view-image-result-ready')
        : null;
    final daemon = await _startDaemon(
      sanadHome: sanadHome,
      sanadStateHome: sanadStateHome,
      port: port,
      textOnly: textOnly,
      pauseFile: pauseFile,
    );
    try {
      await _waitForHealth(port, sanadHome.path);
      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: sanadHome.path,
      );
      final probe = _FrameProbe(socket);
      await probe.waitForFrameType('register_success');
      return _ViewImageHarness._(
        sanadHome: sanadHome,
        sanadStateHome: sanadStateHome,
        workspace: workspace,
        external: external,
        port: port,
        daemon: daemon,
        socket: socket,
        probe: probe,
        deviceId: 'view-image-e2e-device',
        pauseFile: pauseFile,
      );
    } catch (_) {
      daemon.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  String nextSessionId(String label) =>
      'view-image-$label-${DateTime.now().microsecondsSinceEpoch}-${_sessionCounter++}';

  Future<File> writeMagentaImage(
    Directory directory, {
    required String name,
  }) async {
    final image = img.Image(width: 12, height: 10);
    img.fill(image, color: img.ColorRgb8(255, 0, 255));
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(img.encodePng(image), flush: true);
    return file;
  }

  Future<void> createSession(String sessionId) async {
    final requestId = 'create-$sessionId';
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': deviceId,
        'command': 'create_session',
        'payload': {
          'request_id': requestId,
          'session_id': sessionId,
          'title': 'Attachment fixture',
          'provider_id': E2eFixtureAdapter.providerId,
          'model': E2eFixtureAdapter.modelId,
        },
      }),
    );
    await probe.waitForRequest(requestId);
  }

  Future<List<String>> admitAttachments({
    required String sessionId,
    required String requestId,
    required List<Map<String, dynamic>> attachments,
  }) async {
    final payload = await requestAttachmentAdmission(
      sessionId: sessionId,
      requestId: requestId,
      attachments: attachments,
    );
    if (payload['outcome'] != 'accepted') {
      throw StateError('Attachment admission failed: ${payload['outcome']}');
    }
    return (payload['attachment_ids'] as List).cast<String>();
  }

  Future<Map<String, dynamic>> requestAttachmentAdmission({
    required String sessionId,
    required String requestId,
    required List<Map<String, dynamic>> attachments,
  }) async {
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': deviceId,
        'command': 'attachment.admit',
        'payload': {
          'request_id': requestId,
          'session_id': sessionId,
          'attachments': attachments,
        },
      }),
    );
    final result = await probe.waitForRequest(requestId);
    return Map<String, dynamic>.from(result['payload'] as Map? ?? const {});
  }

  void sendAdmittedAttachment({
    required String sessionId,
    required String requestId,
    required List<String> attachmentIds,
  }) {
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': deviceId,
        'command': 'think',
        'payload': {
          'request_id': requestId,
          'session_id': sessionId,
          'provider_instance_id': E2eFixtureAdapter.providerId,
          'model': E2eFixtureAdapter.modelId,
          'message': E2eFixtureAdapter.attachmentImagePrompt,
          'attachment_ids': attachmentIds,
        },
      }),
    );
  }

  void sendViewImage({required String sessionId, required String imagePath}) {
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': deviceId,
        'command': 'think',
        'payload': {
          'request_id': 'req-$sessionId',
          'session_id': sessionId,
          'workspace_id': workspace.path,
          'provider_instance_id': E2eFixtureAdapter.providerId,
          'model': E2eFixtureAdapter.modelId,
          'message':
              '${E2eFixtureAdapter.viewImagePromptPrefix}${jsonEncode(imagePath)}',
        },
      }),
    );
  }

  void respondToPermission({
    required String sessionId,
    required String requestId,
    required bool allowed,
  }) {
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': deviceId,
        'command': 'tool_permission_response',
        'payload': {
          'session_id': sessionId,
          'request_id': requestId,
          'allowed': allowed,
          'scope': 'once',
          'decision': allowed ? 'allow' : 'deny',
        },
      }),
    );
  }

  Future<void> waitForPausedToolResult() async {
    final ready = pauseFile;
    if (ready == null) throw StateError('Pause fixture is not enabled.');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!ready.existsSync()) {
      throw StateError('Timed out waiting for persisted view_image result.');
    }
  }

  Future<void> restartWithoutPause() async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:$port/restart?force=true&timeout_seconds=1',
        ),
      );
      authorizeLocalGatewayTestRequest(request, sanadHome.path);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Controlled restart returned ${response.statusCode}.');
      }
    } finally {
      client.close(force: true);
    }
    await probe.close();
    await socket.close();
    await daemon.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        daemon.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    daemon = await _startDaemon(
      sanadHome: sanadHome,
      sanadStateHome: sanadStateHome,
      port: port,
      textOnly: false,
      pauseFile: null,
    );
    await _waitForHealth(port, sanadHome.path);
    socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: sanadHome.path,
    );
    probe = _FrameProbe(socket);
    await probe.waitForFrameType('register_success');
  }

  void retrySession(String sessionId) {
    socket.add(
      jsonEncode({
        'type': 'protocol_event',
        'event': {
          'type': 'session.runtime_retry',
          'session_id': sessionId,
          'payload': {'request_id': 'retry-$sessionId'},
        },
      }),
    );
  }

  void requestSessionHistory(String sessionId) {
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': deviceId,
        'command': 'get_session_history',
        'payload': {
          'session_id': sessionId,
          'request_id': 'history-$sessionId',
        },
      }),
    );
  }

  String serializedSessionFrames(String sessionId) => jsonEncode(
    probe.frames.where((frame) => probe.sessionId(frame) == sessionId).toList(),
  );

  Future<void> close() async {
    await probe.close();
    await socket.close();
    daemon.kill(ProcessSignal.sigterm);
    await daemon.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        daemon.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    for (final directory in [sanadHome, sanadStateHome]) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  }
}

final class _FrameProbe {
  _FrameProbe(WebSocket socket) {
    _subscription = socket.listen((raw) {
      frames.add(jsonDecode(raw as String) as Map<String, dynamic>);
      _changes.add(null);
    });
  }

  final frames = <Map<String, dynamic>>[];
  final _changes = StreamController<void>.broadcast(sync: true);
  late final StreamSubscription<dynamic> _subscription;

  int deviceEventCount(String sessionId, String eventType) => frames
      .where(
        (frame) =>
            frame['type'] == 'device_event' &&
            this.sessionId(frame) == sessionId &&
            frame['event'] == eventType,
      )
      .length;

  Future<Map<String, dynamic>> waitForFrameType(String type) =>
      _waitFor((frame) => frame['type'] == type, 'frame type $type');

  Future<Map<String, dynamic>> waitForRequest(String requestId) => _waitFor(
    (frame) =>
        frame['request_id'] == requestId ||
        (frame['payload'] is Map &&
            (frame['payload'] as Map)['request_id'] == requestId),
    'request $requestId',
  );

  Future<Map<String, dynamic>> waitForDeviceEvent({
    required String sessionId,
    required String eventType,
  }) => _waitFor(
    (frame) =>
        frame['type'] == 'device_event' &&
        this.sessionId(frame) == sessionId &&
        frame['event'] == eventType,
    '$eventType on $sessionId',
  );

  Future<Map<String, dynamic>> _waitFor(
    bool Function(Map<String, dynamic>) predicate,
    String description,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      for (final frame in frames) {
        if (predicate(frame)) return frame;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw StateError('Timed out waiting for $description');
      }
      await _changes.stream.first.timeout(remaining);
    }
  }

  String? sessionId(Map<String, dynamic> frame) {
    final payload = frame['payload'] is Map
        ? Map<String, dynamic>.from(frame['payload'] as Map)
        : const <String, dynamic>{};
    return frame['session_id']?.toString() ?? payload['session_id']?.toString();
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _changes.close();
  }
}

Future<int> _reserveFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<Process> _startDaemon({
  required Directory sanadHome,
  required Directory sanadStateHome,
  required int port,
  required bool textOnly,
  required File? pauseFile,
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['bin/daemon.dart'],
    workingDirectory: Directory.current.path,
    environment: {
      ...Platform.environment,
      'SANAD_HOME': sanadHome.path,
      'SANAD_STATE_HOME': sanadStateHome.path,
      'SANAD_E2E_TEST_MODE': 'true',
      'SANAD_E2E_TEXT_ONLY_TOOL_RESULTS': '$textOnly',
      if (pauseFile != null) 'SANAD_E2E_VIEW_IMAGE_PAUSE_FILE': pauseFile.path,
      'ENABLE_GATEWAY': 'false',
      'ENABLE_LOCAL_GATEWAY': 'true',
      'LOCAL_GATEWAY_PORT': '$port',
      'LLM_BASE_URL': 'http://127.0.0.1/e2e',
      'LLM_MODEL': E2eFixtureAdapter.modelId,
      'DUMP_REQUESTS': 'false',
    },
  );
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  return process;
}

Future<void> _waitForHealth(int port, String sanadHomePath) async {
  final client = HttpClient();
  final deadline = DateTime.now().add(const Duration(seconds: 20));
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
        if (response.statusCode == HttpStatus.ok &&
            (jsonDecode(body) as Map<String, dynamic>)['status'] == 'ok') {
          return;
        }
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  } finally {
    client.close(force: true);
  }
  throw StateError('Daemon health check failed: $lastError');
}
