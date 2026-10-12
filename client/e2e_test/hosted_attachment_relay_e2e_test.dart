import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_commands.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

void main() {
  test(
    'uploads, admits, executes view_image, and fetches media across an Agent process',
    () async {
      final fixture = await _HostedRelayFixture.start();
      addTearDown(fixture.stop);
      late _WebSocketRelaySocket relaySocket;
      final service = SanadSocketService(
        url: fixture.url,
        hardwareId: 'remote-client-hardware',
        startToken: 'fixture-token',
        cloudSocketFactory: (url, _) {
          relaySocket = _WebSocketRelaySocket(url);
          return relaySocket;
        },
      );
      addTearDown(service.dispose);
      await service.connect();

      final gateway = SocketConversationCommandGateway(
        config: DeviceConfig(
          id: 'remote-device',
          name: 'Remote Agent',
        ),
        controller: service,
      );
      final store = DeviceConversationStore();
      final commands = ConversationCommands(
        gateway: gateway,
        conversationStore: store,
        mapper: UnifiedDeviceMapper(),
      );
      addTearDown(() {
        gateway.dispose();
        store.dispose();
      });

      final source = image.Image(width: 8, height: 4, numChannels: 3);
      image.fill(source, color: image.ColorRgb8(220, 20, 120));
      final bytes = Uint8List.fromList(image.encodePng(source));
      final turnResult = relaySocket.nextEvent('fixture_turn_result');
      final requestId = await commands.sendMessageWithAttachments(
        'Inspect the attached image.',
        sessionId: 'remote-session',
        attachments: [
          {
            'name': 'fixture.png',
            'mime_type': 'image/png',
            'size_bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'data_base64': base64Encode(bytes),
          },
        ],
      );
      expect(requestId, isNotNull);

      final result = Map<String, dynamic>.from(await turnResult as Map);
      expect(result['request_id'], requestId);
      expect(result['attachment_count'], 1);
      expect(result['model_path_count'], 1);
      expect(result['view_image_selected'], isTrue);
      expect(result['view_image_succeeded'], isTrue);

      final media = await service.fetchHostedConversationMedia(
        deviceId: 'remote-device',
        sessionId: 'remote-session',
        mediaId: result['media_id'] as String,
        purpose: 'thumbnail',
      );
      expect(media.mimeType, 'image/png');
      expect(media.bytes, bytes);
      expect(relaySocket.sentDeviceCommands.single, isNot(contains('data_base64')));
      expect(relaySocket.sentDeviceCommands.single, isNot(contains('fixture.png')));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

final class _WebSocketRelaySocket implements socket_io.Socket {
  _WebSocketRelaySocket(this.url);

  final String url;
  final listeners = <String, List<Function>>{};
  final waiters = <String, List<Completer<Object?>>>{};
  final sentDeviceCommands = <String>[];
  WebSocket? webSocket;
  bool _connected = false;

  @override
  bool get connected => _connected;

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  socket_io.Socket onAny(dynamic Function(String, dynamic) handler) => this;

  @override
  socket_io.Socket connect() {
    unawaited(_connect());
    return this;
  }

  Future<void> _connect() async {
    webSocket = await WebSocket.connect(url);
    _connected = true;
    webSocket!.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      _receive(frame['event'] as String, _normalize(frame['data']));
    });
    _receive('connect', null);
    _receive('auth_success', <String, dynamic>{});
  }

  @override
  void emit(String event, [Object? data]) {
    if (event == 'device_command') sentDeviceCommands.add(jsonEncode(data));
    webSocket!.add(jsonEncode({'event': event, 'data': data}));
  }

  Future<Object?> nextEvent(String event) {
    final completer = Completer<Object?>();
    waiters.putIfAbsent(event, () => []).add(completer);
    return completer.future.timeout(const Duration(seconds: 10));
  }

  void _receive(String event, Object? data) {
    final pending = waiters[event];
    if (pending != null && pending.isNotEmpty) pending.removeAt(0).complete(data);
    for (final listener in listeners[event] ?? const <Function>[]) {
      Function.apply(listener, [data]);
    }
  }

  @override
  socket_io.Socket disconnect() {
    _connected = false;
    unawaited(webSocket?.close());
    return this;
  }

  @override
  void dispose() => disconnect();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Object? _normalize(Object? value) {
  if (value is List) return List<int>.from(value);
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), _normalize(item)));
  }
  return value;
}

final class _HostedRelayFixture {
  _HostedRelayFixture(this.process, this.stateHome, this.url);

  final Process process;
  final Directory stateHome;
  final String url;
  bool stopped = false;

  static Future<_HostedRelayFixture> start() async {
    final stateHome = await Directory.systemTemp.createTemp('sanad-hosted-e2e-');
    final agentDirectory = Directory(
      '${Directory.current.parent.path}${Platform.pathSeparator}agent',
    );
    final process = await Process.start(
      _dartExecutable(),
      ['run', 'test/fixtures/hosted_attachment_relay_fixture.dart'],
      workingDirectory: agentDirectory.path,
      environment: {
        ...Platform.environment,
        'SANAD_HOME': stateHome.path,
        'SANAD_STATE_HOME': stateHome.path,
      },
    );
    final stdoutLines = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final stderrLines = <String>[];
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (stderrLines.length < 20) stderrLines.add(line);
    });
    try {
      final ready = await stdoutLines
          .firstWhere((line) => line.startsWith('READY:'))
          .timeout(const Duration(seconds: 10));
      final port = int.parse(ready.substring('READY:'.length));
      return _HostedRelayFixture(
        process,
        stateHome,
        'ws://127.0.0.1:$port',
      );
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await stateHome.delete(recursive: true);
      throw StateError('Hosted relay fixture failed to start: ${stderrLines.join(' | ')}');
    }
  }

  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (stateHome.existsSync()) await stateHome.delete(recursive: true);
  }
}

String _dartExecutable() {
  final resolved = Platform.resolvedExecutable;
  if (!resolved.contains('flutter_tester')) return resolved;
  final cacheDirectory = File(resolved).parent.parent.parent.parent;
  final executable = Platform.isWindows ? 'dart.exe' : 'dart';
  return '${cacheDirectory.path}${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}$executable';
}
