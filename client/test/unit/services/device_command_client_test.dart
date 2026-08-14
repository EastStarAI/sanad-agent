import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService local;
  late FakeSanadSocketService cloud;
  late DeviceConnectionCoordinator coordinator;
  late DeviceCommandClient client;

  setUp(() {
    local = FakeSanadSocketService()..setConnected(true);
    cloud = FakeSanadSocketService()..setConnected(true);
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloud,
      localSocketService: local,
      currentDeviceId: 'this-hardware',
    );
    client = DeviceCommandClient(connectionCoordinator: coordinator);
  });

  tearDown(() {
    coordinator.dispose();
    local.dispose();
    cloud.dispose();
  });

  test('routes the same protocol command to local or cloud for the target device', () async {
    final localDevice = DeviceConfig(
      id: 'local-device',
      name: 'This device',
      hardwareId: 'this-hardware',
      isOnline: true,
    );
    final cloudDevice = DeviceConfig(
      id: 'cloud-device',
      name: 'Other device',
      hardwareId: 'other-hardware',
      isOnline: true,
    );

    final localFuture = client.request(
      device: localDevice,
      command: 'device.settings.get',
      expectedEvent: 'device.settings.snapshot',
    );
    await Future<void>.delayed(Duration.zero);
    final localPayload = local.capturedCommands.single['payload'] as Map<String, dynamic>;
    local.debugEmitEvent({
      'event': 'device.settings.snapshot',
      'payload': {'request_id': localPayload['request_id'], 'route': 'local'},
    });
    expect((await localFuture)['route'], 'local');
    expect(local.capturedCommands.single['device_id'], localDevice.id);

    final cloudFuture = client.request(
      device: cloudDevice,
      command: 'device.settings.get',
      expectedEvent: 'device.settings.snapshot',
    );
    await Future<void>.delayed(Duration.zero);
    final cloudCommand = cloud.capturedCommands.singleWhere(
      (entry) => entry['command'] == 'device.settings.get',
    );
    final cloudPayload = cloudCommand['payload'] as Map<String, dynamic>;
    cloud.debugEmitEvent({
      'event': 'device.settings.snapshot',
      'payload': {'request_id': cloudPayload['request_id'], 'route': 'cloud'},
    });
    expect((await cloudFuture)['route'], 'cloud');
    expect(cloudCommand['device_id'], cloudDevice.id);
  });
}
