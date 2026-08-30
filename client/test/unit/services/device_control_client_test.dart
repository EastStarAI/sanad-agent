import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/device_control_client.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService local;
  late FakeSanadSocketService cloud;
  late DeviceConnectionCoordinator coordinator;
  late DeviceCommandClient commands;
  late DeviceControlClient client;

  setUp(() {
    local = FakeSanadSocketService()..setConnected(true);
    cloud = FakeSanadSocketService()..setConnected(true);
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloud,
      localSocketService: local,
      currentDeviceId: 'this-hardware',
    );
    commands = DeviceCommandClient(connectionCoordinator: coordinator);
    client = DeviceControlClient(commands);
  });

  tearDown(() {
    coordinator.dispose();
    local.dispose();
    cloud.dispose();
  });

  DeviceConfig cloudDevice({bool online = true}) => DeviceConfig(
    id: 'cloud-device',
    name: 'Other device',
    hardwareId: 'other-hardware',
    isOnline: online,
  );

  test('sends update check to the cloud device without a local HTTP call', () async {
    final future = client.checkForUpdates(cloudDevice());
    await Future<void>.delayed(Duration.zero);
    expect(cloud.capturedCommands.single['command'], 'device.update.check');
    expect(cloud.capturedCommands.single['device_id'], 'cloud-device');
    expect(local.capturedCommands, isEmpty);
    final payload = cloud.capturedCommands.single['payload'] as Map<String, dynamic>;
    cloud.debugEmitEvent({
      'event': 'device.update.check.result',
      'payload': {
        'request_id': payload['request_id'],
        'status': 'update_available',
        'current_version': '1.0.0',
        'available_version': '1.1.0',
        'confirmation_token': 'ticket-1',
        'manifest_revision': 'v1.1.0',
        'manifest_fingerprint': 'abc123',
      },
    });
    final result = await future;
    expect(result.updateAvailable, isTrue);
    expect(result.confirmationToken, 'ticket-1');
  });

  test('restart uses the protocol command for a cloud device', () async {
    final future = client.restartAgent(cloudDevice());
    await Future<void>.delayed(Duration.zero);
    expect(cloud.capturedCommands.single['command'], 'device.runtime.restart');
    expect(local.capturedCommands, isEmpty);
    final payload = cloud.capturedCommands.single['payload'] as Map<String, dynamic>;
    cloud.debugEmitEvent({
      'event': 'device.runtime.restart.accepted',
      'payload': {'request_id': payload['request_id'], 'status': 'accepted'},
    });
    expect((await future)['status'], 'accepted');
  });

  test('force restart sends an explicit force flag', () async {
    final future = client.restartAgent(cloudDevice(), force: true);
    await Future<void>.delayed(Duration.zero);
    final command = cloud.capturedCommands.single;
    expect(command['command'], 'device.runtime.restart');
    final payload = command['payload'] as Map<String, dynamic>;
    expect(payload['force'], isTrue);
    cloud.debugEmitEvent({
      'event': 'device.runtime.restart.accepted',
      'payload': {'request_id': payload['request_id'], 'status': 'accepted'},
    });
    expect((await future)['status'], 'accepted');
  });

  test('waitForReconnect succeeds only after offline then online', () async {
    final inventory = _MemoryInventory(
      DeviceConfig(
        id: 'cloud-device',
        name: 'Other device',
        hardwareId: 'other-hardware',
        isOnline: true,
        metadata: const {'version': '1.0.0'},
      ),
    );
    final waiting = client.waitForReconnect(
      inventory: inventory,
      deviceId: 'cloud-device',
      expectedVersion: '1.1.0',
    );
    inventory.emit(
      DeviceConfig(
        id: 'cloud-device',
        name: 'Other device',
        hardwareId: 'other-hardware',
        isOnline: false,
        metadata: const {'version': '1.0.0'},
      ),
    );
    inventory.emit(
      DeviceConfig(
        id: 'cloud-device',
        name: 'Other device',
        hardwareId: 'other-hardware',
        isOnline: true,
        metadata: const {'version': '1.1.0'},
      ),
    );
    final restored = await waiting;
    expect(restored.isOnline, isTrue);
    expect(restored.metadata?['version'], '1.1.0');
  });
}

class _MemoryInventory implements IDeviceRepository {
  _MemoryInventory(DeviceConfig initial) : _agents = [initial];

  List<DeviceConfig> _agents;
  final _controller = StreamController<List<DeviceConfig>>.broadcast();

  void emit(DeviceConfig device) {
    _agents = [device];
    _controller.add(_agents);
  }

  @override
  List<DeviceConfig> get agents => _agents;

  @override
  Stream<List<DeviceConfig>> get onAgentsUpdate => _controller.stream;

  @override
  Future<void> init() async {}

  @override
  Future<List<DeviceConfig>> fetchAgents() async => _agents;

  @override
  DeviceConfig? getActiveAgent() => _agents.isEmpty ? null : _agents.first;

  @override
  String? getActiveAgentId() => _agents.isEmpty ? null : _agents.first.id;

  @override
  Future<void> setActiveAgent(String? deviceId) async {}

  @override
  void createAgent(String name, {String type = 'computer'}) {}

  @override
  Future<void> renameAgent(DeviceConfig device, String name) async {}

  @override
  void deleteAgent(String deviceId) {}

  @override
  Future<void> clearAgents() async {}

  @override
  void dispose() {
    unawaited(_controller.close());
  }
}
