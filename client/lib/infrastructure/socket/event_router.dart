import 'dart:async';

/// Routes incoming events to device-scoped streams.
class EventRouter {
  final Map<String, StreamController<Map<String, dynamic>>> _deviceStreams = {};

  /// Get or create a stream for a specific backend device.
  Stream<Map<String, dynamic>> forDevice(String deviceId) {
    _deviceStreams.putIfAbsent(deviceId, () => StreamController<Map<String, dynamic>>.broadcast());
    return _deviceStreams[deviceId]!.stream;
  }

  /// Merge the streams for a bounded set of server-owned device aliases.
  Stream<Map<String, dynamic>> forDevices(Iterable<String> deviceIds) {
    final normalizedIds = deviceIds.where((id) => id.isNotEmpty).toSet();
    if (normalizedIds.length == 1) return forDevice(normalizedIds.single);

    return Stream<Map<String, dynamic>>.multi((controller) {
      final subscriptions = normalizedIds
          .map(
            (deviceId) => forDevice(deviceId).listen(
              controller.add,
              onError: controller.addError,
            ),
          )
          .toList(growable: false);
      controller.onCancel = () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      };
    }, isBroadcast: true);
  }

  /// Route an event to its device stream. Events without device_id are ignored.
  void routeEvent(Map<String, dynamic> event) {
    final deviceId = event['device_id'] as String?;
    if (deviceId != null && deviceId.isNotEmpty) {
      _deviceStreams.putIfAbsent(deviceId, () => StreamController<Map<String, dynamic>>.broadcast());
      _deviceStreams[deviceId]!.add(event);
    }
  }

  void dispose() {
    for (final controller in _deviceStreams.values) {
      unawaited(controller.close());
    }
    _deviceStreams.clear();
  }
}
