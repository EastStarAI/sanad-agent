import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sanad_client/features/client_cli/data/client_cli_approval_coordinator.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
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
  });
}
