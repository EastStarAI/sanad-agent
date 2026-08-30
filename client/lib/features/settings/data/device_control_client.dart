import 'dart:async';

import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

class DeviceUpdateCheckSnapshot {
  const DeviceUpdateCheckSnapshot({
    required this.status,
    required this.currentVersion,
    this.availableVersion,
    this.message,
    this.confirmationToken,
    this.manifestRevision,
    this.manifestFingerprint,
  });

  final String status;
  final String currentVersion;
  final String? availableVersion;
  final String? message;
  final String? confirmationToken;
  final String? manifestRevision;
  final String? manifestFingerprint;

  bool get updateAvailable => status == 'update_available';
  bool get sourceManaged => status == 'source_managed';
  bool get upToDate => status == 'up_to_date';

  factory DeviceUpdateCheckSnapshot.fromJson(Map<String, dynamic> json) {
    return DeviceUpdateCheckSnapshot(
      status: json['status']?.toString() ?? 'failed',
      currentVersion: json['current_version']?.toString() ?? '',
      availableVersion: json['available_version']?.toString(),
      message: json['message']?.toString(),
      confirmationToken: json['confirmation_token']?.toString(),
      manifestRevision: json['manifest_revision']?.toString(),
      manifestFingerprint: json['manifest_fingerprint']?.toString(),
    );
  }
}

/// Typed remote update/restart commands for one target device.
///
/// Presentation must not branch on local versus cloud transport, and must not
/// call [LocalDaemonController] for these Overview actions.
class DeviceControlClient {
  DeviceControlClient(this._commands);

  final DeviceCommandClient _commands;

  Future<DeviceUpdateCheckSnapshot> checkForUpdates(DeviceConfig device) async {
    final payload = await _commands.request(
      device: device,
      command: 'device.update.check',
      expectedEvent: 'device.update.check.result',
      timeout: const Duration(seconds: 30),
    );
    return DeviceUpdateCheckSnapshot.fromJson(payload);
  }

  Future<Map<String, dynamic>> applyUpdate(
    DeviceConfig device, {
    required DeviceUpdateCheckSnapshot check,
  }) async {
    final token = check.confirmationToken?.trim() ?? '';
    final target = check.availableVersion?.trim() ?? '';
    final revision = check.manifestRevision?.trim() ?? '';
    final fingerprint = check.manifestFingerprint?.trim() ?? '';
    if (token.isEmpty || target.isEmpty || revision.isEmpty || fingerprint.isEmpty) {
      throw StateError('Check for updates before applying an agent update.');
    }
    return _commands.request(
      device: device,
      command: 'device.update.apply',
      expectedEvent: 'device.update.apply.accepted',
      acceptedEvents: const {
        'device.update.apply.accepted',
        'device.update.result',
      },
      timeout: const Duration(minutes: 5),
      payload: {
        'target_version': target,
        'manifest_revision': revision,
        'manifest_fingerprint': fingerprint,
        'confirmation_token': token,
      },
    );
  }

  Future<Map<String, dynamic>> restartAgent(
    DeviceConfig device, {
    bool force = false,
  }) {
    return _commands.request(
      device: device,
      command: 'device.runtime.restart',
      expectedEvent: 'device.runtime.restart.accepted',
      timeout: const Duration(seconds: 90),
      payload: {if (force) 'force': true},
    );
  }

  Future<DeviceConfig> waitForReconnect({
    required IDeviceRepository inventory,
    required String deviceId,
    String? expectedVersion,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    var sawOffline = false;
    final current = _match(inventory.agents, deviceId);
    if (current == null || !current.isOnline) sawOffline = true;

    final completer = Completer<DeviceConfig>();
    late final StreamSubscription<List<DeviceConfig>> subscription;
    subscription = inventory.onAgentsUpdate.listen((agents) {
      final device = _match(agents, deviceId);
      if (device == null) return;
      if (!device.isOnline) {
        sawOffline = true;
        return;
      }
      if (!sawOffline) return;
      if (expectedVersion != null &&
          expectedVersion.isNotEmpty &&
          device.metadata?['version']?.toString() != expectedVersion) {
        return;
      }
      if (!completer.isCompleted) completer.complete(device);
    });

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw StateError(
        expectedVersion == null
            ? 'Timed out waiting for the device to come back online.'
            : 'Timed out waiting for version $expectedVersion to come online.',
      );
    } finally {
      await subscription.cancel();
    }
  }

  DeviceConfig? _match(List<DeviceConfig> agents, String deviceId) {
    for (final agent in agents) {
      if (agent.representsDeviceId(deviceId)) return agent;
    }
    return null;
  }
}
