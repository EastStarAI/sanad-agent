import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_manager.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  const activeDeviceKey = 'active_device_id';
  const savedDeviceId = 'saved-cloud-device';

  late FakeSanadSocketService cloudSocket;
  late FakeSanadSocketService localSocket;
  late DeviceConnectionCoordinator coordinator;
  late DeviceManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      activeDeviceKey: savedDeviceId,
    });
    cloudSocket = FakeSanadSocketService(hardwareId: 'current-device');
    localSocket = FakeSanadSocketService(hardwareId: 'current-device');
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'current-device',
    );
    manager = await DeviceManager.create(cloudSocket, coordinator);
  });

  tearDown(() {
    AppPlatform.overrideIsDesktop = null;
    manager.dispose();
    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('authoritative inventory clears a persisted cloud device that no longer exists', () async {
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': <Map<String, dynamic>>[],
    });

    expect(manager.getActiveAgentId(), isNull);
  });

  test('authoritative inventory preserves a persisted cloud device that still exists', () async {
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        {
          'id': savedDeviceId,
          'name': 'Saved device',
          'is_online': false,
        },
      ],
    });

    expect(manager.getActiveAgentId(), savedDeviceId);
    expect(manager.getActiveAgent()?.id, savedDeviceId);
  });

  test('matching local inventory preserves and normalizes a persisted cloud identity', () async {
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        {
          'id': savedDeviceId,
          'name': 'This device in cloud',
          'hardware_id': 'current-device',
          'is_online': true,
        },
      ],
    });

    expect(manager.getActiveAgentId(), 'local-agent');
    expect(manager.getActiveAgent()?.id, 'local-agent');
    expect(manager.getActiveAgent()?.cloudDeviceId, savedDeviceId);
  });

  test('failed inventory response does not clear the persisted device', () async {
    await manager.handleDevicesResponseForTesting({
      'status': 'error',
      'devices': <Map<String, dynamic>>[],
    });

    expect(manager.getActiveAgentId(), savedDeviceId);
  });

  test('rename uses the cloud id for a merged local device and waits for its response', () async {
    cloudSocket.setConnected(true);
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        {
          'id': savedDeviceId,
          'name': 'Old name',
          'hardware_id': 'current-device',
          'is_online': true,
        },
      ],
    });
    cloudSocket.clearCaptured();

    final rename = manager.renameAgent(manager.agents.single, '  New name  ');
    final command = cloudSocket.capturedCommands.single;
    final payload = command['data'] as Map<String, dynamic>;
    expect(command['event'], 'update_device');
    expect(payload['device_id'], savedDeviceId);
    expect(payload['name'], 'New name');
    expect(payload['request_id'], startsWith('req_'));

    manager.handleDeviceUpdatedForTesting({
      'status': 'ok',
      'request_id': payload['request_id'],
      'device_id': savedDeviceId,
      'device': {
        'id': savedDeviceId,
        'name': 'New name',
        'hardware_id': 'current-device',
        'is_online': true,
      },
    });

    await rename;
    expect(manager.agents.single.name, 'New name');
    expect(manager.agents.single.id, 'local-agent');
  });

  test('rename surfaces a correlated backend error', () async {
    cloudSocket.setConnected(true);
    final device = DeviceConfig(id: 'cloud-device', name: 'Old name');

    final rename = manager.renameAgent(device, 'New name');
    final payload = cloudSocket.capturedCommands.single['data'] as Map<String, dynamic>;
    manager.handleDeviceUpdatedForTesting({
      'status': 'error',
      'request_id': payload['request_id'],
      'device_id': device.id,
      'message': 'Device not found',
    });

    await expectLater(rename, throwsA(isA<DeviceMutationException>()));
  });

  test('local-only device cannot be renamed', () async {
    cloudSocket.setConnected(true);
    final localOnly = DeviceConfig(id: 'local-agent', name: 'This device');

    await expectLater(manager.renameAgent(localOnly, 'New name'), throwsA(isA<DeviceMutationException>()));
    expect(cloudSocket.capturedCommands, isEmpty);
  });

  test('initial fetch normalizes cloud inventory from oldest to newest', () async {
    AppPlatform.overrideIsDesktop = false;

    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        _deviceJson('newest', '2026-03-03T00:00:00Z'),
        _deviceJson('oldest', '2026-01-01T00:00:00Z'),
        _deviceJson('middle', '2026-02-02T00:00:00Z'),
      ],
    });

    expect(manager.agents.map((device) => device.id), ['oldest', 'middle', 'newest']);
  });

  test('device_created inserts the new device by creation time', () async {
    AppPlatform.overrideIsDesktop = false;
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        _deviceJson('oldest', '2026-01-01T00:00:00Z'),
        _deviceJson('newest', '2026-03-03T00:00:00Z'),
      ],
    });

    manager.handleDeviceCreatedForTesting({
      'status': 'ok',
      'device': _deviceJson('middle', '2026-02-02T00:00:00Z'),
    });

    expect(manager.agents.map((device) => device.id), ['oldest', 'middle', 'newest']);
  });

  test('unknown online status triggers authoritative inventory reconciliation', () async {
    AppPlatform.overrideIsDesktop = false;
    cloudSocket.setConnected(true);
    cloudSocket.clearCaptured();

    manager.handleStatusChangeForTesting({
      'device_id': 'newly-paired-device',
      'is_online': true,
    });

    expect(cloudSocket.capturedCommands.single['event'], 'get_devices');
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        _deviceJson('newly-paired-device', '2026-08-29T22:00:00Z'),
      ],
    });
    expect(manager.agents.single.id, 'newly-paired-device');
  });

  test('device_status_changed preserves oldest-to-newest ordering', () async {
    AppPlatform.overrideIsDesktop = false;
    await manager.handleDevicesResponseForTesting({
      'status': 'ok',
      'devices': [
        _deviceJson('newest', '2026-03-03T00:00:00Z'),
        _deviceJson('oldest', '2026-01-01T00:00:00Z'),
      ],
    });

    manager.handleStatusChangeForTesting({
      'device_id': 'oldest',
      'is_online': true,
    });

    expect(manager.agents.map((device) => device.id), ['oldest', 'newest']);
    expect(manager.agents.first.isOnline, isTrue);
  });
}

Map<String, dynamic> _deviceJson(String id, String createdAt) => {
  'id': id,
  'name': id,
  'is_online': false,
  'created_at': createdAt,
};
