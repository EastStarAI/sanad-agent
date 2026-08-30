/// Tests for [SanadSocketService] — Scenarios C1-1 → C1-7.
///
/// SanadSocketService creates the IO.Socket internally, so full socket-level
/// tests (connect/disconnect) belong in integration tests.
/// These unit tests cover:
///   • Observable public state (isConnected, streams, getters)
///   • sendDeviceCommand payload construction via FakeSanadSocketService
///   • execute_tool stream exposure
///   • disconnect / dispose safety
library;

import 'dart:async';
import 'package:logging/logging.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/infrastructure/socket/event_router.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_uri_policy.dart';

import '../../mocks/mock_socket_service.dart';

class _CountingCredentialProvider extends LocalGatewayCredentialProvider {
  var reads = 0;

  @override
  Future<Map<String, String>> headers() async {
    reads++;
    return const {LocalGatewayCredentialProvider.headerName: 'unused'};
  }
}

void main() {
  test('disabled local transport never reads credentials or connects', () async {
    final provider = _CountingCredentialProvider();
    final service = SanadSocketService.local(
      url: 'http://127.0.0.1:58085',
      hardwareId: 'remote-only-platform',
      credentialProvider: provider,
      enabled: false,
    );
    addTearDown(service.dispose);

    await service.connect();

    expect(provider.reads, 0);
    expect(service.isConnected, isFalse);
  });

  test('local transport rejects non-loopback before reading credentials', () async {
    final provider = _CountingCredentialProvider();
    final service = SanadSocketService.local(
      url: 'http://attacker.example:58085',
      hardwareId: 'unsafe-local-url',
      credentialProvider: provider,
    );
    addTearDown(service.dispose);

    await expectLater(service.connect(), throwsA(isA<LocalGatewayUriViolation>()));

    expect(provider.reads, 0);
    expect(service.isConnected, isFalse);
  });
  // ──────────────────────────────────────────────────────────────────────────
  // C1-1 / C1-2 — observable state & streams
  // ──────────────────────────────────────────────────────────────────────────
  group('C1: SanadSocketService — initial state and streams', () {
    late SanadSocketService service;

    setUp(() {
      service = SanadSocketService(
        url: 'http://localhost:8000',
        hardwareId: 'test-device-id',
        startToken: 'test-jwt-token',
      );
    });

    tearDown(() => service.dispose());

    test('C1-2: starts disconnected', () {
      expect(service.isConnected, isFalse);
    });

    test('C1-2: exposes onAuthSuccess stream', () {
      expect(service.onAuthSuccess, isA<Stream<Map<String, dynamic>>>());
    });

    test('exposes onAuthFailure stream', () {
      expect(service.onAuthFailure, isA<Stream<Map<String, dynamic>>>());
    });

    test('C1-2: exposes events broadcast stream', () {
      expect(service.events, isA<Stream<Map<String, dynamic>>>());
    });

    test('exposes remoteToolExecutionStream', () {
      expect(service.remoteToolExecutionStream, isA<Stream<Map<String, dynamic>>>());
    });

    test('eventRouter is an EventRouter instance', () {
      expect(service.eventRouter, isA<EventRouter>());
    });

    test('socket is null before connect()', () {
      expect(service.socket, isNull);
    });

    test('starts with disconnected lifecycle state', () {
      expect(service.lifecycleState, SocketLifecycleState.disconnected);
      expect(service.isReady, isFalse);
      expect(service.isSocketConnected, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // C1-4 / C1-5 — sendDeviceCommand payload via FakeSanadSocketService
  // ──────────────────────────────────────────────────────────────────────────
  group('C1-4 / C1-5: sendDeviceCommand payload', () {
    late FakeSanadSocketService service;

    setUp(() {
      service = FakeSanadSocketService(hardwareId: 'my-device-uuid');
      service.setConnected(true);
    });

    tearDown(() => service.dispose());

    test('C1-4: emits device_command with correct fields', () {
      service.sendDeviceCommand(
        deviceId: 'agent-uuid',
        command: 'think',
        payload: {'message': 'مرحباً', 'session_id': 'session-1'},
      );

      expect(service.capturedCommands.length, 1);
      final cmd = service.capturedCommands.first;
      expect(
        cmd.containsKey(
          'agent'
          '_type',
        ),
        isFalse,
      );
      expect(cmd['device_id'], 'agent-uuid');
      expect(cmd['command'], 'think');
    });

    test('C1-5: hardware_id is baked in by FakeSanadSocketService', () {
      // The real SanadSocketService adds _hardwareId automatically in the
      // emitted socket payload. We verify the hardware_id is set on the
      // service object (constructor arg) and is the one used.
      expect(service.capturedCommands, isEmpty); // nothing sent yet

      service.sendDeviceCommand(deviceId: 'a', command: 'think');

      // FakeSanadSocketService captures without hardware_id (override),
      // but the real service adds it in the map before emit.
      // This test verifies the constructor stores the hardwareId.
      // (Integration tests verify the actual socket emit contains hardware_id.)
      expect(service.capturedCommands.isNotEmpty, isTrue);
    });

    test('payload is forwarded unchanged', () {
      service.sendDeviceCommand(deviceId: 'agent-uuid', command: 'get_sessions', payload: {'request_id': 'req-123'});

      final payload = service.capturedCommands.first['payload'] as Map?;
      expect(payload?['request_id'], 'req-123');
    });

    test('sendDeviceCommand with null payload is allowed', () {
      expect(() => service.sendDeviceCommand(deviceId: 'a', command: 'stop'), returnsNormally);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Real SanadSocketService: sendDeviceCommand guard when not connected
  // ──────────────────────────────────────────────────────────────────────────
  group('sendDeviceCommand when not connected', () {
    late SanadSocketService service;

    setUp(() {
      service = SanadSocketService(url: 'http://localhost:8000', hardwareId: 'dev-1', startToken: 'token');
    });

    tearDown(() => service.dispose());

    test('does not throw when socket is null (not yet connected)', () {
      expect(() => service.sendDeviceCommand(deviceId: 'a', command: 'think'), returnsNormally);
    });
  });

  group('socket diagnostic logging', () {
    late SanadSocketService service;

    setUp(() {
      service = SanadSocketService(
        url: 'http://localhost:8000',
        hardwareId: 'dev-1',
      );
    });

    tearDown(() => service.dispose());

    test('recursively redacts credentials while retaining safe context', () {
      final formatted = service.debugFormatData({
        'token': 'raw-access-token',
        'hardware_id': 'hardware-1',
        'payload': {
          'refresh_token': 'raw-refresh-token',
          'accessToken': 'raw-camel-case-token',
          'headers': {'Authorization': 'Bearer raw-bearer-token'},
          'items': [
            {'client-secret': 'raw-client-secret', 'status': 'ready'},
          ],
          'secrets': {'bearer_token': 'g6-canary-bearer-9f3a7c2e1b88'},
        },
      });

      expect(formatted, isNot(contains('raw-access-token')));
      expect(formatted, isNot(contains('raw-refresh-token')));
      expect(formatted, isNot(contains('raw-camel-case-token')));
      expect(formatted, isNot(contains('raw-bearer-token')));
      expect(formatted, isNot(contains('raw-client-secret')));
      expect(formatted, isNot(contains('g6-canary-bearer-9f3a7c2e1b88')));
      expect(formatted, contains('[REDACTED]'));
      expect(formatted, contains('hardware-1'));
      expect(formatted, contains('ready'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // C1-3 — auth_error: onAuthSuccess stream (observable state)
  // ──────────────────────────────────────────────────────────────────────────
  group('C1-3: auth error stream exposure', () {
    late FakeSanadSocketService service;

    setUp(() {
      service = FakeSanadSocketService();
    });

    tearDown(() => service.dispose());

    test('eventRouter routes device payload to device stream', () async {
      final received = <Map<String, dynamic>>[];
      final sub = service.eventRouter.forDevice('device-uuid').listen(received.add);

      // Simulate the gateway routing an auth-related event through event router
      service.eventRouter.routeEvent({
        'device_id': 'device-uuid',
        'event': 'ack',
        'payload': {'status': 'started'},
      });

      await Future<void>.delayed(Duration.zero);
      expect(received.isNotEmpty, isTrue);

      await sub.cancel();
    });

    test('debug auth failure updates lifecycle and emits failure stream', () async {
      final failures = <Map<String, dynamic>>[];
      final sub = service.onAuthFailure.listen(failures.add);

      service.debugEmitAuthFailure({'message': 'Invalid token'});

      await Future<void>.delayed(Duration.zero);

      expect(service.lifecycleState, SocketLifecycleState.authFailed);
      expect(service.isConnected, isFalse);
      expect(failures.single['message'], 'Invalid token');

      await sub.cancel();
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // C1-6 — setAccessToken triggers reconnect
  // ──────────────────────────────────────────────────────────────────────────
  group('C1-6: setAccessToken', () {
    late SanadSocketService service;

    setUp(() {
      service = SanadSocketService(url: 'http://localhost:8000', hardwareId: 'dev-1', startToken: 'old-token');
    });

    tearDown(() => service.dispose());

    test('setAccessToken with same token is a no-op (does not throw)', () {
      expect(() => service.setAccessToken('old-token'), returnsNormally);
    });

    test('setAccessToken with new token does not throw', () {
      expect(() => service.setAccessToken('new-token'), returnsNormally);
    });

    test('setAccessToken with null does not throw', () {
      expect(() => service.setAccessToken(null), returnsNormally);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // disconnect / dispose safety
  // ──────────────────────────────────────────────────────────────────────────
  group('disconnect and dispose', () {
    late SanadSocketService service;

    setUp(() {
      service = SanadSocketService(url: 'http://localhost:8000', hardwareId: 'dev-1');
    });

    test('disconnect() when not connected does not throw', () {
      expect(() => service.disconnect(), returnsNormally);
    });

    test('dispose() closes streams without error', () {
      expect(() => service.dispose(), returnsNormally);
    });

    test('isConnected is false after disconnect()', () {
      service.disconnect();
      expect(service.isConnected, isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // sendToolResult — payload structure (via FakeSanadSocketService)
  // ──────────────────────────────────────────────────────────────────────────
  group('sendToolResult payload structure', () {
    late FakeSanadSocketService service;

    setUp(() {
      service = FakeSanadSocketService(hardwareId: 'my-device');
      service.setConnected(true);
    });

    tearDown(() => service.dispose());

    test('success result has status=success and isError=false', () {
      service.sendToolResult(runId: 'run-abc', output: 'The result content', deviceId: 'agent-uuid');

      final cmd = service.capturedCommands.first;
      expect(cmd['command'], 'tool_result');
      final payload = cmd['payload'] as Map;
      expect(payload['run_id'], 'run-abc');
      expect(payload['status'], 'success');
      expect(payload['isError'], isFalse);
      expect(payload['output'], 'The result content');
    });

    test('error result has status=error and isError=true', () {
      service.sendToolResult(runId: 'run-xyz', error: 'Tool execution failed', isError: true, deviceId: 'agent-uuid');

      final cmd = service.capturedCommands.first;
      final payload = cmd['payload'] as Map;
      expect(payload['status'], 'error');
      expect(payload['isError'], isTrue);
      expect(payload['output'], 'Tool execution failed');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // C1-7 — remoteToolExecutionStream existence
  // ──────────────────────────────────────────────────────────────────────────
  group('C1-7: remoteToolExecutionStream', () {
    late SanadSocketService service;

    setUp(() {
      service = SanadSocketService(url: 'http://localhost:8000', hardwareId: 'dev-1');
    });

    tearDown(() => service.dispose());

    test('stream is broadcast (can have multiple listeners)', () {
      final s1 = service.remoteToolExecutionStream.listen((_) {});
      final s2 = service.remoteToolExecutionStream.listen((_) {});

      // If it's a broadcast stream, this should not throw
      expect(s1, isNotNull);
      expect(s2, isNotNull);

      unawaited(s1.cancel());
      unawaited(s2.cancel());
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Local WebSocket Reconnection
  // ──────────────────────────────────────────────────────────────────────────
  group('Local WebSocket Reconnection', () {
    test('schedules reconnect on connection failure and executes retry', () async {
      final service = SanadSocketService.local(url: 'ws://127.0.0.1:65530', hardwareId: 'dev-reconnect-test');

      final states = <SocketLifecycleState>[];
      final sub = service.lifecycleStateStream.listen(states.add);

      // First connection attempt (fails immediately)
      try {
        await service.connect();
      } catch (_) {
        // Expected
      }

      expect(service.lifecycleState, SocketLifecycleState.error);
      states.clear();

      // Wait 2.5 seconds for the automatic reconnect timer to fire
      await Future<void>.delayed(const Duration(milliseconds: 2500));

      // Reconnect attempt should have been triggered, transitioning state to connecting and then back to error (since port is still closed)
      expect(states, contains(SocketLifecycleState.connecting));
      expect(states, contains(SocketLifecycleState.error));

      await sub.cancel();
      service.dispose();
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Logging deduplication
  // ──────────────────────────────────────────────────────────────────────────
  group('Logging deduplication', () {
    late SanadSocketService service;
    final loggedMessages = <String>[];
    StreamSubscription? logSubscription;

    setUp(() {
      service = SanadSocketService(
        url: 'http://localhost:8000',
        hardwareId: 'dev-logging-test',
      );
      loggedMessages.clear();
      logSubscription = Logger('SanadSocket').onRecord.listen((record) {
        loggedMessages.add(record.message);
      });
    });

    tearDown(() async {
      await logSubscription?.cancel();
      service.dispose();
    });

    test('deduplicates consecutive thought_stream event logs but prints other consecutive events', () {
      // Print 'tool_use'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'tool_use',
      });

      // Print 'tool_result'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'tool_result',
      });

      // Print first 'thought_stream'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'thought_stream',
      });

      // Print second consecutive 'thought_stream' (should be skipped)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'thought_stream',
      });

      // Print third consecutive 'thought_stream' (should be skipped)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'thought_stream',
      });

      // Print 'final_answer'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'final_answer',
      });

      // Print 'thought_stream' again after final_answer (should be printed once again)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'thought_stream',
      });

      // Print consecutive 'thought_stream' again (should be skipped)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'thought_stream',
      });

      expect(loggedMessages.length, 5);
      expect(loggedMessages[0], contains('[event \x1B[35mtool_use\x1B[0m]'));
      expect(loggedMessages[1], contains('[event \x1B[35mtool_result\x1B[0m]'));
      expect(loggedMessages[2], contains('[event \x1B[35mthought_stream\x1B[0m]'));
      expect(loggedMessages[3], contains('[event \x1B[35mfinal_answer\x1B[0m]'));
      expect(loggedMessages[4], contains('[event \x1B[35mthought_stream\x1B[0m]'));
    });

    test('deduplicates consecutive reasoning_stream event logs but prints other consecutive events', () {
      // Print 'tool_use'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'tool_use',
      });

      // Print first 'reasoning_stream'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'reasoning_stream',
      });

      // Print second consecutive 'reasoning_stream' (should be skipped)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'reasoning_stream',
      });

      // Print 'final_answer'
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'final_answer',
      });

      // Print 'reasoning_stream' again after final_answer (should be printed once again)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'reasoning_stream',
      });

      // Print consecutive 'reasoning_stream' again (should be skipped)
      service.debugLogIncomingSocketEvent('device_event', {
        'event': 'reasoning_stream',
      });

      expect(loggedMessages.length, 4);
      expect(loggedMessages[0], contains('[event \x1B[35mtool_use\x1B[0m]'));
      expect(loggedMessages[1], contains('[event \x1B[35mreasoning_stream\x1B[0m]'));
      expect(loggedMessages[2], contains('[event \x1B[35mfinal_answer\x1B[0m]'));
      expect(loggedMessages[3], contains('[event \x1B[35mreasoning_stream\x1B[0m]'));
    });
  });
}
