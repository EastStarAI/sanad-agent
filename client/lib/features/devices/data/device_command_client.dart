import 'dart:async';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:uuid/uuid.dart';

/// Correlated Sanad protocol request/response client for one target device.
/// Transport resolution stays entirely inside [DeviceConnectionCoordinator].
class DeviceCommandClient {
  DeviceCommandClient({
    required DeviceConnectionCoordinator connectionCoordinator,
    Uuid uuid = const Uuid(),
  }) : _connectionCoordinator = connectionCoordinator,
       _uuid = uuid;

  final DeviceConnectionCoordinator _connectionCoordinator;
  final Uuid _uuid;

  Future<Map<String, dynamic>> request({
    required DeviceConfig device,
    required String command,
    required String expectedEvent,
    Set<String>? acceptedEvents,
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 10),
    bool Function(Map<String, dynamic> payload)? payloadMatches,
  }) async {
    final endpoint = await _connectionCoordinator.ensureConnectedEndpointForAgent(device);
    if (!endpoint.socketService.isConnected) {
      throw StateError('Device ${device.name} is not connected.');
    }

    final requestId = 'req_${_uuid.v4()}';
    final completer = Completer<Map<String, dynamic>>();
    late final StreamSubscription<Map<String, dynamic>> subscription;
    subscription = endpoint.socketService.events.listen((event) {
      final responsePayload = Map<String, dynamic>.from(
        event['payload'] as Map? ?? const {},
      );
      final responseRequestId =
          event['request_id']?.toString() ??
          responsePayload['request_id']?.toString() ??
          responsePayload['id']?.toString();
      if (responseRequestId != requestId) return;

      final eventName = event['event']?.toString();
      if (eventName == 'error') {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError(
              responsePayload['message']?.toString() ?? 'Device command failed.',
            ),
          );
        }
        return;
      }
      if ((eventName != expectedEvent && !(acceptedEvents ?? const <String>{}).contains(eventName)) ||
          (payloadMatches != null && !payloadMatches(responsePayload))) {
        return;
      }
      if (!completer.isCompleted) completer.complete(responsePayload);
    });

    endpoint.socketService.sendDeviceCommand(
      deviceId: endpoint.protocolDeviceId,
      command: command,
      payload: {'request_id': requestId, ...payload},
    );

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw StateError('Timed out waiting for $command on ${device.name}.');
    } finally {
      unawaited(subscription.cancel());
    }
  }
}
