import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';

import '../../helpers/fake_socket.dart';

void main() {
  tearDown(() {
    AppPlatform.overrideIsDesktop = null;
  });

  DeviceInventoryMerger createMerger({
    required FakeSanadSocketService localSocket,
    String currentDeviceId = 'device-1',
  }) {
    final cloudSocket = FakeSanadSocketService(hardwareId: currentDeviceId);
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: currentDeviceId,
    );
    addTearDown(() {
      coordinator.dispose();
      cloudSocket.dispose();
      localSocket.dispose();
    });
    return DeviceInventoryMerger(
      connectionCoordinator: coordinator,
      localSource: LocalDeviceInventorySource(coordinator),
    );
  }

  test('adds this device on desktop when no cloud device matches local hardware', () {
    AppPlatform.overrideIsDesktop = true;
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final merger = createMerger(localSocket: localSocket);

    final devices = merger.merge(const <DeviceConfig>[]);

    expect(devices, hasLength(1));
    expect(devices.single.id, DeviceInventoryIds.localDevice);
    expect(devices.single.name, 'This device');
    expect(devices.single.isLocalReachable, isTrue);
  });

  test('does not add this device on non-desktop platforms', () {
    AppPlatform.overrideIsDesktop = false;
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final merger = createMerger(localSocket: localSocket);

    final devices = merger.merge(const <DeviceConfig>[]);

    expect(devices, isEmpty);
  });

  test('keeps local identity and uses cloud display data when cloud matches local hardware', () {
    AppPlatform.overrideIsDesktop = true;
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final merger = createMerger(localSocket: localSocket);
    final cloudDevice = DeviceConfig(
      id: 'cloud-device',
      name: 'Sanad Agent (Macos)',
      hardwareId: 'device-1',
      isOnline: false,
    );

    final devices = merger.merge([cloudDevice]);

    expect(devices, hasLength(1));
    expect(devices.single.id, DeviceInventoryIds.localDevice);
    expect(devices.single.name, 'Sanad Agent (Macos)');
    expect(devices.single.isLocalReachable, isTrue);
    expect(devices.single.isOnline, isTrue);
    expect(devices.single.metadata?['cloud_device_id'], 'cloud-device');
  });

  test('pins the local device first then orders cloud inventory oldest to newest', () {
    AppPlatform.overrideIsDesktop = true;
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final merger = createMerger(localSocket: localSocket);

    final devices = merger.merge([
      DeviceConfig(
        id: 'newest',
        name: 'Newest',
        hardwareId: 'device-3',
        createdAt: DateTime.utc(2026, 3, 3),
      ),
      DeviceConfig(
        id: 'current-cloud',
        name: 'Current',
        hardwareId: 'device-1',
        createdAt: DateTime.utc(2026, 2, 2),
      ),
      DeviceConfig(
        id: 'oldest',
        name: 'Oldest',
        hardwareId: 'device-2',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    ]);

    expect(devices.map((device) => device.id), [DeviceInventoryIds.localDevice, 'oldest', 'newest']);
    expect(devices.first.cloudDeviceId, 'current-cloud');
  });

  test('keeps local identity while the matching local daemon restarts', () {
    AppPlatform.overrideIsDesktop = true;
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(false);
    final merger = createMerger(localSocket: localSocket);
    final cloudDevice = DeviceConfig(
      id: 'cloud-device',
      name: 'Sanad Agent (Macos)',
      hardwareId: 'device-1',
      isOnline: true,
    );

    final devices = merger.merge([cloudDevice]);

    expect(devices, hasLength(1));
    expect(devices.single.id, DeviceInventoryIds.localDevice);
    expect(devices.single.metadata?['cloud_device_id'], 'cloud-device');
    expect(devices.single.isLocalReachable, isFalse);
    expect(devices.single.isOnline, isTrue);
  });
}
