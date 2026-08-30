/// Manual fake implementation of [SanadSocketService] for unit tests.
///
/// Instead of using build_runner / @GenerateMocks, this file provides a
/// hand-written [FakeSanadSocketService] that:
///   - Inherits the real [EventRouter] so event routing works in tests.
///   - Captures every [sendDeviceCommand] / [sendToolResult] call.
///   - Exposes [setConnected] to control the [isConnected] state.
///
/// Usage:
/// ```dart
/// final service = FakeSanadSocketService();
/// service.setConnected(true);
/// service.eventRouter.routeEvent({...}); // simulate incoming socket event
/// expect(service.capturedCommands.last['command'], 'think');
/// ```
library;

import 'dart:async';

import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

class FakeSanadSocketService extends SanadSocketService {
  final List<Map<String, dynamic>> _capturedCommands = [];
  final StreamController<bool> _fakeConnectionStatusController = StreamController<bool>.broadcast();
  final StreamController<SocketLifecycleState> _fakeLifecycleController =
      StreamController<SocketLifecycleState>.broadcast();

  /// All calls to [sendDeviceCommand] and [sendToolResult] recorded here.
  List<Map<String, dynamic>> get capturedCommands => List.unmodifiable(_capturedCommands);

  bool _fakeReady = false;
  SocketLifecycleState _fakeLifecycleState = SocketLifecycleState.disconnected;
  Map<String, dynamic>? autoCapabilitiesPayload = const <String, dynamic>{};

  FakeSanadSocketService({String hardwareId = 'test-device-id'})
    : super(url: 'http://localhost:8000', hardwareId: hardwareId);

  /// Manually switch the connected state and notify listeners.
  void setConnected(bool value) {
    _fakeReady = value;
    _fakeLifecycleState = value ? SocketLifecycleState.ready : SocketLifecycleState.disconnected;
    _fakeConnectionStatusController.add(value);
    _fakeLifecycleController.add(_fakeLifecycleState);
  }

  void setLifecycleState(SocketLifecycleState value) {
    _fakeLifecycleState = value;
    _fakeReady = value == SocketLifecycleState.ready;
    _fakeConnectionStatusController.add(_fakeReady);
    _fakeLifecycleController.add(value);
  }

  @override
  void debugEmitAuthFailure(Map<String, dynamic> payload) {
    setLifecycleState(SocketLifecycleState.authFailed);
    super.debugEmitAuthFailure(payload);
  }

  @override
  bool get isConnected => _fakeReady;

  @override
  SocketLifecycleState get lifecycleState => _fakeLifecycleState;

  @override
  Stream<SocketLifecycleState> get lifecycleStateStream => _fakeLifecycleController.stream;

  @override
  Stream<bool> get connectionStatusStream => _fakeConnectionStatusController.stream;

  /// Captures the call; does NOT actually emit to a socket.
  @override
  void sendDeviceCommand({
    required String deviceId,
    required String command,
    Map<String, dynamic>? payload,
  }) {
    _capturedCommands.add({
      'device_id': deviceId,
      'command': command,
      'payload': payload,
    });
  }

  /// Captures the call; does NOT actually emit to a socket.
  @override
  void sendToolResult({
    required String runId,
    String? output,
    String? error,
    bool isError = false,
    String? deviceId,
  }) {
    _capturedCommands.add({
      'device_id': deviceId ?? '',
      'command': 'tool_result',
      'payload': {
        'run_id': runId,
        'status': isError ? 'error' : 'success',
        'output': isError ? (error ?? output ?? 'Tool execution failed') : (output ?? ''),
        'isError': isError,
        'hardware_id': hardwareId,
      },
    });
  }

  @override
  void emit(String event, dynamic data) {
    _capturedCommands.add({
      'event': event,
      'data': data,
    });

    if (event == 'get_capabilities' && data is Map<String, dynamic>) {
      unawaited(
        Future<void>.microtask(() {
          debugEmitEvent({
            'type': 'capabilities',
            if (data['device_id'] != null) 'device_id': data['device_id'],
            if (data['request_id'] != null) 'request_id': data['request_id'],
            'payload': autoCapabilitiesPayload,
          });
        }),
      );
    }
  }

  void clearCaptured() => _capturedCommands.clear();

  @override
  void dispose() {
    unawaited(_fakeLifecycleController.close());
    unawaited(_fakeConnectionStatusController.close());
    super.dispose();
  }
}
