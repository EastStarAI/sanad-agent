/// Dictation engine: the daemon-facing handle for one recognition session.
///
/// The engine never touches native handles itself. It owns a worker isolate
/// (see `stt_isolate.dart`), forwards audio with bounded backpressure, and
/// republishes the worker's messages as [SttEvent]s.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'stt_isolate.dart';
import 'stt_model_store.dart';
import 'stt_types.dart';
import 'whispercpp_isolate.dart';

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
    bool useGpu = true,
  });

  /// Queues 16 kHz mono PCM16 little-endian audio.
  void acceptAudio(Uint8List pcm16);

  /// Flushes the tail segment and completes the session.
  Future<void> finish();

  /// Prepares a finished engine for a new session without reloading the model.
  ///
  /// Only meaningful when the engine was kept warm between sessions; a fresh
  /// engine is already in this state.
  Future<void> reset();

  /// Drops pending audio and any in-flight decode result.
  Future<void> cancel();

  Future<void> dispose();
}

class SherpaSttEngine implements SttEngine {
  SherpaSttEngine({
    this.maxQueuedChunks = 200,
    this.entryPoint = sttWorkerEntry,
  });

  /// The isolate body: `sttWorkerEntry` for sherpa, `whisperCppWorkerEntry` for
  /// the whisper.cpp engine. Everything above this line is engine-agnostic.
  final void Function(SendPort) entryPoint;

  /// High-water mark of queued audio chunks (~100 ms each, so 20 s). Audio
  /// beyond it is dropped and counted instead of growing without bound. The
  /// worst-case Egyptian segment (10 s, RTF 0.53) needs ~5.3 s of buffer.
  final int maxQueuedChunks;

  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();
  final Queue<Uint8List> _queue = ListQueue<Uint8List>();

  /// Daemon-side logger for worker metadata lines (gate measurements, typed
  /// codes). Never audio or transcript text.
  final Logger _logger = Logger('SttEngine');

  Isolate? _isolate;
  SendPort? _inbox;
  ReceivePort? _outbox;
  Completer<void>? _ready;
  bool _busy = false;
  bool _closed = false;
  bool _cancelled = false;
  int _droppedChunks = 0;
  Completer<void>? _finished;

  /// Completes when the worker reports it freed its native handles.
  ///
  /// Killing the isolate first skipped the worker's `free()` calls, so every
  /// session leaked its model: measured 661 → 1045 → 1332 MB across three
  /// consecutive multilingual sessions, roughly one model per session.
  final Completer<void> _workerClosed = Completer<void>();
  int _threads = 0;

  /// `malloc_zone_pressure_relief(NULL, 0)`.
  ///
  /// Freeing a 300 MB model marks its malloc regions empty, but the allocator
  /// keeps them resident: measured 669 MB → 1.2 GB over six consecutive
  /// sessions even after the worker freed everything. Asking the system to
  /// relieve the pressure hands those pages back instead of letting them
  /// accumulate for the lifetime of the daemon.
  static final int Function(Pointer<Void>, int) _pressureRelief = () {
    try {
      return DynamicLibrary.process()
          .lookupFunction<
            IntPtr Function(Pointer<Void>, IntPtr),
            int Function(Pointer<Void>, int)
          >('malloc_zone_pressure_relief');
    } on Object {
      return (_, _) => 0;
    }
  }();

  static void _releaseFreedPages() {
    try {
      _pressureRelief(nullptr, 0);
    } on Object {
      // Not fatal: the pages are free, the process just keeps them longer.
    }
  }

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
    bool useGpu = true,
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
        case 'partial':
          if (_cancelled || _closed) return;
          _emit(
            SttPartialEvent(
              seq: message['seq'] as int? ?? 0,
              text: (message['text'] as String? ?? '').trim(),
            ),
          );
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
          if (!_workerClosed.isCompleted) _workerClosed.complete();
          _closeEvents();
        case 'log':
          // The worker forwards its metadata lines here so the daemon's own
          // logger owns them: a worker isolate has no shared log listener.
          final line = message['message'] as String?;
          if (line != null && line.isNotEmpty) _logger.info(line);
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
      entryPoint,
      outbox.sendPort,
      debugName: 'sanad-stt-worker',
      onExit: controlPort.sendPort,
      onError: controlPort.sendPort,
    );

    _threads = threads;
    _inbox = await portCompleter.future;
    _inbox!.send({
      'cmd': 'init',
      'modelId': modelId,
      'mode': files.mode.name,
      'joiner': files.joiner,
      'encoder': files.encoder,
      'decoder': files.decoder,
      'tokens': files.tokens,
      'vad': files.vad,
      'model': files.model,
      'language': files.language,
      'threads': threads,
      'streamingModelType': files.streamingModelType,
      'useGpu': useGpu,
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
    _inbox!.send({'cmd': 'finish', 'threads': _threads});
    await finished.future.timeout(
      const Duration(seconds: 300),
      onTimeout: () {},
    );
  }

  @override
  Future<void> reset() async {
    if (_closed) return;
    _queue.clear();
    _cancelled = false;
    _finished = null;
    _busy = false;
    _inbox?.send({'cmd': 'reset'});
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
    final inbox = _inbox;
    inbox?.send({'cmd': 'dispose'});
    // Give the worker the chance to free the model. The isolate kill is only a
    // fallback: a killed isolate never runs its `free()` calls and the native
    // memory stays allocated until the daemon exits.
    try {
      await _workerClosed.future.timeout(const Duration(seconds: 5));
    } on Object {
      // The worker is gone or unresponsive; the kill below still reclaims it.
    }
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _inbox = null;
    _outbox?.close();
    _outbox = null;
    await _closeEvents();
    _releaseFreedPages();
  }

  void _emit(SttEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _closeEvents() async {
    if (!_events.isClosed) await _events.close();
  }
}

/// whisper.cpp engine: one ggml file, mmap'd by the C shim, decoded in a worker
/// isolate. Same event vocabulary as the sherpa engine.
class WhisperCppSttEngine extends SherpaSttEngine {
  WhisperCppSttEngine() : super(entryPoint: whisperCppWorkerEntry);
}
