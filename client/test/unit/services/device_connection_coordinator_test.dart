import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_socket.dart';

class _RetrySocket extends FakeSanadSocketService {
  int attempts = 0;

  @override
  Future<void> connect() async {
    attempts++;
    if (attempts == 1) throw StateError('first attempt failed');
    setConnected(true);
  }
}

class _ReadyDaemonController implements LocalDaemonController {
  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async => {'status': 'ok', 'version': '1.0.0'};
  @override
  Future<String?> getDaemonVersion() async => '1.0.0';
  @override
  Future<bool> install() async => true;
  @override
  bool isServiceInstalled() => true;
  @override
  Future<bool> isDaemonRunning() async => true;
  @override
  Future<bool> restartDaemon() async => true;
  @override
  bool get shouldAutoStart => true;
  @override
  Future<bool> startDaemon() async => true;
  @override
  Future<bool> stopDaemon() async => true;
  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async => const AgentLifecycleResult(AgentLifecycleStatus.upToDate);
}

void main() {
  test('prefers local when sanadagent agent is on the same device and local socket is ready', () {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );

    final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', hardwareId: 'device-1', isOnline: true);

    final endpoint = coordinator.resolve(agent);

    expect(endpoint.scope, ConnectionScope.local);
    expect(identical(endpoint.socketService, localSocket), isTrue);
    expect(endpoint.isLocalReachable, isTrue);

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('falls back to cloud when local socket is unavailable', () {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );

    final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', hardwareId: 'device-1', isOnline: true);

    final endpoint = coordinator.resolve(agent);

    expect(endpoint.scope, ConnectionScope.cloud);
    expect(identical(endpoint.socketService, cloudSocket), isTrue);
    expect(endpoint.isLocalReachable, isFalse);

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('does not invent a new agent type while decorating local metadata', () {
    final socket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: socket,
      localSocketService: socket,
      currentDeviceId: 'device-1',
    );

    final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', hardwareId: 'device-1', isOnline: true);

    final decorated = coordinator.decorateAgent(agent);

    expect(decorated.isLocalReachable, isTrue);
    expect(decorated.prefersLocalConnection, isTrue);

    coordinator.dispose();
    socket.dispose();
  });

  test('failed local connection attempts can be retried in the same lifecycle', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final localSocket = _RetrySocket();
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
      daemonController: _ReadyDaemonController(),
    );

    await coordinator.ensureLocalConnection();
    expect(localSocket.isConnected, isFalse);
    await coordinator.ensureLocalConnection();

    expect(localSocket.isConnected, isTrue);
    expect(localSocket.attempts, 2);

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('announces per-device interest and binds local assertion before takeover', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')
      ..setConnected(true)
      ..presenceAssertion = 'assertion-1';
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final agent = DeviceConfig(
      id: 'local-agent',
      name: 'Sanad Agent',
      hardwareId: 'device-1',
      metadata: const {'cloud_device_id': 'cloud-device-1'},
    );

    await coordinator.synchronizeDeliveryPresence(agent);

    expect(
      cloudSocket.capturedCommands.first,
      {
        'event': 'delivery_presence_interest',
        'data': {
          'device_ids': ['cloud-device-1'],
        },
      },
    );
    expect(cloudSocket.capturedCommands.last['event'], 'request_local_presence_assertion');
    expect(localSocket.appliedLocalPresenceAssertion, 'assertion-1');
    expect(localSocket.localHelloRefreshes, 1);

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('publishes the complete device interest set and removes only absent inventory devices', () {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final first = DeviceConfig(id: 'device-b', name: 'Remote B');
    final second = DeviceConfig(id: 'device-a', name: 'Remote A');

    coordinator.synchronizeCloudInterests([first, second]);
    expect(cloudSocket.capturedCommands.last, {
      'event': 'delivery_presence_interest',
      'data': {
        'device_ids': ['device-a', 'device-b'],
      },
    });

    coordinator.synchronizeCloudInterests([second]);
    expect(cloudSocket.capturedCommands.last, {
      'event': 'delivery_presence_interest',
      'data': {
        'device_ids': ['device-a'],
      },
    });

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('per-device synchronization preserves previously interested devices', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );

    await coordinator.synchronizeDeliveryPresence(DeviceConfig(id: 'device-a', name: 'Remote A'));
    await coordinator.synchronizeDeliveryPresence(DeviceConfig(id: 'device-b', name: 'Remote B'));

    expect(cloudSocket.capturedCommands.last, {
      'event': 'delivery_presence_interest',
      'data': {
        'device_ids': ['device-a', 'device-b'],
      },
    });

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('keeps cloud route safe when assertion cannot be obtained', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final agent = DeviceConfig(
      id: 'cloud-device-1',
      name: 'Sanad Agent',
      hardwareId: 'device-1',
    );

    await coordinator.synchronizeDeliveryPresence(agent);

    expect(localSocket.appliedLocalPresenceAssertion, isNull);
    expect(localSocket.localHelloRefreshes, 0);

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('respects custom expectedVersion parameter', () {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
      expectedVersion: '2.0.0',
    );

    expect(coordinator.expectedVersion, '2.0.0');

    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });
}
