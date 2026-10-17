import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

import 'package:sanad_client/core/interfaces/socket_gateway.dart';
import 'package:sanad_client/infrastructure/socket/socket_connection_controller.dart';

/// Owns outgoing command dispatch (`emit`, `sendDeviceCommand`, `sendToolResult`)
/// and `emitWithResponse` response correlation.
class SocketCommandTransport implements ISocketGateway {
  static final _logger = Logger('SanadSocket');

  final String _hardwareId;
  final SocketConnectionController _connection;
  final Duration _responseTimeout;

  SocketCommandTransport({
    required String hardwareId,
    required SocketConnectionController connection,
    Duration responseTimeout = const Duration(seconds: 10),
  }) : _hardwareId = hardwareId,
       _connection = connection,
       _responseTimeout = responseTimeout;

  String get hardwareId => _hardwareId;
  SocketConnectionController get connection => _connection;

  void emit(String event, dynamic data) {
    if (!_connection.isConnected) {
      _logger.severe(
        '[${_connection.hashCode}]: ❌ Cannot emit $event, socket is not ready',
      );
      return;
    }
    _connection.logOutgoingSocketEvent(event, data);
    if (_connection.isLocalTransport) {
      final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{'payload': data};
      _connection.localSocket?.add(jsonEncode({'type': event, ...payload}));
      return;
    }
    _connection.socket!.emit(event, data);
  }

  @override
  void sendDeviceCommand({
    required String deviceId,
    required String command,
    Map<String, dynamic>? payload,
  }) {
    if (!_connection.isConnected) {
      _logger.severe(
        '[${_connection.hashCode}]: ❌ Cannot send command, socket is not ready.',
      );
      return;
    }

    final data = {
      'device_id': deviceId,
      'hardware_id': _hardwareId,
      'command': command,
      if (payload != null) 'payload': payload,
    };

    _connection.logOutgoingSocketEvent('device_command', data);

    try {
      if (_connection.isLocalTransport) {
        _connection.localSocket?.add(jsonEncode({'type': 'execute_command', ...data}));
      } else {
        _connection.socket!.emit('device_command', data);
      }
    } catch (_) {
      _logger.severe('[${_connection.hashCode}]: ❌ Error emitting device command');
    }
  }

  @override
  void sendToolResult({
    required String runId,
    String? output,
    String? error,
    bool isError = false,
    String? deviceId,
  }) {
    if (!_connection.isConnected) {
      _logger.severe(
        '[${_connection.hashCode}]: ❌ Cannot send tool result, socket is not ready',
      );
      return;
    }

    final payload = {
      'run_id': runId,
      'status': isError ? 'error' : 'success',
      'output': isError ? (error ?? output ?? 'Tool execution failed') : (output ?? ''),
      'isError': isError,
      'hardware_id': _hardwareId,
    };

    final commandData = {
      'device_id': deviceId ?? '',
      'hardware_id': _hardwareId,
      'command': 'tool_result',
      'payload': payload,
    };

    _connection.logOutgoingSocketEvent('device_command', commandData);

    try {
      if (_connection.isLocalTransport) {
        _connection.localSocket?.add(
          jsonEncode({'type': 'execute_command', ...commandData}),
        );
      } else {
        _connection.socket!.emit('device_command', commandData);
      }
    } catch (_) {
      _logger.severe('[${_connection.hashCode}]: ❌ Error sending tool result');
    }
  }

  Future<void> emitWithResponse(
    String event,
    Map<String, dynamic> data,
    void Function(Map<String, dynamic>) handler,
  ) async {
    final socket = _connection.socket;
    if (socket == null || !socket.connected || !_connection.isReady || _connection.isLocalTransport) {
      return;
    }

    final completer = Completer<void>();
    final responseEvent = '${event}_response';

    void cleanup() {
      socket.off(responseEvent);
    }

    socket.on(responseEvent, (response) {
      handler(Map<String, dynamic>.from(response));
      cleanup();
      completer.complete();
    });

    _connection.logOutgoingSocketEvent(event, data);
    socket.emit(event, data);

    try {
      await completer.future.timeout(_responseTimeout);
    } catch (_) {
      cleanup();
    }
  }
}
