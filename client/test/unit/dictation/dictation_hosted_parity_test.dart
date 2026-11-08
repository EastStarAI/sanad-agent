import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

/// The vocabulary the local channel emits. The hosted adapter reshapes a
/// relayed `dictation_event` into exactly these maps, so the session, cubit, and
/// insertion code cannot tell the channels apart.
const List<Map<String, dynamic>> _canonicalSequence = [
  {'event': 'dictation_ready', 'model_id': 'whisper-base-int8', 'load_ms': 9},
  {'event': 'dictation_partial', 'seq': 0, 'text': 'hello'},
  {'event': 'dictation_final', 'seq': 0, 'text': 'Hello there'},
];

class _Transport implements DictationTransport {
  final StreamController<Map<String, dynamic>> controller =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<String> commands = <String>[];
  final List<List<int>> audio = <List<int>>[];
  bool closed = false;

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  @override
  bool get isOpen => !closed;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {
    commands.add(event);
  }

  @override
  void sendAudio(List<int> pcm16) => audio.add(pcm16);

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }
}

class _Resolver implements DictationResolver {
  _Resolver(this.transport);

  final _Transport transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async => transport;
}

class _Capture implements DictationCapture {
  final StreamController<List<int>> controller =
      StreamController<List<int>>.broadcast();
  bool flushOnStop = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async => controller.stream;

  @override
  Future<void> stop() async {
    if (flushOnStop && !controller.isClosed) controller.add([7, 7]);
    if (!controller.isClosed) await controller.close();
  }

  @override
  Future<void> dispose() async {
    if (!controller.isClosed) await controller.close();
  }
}

void main() {
  final device = DeviceConfig(id: 'dev-1', name: 'Device', isOnline: true);

  late _Transport transport;
  late _Capture capture;
  late DictationCubit cubit;

  setUp(() {
    transport = _Transport();
    capture = _Capture();
    cubit = DictationCubit(
      resolver: _Resolver(transport),
      capture: capture,
      sessionIdFactory: () => 'dict-11111111-1111-4111-8111-111111111111',
    );
  });

  tearDown(() async {
    await cubit.close();
    if (!transport.controller.isClosed) await transport.controller.close();
    if (!capture.controller.isClosed) await capture.controller.close();
  });

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> startSession() async {
    await cubit.start(device);
    transport.controller.add({
      'event': 'dictation_ready',
      'model_id': 'whisper-base-int8',
      'load_ms': 9,
    });
    await settle();
  }

  group('channel parity', () {
    test('the canonical sequence drives the same state from either channel',
        () async {
      await startSession();
      for (final event in _canonicalSequence.skip(1)) {
        transport.controller.add(event);
        await settle();
      }

      expect(cubit.state.status, DictationStatus.listening);
      expect(cubit.state.committedText, 'Hello there');
      expect(cubit.state.partialText, '');
    });

    test('identity fields of a relayed payload are inert to the session',
        () async {
      await startSession();
      // A relayed hosted event carries identity and version fields the local
      // channel never sends; consuming them must not change the outcome.
      transport.controller.add({
        'event': 'dictation_final',
        'seq': 0,
        'text': 'Hello there',
        'dictation_id': 'dict-11111111-1111-4111-8111-111111111111',
        'request_id': 'dict-11111111-1111-4111-8111-111111111111',
        'session_id': 'dict-11111111-1111-4111-8111-111111111111',
        'version': 'v1',
      });
      await settle();

      expect(cubit.state.committedText, 'Hello there');
      expect(cubit.state.errorCode, isNull);
    });

    test('a delayed final and done after the ordered end still land', () async {
      // Regression guard for origin retirement: `dictation_end` closes ingress,
      // but the drain results arrive afterwards. Dropping them loses the
      // transcript of a normal stop, so the send path must still see text.
      await startSession();
      capture.flushOnStop = true;
      final sent = cubit.sendWhenSettled(
        timeout: const Duration(seconds: 5),
      );
      await settle();

      expect(transport.commands, contains('stop'));

      // The daemon answers after the stop, in this order.
      transport.controller.add({
        'event': 'dictation_final',
        'seq': 0,
        'text': 'spoken words',
        'audio_ms': 900,
        'decode_ms': 40,
      });
      await settle();
      transport.controller.add({
        'event': 'dictation_done',
        'segments': 1,
        'dropped_chunks': 0,
      });

      expect(await sent, isTrue);
      expect(cubit.state.status, DictationStatus.idle);
      expect(cubit.state.discardText, isFalse);
    });

    test('a drain with no recognized speech is reported as no speech',
        () async {
      await startSession();
      final sent = cubit.sendWhenSettled(
        timeout: const Duration(seconds: 5),
      );
      await settle();
      transport.controller.add({
        'event': 'dictation_done',
        'segments': 0,
        'dropped_chunks': 2,
      });

      expect(await sent, isFalse);
      expect(cubit.state.errorCode, 'no_speech');
    });
  });

  group('daemon status projection', () {
    test('platform verdict and readiness reason stay separate', () async {
      await startSession();
      transport.controller.add({
        'event': 'stt_status',
        'supported': false,
        'ready': false,
        'reason': 'unsupported_platform',
        'busy': false,
        'selected': null,
        'models': const [],
      });
      await settle();
      expect(cubit.state.model.isPlatformSupported, isFalse);
      expect(cubit.state.model.unavailableReason, 'unsupported_platform');
      expect(cubit.state.model.readinessReason, isNull);
      expect(cubit.state.model.blockedReason, 'unsupported_platform');

      transport.controller.add({
        'event': 'stt_status',
        'supported': true,
        'ready': false,
        'reason': 'native_runtime_missing',
        'busy': true,
        'selected': 'path-override',
        'models': [
          {
            'id': 'path-override',
            'label_code': 'path_override',
            'note': '/models/ggml.bin',
            'total_bytes': 0,
            'installed': true,
          },
        ],
      });
      await settle();
      expect(cubit.state.model.isPlatformSupported, isTrue);
      expect(cubit.state.model.unavailableReason, isNull);
      expect(cubit.state.model.readinessReason, 'native_runtime_missing');
      expect(cubit.state.model.blockedReason, 'native_runtime_missing');
      expect(cubit.state.model.busy, isTrue);
      expect(cubit.state.model.models.single.labelCode, 'path_override');
      // Supported but not ready: the runtime is missing, and the path-override
      // row is a model detail — it never turns readiness into ready.
      expect(cubit.state.model.isReady, isFalse);
    });

    test('dictation_ready clears the readiness reason', () async {
      await startSession();
      transport.controller.add({
        'event': 'stt_status',
        'supported': true,
        'ready': false,
        'reason': 'native_runtime_preparing',
        'models': const [],
      });
      await settle();
      expect(cubit.state.model.readinessReason, 'native_runtime_preparing');

      transport.controller.add({'event': 'dictation_ready', 'load_ms': 4});
      await settle();
      expect(cubit.state.model.readinessReason, isNull);
      expect(cubit.state.model.isReady, isTrue);
    });
  });
}
