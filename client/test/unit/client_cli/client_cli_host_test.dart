import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sanad_client/features/client_cli/data/client_cli_approval_coordinator.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_record.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_settings.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

import '../../helpers/fake_device_repository.dart';
import '../../mocks/mock_socket_service.dart';

class FakeTestDeviceConnectionCoordinator extends Fake implements DeviceConnectionCoordinator {
  final SanadSocketService mockSocket;

  FakeTestDeviceConnectionCoordinator(this.mockSocket);

  @override
  String get currentDeviceId => 'local-hardware-id';

  @override
  Future<ResolvedAgentEndpoint> ensureConnectedEndpointForAgent(DeviceConfig agent) async {
    return ResolvedAgentEndpoint(
      agent: agent,
      scope: ConnectionScope.cloud,
      socketService: mockSocket,
      isLocalReachable: false,
    );
  }
}

class TestSanadSocketService extends FakeSanadSocketService {
  TestSanadSocketService() : super(hardwareId: 'cloud-server');

  List<Map<String, dynamic>> get sentCommands => capturedCommands;

  void emitMockEvent(Map<String, dynamic> event) {
    debugEmitEvent(event);
  }
}

class _ConcurrencyProbeOwnership extends ClientCliOwnership {
  _ConcurrencyProbeOwnership({required super.processAliveChecker});

  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> acquireOwnership(ClientCliRecord record) async {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      // Widen the window so overlapping lifecycle mutations cannot hide.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await super.acquireOwnership(record);
    } finally {
      _inFlight--;
    }
  }
}

void main() {
  group('ClientCliHost', () {
    late Directory tempHome;
    late ClientCliOwnership ownership;
    late ClientCliApprovalCoordinator approvalCoordinator;
    late FakeDeviceRepository deviceRepo;
    late TestSanadSocketService mockSocket;
    late FakeTestDeviceConnectionCoordinator coordinator;
    late ClientCliHost host;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('client_cli_host_test_');
      ownership = ClientCliOwnership(processAliveChecker: (_) async => true);
      approvalCoordinator = ClientCliApprovalCoordinator();
      deviceRepo = FakeDeviceRepository();
      mockSocket = TestSanadSocketService()..setConnected(true);
      coordinator = FakeTestDeviceConnectionCoordinator(mockSocket);

      deviceRepo.seedAgents([
        DeviceConfig(
          id: 'local-hw-1',
          name: 'My Desktop',
          hardwareId: 'local-hw-1',
          isOnline: true,
        ),
        DeviceConfig(
          id: 'dev-remote-1',
          name: 'Remote Worker',
          hardwareId: 'remote-hw-1',
          isOnline: true,
          metadata: {'cloud_device_id': 'dev-remote-1', 'platform': 'linux'},
        ),
      ]);

      host = ClientCliHost(
        connectionCoordinator: coordinator,
        deviceRepository: deviceRepo,
        ownership: ownership,
        approvalCoordinator: approvalCoordinator,
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        initialEnabled: false,
        initialPermissionMode: ClientCliSettings.defaultMode,
      );
    });

    tearDown(() async {
      await host.stop();
      approvalCoordinator.dispose();
      mockSocket.dispose();
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('starts and binds loopback server, writes record', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      expect(host.isRunning, isTrue);
      expect(host.port, isNotNull);
      expect(host.token, isNotNull);

      final record = await ownership.readRecord(tempHome.path);
      expect(record, isNotNull);
      expect(record!.port, host.port);
      expect(record.token, host.token);
      expect(record.enabled, isTrue);
      expect(record.permissionMode, 'default');
    });

    test('rejects requests with missing or invalid token with 401', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      final client = http.Client();
      try {
        final resNoToken = await client.get(Uri.parse('http://127.0.0.1:${host.port}/health'));
        expect(resNoToken.statusCode, 401);

        final resBadToken = await client.get(
          Uri.parse('http://127.0.0.1:${host.port}/health'),
          headers: {'x-sanad-client-token': 'wrong-token'},
        );
        expect(resBadToken.statusCode, 401);
      } finally {
        client.close();
      }
    });

    test('returns health information on /health with valid token', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      final client = http.Client();
      try {
        final res = await client.get(
          Uri.parse('http://127.0.0.1:${host.port}/health'),
          headers: {'x-sanad-client-token': host.token!},
        );
        expect(res.statusCode, 200);
        final data = jsonDecode(res.body);
        expect(data['status'], 'ok');
        expect(data['enabled'], isTrue);
        expect(data['permission_mode'], 'default');
        expect(data['client_version'], '1.0.15');
      } finally {
        client.close();
      }
    });

    test('returns 403 on /devices when disabled, lists remote devices when enabled', () async {
      await host.start(); // initialEnabled is false

      final client = http.Client();
      try {
        // 1. When disabled -> 403
        var res = await client.get(
          Uri.parse('http://127.0.0.1:${host.port}/devices'),
          headers: {'x-sanad-client-token': host.token!},
        );
        expect(res.statusCode, 403);

        // 2. Enable -> 200 with only remote devices
        await host.updateSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        );

        res = await client.get(
          Uri.parse('http://127.0.0.1:${host.port}/devices'),
          headers: {'x-sanad-client-token': host.token!},
        );
        expect(res.statusCode, 200);
        final data = jsonDecode(res.body);
        final devices = data['devices'] as List;
        expect(devices.length, 1);
        expect(devices.first['id'], 'dev-remote-1');
        expect(devices.first['name'], 'Remote Worker');
      } finally {
        client.close();
      }
    });

    test('full_access mode forwards command directly and streams stdout/stderr/result', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.fullAccessMode,
      );

      final wsUri = Uri.parse('ws://127.0.0.1:${host.port}/ws?token=${host.token}');
      final socket = await WebSocket.connect(wsUri.toString());

      final stdoutChunks = <String>[];
      final stderrChunks = <String>[];
      final completer = Completer<Map<String, dynamic>>();

      socket.listen((msg) {
        final data = jsonDecode(msg.toString()) as Map<String, dynamic>;
        if (data['type'] == 'stdout') {
          stdoutChunks.add(data['text']);
        } else if (data['type'] == 'stderr') {
          stderrChunks.add(data['text']);
        } else if (data['type'] == 'result') {
          completer.complete(data);
        }
      });

      // Send execute
      socket.add(
        jsonEncode({
          'type': 'execute',
          'request_id': 'req-test-1',
          'device_id': 'dev-remote-1',
          'argv': ['ws', 'list'],
          'stdin': null,
          'brief_content': null,
          'timeout_seconds': 30,
        }),
      );

      // Verify command was dispatched to mock socket
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mockSocket.sentCommands.length, 1);
      final sent = mockSocket.sentCommands.first;
      expect(sent['command'], 'device.cli.execute');
      expect(sent['device_id'], 'dev-remote-1');
      expect(sent['payload']['argv'], ['ws', 'list']);

      // Emit stdout event from remote agent
      mockSocket.emitMockEvent({
        'event': 'device.cli.stdout',
        'request_id': 'req-test-1',
        'payload': {'request_id': 'req-test-1', 'text': 'Workspace 1\n'},
      });

      // Emit stderr event from remote agent
      mockSocket.emitMockEvent({
        'event': 'device.cli.stderr',
        'request_id': 'req-test-1',
        'payload': {'request_id': 'req-test-1', 'text': 'Notice: default ws\n'},
      });

      // Emit terminal result from remote agent
      mockSocket.emitMockEvent({
        'event': 'device.cli.result',
        'request_id': 'req-test-1',
        'payload': {'request_id': 'req-test-1', 'exit_code': 0, 'cancelled': false},
      });

      final result = await completer.future.timeout(const Duration(seconds: 2));
      expect(result['exit_code'], 0);
      expect(stdoutChunks, contains('Workspace 1\n'));
      expect(stderrChunks, contains('Notice: default ws\n'));

      await socket.close();
    });

    test('default mode prompts for approval; denial produces rejected result', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      final wsUri = Uri.parse('ws://127.0.0.1:${host.port}/ws?token=${host.token}');
      final socket = await WebSocket.connect(wsUri.toString());

      final completer = Completer<Map<String, dynamic>>();
      socket.listen((msg) {
        final data = jsonDecode(msg.toString()) as Map<String, dynamic>;
        if (data['type'] == 'result') {
          completer.complete(data);
        }
      });

      // Send execute
      socket.add(
        jsonEncode({
          'type': 'execute',
          'request_id': 'req-test-2',
          'device_id': 'dev-remote-1',
          'argv': ['run', 'do something risky'],
        }),
      );

      // Wait for approval request to be emitted
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(approvalCoordinator.currentRequest, isNotNull);
      expect(approvalCoordinator.currentRequest!.id, 'req-test-2');
      expect(approvalCoordinator.currentRequest!.deviceName, 'Remote Worker');

      // User denies in Client UI
      approvalCoordinator.resolveCurrent(ClientCliApprovalDecision.deny);

      final result = await completer.future.timeout(const Duration(seconds: 2));
      expect(result['exit_code'], 1);
      expect(result['error'], contains('Command rejected by user in Sanad Client'));

      // Nothing sent to remote agent
      expect(mockSocket.sentCommands, isEmpty);

      await socket.close();
    });

    test('default mode announces the pending approval before it prompts', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      final wsUri = Uri.parse('ws://127.0.0.1:${host.port}/ws?token=${host.token}');
      final socket = await WebSocket.connect(wsUri.toString());

      final frames = <Map<String, dynamic>>[];
      final statusSeen = Completer<Map<String, dynamic>>();
      final resultSeen = Completer<Map<String, dynamic>>();
      socket.listen((msg) {
        final data = jsonDecode(msg.toString()) as Map<String, dynamic>;
        frames.add(data);
        if (data['type'] == 'status' && !statusSeen.isCompleted) {
          statusSeen.complete(data);
        }
        if (data['type'] == 'result' && !resultSeen.isCompleted) {
          resultSeen.complete(data);
        }
      });

      socket.add(
        jsonEncode({
          'type': 'execute',
          'request_id': 'req-approval-notice',
          'device_id': 'dev-remote-1',
          'argv': ['ws', 'list'],
        }),
      );

      final status = await statusSeen.future.timeout(const Duration(seconds: 2));
      expect(status['code'], 'approval_pending');
      expect(status['message'], contains('Waiting for approval'));
      // The notice precedes the approval prompt, so a headless caller explains
      // the wait before the user is asked.
      expect(approvalCoordinator.currentRequest, isNotNull);

      approvalCoordinator.resolveCurrent(ClientCliApprovalDecision.deny);
      final result = await resultSeen.future.timeout(const Duration(seconds: 2));
      expect(result['exit_code'], 1);
      expect(result['error'], contains('rejected by user'));
      expect(
        frames.indexOf(status) < frames.indexOf(result),
        isTrue,
        reason: 'the approval notice must precede the terminal result',
      );

      await socket.close();
    });

    test('approval is scoped to the session the Agent will act on, not to a '
        'token the parser consumed as a message', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      final wsUri = Uri.parse('ws://127.0.0.1:${host.port}/ws?token=${host.token}');
      final socket = await WebSocket.connect(wsUri.toString());
      final resultSeen = Completer<Map<String, dynamic>>();
      socket.listen((msg) {
        final data = jsonDecode(msg.toString()) as Map<String, dynamic>;
        if (data['type'] == 'result' && !resultSeen.isCompleted) {
          resultSeen.complete(data);
        }
      });

      socket.add(
        jsonEncode({
          'type': 'execute',
          'request_id': 'req-steer-target',
          'device_id': 'dev-remote-1',
          // `args` consumes `-s` as the value of `--message`, so the Agent
          // targets sess-B. Approving sess-A would approve a different session.
          'argv': ['session', 'steer', 'sess-B', '--message', '-s', 'sess-A'],
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(approvalCoordinator.currentRequest, isNotNull);
      expect(
        approvalCoordinator.currentRequest!.sessionId,
        'sess-B',
        reason: 'the approval must name the session the Agent acts on',
      );

      approvalCoordinator.resolveCurrent(ClientCliApprovalDecision.deny);
      final result = await resultSeen.future.timeout(const Duration(seconds: 2));
      expect(result['exit_code'], 1);

      await socket.close();
    });

    test('two different session ids in one relay are refused, not guessed',
        () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      final wsUri = Uri.parse('ws://127.0.0.1:${host.port}/ws?token=${host.token}');
      final socket = await WebSocket.connect(wsUri.toString());
      final errorSeen = Completer<Map<String, dynamic>>();
      socket.listen((msg) {
        final data = jsonDecode(msg.toString()) as Map<String, dynamic>;
        if (data['type'] == 'error' && !errorSeen.isCompleted) {
          errorSeen.complete(data);
        }
      });

      socket.add(
        jsonEncode({
          'type': 'execute',
          'request_id': 'req-steer-conflict',
          'device_id': 'dev-remote-1',
          'argv': [
            'session',
            'steer',
            'sess-B',
            '--session',
            'sess-A',
            '--message',
            'x',
          ],
        }),
      );

      final error = await errorSeen.future.timeout(const Duration(seconds: 2));
      expect(error['code'], 'ambiguous_session_target');
      expect(
        approvalCoordinator.currentRequest,
        isNull,
        reason: 'nothing is approved when the target is ambiguous',
      );
      expect(
        mockSocket.sentCommands,
        isEmpty,
        reason: 'an ambiguous target is never relayed to the Agent',
      );

      await socket.close();
    });

    test('a relay whose device event stream ends still returns one terminal result',
        () async {
      final livenessSocket = TestSanadSocketService()..setConnected(true);
      final livenessCoordinator = FakeTestDeviceConnectionCoordinator(livenessSocket);
      final livenessHost = ClientCliHost(
        connectionCoordinator: livenessCoordinator,
        deviceRepository: deviceRepo,
        ownership: ownership,
        approvalCoordinator: ClientCliApprovalCoordinator(),
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        initialEnabled: true,
        initialPermissionMode: ClientCliSettings.fullAccessMode,
      );

      try {
        await livenessHost.start();
        final wsUri = Uri.parse(
          'ws://127.0.0.1:${livenessHost.port}/ws?token=${livenessHost.token}',
        );
        final socket = await WebSocket.connect(wsUri.toString());

        final resultFrames = <Map<String, dynamic>>[];
        final terminal = Completer<Map<String, dynamic>>();
        socket.listen((msg) {
          final data = jsonDecode(msg.toString()) as Map<String, dynamic>;
          if (data['type'] == 'result') {
            resultFrames.add(data);
            if (!terminal.isCompleted) terminal.complete(data);
          }
        });

        socket.add(
          jsonEncode({
            'type': 'execute',
            'request_id': 'req-stream-lost',
            'device_id': 'dev-remote-1',
            'argv': ['run', '--workspace', 'ws-core', 'work'],
          }),
        );

        // The remote execution started, then the device transport was torn
        // down before any terminal result arrived.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(livenessSocket.sentCommands, isNotEmpty);
        livenessSocket.dispose();

        final result = await terminal.future.timeout(const Duration(seconds: 2));
        expect(result['exit_code'], isNot(0));
        expect(result['error'], contains('ended before a terminal result'));
        expect(resultFrames, hasLength(1));

        await socket.close();
        await livenessHost.stop();
      } finally {
        await livenessHost.stop();
      }
    });

    test('stopping host releases ownership and closes server', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isTrue);

      await host.stop();
      expect(host.isRunning, isFalse);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isFalse);
    });

    test('re-applying an enabled setting restores a released endpoint', () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );
      final releasedPort = host.port;
      expect(host.isRunning, isTrue);

      // Simulate the logout path that releases ownership while the feature
      // stays enabled in settings.
      await host.stop();
      expect(host.isRunning, isFalse);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isFalse);

      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      expect(host.isRunning, isTrue);
      expect(host.port, isNotNull);
      expect(host.port, isNot(releasedPort));
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isTrue);

      final record = await ownership.readRecord(tempHome.path);
      expect(record?.enabled, isTrue);
      expect(record?.port, host.port);
    });

    test('re-applying a disabled setting keeps the endpoint closed', () async {
      await host.updateSettings(
        enabled: false,
        permissionMode: ClientCliSettings.defaultMode,
      );

      expect(host.isRunning, isFalse);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isFalse);
    });

    test('concurrent enable requests publish exactly one serving endpoint', () async {
      final probe = _ConcurrencyProbeOwnership(
        processAliveChecker: (_) async => true,
      );
      final probeHost = ClientCliHost(
        connectionCoordinator: coordinator,
        deviceRepository: deviceRepo,
        ownership: probe,
        approvalCoordinator: approvalCoordinator,
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        initialEnabled: false,
        initialPermissionMode: ClientCliSettings.defaultMode,
      );

      await Future.wait([
        probeHost.updateSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        ),
        probeHost.updateSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        ),
        probeHost.updateSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        ),
      ]);

      // Lifecycle mutations are serialized: only one owner acquisition may be in
      // flight, so a second start can never bind a listener on a published server.
      expect(probe.maxInFlight, 1);
      expect(probeHost.isRunning, isTrue);
      final port = probeHost.port!;

      final response = await http
          .get(
            Uri.parse('http://127.0.0.1:$port/health'),
            headers: {'x-sanad-client-token': probeHost.token!},
          )
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);

      final record = await probe.readRecord(tempHome.path);
      expect(record?.port, port);
      expect(record?.enabled, isTrue);

      await probeHost.stop();
    });

    test('an enable immediately followed by stop settles as stopped', () async {
      await Future.wait([
        host.updateSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        ),
        host.stop(),
      ]);

      expect(host.isRunning, isFalse);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isFalse);
    });

    test('a stop immediately followed by enable restores a serving endpoint',
        () async {
      await host.updateSettings(
        enabled: true,
        permissionMode: ClientCliSettings.defaultMode,
      );

      await Future.wait([
        host.stop(),
        host.updateSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        ),
      ]);

      expect(host.isRunning, isTrue);
      final port = host.port!;

      final response = await http
          .get(
            Uri.parse('http://127.0.0.1:$port/health'),
            headers: {'x-sanad-client-token': host.token!},
          )
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);

      final record = await ownership.readRecord(tempHome.path);
      expect(record?.port, port);
    });
  });
}
