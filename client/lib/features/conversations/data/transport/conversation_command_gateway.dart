import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

abstract class ConversationCommandGateway {
  bool get isConnected;
  Stream<Map<String, dynamic>> get events;

  void sendCommand({
    required String command,
    Map<String, dynamic>? payload,
  });

  Future<Map<String, dynamic>?> request({
    required String command,
    required Map<String, dynamic> payload,
    required String requestId,
    Duration timeout = const Duration(seconds: 10),
  });

  void dispose();
}

class SocketConversationCommandGateway implements ConversationCommandGateway {
  final DeviceConfig _config;
  final SanadSocketService _controller;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  late final StreamSubscription<Map<String, dynamic>> _eventSubscription;

  SocketConversationCommandGateway({
    required DeviceConfig config,
    required SanadSocketService controller,
  }) : _config = config,
       _controller = controller {
    _eventSubscription = events.listen(_handleIncomingEvent);
  }

  @override
  bool get isConnected => _controller.isConnected;

  @override
  Stream<Map<String, dynamic>> get events => _controller.eventRouter.forDevices({
    _config.id,
    if (_config.cloudDeviceId case final cloudDeviceId?) cloudDeviceId,
  });

  @override
  void sendCommand({
    required String command,
    Map<String, dynamic>? payload,
  }) {
    if (!_controller.isConnected) return;

    _controller.sendDeviceCommand(
      deviceId: _controller.isLocalTransport
          ? (_config.hardwareId ?? _config.id)
          : (_config.accountDeviceId ?? _config.id),
      command: command,
      payload: payload,
    );
  }

  @override
  Future<Map<String, dynamic>?> request({
    required String command,
    required Map<String, dynamic> payload,
    required String requestId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_controller.isConnected) return null;
    if (_pendingRequests.containsKey(requestId)) {
      throw StateError('Duplicate conversation request id: $requestId');
    }

    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;
    sendCommand(command: command, payload: payload);

    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      _pendingRequests.remove(requestId);
      return null;
    }
  }

  void _handleIncomingEvent(Map<String, dynamic> event) {
    final deviceId = event['device_id'];
    if (deviceId != null && (deviceId is! String || !_config.representsDeviceId(deviceId))) return;

    final payload = event['payload'] as Map<String, dynamic>? ?? {};
    final requestId = event['request_id'] as String? ?? payload['request_id'] as String? ?? payload['id'] as String?;
    if (requestId == null) return;

    final completer = _pendingRequests.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(event);
    }
  }

  @override
  void dispose() {
    unawaited(_eventSubscription.cancel());
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Conversation command gateway disposed.'));
      }
    }
    _pendingRequests.clear();
  }
}
