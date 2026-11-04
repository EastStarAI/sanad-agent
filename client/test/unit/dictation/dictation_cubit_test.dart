import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

class FakeDictationTransport implements DictationTransport {
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

class FakeResolver implements DictationResolver {
  FakeResolver({this.transport, this.failure});

  final FakeDictationTransport? transport;
  final Object? failure;
  int calls = 0;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async {
    calls++;
    final error = failure;
    if (error != null) throw error;
    return transport!;
  }
}

class FakeCapture implements DictationCapture {
  final StreamController<List<int>> controller =
      StreamController<List<int>>.broadcast();
  bool started = false;
  bool stopped = false;
  bool disposed = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async {
    started = true;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!controller.isClosed) await controller.close();
  }
}

void main() {
  final device = DeviceConfig(id: 'dev-1', name: 'Device', isOnline: true);

  late FakeDictationTransport transport;
  late FakeCapture capture;
  late DictationCubit cubit;

  DictationCubit build({
    Object? failure,
    DictationPreviewPolicy policy = DictationPreviewPolicy.live,
  }) {
    return DictationCubit(
      resolver: FakeResolver(transport: transport, failure: failure),
      capture: capture,
      previewPolicy: policy,
      sessionIdFactory: () => 'session-1',
    );
  }

  setUp(() {
    transport = FakeDictationTransport();
    capture = FakeCapture();
  });

  tearDown(() async {
    await cubit.close();
    if (!transport.controller.isClosed) await transport.controller.close();
    if (!capture.controller.isClosed) await capture.controller.close();
  });

  group('dictation cubit', () {
    test('starts a session and forwards microphone audio as-is', () async {
      cubit = build();
      await cubit.start(device);

      expect(cubit.state.status, DictationStatus.listening);
      expect(transport.commands, contains('start'));

      capture.controller.add([1, 2, 3, 4]);
      await Future<void>.delayed(Duration.zero);
      expect(transport.audio.single, [1, 2, 3, 4]);
    });

    test('parses the daemon catalog and selection from stt_status', () async {
      cubit = build();
      await cubit.start(device);

      transport.controller.add({
        'event': 'stt_status',
        'supported': true,
        'selected': 'whisper-base-int8',
        'models': [
          {
            'id': 'whisper-base-int8',
            'label': 'Whisper base',
            'total_bytes': 161000000,
            'hosted': true,
            'installed': true,
          },
          {
            'id': 'egy-whisper-turbo-int8',
            'label': 'Egyptian',
            'hosted': false,
            'installed': false,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.model.selectedModelId, 'whisper-base-int8');
      expect(cubit.state.model.isReady, isTrue);
      expect(cubit.state.model.models, hasLength(2));
      expect(cubit.state.model.models.last.hosted, isFalse);
    });

    test('live policy shows partials, finals commit and clear the tail', () async {
      cubit = build();
      await cubit.start(device);

      transport.controller.add({'event': 'dictation_partial', 'seq': 1, 'text': 'السلا'});
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.partialText, 'السلا');

      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'السلام عليكم'});
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.committedText, 'السلام عليكم');
      expect(cubit.state.partialText, isEmpty);

      transport.controller.add({'event': 'dictation_final', 'seq': 2, 'text': 'عامل إيه'});
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.committedText, 'السلام عليكم عامل إيه');
    });

    test('on_stop policy buffers partials but still commits finals', () async {
      cubit = build(policy: DictationPreviewPolicy.onStop);
      await cubit.start(device);

      transport.controller.add({'event': 'dictation_partial', 'seq': 1, 'text': 'abc'});
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.partialText, isEmpty);
      expect(cubit.state.visibleText, isEmpty);

      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'abc def'});
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.visibleText, 'abc def');
    });

    test('stop drains then closes the session but keeps the text', () async {
      cubit = build();
      await cubit.start(device);
      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      await Future<void>.delayed(Duration.zero);

      await cubit.stop();
      expect(transport.commands, contains('stop'));
      expect(cubit.state.status, DictationStatus.finalizing);

      transport.controller.add({'event': 'dictation_done', 'segments': 1});
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.status, DictationStatus.idle);
      expect(cubit.state.committedText, 'نص');
      expect(transport.closed, isTrue);
    });

    test('a missing model ends the session and asks for the sheet', () async {
      cubit = build();
      await cubit.start(device);

      transport.controller.add({
        'event': 'dictation_error',
        'code': 'model_not_installed',
        'message': 'install a dictation model first',
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.status, DictationStatus.idle);
      expect(cubit.state.errorCode, 'model_not_installed');
      expect(cubit.state.sessionNeedsFirstUseSheet, isTrue);
      expect(cubit.state.committedText, isEmpty);
    });

    test('an unavailable transport surfaces its reason without text', () async {
      cubit = build(failure: const DictationTransportUnavailable('remote_scope'));
      await cubit.start(device);

      expect(cubit.state.status, DictationStatus.idle);
      expect(cubit.state.errorCode, 'remote_scope');
      expect(cubit.state.committedText, isEmpty);
    });

    test('cancel drops everything the session produced', () async {
      cubit = build();
      await cubit.start(device);
      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      await Future<void>.delayed(Duration.zero);

      await cubit.cancel();

      expect(cubit.state.committedText, isEmpty);
      expect(cubit.state.status, DictationStatus.idle);
      expect(transport.commands, contains('cancel'));
    });
  });
}
