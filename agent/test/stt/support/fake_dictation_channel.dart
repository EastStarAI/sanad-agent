import 'dart:async';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/stt_engine.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';

/// In-process [DictationChannel] used by the dictation channel tests.
class FakeDictationChannel implements DictationChannel {
  final _audio = StreamController<Uint8List>.broadcast();
  final _commands = StreamController<DictationMessage>.broadcast();
  final sent = <(String, Map<String, dynamic>)>[];
  bool closed = false;
  int dropped = 0;

  @override
  Stream<Uint8List> get audio => _audio.stream;

  @override
  Stream<DictationMessage> get commands => _commands.stream;

  @override
  int get droppedFrames => dropped;

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

  void addAudio(List<int> bytes) {
    if (_audio.isClosed) return;
    _audio.add(Uint8List.fromList(bytes));
  }

  /// True once the service attached its command listener.
  bool get hasListener => _commands.hasListener;

  void sendCommand(DictationCommand command, {String? modelId}) {
    if (_commands.isClosed) return;
    _commands.add(DictationMessage(command, {'model_id': ?modelId}));
  }

  List<Map<String, dynamic>> eventsOf(String name) => [
    for (final entry in sent)
      if (entry.$1 == name) entry.$2,
  ];

  bool get hasEvent => sent.any((entry) => entry.$1 == 'dictation_error');

  /// Waits until [name] was emitted, or fails the test on timeout.
  Future<Map<String, dynamic>> awaitEvent(
    String name, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final events = eventsOf(name);
      if (events.isNotEmpty) return events.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('no "$name" event within $timeout; sent=$sent');
  }
}

/// [SttEngine] double that records what the session did to it.
class FakeSttEngine implements SttEngine {
  FakeSttEngine({this.readyEvent});

  final _events = StreamController<SttEvent>.broadcast();
  final audioLengths = <int>[];
  bool finishCalled = false;
  bool cancelCalled = false;
  bool resetCalled = false;
  bool disposed = false;
  bool disposedAfterSessionEnd = false;
  bool started = false;

  /// Held by a test to delay `start()` past a channel close.
  Completer<void>? startGate;

  /// Held by a test to keep a drain in flight while it observes the lease.
  Completer<void>? finishGate;

  SttReadyEvent? readyEvent;

  @override
  SttReadyEvent? get ready => readyEvent;

  @override
  Stream<SttEvent> get events => _events.stream;

  @override
  Future<void> start(
    SttModelFiles files, {
    required String modelId,
    int threads = 2,
    bool useGpu = true,
    String? sherpaNativeDir,
  }) async {
    started = true;
    final gate = startGate;
    if (gate != null) await gate.future;
  }

  @override
  void acceptAudio(Uint8List pcm16) => audioLengths.add(pcm16.length);

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

  void emit(SttEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
