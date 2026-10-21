import 'dart:async';

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
  @override
  bool get ownsStoppedAgentLifecycle => false;
}

/// Records lifecycle calls in order so tests can assert sequencing.
class _ScriptedDaemonController implements LocalDaemonController {
  _ScriptedDaemonController({
    this.running = false,
    this.autoStart = true,
    this.serviceInstalled = true,
    this.ownsLifecycle = true,
    this.updateStatus = AgentLifecycleStatus.ready,
  });

  bool running;
  bool autoStart;
  bool serviceInstalled;
  bool ownsLifecycle;
  AgentLifecycleStatus updateStatus;
  Completer<void>? updateGate;
  final calls = <String>[];
  final updateTargets = <String>[];

  @override
  bool get ownsStoppedAgentLifecycle => ownsLifecycle;
  @override
  bool get shouldAutoStart => autoStart;
  @override
  bool isServiceInstalled() => serviceInstalled;
  @override
  Future<bool> isDaemonRunning() async => running;
  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async => running ? {'version': '1.0.0'} : null;
  @override
  Future<String?> getDaemonVersion() async => running ? '1.0.0' : null;
  @override
  Future<bool> install() async => true;
  @override
  Future<bool> restartDaemon() async => true;
  @override
  Future<bool> stopDaemon() async => true;
  @override
  Future<bool> startDaemon() async {
    calls.add('start');
    running = true;
    return true;
  }

  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    calls.add('update');
    updateTargets.add(targetVersion);
    await updateGate?.future;
    return AgentLifecycleResult(updateStatus);
  }
}

DeviceConnectionCoordinator _coordinatorFor(LocalDaemonController daemon) => DeviceConnectionCoordinator(
  cloudSocketService: FakeSanadSocketService(hardwareId: 'device-1'),
  localSocketService: FakeSanadSocketService(hardwareId: 'device-1'),
  currentDeviceId: 'device-1',
  daemonController: daemon,
  expectedVersion: '1.2.3',
);

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

  test('synthetic inventory id alone never selects the local transport', () {
    final cloudSocket = FakeSanadSocketService()..setConnected(true);
    final localSocket = FakeSanadSocketService()..setConnected(true);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final device = DeviceConfig(
      id: 'this-hardware',
      name: 'Incomplete inventory row',
      isOnline: true,
    );

    final endpoint = coordinator.resolve(device);

    expect(endpoint.scope, ConnectionScope.cloud);
    expect(identical(endpoint.socketService, cloudSocket), isTrue);

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

  test('announces per-device cloud interest without a local assertion exchange', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final agent = DeviceConfig(
      id: 'device-1',
      name: 'Sanad Agent',
      hardwareId: 'device-1',
      metadata: const {'cloud_device_id': 'cloud-device-1'},
    );

    await coordinator.synchronizeDeliveryPresence(agent);

    expect(cloudSocket.capturedCommands, [
      {
        'event': 'delivery_presence_interest',
        'data': {
          'device_ids': ['cloud-device-1'],
        },
      },
    ]);

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

  group('Task 107 local agent auto-pairing', () {
    test('a running agent is paired to the exact client version', () async {
      final daemon = _ScriptedDaemonController(running: true);
      final coordinator = _coordinatorFor(daemon);
      addTearDown(coordinator.dispose);

      expect(await coordinator.checkAndStartLocalDaemon(), isTrue);
      expect(daemon.calls, ['update']);
      expect(daemon.updateTargets, ['1.2.3']);
    });

    test('a stopped standalone agent is handed to the controller without starting it first', () async {
      final daemon = _ScriptedDaemonController(serviceInstalled: false, autoStart: false);
      final coordinator = _coordinatorFor(daemon);
      addTearDown(coordinator.dispose);

      expect(await coordinator.checkAndStartLocalDaemon(), isFalse);
      expect(daemon.calls, isEmpty, reason: 'no auto-start without force or a registered service');

      expect(await coordinator.checkAndStartLocalDaemon(force: true), isTrue);
      expect(daemon.calls, ['update'], reason: 'an incompatible binary must never be started before validation');
    });

    test('a source-managed agent is still started before the update query on Run Locally', () async {
      final daemon = _ScriptedDaemonController(
        autoStart: false,
        ownsLifecycle: false,
        updateStatus: AgentLifecycleStatus.sourceManaged,
      );
      final coordinator = _coordinatorFor(daemon);
      addTearDown(coordinator.dispose);

      expect(await coordinator.checkAndStartLocalDaemon(force: true), isTrue);
      expect(daemon.calls, ['start', 'update']);
    });

    test('concurrent callers share one lifecycle attempt', () async {
      final daemon = _ScriptedDaemonController()..updateGate = Completer<void>();
      final coordinator = _coordinatorFor(daemon);
      addTearDown(coordinator.dispose);

      final first = coordinator.checkAndStartLocalDaemon();
      final second = coordinator.checkAndStartLocalDaemon();
      await Future<void>.delayed(Duration.zero);
      daemon.updateGate!.complete();

      expect(await Future.wait([first, second]), [true, true]);
      expect(daemon.calls, ['update']);
    });

    test('a forced caller retries once after joining a failed unforced attempt', () async {
      final daemon = _ScriptedDaemonController(updateStatus: AgentLifecycleStatus.networkFailed)
        ..updateGate = Completer<void>();
      final coordinator = _coordinatorFor(daemon);
      addTearDown(coordinator.dispose);

      final unforced = coordinator.checkAndStartLocalDaemon();
      final forced = coordinator.checkAndStartLocalDaemon(force: true);
      await Future<void>.delayed(Duration.zero);
      daemon
        ..updateGate!.complete()
        ..updateGate = null;

      expect(await unforced, isFalse);
      expect(await forced, isFalse);
      expect(daemon.calls, ['update', 'update']);
    });
  });
}
