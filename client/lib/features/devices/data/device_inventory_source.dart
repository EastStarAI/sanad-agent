import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';

class DeviceInventoryIds {
  static const localDevice = 'local-agent';

  const DeviceInventoryIds._();
}

abstract class DeviceInventorySource {
  List<DeviceConfig> snapshot();
}

class LocalDeviceInventorySource implements DeviceInventorySource {
  final DeviceConnectionCoordinator _connectionCoordinator;

  const LocalDeviceInventorySource(this._connectionCoordinator);

  @override
  List<DeviceConfig> snapshot() {
    if (!AppPlatform.isDesktop) return const <DeviceConfig>[];

    final localDevice = DeviceConfig(
      id: DeviceInventoryIds.localDevice,
      name: 'This device',
      hardwareId: _connectionCoordinator.currentDeviceId,
      isOnline: _connectionCoordinator.localSocketService.isConnected,
    );
    return [_connectionCoordinator.decorateAgent(localDevice)];
  }
}

class DeviceInventoryOrdering {
  const DeviceInventoryOrdering._();

  static List<DeviceConfig> oldestFirst(Iterable<DeviceConfig> devices) {
    final ordered = devices.toList()..sort(compare);
    return List.unmodifiable(ordered);
  }

  static int compare(DeviceConfig left, DeviceConfig right) {
    if (left.id == DeviceInventoryIds.localDevice && right.id != DeviceInventoryIds.localDevice) return -1;
    if (left.id != DeviceInventoryIds.localDevice && right.id == DeviceInventoryIds.localDevice) return 1;

    final leftCreatedAt = left.createdAt;
    final rightCreatedAt = right.createdAt;
    if (leftCreatedAt == null && rightCreatedAt != null) return 1;
    if (leftCreatedAt != null && rightCreatedAt == null) return -1;
    final timestampOrder = leftCreatedAt?.compareTo(rightCreatedAt!) ?? 0;
    if (timestampOrder != 0) return timestampOrder;
    return left.id.compareTo(right.id);
  }
}

class DeviceInventoryMerger {
  final DeviceConnectionCoordinator _connectionCoordinator;
  final DeviceInventorySource _localSource;

  const DeviceInventoryMerger({
    required DeviceConnectionCoordinator connectionCoordinator,
    required DeviceInventorySource localSource,
  }) : _connectionCoordinator = connectionCoordinator,
       _localSource = localSource;

  List<DeviceConfig> merge(List<DeviceConfig> cloudDevices) {
    final decoratedCloud = cloudDevices.map(_connectionCoordinator.decorateAgent).toList();
    final localDevices = _localSource.snapshot();
    if (localDevices.isEmpty) {
      return DeviceInventoryOrdering.oldestFirst(decoratedCloud);
    }
    final localDevice = localDevices.first;
    final matchingCloudDevice = _sameHardwareDevice(decoratedCloud);
    if (matchingCloudDevice != null) {
      return DeviceInventoryOrdering.oldestFirst([
        _localDeviceWithCloudDisplay(localDevice, matchingCloudDevice),
        ...decoratedCloud.where((device) => !_isSameHardwareDevice(device)),
      ]);
    }
    return DeviceInventoryOrdering.oldestFirst([...decoratedCloud, ...localDevices]);
  }

  DeviceConfig? _sameHardwareDevice(List<DeviceConfig> devices) {
    return devices.where(_isSameHardwareDevice).firstOrNull;
  }

  bool _isSameHardwareDevice(DeviceConfig device) {
    return device.hardwareId == _connectionCoordinator.currentDeviceId || device.id == DeviceInventoryIds.localDevice;
  }

  DeviceConfig _localDeviceWithCloudDisplay(DeviceConfig localDevice, DeviceConfig cloudDevice) {
    final metadata = <String, dynamic>{
      ...?cloudDevice.metadata,
      ...?localDevice.metadata,
      'cloud_device_id': cloudDevice.id,
      'cloud_device_name': cloudDevice.name,
    };
    return localDevice.copyWith(
      name: cloudDevice.name,
      token: cloudDevice.token,
      sessionId: cloudDevice.sessionId,
      metadata: metadata,
      createdAt: cloudDevice.createdAt,
      updatedAt: cloudDevice.updatedAt,
      isOnline: localDevice.isLocalReachable || cloudDevice.isOnline,
    );
  }
}
