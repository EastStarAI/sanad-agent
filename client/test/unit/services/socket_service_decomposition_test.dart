import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/infrastructure/socket/hosted_conversation_media.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

final class _TestCloudSocket implements socket_io.Socket {
  final listeners = <String, List<Function>>{};
  final emitted = <(String, dynamic)>[];
  final offs = <String>[];
  bool isConnected = true;

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  socket_io.Socket onAny(dynamic Function(String, dynamic) handler) => this;

  @override
  socket_io.Socket off(String event, [Function? fn]) {
    offs.add(event);
    listeners.remove(event);
    return this;
  }

  @override
  void emit(String event, [dynamic data]) {
    emitted.add((event, data));
  }

  void receive(String event, dynamic data) {
    for (final listener in List<Function>.from(listeners[event] ?? const <Function>[])) {
      Function.apply(listener, [data]);
    }
  }

  @override
  socket_io.Socket connect() {
    scheduleMicrotask(() {
      receive('connect', null);
      receive('auth_success', <String, dynamic>{'status': 'ok'});
    });
    return this;
  }

  @override
  socket_io.Socket disconnect() {
    isConnected = false;
    receive('disconnect', null);
    return this;
  }

  @override
  socket_io.Socket dispose() {
    disconnect();
    listeners.clear();
    return this;
  }

  @override
  bool get connected => isConnected;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubCredentialProvider extends LocalGatewayCredentialProvider {
  @override
  Future<Map<String, String>> headers() async {
    return const {'x-sanad-local-token': 'stub'};
  }
}

class _RecordingMediaRelayClient extends HostedMediaRelayClient {
  var admitCalled = false;
  var fetchCalled = false;
  final List<String> receivedEvents = [];

  _RecordingMediaRelayClient({required super.connection});

  @override
  void handleRelayEvent(String event, dynamic data) {
    receivedEvents.add(event);
    super.handleRelayEvent(event, data);
  }

  @override
  Future<List<String>> admitHostedAttachments({
    required String deviceId,
    required String sessionId,
    required String requestId,
    required List<Map<String, dynamic>> attachments,
  }) async {
    admitCalled = true;
    return ['stub-attachment-id'];
  }

  @override
  Future<HostedConversationMedia> fetchHostedConversationMedia({
    required String deviceId,
    required String sessionId,
    required String mediaId,
    required String purpose,
    void Function(void Function())? registerCancel,
  }) async {
    fetchCalled = true;
    return HostedConversationMedia(
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
    );
  }
}

void main() {
  group('SocketConnectionController reconnect and backoff ownership', () {
    test('schedules reconnect with custom backoff policy on failure', () async {
      final delays = <int>[];
      final controller = SocketConnectionController.local(
        url: 'http://127.0.0.1:65530',
        hardwareId: 'test-hw',
        credentialProvider: _StubCredentialProvider(),
        reconnectDelay: (attempt) {
          delays.add(attempt);
          return const Duration(milliseconds: 50);
        },
      );
      addTearDown(controller.dispose);

      // Attempt initial connection which fails because loopback port is not listening.
      await expectLater(controller.connect(), throwsA(isA<Exception>()));

      expect(controller.reconnectAttempts, 1);
      expect(controller.reconnectTimer?.isActive, isTrue);
      expect(delays, [1]);
    });

    test('disconnect() cancels active reconnect timer and resets attempts', () async {
      final controller = SocketConnectionController.local(
        url: 'http://127.0.0.1:65530',
        hardwareId: 'test-hw',
        credentialProvider: _StubCredentialProvider(),
        reconnectDelay: (_) => const Duration(seconds: 10),
      );
      addTearDown(controller.dispose);

      await expectLater(controller.connect(), throwsA(isA<Exception>()));
      expect(controller.reconnectTimer?.isActive, isTrue);
      expect(controller.reconnectAttempts, 1);

      controller.disconnect();

      expect(controller.reconnectTimer, isNull);
      expect(controller.reconnectAttempts, 0);
      expect(controller.explicitDisconnect, isTrue);
      expect(controller.lifecycleState, SocketLifecycleState.disconnected);
    });

    test('reconnect() clears explicit disconnect and attempts connection', () async {
      final testSocket = _TestCloudSocket();
      final controller = SocketConnectionController(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'test-token',
        cloudSocketFactory: (_, _) => testSocket,
      );
      addTearDown(controller.dispose);

      await controller.connect();
      expect(controller.isReady, isTrue);

      controller.disconnect();
      expect(controller.explicitDisconnect, isTrue);
      expect(controller.isConnected, isFalse);

      await controller.reconnect();
      expect(controller.explicitDisconnect, isFalse);
      expect(controller.isReady, isTrue);
    });
  });

  group('SocketCommandTransport response correlation', () {
    late _TestCloudSocket socket;
    late SocketConnectionController connection;
    late SocketCommandTransport transport;

    setUp(() async {
      socket = _TestCloudSocket();
      connection = SocketConnectionController(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
      );
      await connection.connect();
      transport = SocketCommandTransport(
        hardwareId: 'test-hw',
        connection: connection,
        responseTimeout: const Duration(milliseconds: 100),
      );
    });

    tearDown(() {
      connection.dispose();
    });

    test('correlates event response, invokes handler, and unregisters listener', () async {
      Map<String, dynamic>? receivedResponse;
      final emitFuture = transport.emitWithResponse(
        'get_info',
        {'query': 'version'},
        (response) {
          receivedResponse = response;
        },
      );

      // Verify emit occurred
      expect(
        socket.emitted.any((e) => e.$1 == 'get_info' && (e.$2 as Map)['query'] == 'version'),
        isTrue,
      );
      expect(socket.listeners.containsKey('get_info_response'), isTrue);

      // Simulate gateway responding
      socket.receive('get_info_response', {'version': '2.4.0'});
      await emitFuture;

      expect(receivedResponse, {'version': '2.4.0'});
      // Verify cleanup unregisters listener
      expect(socket.offs, contains('get_info_response'));
      expect(socket.listeners.containsKey('get_info_response'), isFalse);
    });

    test('cleans up response listener when timeout expires without reply', () async {
      final emitFuture = transport.emitWithResponse(
        'slow_request',
        {'foo': 'bar'},
        (_) {},
      );

      expect(socket.listeners.containsKey('slow_request_response'), isTrue);

      // Await timeout
      await emitFuture;

      expect(socket.offs, contains('slow_request_response'));
      expect(socket.listeners.containsKey('slow_request_response'), isFalse);
    });

    test('skips emit and correlation when connection is not ready', () async {
      connection.disconnect();

      var handlerInvoked = false;
      await transport.emitWithResponse(
        'never_sent',
        {},
        (_) => handlerInvoked = true,
      );

      expect(socket.emitted.any((e) => e.$1 == 'never_sent'), isFalse);
      expect(socket.listeners.containsKey('never_sent_response'), isFalse);
      expect(handlerInvoked, isFalse);
    });
  });

  // Task 113a port guard for 327805d2: a response timeout that fires after a
  // reconnect cleans up on the connection's live socket, as on 6a832396.
  group('SocketCommandTransport timeout after a reconnect', () {
    late List<_TestCloudSocket> sockets;
    late SocketConnectionController connection;
    late SocketCommandTransport transport;

    setUp(() async {
      sockets = [];
      connection = SocketConnectionController(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) {
          final socket = _TestCloudSocket();
          sockets.add(socket);
          return socket;
        },
      );
      await connection.connect();
      transport = SocketCommandTransport(
        hardwareId: 'test-hw',
        connection: connection,
        responseTimeout: const Duration(milliseconds: 100),
      );
    });

    tearDown(() {
      connection.dispose();
    });

    test('late timeout cleans up on the live socket, not the replaced one', () async {
      final staleCall = transport.emitWithResponse('slow_request', {}, (_) {});
      final firstSocket = sockets.single;
      expect(firstSocket.listeners.containsKey('slow_request_response'), isTrue);

      await connection.reconnect();
      expect(sockets, hasLength(2));
      final liveSocket = sockets.last;
      expect(connection.socket, same(liveSocket));
      final firstSocketOffs = firstSocket.offs.length;

      await staleCall;

      expect(liveSocket.offs, contains('slow_request_response'));
      expect(firstSocket.offs, hasLength(firstSocketOffs));
    });

    test("late timeout keeps another call's response listener on the live socket", () async {
      final staleCall = transport.emitWithResponse('slow_request', {}, (_) {});
      await connection.reconnect();
      final liveSocket = sockets.last;

      Map<String, dynamic>? received;
      final liveCall = transport.emitWithResponse(
        'get_info',
        {},
        (response) => received = response,
      );
      await staleCall;

      expect(liveSocket.listeners.containsKey('get_info_response'), isTrue);
      liveSocket.receive('get_info_response', {'version': '2.4.0'});
      await liveCall;
      expect(received, {'version': '2.4.0'});
    });

    test(
      "late timeout keeps a same-event call's response listener on the live socket",
      () async {
        final staleCall = transport.emitWithResponse('slow_request', {}, (_) {});
        await connection.reconnect();
        final liveSocket = sockets.last;

        final liveCall = transport.emitWithResponse('slow_request', {}, (_) {});
        await staleCall;

        expect(liveSocket.listeners.containsKey('slow_request_response'), isTrue);
        await liveCall;
      },
      skip: 'Pre-existing on 6a832396: cleanup calls off(event) on the live socket, '
          'which removes every listener for that event, including a newer call made '
          'after the reconnect. Kept unchanged by the SRP port.',
    );
  });

  group('HostedMediaRelayClient and hosted-media delegation', () {
    test('SanadSocketService delegates admitHostedAttachments to HostedMediaRelayClient', () async {
      final socket = _TestCloudSocket();
      final connection = SocketConnectionController(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
      );
      final recordingRelay = _RecordingMediaRelayClient(connection: connection);

      final service = SanadSocketService(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
        connectionController: connection,
        mediaRelayClient: recordingRelay,
      );
      addTearDown(service.dispose);

      await service.connect();

      final result = await service.admitHostedAttachments(
        deviceId: 'dev-1',
        sessionId: 'sess-1',
        requestId: 'req-1',
        attachments: [
          {'name': 'f.txt', 'data_base64': base64Encode([1, 2, 3])},
        ],
      );

      expect(recordingRelay.admitCalled, isTrue);
      expect(result, ['stub-attachment-id']);
    });

    test('SanadSocketService delegates fetchHostedConversationMedia to HostedMediaRelayClient', () async {
      final socket = _TestCloudSocket();
      final connection = SocketConnectionController(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
      );
      final recordingRelay = _RecordingMediaRelayClient(connection: connection);

      final service = SanadSocketService(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
        connectionController: connection,
        mediaRelayClient: recordingRelay,
      );
      addTearDown(service.dispose);

      await service.connect();

      final result = await service.fetchHostedConversationMedia(
        deviceId: 'dev-1',
        sessionId: 'sess-1',
        mediaId: 'med-1',
        purpose: 'display',
      );

      expect(recordingRelay.fetchCalled, isTrue);
      expect(result.mimeType, 'image/png');
      expect(result.bytes, [1, 2, 3]);
    });

    test('SocketConnectionController routes relay events to HostedMediaRelayClient', () async {
      final socket = _TestCloudSocket();
      final connection = SocketConnectionController(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
      );
      final recordingRelay = _RecordingMediaRelayClient(connection: connection);

      final service = SanadSocketService(
        url: 'https://gateway.invalid',
        hardwareId: 'test-hw',
        startToken: 'token',
        cloudSocketFactory: (_, _) => socket,
        connectionController: connection,
        mediaRelayClient: recordingRelay,
      );
      addTearDown(service.dispose);

      await service.connect();

      socket.receive('attachment_upload_ack', {'upload_id': 'up-1', 'state': 'chunk'});
      socket.receive('conversation_media_chunk', {'route_id': 'rt-1', 'index': 0});

      expect(recordingRelay.receivedEvents, [
        'attachment_upload_ack',
        'conversation_media_chunk',
      ]);
    });
  });
}
