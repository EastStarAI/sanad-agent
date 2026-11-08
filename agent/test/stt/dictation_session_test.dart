import 'dart:async';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/stt_engine.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

class _FakeEngine implements SttEngine {
  final _events = StreamController<SttEvent>.broadcast();
  final audio = <int>[];
  bool finishCalled = false;
  bool cancelCalled = false;
  bool resetCalled = false;
  bool disposed = false;
  bool started = false;
  Completer<void>? finishGate;

  @override
  Stream<SttEvent> get events => _events.stream;

  SttReadyEvent? readyEvent;

  @override
  SttReadyEvent? get ready => readyEvent;

  @override
  Future<void> start(
    SttModelFiles files, {
    required String modelId,
    int threads = 2,
    bool useGpu = true,
  }) async {
    started = true;
  }

  @override
  void acceptAudio(Uint8List pcm16) => audio.add(pcm16.length);

  @override
  Future<void> finish() async {
    finishCalled = true;
    final gate = finishGate;
    if (gate != null) await gate.future;
    emit(const SttDoneEvent(droppedChunks: 0));
  }

  @override
  Future<void> cancel() async => cancelCalled = true;

  @override
  Future<void> reset() async => resetCalled = true;

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_events.isClosed) await _events.close();
  }

  void emit(SttEvent event) => _events.add(event);
}

class _FakeChannel implements DictationChannel {
  final _audio = StreamController<Uint8List>.broadcast();
  final _commands = StreamController<DictationMessage>.broadcast();
  final sent = <(String, Map<String, dynamic>)>[];
  bool closed = false;

  @override
  Stream<Uint8List> get audio => _audio.stream;

  @override
  Stream<DictationMessage> get commands => _commands.stream;

  @override
  void send(String event, [Map<String, dynamic> payload = const {}]) {
    sent.add((event, payload));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_audio.isClosed) await _audio.close();
    if (!_commands.isClosed) await _commands.close();
  }

  void addAudio(List<int> bytes) => _audio.add(Uint8List.fromList(bytes));
  void sendCommand(DictationCommand command) =>
      _commands.add(DictationMessage(command, const {}));

  List<Map<String, dynamic>> eventsOf(String name) => [
    for (final entry in sent)
      if (entry.$1 == name) entry.$2,
  ];
}

void main() {
  late _FakeEngine engine;
  late _FakeChannel channel;

  setUp(() {
    engine = _FakeEngine();
    channel = _FakeChannel();
  });

  DictationSession sessionWith({
    Duration maxSessionDuration = const Duration(minutes: 5),
  }) {
    return DictationSession(
      transport: channel,
      engine: engine,
      modelId: 'test-model',
      maxSessionDuration: maxSessionDuration,
    );
  }

  group('dictation session', () {
    test('republishes ready and final events with client-safe payloads', () async {
      final session = sessionWith();
      await session.start();
      engine.emit(const SttReadyEvent(loadMs: 765, modelId: 'test-model'));
      engine.emit(
        const SttFinalEvent(
          seq: 0,
          text: 'أهلاً',
          audioMs: 2400,
          decodeMs: 900,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(channel.eventsOf('dictation_ready').single['load_ms'], 765);
      final finals = channel.eventsOf('dictation_final');
      expect(finals, hasLength(1));
      expect(finals.single['seq'], 0);
      expect(finals.single['text'], 'أهلاً');
      expect(finals.single['audio_ms'], 2400);
      await session.close();
    });

    test('a streaming partial reaches the client before the final', () async {
      final session = sessionWith();
      await session.start();
      engine.emit(const SttPartialEvent(seq: 0, text: 'hello wor'));
      engine.emit(const SttPartialEvent(seq: 0, text: 'hello world'));
      engine.emit(
        const SttFinalEvent(seq: 0, text: 'hello world', audioMs: 0, decodeMs: 0),
      );
      await Future<void>.delayed(Duration.zero);

      final partials = channel.eventsOf('dictation_partial');
      expect(partials.map((event) => event['text']), ['hello wor', 'hello world']);
      // The final reuses the partial's seq, so the client replaces rather than
      // appends, and nothing is duplicated.
      final finals = channel.eventsOf('dictation_final');
      expect(finals.single['seq'], partials.last['seq']);
      expect(channel.eventsOf('dictation_ready'), isEmpty);
      await session.close();
    });

    test('a cancelled session publishes no partial', () async {
      final session = sessionWith();
      await session.start();
      await session.close();

      expect(engine.cancelCalled, isTrue);
      expect(channel.eventsOf('dictation_partial'), isEmpty);
      expect(channel.eventsOf('dictation_final'), isEmpty);
    });

    test('replays readiness the engine reported before the session attached', () async {
      engine.readyEvent = const SttReadyEvent(loadMs: 321, modelId: 'test-model');
      final session = sessionWith();
      await session.start();
      await Future<void>.delayed(Duration.zero);

      // Without the replay the client would sit in its loading state forever.
      final ready = channel.eventsOf('dictation_ready');
      expect(ready, hasLength(1));
      expect(ready.single['load_ms'], 321);
      await session.close();
    });

    test('forwards microphone audio to the engine only while open', () async {
      final session = sessionWith();
      await session.start();
      channel.addAudio([1, 2, 3, 4]);
      await Future<void>.delayed(Duration.zero);
      expect(engine.audio, [4]);

      await session.close();
      if (!channel.closed) channel.addAudio([5, 6]);
      await Future<void>.delayed(Duration.zero);
      expect(engine.audio, [4]);
    });

    test('a stop waits for the drain before closing the channel', () async {
      final gate = Completer<void>();
      engine.finishGate = gate;
      final session = sessionWith();
      await session.start();
      channel.sendCommand(DictationCommand.stop);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The trailing audio is still being decoded: the client must keep the
      // channel open so the final segment and `done` still reach it.
      expect(engine.finishCalled, isTrue);
      expect(channel.closed, isFalse);
      expect(channel.eventsOf('dictation_done'), isEmpty);

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(channel.eventsOf('dictation_done'), hasLength(1));
      expect(channel.closed, isTrue);
      expect(engine.disposed, isTrue);
    });

    test('a stop command drains the engine and closes the channel', () async {
      final session = sessionWith();
      await session.start();
      channel.sendCommand(DictationCommand.stop);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(engine.finishCalled, isTrue);
      expect(engine.disposed, isTrue);
      expect(channel.closed, isTrue);
    });

    test('a cancel command never finishes and never publishes text', () async {
      final session = sessionWith();
      await session.start();
      channel.sendCommand(DictationCommand.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(engine.cancelCalled, isTrue);
      expect(engine.finishCalled, isFalse);
      expect(channel.eventsOf('dictation_final'), isEmpty);
    });

    test('exceeding the session limit fails with session_limit', () async {
      final session = sessionWith(maxSessionDuration: Duration.zero);
      await session.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      channel.addAudio([1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final errors = channel.eventsOf('dictation_error');
      expect(errors.single['code'], 'session_limit');
      expect(engine.cancelCalled, isTrue);
      expect(engine.audio, isEmpty);
    });

    test('an engine error is surfaced without leaking transcript text', () async {
      final session = sessionWith();
      await session.start();
      engine.emit(
        const SttErrorEvent(SttException('decode_failed', 'boom')),
      );
      await Future<void>.delayed(Duration.zero);

      final error = channel.eventsOf('dictation_error').single;
      expect(error['code'], 'decode_failed');
      expect(error['message'], 'boom');
      await session.close();
    });
  });
}
