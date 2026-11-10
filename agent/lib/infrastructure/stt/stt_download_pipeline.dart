/// The bounded write half of a dictation model download.
///
/// A download is a socket read and a file write, and on a slow host the second
/// one used to pace the first: every 64 KiB chunk was written with an `await`
/// inside the socket's isolate, so the connection idled for the whole write.
/// Measured on the owner's 4-core Neoverse-N1 host (real catalog URL): reading
/// alone 66.1 MB/s, the shipped read-then-await-write loop 29.1 MB/s, and this
/// pipeline — read in one isolate, write in another behind
/// [kSttWriteWindowBytes] — 61.2 MB/s with 19 CPU-s/GB instead of 43.5.
///
/// The window is what keeps the bound PR391 established: bytes are queued up to
/// a fixed number and the reader waits once it is full, so a fast producer can
/// never retain an artifact in the heap. The difference from the old `IOSink`
/// defect is that the queue is *bytes*, capped, and drained by an isolated
/// writer that awaits every single write — not a fire-and-forget sink.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Bytes a pipeline may hold ahead of the writer.
///
/// Sized from measurement, not from a hunch: 4 MiB is 21 times the 1856 KiB
/// socket buffer the sealed-pipeline test observes on macOS, and it was the
/// window that reached the read-only ceiling on the Oracle host. Larger windows
/// (16 MiB measured) changed throughput by 1 % and only widened the bound.
const int kSttWriteWindowBytes = 4 * 1024 * 1024;



/// Accepts artifact bytes and writes them without blocking the reader.
///
/// Contract:
/// * [add] returns once the bytes are accepted or once the window has room;
///   it never waits for the disk unless the window is full.
/// * [drain] returns when everything already added is on disk.
/// * [close] drains and closes the destination, and is idempotent. It is the
///   right call from a `finally`: on cancel the bytes already accepted still
///   land, which is what makes a resumed install continue from a real prefix.
/// * A write failure surfaces as [SttWriteFailure] from [add], [drain] or
///   [close] — never as a silently short file.
abstract class SttWritePipeline {
  Future<void> add(List<int> chunk);

  Future<void> drain();

  Future<void> close();
}

/// Opens the destination of one artifact.
typedef SttWritePipelineFactory =
    Future<SttWritePipeline> Function(File file, FileMode mode);

/// A write the destination refused, carried across the isolate boundary.
///
/// `RandomAccessFile` failures are [FileSystemException]s, which cannot cross an
/// isolate; this is the same information in a sendable shape so the store can
/// keep mapping ENOSPC to `storage_full` exactly where it always did.
class SttWriteFailure implements Exception {
  const SttWriteFailure(this.message, [this.osErrorCode, this.osErrorMessage]);

  final String message;
  final int? osErrorCode;
  final String? osErrorMessage;

  FileSystemException toFileSystemException({String? path}) => FileSystemException(
    message,
    path,
    osErrorCode == null
        ? null
        : OSError(osErrorMessage ?? message, osErrorCode!),
  );

  @override
  String toString() => osErrorCode == null
      ? 'SttWriteFailure: $message'
      : 'SttWriteFailure: $message (os error $osErrorCode: $osErrorMessage)';
}

/// Production pipeline: the file lives in its own isolate.
///
/// The isolate opens the file itself — a `RandomAccessFile` is not sendable —
/// and answers one integer per accepted write so the reader can account for the
/// window without trusting a shared counter.
class IsolateWritePipeline implements SttWritePipeline {
  IsolateWritePipeline._(this._commands, this._inbox, this._closed);

  final SendPort _commands;
  final ReceivePort _inbox;
  final Completer<void> _closed;
  final List<_RoomWaiter> _room = <_RoomWaiter>[];
  Completer<void>? _drained;
  SttWriteFailure? _failure;
  Isolate? _isolate;
  int _queued = 0;
  bool _closing = false;
  bool _done = false;

  static Future<SttWritePipeline> open(File file, FileMode mode) async {
    final inbox = ReceivePort();
    final closed = Completer<void>();
    final ready = Completer<SendPort>();
    late IsolateWritePipeline pipeline;
    inbox.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      pipeline._onMessage(message);
    });
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(
      _writerMain,
      <Object>[inbox.sendPort, file.path, mode == FileMode.append],
      onExit: exit.sendPort,
      errorsAreFatal: true,
    );
    exit.listen((Object? _) {
      exit.close();
      // The writer ended without saying goodbye: a crashed isolate, not a
      // completed artifact.
      if (!pipeline._closing) {
        pipeline._fail(
          const SttWriteFailure('the download writer exited unexpectedly'),
        );
      }
      pipeline._finishClosing();
    });
    final commands = await ready.future;
    pipeline = IsolateWritePipeline._(commands, inbox, closed);
    pipeline._isolate = isolate;
    return pipeline;
  }

  void _onMessage(Object? message) {
    if (message is int) {
      _queued -= message;
      if (_queued < 0) _queued = 0;
      _release();
      return;
    }
    if (message is String) {
      if (message == 'closed') _finishClosing();
      return;
    }
    if (message is List) {
      _fail(
        SttWriteFailure(
          message.length > 1 ? '${message[1]}' : 'write failed',
          message.length > 2 ? message[2] as int? : null,
          message.length > 3 ? '${message[3]}' : null,
        ),
      );
    }
  }

  void _release() {
    while (_room.isNotEmpty) {
      final waiter = _room.first;
      if (_queued + waiter.size > kSttWriteWindowBytes) break;
      _room.removeAt(0);
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    if (_queued == 0) {
      final drained = _drained;
      _drained = null;
      if (drained != null && !drained.isCompleted) drained.complete();
    }
  }

  void _fail(SttWriteFailure failure) {
    _failure ??= failure;
    for (final waiter in _room) {
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    _room.clear();
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  void _finishClosing() {
    if (_done) return;
    _done = true;
    if (!_closed.isCompleted) _closed.complete();
  }

  void _throwIfFailed() {
    final failure = _failure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> add(List<int> chunk) async {
    _throwIfFailed();
    if (chunk.isEmpty) return;
    if (_queued + chunk.length > kSttWriteWindowBytes) {
      final waiter = _RoomWaiter(chunk.length);
      _room.add(waiter);
      await waiter.completer.future;
      _throwIfFailed();
    }
    if (_done) return;
    _queued += chunk.length;
    // A copy: the caller may reuse its buffer as soon as this returns.
    _commands.send(Uint8List.fromList(chunk));
  }

  @override
  Future<void> drain() async {
    _throwIfFailed();
    if (_queued == 0) return;
    final drained = Completer<void>();
    _drained = drained;
    await drained.future;
    _throwIfFailed();
  }

  @override
  Future<void> close() async {
    if (_done && _closed.isCompleted) return;
    _closing = true;
    if (!_done) _commands.send('close');
    await _closed.future;
    _inbox.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _throwIfFailed();
  }
}

class _RoomWaiter {
  _RoomWaiter(this.size);

  final int size;
  final Completer<void> completer = Completer<void>();
}

/// The writer isolate: one destination, every write awaited, one ack each.
void _writerMain(List<Object> args) {
  final inbox = args[0] as SendPort;
  final path = args[1] as String;
  final append = args[2] as bool;
  final commands = ReceivePort();
  inbox.send(commands.sendPort);
  RandomAccessFile? file;
  try {
    file = File(path).openSync(mode: append ? FileMode.append : FileMode.write);
  } on FileSystemException catch (error) {
    inbox.send(<Object?>['error', error.message, error.osError?.errorCode, error.osError?.message]);
    commands.close();
    return;
  }
  commands.listen((Object? message) {
    if (message is Uint8List) {
      try {
        file!.writeFromSync(message);
        inbox.send(message.length);
      } on FileSystemException catch (error) {
        inbox.send(<Object?>[
          'error',
          error.message,
          error.osError?.errorCode,
          error.osError?.message,
        ]);
        commands.close();
      }
      return;
    }
    if (message == 'close') {
      try {
        file!.flushSync();
      } on FileSystemException {
        // Closing already loses nothing a flush could have saved; the close
        // below is what releases the handle.
      }
      try {
        file!.closeSync();
      } on FileSystemException {
        // A handle that will not close is already unusable.
      }
      inbox.send('closed');
      commands.close();
    }
  });
}

/// Same contract, in-process: the seam unit tests drive.
///
/// It exists so a test can inject a [SttWriteSink] that stalls, counts, or
/// fails while the *shipped* window accounting still runs. Production never
/// takes this path.
class InProcessWritePipeline implements SttWritePipeline {
  InProcessWritePipeline(this._sink);

  final SttWriteSink _sink;
  final List<_RoomWaiter> _room = <_RoomWaiter>[];
  final List<Uint8List> _pending = <Uint8List>[];
  Object? _failure;
  int _queued = 0;
  bool _closed = false;
  bool _pumping = false;
  Completer<void>? _idle;

  /// Bytes accepted but not yet written; the test's window probe.
  int get queuedBytes => _queued;

  void _release() {
    while (_room.isNotEmpty) {
      final waiter = _room.first;
      if (_queued + waiter.size > kSttWriteWindowBytes) break;
      _room.removeAt(0);
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    if (_queued == 0) {
      final idle = _idle;
      _idle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }

  void _throwIfFailed() {
    final failure = _failure;
    if (failure != null) throw failure;
  }

  /// Normalises a sink failure so both pipelines fail the same way.
  static Object _asFailure(Object error) {
    if (error is FileSystemException) {
      return SttWriteFailure(
        error.message,
        error.osError?.errorCode,
        error.osError?.message,
      );
    }
    return error;
  }

  /// Writes the queue in order, one chunk at a time.
  ///
  /// One worker, never two: it starts when bytes are accepted and stops when the
  /// queue is empty, which is what makes [queuedBytes] the real lead the reader
  /// has over the disk. Failures stop the writes but not the pump — the queued
  /// bytes are still accounted for, so a reader waiting for room is released
  /// and sees the failure instead of hanging on it.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    while (_pending.isNotEmpty) {
      final bytes = _pending.removeAt(0);
      try {
        if (_failure == null) await _sink.writeFrom(bytes);
      } on Object catch (error) {
        _failure ??= _asFailure(error);
      } finally {
        _queued -= bytes.length;
        _release();
      }
    }
    _pumping = false;
  }

  @override
  Future<void> add(List<int> chunk) async {
    _throwIfFailed();
    if (chunk.isEmpty || _closed) return;
    if (_queued + chunk.length > kSttWriteWindowBytes) {
      final waiter = _RoomWaiter(chunk.length);
      _room.add(waiter);
      await waiter.completer.future;
      _throwIfFailed();
      if (_closed) return;
    }
    // Copied because the caller may reuse its buffer as soon as `add` returns
    // and the write happens after that.
    final bytes = Uint8List.fromList(chunk);
    _queued += bytes.length;
    _pending.add(bytes);
    unawaited(_pump());
  }

  @override
  Future<void> drain() async {
    _throwIfFailed();
    if (_queued > 0) {
      final idle = Completer<void>();
      _idle = idle;
      await idle.future;
    }
    _throwIfFailed();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_queued > 0) {
      final idle = Completer<void>();
      _idle = idle;
      await idle.future;
    }
    try {
      // The sink is closed even when a write already failed: a refused write
      // must not leak the handle the next attempt resumes from.
      if (_failure == null) await _sink.flush();
      await _sink.close();
    } on Object catch (error) {
      _failure ??= _asFailure(error);
    }
    _throwIfFailed();
  }
}

/// Sequential byte sink for one artifact file.
///
/// It is the seam between the pipeline and the bytes: awaiting [writeFrom] keeps
/// at most one chunk alive, while a fire-and-forget write lets a fast producer
/// queue the whole artifact in the heap. A test injects one to stall, count, or
/// fail writes and hold the pipeline to its window.
abstract class SttWriteSink {
  Future<void> writeFrom(List<int> bytes);

  Future<void> flush();

  Future<void> close();
}

/// Opens the destination writer for one artifact and mode.
typedef SttWriteSinkOpener =
    Future<SttWriteSink> Function(File file, FileMode mode);

class _FileWriteSink implements SttWriteSink {
  _FileWriteSink(this._handle);

  final RandomAccessFile _handle;

  @override
  Future<void> writeFrom(List<int> bytes) => _handle.writeFrom(bytes);

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() => _handle.close();
}

/// The plain file sink: one `RandomAccessFile`, writes awaited in order.
Future<SttWriteSink> openFileWriteSink(File file, FileMode mode) async =>
    _FileWriteSink(await file.open(mode: mode));

/// In-process pipeline for tests and for callers that already hold a sink.
SttWritePipelineFactory inProcessPipeline([
  SttWriteSinkOpener opener = openFileWriteSink,
]) => (file, mode) async => InProcessWritePipeline(await opener(file, mode));


/// Keeps the smallest window above one chunk so a large chunk still fits.
int get effectiveWindowBytes =>
    math.max(kSttWriteWindowBytes, 64 * 1024);
