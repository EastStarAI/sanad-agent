import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:get_it/get_it.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:test/test.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/infrastructure/voice/voice_transport_channel.dart';

class FakeWebSocket implements WebSocket {
  final controller = StreamController<dynamic>();
  final sent = <dynamic>[];

  @override
  StreamSubscription listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(dynamic data) {
    sent.add(data);
  }

  @override
  Future close([int? code, String? reason]) async {
    await controller.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return null;
  }
}

class FakeSocket implements io.Socket {
  final listeners = <String, List<Function>>{};
  final emitted = <String, dynamic>{};

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  void off(String event, [Function? fn]) {
    listeners.remove(event);
  }

  @override
  void emit(String event, [dynamic data]) {
    emitted[event] = data;
  }

  @override
  bool get connected => true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return null;
  }
}

class FakeServerSanadGatewayPlatform implements ServerSanadGatewayPlatform {
  @override
  final io.Socket socket;
  FakeServerSanadGatewayPlatform(this.socket);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return null;
  }
}

void main() {
  group('LocalWebSocketTransportChannel Tests', () {
    late FakeWebSocket ws;
    late LocalWebSocketTransportChannel channel;

    setUp(() {
      ws = FakeWebSocket();
      channel = LocalWebSocketTransportChannel(ws);
    });

    test('receives binary PCM audio from WebSocket', () async {
      final pcmData = [0, 1, 2, 3];

      expect(channel.inputAudioStream, emits(pcmData));

      ws.controller.add(pcmData);
    });

    test('receives control event JSON from WebSocket', () async {
      final controlJson = '{"event": "interrupt"}';

      expect(channel.controlEvents, emits('interrupt'));

      ws.controller.add(controlJson);
    });

    test('sendOutputAudio adds binary data to WebSocket', () {
      final outputPcm = [4, 5, 6, 7];
      channel.sendOutputAudio(outputPcm);

      expect(ws.sent.length, 1);
      expect(ws.sent.first, outputPcm);
    });

    test('sendControlEvent adds JSON string to WebSocket', () {
      channel.sendControlEvent('voice_text_response', {'text': 'Hello'});

      expect(ws.sent.length, 1);
      final sentStr = ws.sent.first as String;
      final decoded = jsonDecode(sentStr);
      expect(decoded['type'], 'device_event');
      expect(decoded['event'], 'voice_text_response');
      expect(decoded['payload']['text'], 'Hello');
    });
  });

  group('CloudSocketIoTransportChannel Tests', () {
    late FakeSocket socket;
    late CloudSocketIoTransportChannel channel;
    final getIt = GetIt.instance;

    setUp(() {
      socket = FakeSocket();
      final gateway = FakeServerSanadGatewayPlatform(socket);
      getIt.registerSingleton<ServerSanadGatewayPlatform>(gateway);
      channel = CloudSocketIoTransportChannel(
        deviceId: 'device-123',
        sessionId: 'voice-1',
        requestId: 'voice-1',
      );
    });

    tearDown(() {
      getIt.unregister<ServerSanadGatewayPlatform>();
    });

    Map<String, dynamic> relayed(List<int> data) => {
      'session_id': 'voice-1',
      'request_id': 'voice-1',
      'data': data,
    };

    test('receives binary PCM audio for its own identity', () async {
      final pcmData = [10, 11, 12, 13];

      expect(channel.inputAudioStream, emits(pcmData));

      final handler = socket.listeners['voice_audio_chunk_relay']!.first;
      handler(relayed(pcmData));
    });

    test('an identity-less or foreign audio frame is ignored', () async {
      final received = <List<int>>[];
      final subscription = channel.inputAudioStream.listen(received.add);
      addTearDown(subscription.cancel);
      final handler = socket.listeners['voice_audio_chunk_relay']!.first;

      handler({'data': [1, 2, 3, 4]});
      handler({'session_id': 'voice-2', 'request_id': 'voice-2', 'data': [5]});
      handler({'session_id': 'voice-1', 'data': [6]});
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('receives a control event for its own identity', () async {
      expect(channel.controlEvents, emits('interrupt'));

      final handler = socket.listeners['voice_control_relay']!.first;
      handler({
        'session_id': 'voice-1',
        'request_id': 'voice-1',
        'event': 'interrupt',
      });
    });

    test('sendOutputAudio carries device and session identity', () {
      final outputPcm = [14, 15, 16, 17];
      channel.sendOutputAudio(outputPcm);

      expect(socket.emitted.containsKey('device_voice_audio_chunk'), true);
      final payload = socket.emitted['device_voice_audio_chunk'] as Map;
      expect(payload['device_id'], 'device-123');
      expect(payload['session_id'], 'voice-1');
      expect(payload['request_id'], 'voice-1');
      expect(payload['data'], outputPcm);
    });

    test('sendControlEvent emits an origin-scoped device_event', () {
      channel.sendControlEvent('voice_interrupted', {});

      expect(socket.emitted.containsKey('device_event'), true);
      final payload = socket.emitted['device_event'] as Map;
      expect(payload['device_id'], 'device-123');
      expect(payload['type'], 'device_event');
      expect(payload['event'], 'voice_interrupted');
      expect(payload['session_id'], 'voice-1');
      expect(payload['event_id'], isA<String>());
      expect((payload['event_id'] as String).isNotEmpty, isTrue);
      expect(payload['delivery'], {
        'scope': 'origin',
        'request_id': 'voice-1',
      });
    });

    test('close detaches only this session listeners', () async {
      await channel.close();

      expect(socket.listeners.containsKey('voice_audio_chunk_relay'), isFalse);
      expect(socket.listeners.containsKey('voice_control_relay'), isFalse);
    });
  });
}
