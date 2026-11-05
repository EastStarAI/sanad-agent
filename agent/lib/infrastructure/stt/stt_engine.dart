/// Dictation engine: the daemon-facing handle for one recognition session.
///
/// The engine never touches native handles itself. It owns a worker isolate
/// (see `stt_isolate.dart`), forwards audio with bounded backpressure, and
/// republishes the worker's messages as [SttEvent]s.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'stt_isolate.dart';
import 'stt_model_store.dart';
import 'stt_types.dart';

abstract class SttEngine {
  /// Typed events for this session. Completes when the worker closes.
  Stream<SttEvent> get events;

  /// The readiness the worker already reported, if it has one.
  ///
  /// The engine loads the recognizer before a session subscribes to [events],
  /// so the ready event must be replayable or the client would wait forever.
  SttReadyEvent? get ready;

  /// Spawns the worker and loads the recognizer.
  Future<void> start(
    SttModelFiles files, {
    required String modelId,
    int threads = 2,
  });

  /// Queues 16 kHz mono PCM16 little-endian audio.
  void acceptAudio(Uint8List pcm16);

  /// Flushes the tail segment and completes the session.
  Future<void> finish();

  /// Drops pending audio and any in-flight decode result.
  Future<void> cancel();

  Future<void> dispose();
}

class SherpaSttEngine implements SttEngine {
  SherpaSttEngine({this.maxQueuedChunks = 200});

  /// High-water mark of queued audio chunks (~100 ms each, so 20 s). Audio
  /// beyond it is dropped and counted instead of growing without bound. The
  /// worst-case Egyptian segment (10 s, RTF 0.53) needs ~5.3 s of buffer.
  final int maxQueuedChunks;

  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();
  final Queue<Uint8List> _queue = ListQueue<Uint8List>();

  Isolate? _isolate;
  SendPort? _inbox;
  ReceivePort? _outbox;
  Completer<void>? _ready;
  bool _busy = false;
  bool _closed = false;
  bool _cancelled = false;
  int _droppedChunks = 0;
  Completer<void>? _finished;

  @override
  Stream<SttEvent> get events => _events.stream;

  SttReadyEvent? _readyEvent;

  @override
  SttReadyEvent? get ready => _readyEvent;

  @override
  Future<void> start(
    SttModelFiles files, {
    required String modelId,
    int threads = 2,
  }) async {
    final outbox = ReceivePort();
    _outbox = outbox;
    _ready = Completer<void>();
    final portCompleter = Completer<SendPort>();

    outbox.listen((message) {
      if (message is! Map) return;
      switch (message['evt']) {
        case 'port':
          final port = message['port'] as SendPort;
          if (!portCompleter.isCompleted) portCompleter.complete(port);
        case 'ready':
          final ready = SttReadyEvent(
            loadMs: message['loadMs'] as int? ?? 0,
            modelId: message['modelId'] as String? ?? modelId,
          );
          _readyEvent = ready;
          _emit(ready);
          if (!(_ready?.isCompleted ?? true)) _ready?.complete();
        case 'final':
          if (_cancelled || _closed) return;
          _emit(
            SttFinalEvent(
              seq: message['seq'] as int? ?? 0,
              text: (message['text'] as String? ?? '').trim(),
              audioMs: message['audioMs'] as int? ?? 0,
              decodeMs: message['decodeMs'] as int? ?? 0,
            ),
          );
        case 'idle':
          _busy = false;
          _flushQueue();
        case 'done':
          if (_cancelled || _closed) return;
          _emit(SttDoneEvent(droppedChunks: _droppedChunks));
          if (!(_finished?.isCompleted ?? true)) _finished?.complete();
        case 'error':
          _emit(
            SttErrorEvent(
              SttException(
                message['code'] as String? ?? 'engine_error',
                message['message'] as String? ?? 'unknown dictation error',
              ),
            ),
          );
          if (!(_ready?.isCompleted ?? true)) {
            _ready?.completeError(
              SttException(
                message['code'] as String? ?? 'engine_error',
                message['message'] as String? ?? 'unknown dictation error',
              ),
            );
          }
        case 'closed':
          _closeEvents();
      }
    });

    final controlPort = ReceivePort();
    controlPort.listen((message) {
      if (message is List) {
        _emit(
          SttErrorEvent(
            SttException('worker_crashed', '${message.first}'),
          ),
        );
      } else {
        _emit(
          const SttErrorEvent(
            SttException('worker_exited', 'the dictation worker exited'),
          ),
        );
      }
      _closeEvents();
    });

    _isolate = await Isolate.spawn(
      sttWorkerEntry,
      outbox.sendPort,
      debugName: 'sanad-stt-worker',
      onExit: controlPort.sendPort,
      onError: controlPort.sendPort,
    );

    _inbox = await portCompleter.future;
    _inbox!.send({
      'cmd': 'init',
      'modelId': modelId,
      'encoder': files.encoder,
      'decoder': files.decoder,
      'tokens': files.tokens,
      'vad': files.vad,
      'language': files.language,
      'threads': threads,
    });
    await _ready!.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw const SttException(
        'load_timeout',
        'the recognizer did not load within 60s',
      ),
    );
  }

  @override
  void acceptAudio(Uint8List pcm16) {
    if (_closed || _cancelled || _inbox == null) return;
    if (_busy) {
      if (_queue.length >= maxQueuedChunks) {
        _droppedChunks++;
        return;
      }
      _queue.add(pcm16);
      return;
    }
    _busy = true;
    _inbox!.send({'cmd': 'audio', 'pcm': pcm16});
  }

  void _flushQueue() {
    if (_closed || _cancelled || _inbox == null) return;
    if (_queue.isEmpty) return;
    _busy = true;
    _inbox!.send({'cmd': 'audio', 'pcm': _queue.removeFirst()});
  }

  /// Flushes the tail of the audio and resolves once the worker reports that
  /// draining finished, so the caller can wait for the last segment before
  /// tearing the worker down.
  ///
  /// A batch model decodes the whole utterance here, which is many times real
  /// time on long recordings, so the wait is generous rather than a timeout in
  /// disguise: closing early would throw the transcript away.
  @override
  Future<void> finish() async {
    if (_closed || _inbox == null) return;
    final finished = Completer<void>();
    _finished = finished;
    _inbox!.send({'cmd': 'finish'});
    await finished.future.timeout(
      const Duration(seconds: 300),
      onTimeout: () {},
    );
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _queue.clear();
    _inbox?.send({'cmd': 'cancel'});
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    _inbox?.send({'cmd': 'dispose'});
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _inbox = null;
    _outbox?.close();
    _outbox = null;
    await _closeEvents();
  }

  void _emit(SttEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _closeEvents() async {
    if (!_events.isClosed) await _events.close();
  }
}
