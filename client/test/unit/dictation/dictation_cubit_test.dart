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

  /// Emits one final chunk while stopping, like a recorder flushing its buffer.
  bool flushOnStop = false;

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
    // Mirrors the recorder: stopping closes the audio stream, which signals that
    // the final frames were delivered.
    if (flushOnStop && !controller.isClosed) controller.add([9, 9]);
    if (!controller.isClosed) await controller.close();
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
    /// Starts a session and completes the handshake the daemon sends once the
    /// recognizer is loaded; capture only begins after it.
    Future<void> startSession() async {
      await cubit.start(device);
      transport.controller.add({
        'event': 'dictation_ready',
        'model_id': 'whisper-base-int8',
        'load_ms': 12,
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    test('starts a session and forwards microphone audio as-is', () async {
      cubit = build();
      await startSession();

      expect(cubit.state.status, DictationStatus.listening);
      expect(transport.commands, contains('start'));

      capture.controller.add([1, 2, 3, 4]);
      await Future<void>.delayed(Duration.zero);
      expect(transport.audio.single, [1, 2, 3, 4]);
    });

    test('parses the daemon catalog and selection from stt_status', () async {
      cubit = build();
      await startSession();

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
            'hosted': true,
            'installed': false,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.model.selectedModelId, 'whisper-base-int8');
      expect(cubit.state.model.isReady, isTrue);
      expect(cubit.state.model.models, hasLength(2));
      expect(cubit.state.model.models.last.hosted, isTrue);
    });

    test('carries the decoding mode of each catalog entry', () async {
      cubit = build();
      await startSession();

      transport.controller.add({
        'event': 'stt_status',
        'supported': true,
        'selected': 'whisper-base-int8',
        'models': [
          {
            'id': 'whisper-base-int8',
            'label': 'Whisper base',
            'mode': 'batchVad',
            'installed': true,
          },
          {
            'id': 'stream-en-int8',
            'label': 'English streaming',
            'mode': 'streaming',
            'installed': false,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final models = cubit.state.model.models;
      expect(models.first.mode, DictationModelMode.batch);
      expect(models.first.isStreaming, isFalse);
      expect(models.last.mode, DictationModelMode.streaming);
      expect(models.last.isStreaming, isTrue);
    });

    test('live policy shows partials and appends each final', () async {
      cubit = build();
      await startSession();

      transport.controller.add({'event': 'dictation_partial', 'seq': 1, 'text': 'السلا'});
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.partialText, 'السلا');

      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'السلام عليكم'});
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.committedText, 'السلام عليكم');
      expect(cubit.state.partialText, isEmpty);

      transport.controller.add({'event': 'dictation_final', 'seq': 2, 'text': 'عامل إيه'});
      await Future<void>.delayed(Duration.zero);
      // A streaming model closes one segment per silence; the next final extends
      // the transcript instead of wiping the words already spoken.
      expect(cubit.state.committedText, 'السلام عليكم عامل إيه');
    });

    test('on_stop policy buffers partials but still commits finals', () async {
      cubit = build(policy: DictationPreviewPolicy.onStop);
      await startSession();

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
      await startSession();
      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      await Future<void>.delayed(Duration.zero);

      await cubit.stop();
      expect(transport.commands, contains('stop'));
      expect(cubit.state.status, DictationStatus.finalizing);

      transport.controller.add({'event': 'dictation_done', 'segments': 1});
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.status, DictationStatus.idle);
      // The text is session-scoped: it reaches the composer through the widget
      // and must not linger here, otherwise the next session repeats it.
      expect(cubit.state.committedText, isEmpty);
      expect(transport.closed, isTrue);
    });

    test('a missing model ends the session and asks for the sheet', () async {
      cubit = build();
      await startSession();

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
      await startSession();

      expect(cubit.state.status, DictationStatus.idle);
      expect(cubit.state.errorCode, 'remote_scope');
      expect(cubit.state.committedText, isEmpty);
    });

    test('cancel drops everything the session produced', () async {
      cubit = build();
      await startSession();
      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      await Future<void>.delayed(Duration.zero);

      await cubit.cancel();

      expect(cubit.state.committedText, isEmpty);
      expect(cubit.state.status, DictationStatus.idle);
      expect(transport.commands, contains('cancel'));
    });

    test('a drain with no segment reports no speech', () async {
      cubit = build();
      await startSession();

      await cubit.stop();
      transport.controller.add({'event': 'dictation_done', 'segments': 0});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.status, DictationStatus.idle);
      expect(cubit.state.errorCode, 'no_speech');
    });

    test('stopAndWait resolves only after the transcript lands', () async {
      cubit = build();
      await startSession();

      var settled = false;
      final waiting = cubit.stopAndWait().then((_) => settled = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Still decoding: a send at this point would post stale composer text.
      expect(settled, isFalse);

      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      transport.controller.add({'event': 'dictation_done', 'segments': 1});
      await waiting;

      expect(settled, isTrue);
      expect(cubit.state.status, DictationStatus.idle);
    });

    test('sendWhenSettled waits for the transcript, then reports success', () async {
      cubit = build();
      await startSession();

      final pending = cubit.sendWhenSettled();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The button is spinning and must stay unpressable until this clears.
      expect(cubit.state.awaitingSend, isTrue);

      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      transport.controller.add({'event': 'dictation_done', 'segments': 1});

      expect(await pending, isTrue);
      expect(cubit.state.awaitingSend, isFalse);
      expect(cubit.state.status, DictationStatus.idle);
    });

    test('a session that heard nothing does not become a send', () async {
      cubit = build();
      await startSession();

      final pending = cubit.sendWhenSettled();
      transport.controller.add({'event': 'dictation_done', 'segments': 0});

      expect(await pending, isFalse);
      expect(cubit.state.awaitingSend, isFalse);
    });

    test('a dictation error releases the wait instead of sending', () async {
      cubit = build();
      await startSession();

      final pending = cubit.sendWhenSettled();
      transport.controller.add({
        'event': 'dictation_error',
        'code': 'engine_crashed',
        'message': 'boom',
      });

      expect(await pending, isFalse);
      expect(cubit.state.awaitingSend, isFalse);
    });

    test('cancelling the pending send keeps the session text', () async {
      cubit = build();
      await startSession();

      final pending = cubit.sendWhenSettled();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cubit.cancelPendingSend();

      expect(await pending, isFalse);
      expect(cubit.state.awaitingSend, isFalse);

      // The session still finishes on its own, so nothing spoken is lost.
      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      transport.controller.add({'event': 'dictation_done', 'segments': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cubit.state.status, DictationStatus.idle);
    });

    test('loudness reaches listeners while audio is captured', () async {
      cubit = build();
      await startSession();

      final levels = <double>[];
      final sub = cubit.stream.listen((state) => levels.add(state.level));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // 100 ms of a loud tone: the meter must see a level well above silence.
      final pcm = List<int>.generate(3200, (i) => i.isEven ? 0x40 : 0x1F);
      capture.controller.add(pcm);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      // A state that is "equal" would be swallowed by the cubit and the meter
      // would never repaint, so the level has to be part of equality.
      expect(levels, isNotEmpty);
      expect(levels.last, greaterThan(0.2));
    });

    test('a quiet microphone still moves the meter well above silence', () async {
      cubit = build();
      await startSession();

      final levels = <double>[];
      final sub = cubit.stream.listen((state) => levels.add(state.level));
      // Capture is attached asynchronously after the ready handshake.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Amplitude ~400 of 32768 (-38 dBFS): typical speech on a low-gain mic.
      final pcm = List<int>.generate(3200, (i) => i.isEven ? 0x90 : 0x01);
      capture.controller.add(pcm);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(capture.started, isTrue);
      expect(transport.audio, isNotEmpty);
      expect(cubit.state.level, greaterThan(0.4));
    });

    test('a stop flushes the last frames before asking the daemon to decode', () async {
      cubit = build();
      await startSession();
      capture.flushOnStop = true;

      await cubit.stop();

      // The frames the user spoke last must reach the daemon *before* the stop
      // command, otherwise they are decoded as if they were never said.
      expect(transport.audio, contains(equals([9, 9])));
      expect(transport.commands.last, 'stop');
      expect(capture.stopped, isTrue);
    });

    test('the client session cap stops the session and reports the limit', () async {
      cubit = build();
      await startSession();
      transport.controller.add({'event': 'dictation_final', 'seq': 1, 'text': 'نص'});
      await Future<void>.delayed(Duration.zero);

      await cubit.stopForLimit();
      transport.controller.add({'event': 'dictation_done', 'segments': 1});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.errorCode, 'session_limit');
      expect(cubit.state.committedText, isEmpty);
    });

    test('an install is tracked until the daemon reports the model installed', () async {
      cubit = build();
      await cubit.installModel('whisper-base-int8', device: device);

      expect(transport.commands, contains('install'));
      expect(cubit.state.model.installingModelId, 'whisper-base-int8');
      expect(cubit.state.model.downloadProgress, 0);

      transport.controller.add({
        'event': 'stt_download_progress',
        'model_id': 'whisper-base-int8',
        'received_bytes': 50,
        'total_bytes': 200,
      });
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.model.downloadProgress, closeTo(0.25, 0.001));

      transport.controller.add({
        'event': 'stt_status',
        'supported': true,
        'selected': 'whisper-base-int8',
        'models': [
          {
            'id': 'whisper-base-int8',
            'label': 'Whisper base',
            'hosted': true,
            'installed': true,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.model.installingModelId, isNull);
      expect(cubit.state.model.downloadProgress, isNull);
      expect(cubit.state.model.isReady, isTrue);
    });

    test('a dictation error clears the install state', () async {
      cubit = build();
      await cubit.installModel('whisper-base-int8', device: device);

      transport.controller.add({
        'event': 'dictation_error',
        'code': 'download_failed',
        'message': 'HTTP 500',
      });
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.model.installingModelId, isNull);
      expect(cubit.state.errorCode, 'download_failed');
    });
  });
}