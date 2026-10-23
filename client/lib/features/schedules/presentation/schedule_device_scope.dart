import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

/// Resolves the device a Schedules route names (Task 139 C1).
///
/// The route carries a `deviceId`; the transport-bearing [DeviceConfig] lives in
/// the device inventory, so the cubit resolves it at call time instead of owning
/// a device copy. A route device that is not in the inventory resolves to
/// `null`, which the cubit treats as "unavailable": no request is issued for a
/// device this Client cannot address (S18).
abstract final class ScheduleDeviceScope {
  /// The inventory row for [deviceId], or `null` when it is not known.
  static DeviceConfig? resolve(String deviceId) {
    if (deviceId.isEmpty) return null;
    final repository = getIt<IDeviceRepository>();
    final active = repository.getActiveAgent();
    if (active != null && active.representsDeviceId(deviceId)) return active;
    for (final device in repository.agents) {
      if (device.representsDeviceId(deviceId)) return device;
    }
    return null;
  }
}
