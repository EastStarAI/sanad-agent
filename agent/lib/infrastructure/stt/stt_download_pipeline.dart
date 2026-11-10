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

/// Bytes written before the page cache is forced out to the disk.
///
/// A write that is merely *accepted* by the kernel is not on the disk: Linux
/// defers writeback to `dirty_expire_centisecs` (30 s by default) and only
/// starts earlier when `dirty_background_ratio` is reached, which on a host
/// with a lot of RAM is far above one artifact. The single `flushSync()` on
/// close therefore used to pay for the whole download alone — measured on the
/// reference arm64 host, a 1.62 GB artifact transferred in 36.0 s and then
/// spent 23.8 s in one fsync with an idle network, and the end-to-end install
/// landed at 27.1 MB/s against a 45-54 MB/s disk.
///
/// Flushing every 64 MiB moves that cost inside the transfer, and the install
/// then costs about `max(network, disk)` instead of their sum — but only if the
/// flush does not stop the writer. An fsync of one window takes about as long as
/// reading one window takes to arrive (~1.2 s against ~1.3 s per 64 MiB on the
/// reference host), so a synchronous flush simply re-serialized the two phases:
/// read a window, fsync it, read the next, and the end-to-end stayed at their
/// sum while every window paid a round trip. Writeback is therefore forced out
/// by a separate isolate (see [_flusherMain]) while the writer keeps writing,
/// and the writer is held to at most two windows ahead of the last completed
/// flush (`canAccept` in [_FlushGovernor]) so the dirty page cache stays bounded
/// — about 128 MiB — whatever the artifact size.
const int kSttFlushWindowBytes = 64 * 1024 * 1024;

/// Accepts artifact bytes and writes them without blocking the reader.
///
/// Contract:
/// * [add] returns once the bytes are accepted or once the window has room;
///   it never waits for the disk unless the window is full.
/// * [drain] returns when everything already added has been written; writeback
///   may still be in flight, so [close] is the durability boundary.
/// * [close] drains, waits for any running writeback, forces the remainder out
///   and closes the destination, and is idempotent. It is the right call from a
///   `finally`: on cancel the bytes already accepted still land, which is what
///   makes a resumed install continue from a real prefix.
/// * Page cache is forced out every [kSttFlushWindowBytes] of written bytes
///   *without* stopping the writer, so the kernel cannot defer the whole
///   artifact to the close flush and the disk still overlaps the socket.
/// * The writer never runs more than two windows ahead of the last **completed**
///   writeback: past that it waits, which bounds the dirty page cache at any
///   artifact size and paces the read to a disk that is slower than the link.
/// * A write or flush failure surfaces as [SttWriteFailure] from [add],
///   [drain] or [close] — never as a silently short file.
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
  final _WriteWindow _window = _WriteWindow();
  SttWriteFailure? _failure;
  Isolate? _isolate;
  Isolate? _flusher;
  bool _closing = false;
  bool _done = false;

  static Future<SttWritePipeline> open(
    File file,
    FileMode mode, {
    int flushWindowBytes = kSttFlushWindowBytes,
  }) async {
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
      <Object>[inbox.sendPort, file.path, mode == FileMode.append, flushWindowBytes],
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
    await pipeline._startFlusher(file.path);
    return pipeline;
  }

  /// Starts the isolate that owns writeback, wired to this writer directly.
  ///
  /// It is spawned from here rather than from the writer so this pipeline owns
  /// both isolates and can end either of them: a nested isolate would outlive a
  /// killed writer. It acks to the writer's own channel, so a completion never
  /// travels through the reader's isolate.
  Future<void> _startFlusher(String path) async {
    final exit = ReceivePort();
    try {
      _flusher = await Isolate.spawn(
        _flusherMain,
        <Object>[_commands, path],
        onExit: exit.sendPort,
        errorsAreFatal: true,
      );
    } on Object {
      exit.close();
      _isolate?.kill(priority: Isolate.immediate);
      _inbox.close();
      rethrow;
    }
    exit.listen((Object? _) {
      exit.close();
      if (_done || _closing) return;
      // Writeback stopped while the artifact was still being written: the page
      // cache is no longer bounded by anything, so this is a failed install.
      _fail(const SttWriteFailure('the download flusher exited unexpectedly'));
      _finishClosing();
    });
  }

  void _onMessage(Object? message) {
    if (message is int) {
      _window.release(message);
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

  void _fail(SttWriteFailure failure) {
    _failure ??= failure;
    _window.wakeAll();
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
    final source = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    for (var offset = 0; offset < source.length;) {
      final take = source.length - offset < kSttWriteWindowBytes
          ? source.length - offset
          : kSttWriteWindowBytes;
      await _window.reserve(take);
      _throwIfFailed();
      if (_done) return;
      _window.accept(take);
      // A copy: the caller may reuse its buffer as soon as this returns, and the
      // writer isolate gets its own memory either way.
      _commands.send(
        Uint8List.fromList(Uint8List.sublistView(source, offset, offset + take)),
      );
      offset += take;
    }
  }

  @override
  Future<void> drain() async {
    _throwIfFailed();
    await _window.idle();
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
    // The flusher ends on the writer's `exit`; this is the net for the paths
    // where the writer never got that far.
    _flusher?.kill(priority: Isolate.immediate);
    _flusher = null;
    _throwIfFailed();
  }
}

/// The writeback rule both pipelines obey.
///
/// It answers exactly two questions, and the answers are the whole contract:
///
/// * **When is writeback due?** Every [window] bytes written, counted from the
///   last flush *issued* — and at most one request in flight plus one
///   remembered, so a slow disk coalesces instead of queueing a flush per
///   window.
/// * **May the writer keep writing?** Only while it stays within two windows of
///   the last **completed** flush ([canAccept]). Past that the caller must wait
///   for a completion, which is what bounds the dirty page cache and, when the
///   disk is slower than the link, turns a fast read into backpressure.
///
/// [window] is [kSttFlushWindowBytes] everywhere except the in-process test seam,
/// which injects a small one to observe cadence and bounds without writing
/// 256 MiB per assertion.
class _FlushGovernor {
  _FlushGovernor({required this.onRequest, this.window = kSttFlushWindowBytes})
    : assert(window > 0, 'a flush window must accept at least one byte');

  final int window;

  /// Starts one writeback. Called at most once at a time by this owner.
  final void Function() onRequest;

  int _written = 0;
  int _flushedAt = 0;
  int? _inFlightAt;
  bool _pending = false;
  Completer<void>? _idle;

  /// Whether a writeback the owner started has not completed yet.
  bool get flushInFlight => _inFlightAt != null;

  /// Bytes written since the last writeback completed.
  int get unflushedBytes => _written - _flushedAt;

  /// Whether a further [bytes] stay inside the two-window bound.
  bool canAccept(int bytes) => _written + bytes - _flushedAt <= 2 * window;

  /// Accounts one write that landed and requests writeback when it is due.
  void wrote(int bytes) {
    _written += bytes;
    final inFlight = _inFlightAt;
    if (inFlight == null) {
      if (_written - _flushedAt >= window) {
        _inFlightAt = _written;
        onRequest();
      }
    } else if (_written - inFlight >= window) {
      // One remembered request, never a queue: the completion below decides
      // whether it is still due.
      _pending = true;
    }
  }

  /// Accounts a writeback the destination completed.
  ///
  /// The request point is what counts as durable, not the current write count:
  /// bytes written while the flush ran may or may not have been covered by it,
  /// so they are treated as unflushed. That keeps the bound honest.
  void completed() {
    final at = _inFlightAt;
    if (at != null && at > _flushedAt) _flushedAt = at;
    _inFlightAt = null;
    if (_pending) {
      _pending = false;
      if (_written - _flushedAt >= window) {
        _inFlightAt = _written;
        onRequest();
      }
    }
    _completeIdle();
  }

  /// Abandons a running request: the destination failed, so there is nothing to
  /// wait for and nobody may stay blocked on it.
  void abandoned() {
    _inFlightAt = null;
    _pending = false;
    _completeIdle();
  }

  /// Completes when no writeback is in flight (including one that a completion
  /// immediately re-arms).
  Future<void> idle() async {
    while (flushInFlight) {
      final idle = Completer<void>();
      _idle = idle;
      await idle.future;
    }
  }

  void _completeIdle() {
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }
}

class _RoomWaiter {
  _RoomWaiter(this.size);

  final int size;
  final Completer<void> completer = Completer<void>();
}

/// The byte window both pipelines share.
///
/// One rule, in one place: the reader may run at most [kSttWriteWindowBytes]
/// ahead of the disk. Callers **reserve** room before accepting bytes and
/// **release** it when the write completes, and a chunk is split into
/// window-sized pieces first — a socket hands over whatever it has buffered,
/// which after a pause is megabytes, so checking `queued + chunk.length` once
/// per call both over-admits such a chunk and deadlocks on one bigger than the
/// window itself, since no completion could ever make room for it.
class _WriteWindow {
  final List<_RoomWaiter> _room = <_RoomWaiter>[];
  Completer<void>? _idle;
  int _queued = 0;

  /// Bytes accepted but not yet written.
  int get queuedBytes => _queued;

  /// Waits until [size] bytes fit; [size] never exceeds the window.
  Future<void> reserve(int size) async {
    assert(size <= kSttWriteWindowBytes, 'a piece larger than the window');
    while (_queued + size > kSttWriteWindowBytes) {
      final waiter = _RoomWaiter(size);
      _room.add(waiter);
      await waiter.completer.future;
    }
  }

  /// Accounts [size] accepted bytes.
  void accept(int size) => _queued += size;

  /// Accounts [size] written bytes and wakes whatever now fits.
  void release(int size) {
    _queued -= size;
    if (_queued < 0) _queued = 0;
    _wake();
  }

  /// Completes when nothing is queued.
  Future<void> idle() async {
    if (_queued == 0) return;
    final idle = Completer<void>();
    _idle = idle;
    await idle.future;
  }

  /// Wakes every waiter: the transfer failed, so nobody should keep waiting.
  void wakeAll() {
    for (final waiter in _room) {
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    _room.clear();
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  void _wake() {
    while (_room.isNotEmpty &&
        _queued + _room.first.size <= kSttWriteWindowBytes) {
      final waiter = _room.removeAt(0);
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    if (_queued == 0) {
      final idle = _idle;
      _idle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }
}

/// The writer isolate: one destination, one ack per written piece.
///
/// A write and an fsync are both blocking syscalls on the calling isolate's own
/// thread, so doing both here would serialize them again: the reader would stop
/// for the length of every flush. Writeback is therefore forced out by
/// [_flusherMain] — a second isolate, its own handle of the same file — and this
/// isolate keeps writing while that runs. Past two windows of unflushed bytes it
/// stops acking instead (the backlog below), which is what keeps the dirty page
/// cache bounded and paces the read to a slow disk.
void _writerMain(List<Object> args) {
  _IsolateWriter(
    args[0] as SendPort,
    args[1] as String,
    args[2] as bool,
    args[3] as int,
  ).run();
}

/// The write half of one artifact, inside the writer isolate.
class _IsolateWriter {
  _IsolateWriter(this._inbox, this._path, this._append, this._window);

  final SendPort _inbox;
  final String _path;
  final bool _append;
  final int _window;

  late final _FlushGovernor _flush = _FlushGovernor(
    window: _window,
    onRequest: _requestFlush,
  );
  ReceivePort? _commands;
  RandomAccessFile? _file;
  SendPort? _flusher;

  /// Pieces accepted from the reader that the two-window bound refused so far.
  ///
  /// They are already copied and owned here, so holding them is not a second
  /// queue of the artifact: the reader cannot send more once its 4 MiB window is
  /// full, which bounds this list to one window.
  final List<Uint8List> _backlog = <Uint8List>[];
  bool _flushWanted = false;
  bool _closeRequested = false;
  bool _finished = false;

  void run() {
    final commands = ReceivePort();
    _commands = commands;
    _inbox.send(commands.sendPort);
    try {
      _file = File(_path).openSync(
        mode: _append ? FileMode.append : FileMode.write,
      );
    } on FileSystemException catch (error) {
      _report(error.message, error.osError?.errorCode, error.osError?.message);
      commands.close();
      return;
    }
    commands.listen(_onMessage);
  }

  void _onMessage(Object? message) {
    if (message is Uint8List) {
      _accept(message);
      return;
    }
    if (message is SendPort) {
      // The flusher's command channel, handed over once it opened its handle.
      _flusher = message;
      if (_flushWanted) {
        _flushWanted = false;
        message.send('flush');
      }
      return;
    }
    if (message is String) {
      if (message == 'flushed') {
        _flush.completed();
        _resume();
        _maybeFinish();
      } else if (message == 'close') {
        _closeRequested = true;
        _resume();
        _maybeFinish();
      }
      return;
    }
    if (message is List) {
      // The flusher could not force writeback: the same typed failure a refused
      // write is, so it travels to the store through the same channel.
      _reportMessage(message);
      _stop();
    }
  }

  void _accept(Uint8List piece) {
    if (_finished) return;
    if (!_flush.canAccept(piece.length)) {
      // Two windows ahead of the last completed writeback: this piece waits here
      // and the reader gets no ack until a flush lands, which is the throttle.
      _backlog.add(piece);
      return;
    }
    _write(piece);
  }

  /// Writes whatever the bound now allows, in arrival order.
  void _resume() {
    while (!_finished &&
        _backlog.isNotEmpty &&
        _flush.canAccept(_backlog.first.length)) {
      _write(_backlog.removeAt(0));
    }
  }

  void _write(Uint8List piece) {
    try {
      _file!.writeFromSync(piece);
    } on FileSystemException catch (error) {
      _report(error.message, error.osError?.errorCode, error.osError?.message);
      _stop();
      return;
    }
    // Acked as soon as the bytes are in the page cache: writeback is somebody
    // else's thread, so the reader is never stopped for the length of an fsync.
    _inbox.send(piece.length);
    _flush.wrote(piece.length);
  }

  void _requestFlush() {
    final flusher = _flusher;
    if (flusher == null) {
      _flushWanted = true;
      return;
    }
    flusher.send('flush');
  }

  void _maybeFinish() {
    if (!_closeRequested || _finished) return;
    _resume();
    if (_backlog.isNotEmpty || _flush.flushInFlight) return;
    // Durability is unchanged: everything is written, no writeback is running,
    // and this last fsync now only covers what the periodic flushes left (under
    // one window). A torn `.partial` is still caught by the resume re-read.
    try {
      _file!.flushSync();
    } on FileSystemException {
      // Closing already loses nothing a flush could have saved.
    }
    try {
      _file!.closeSync();
    } on FileSystemException {
      // A handle that will not close is already unusable.
    }
    _flusher?.send('exit');
    _inbox.send('closed');
    _stop(closed: true);
  }

  void _stop({bool closed = false}) {
    if (_finished) return;
    _finished = true;
    if (!closed) {
      try {
        _file?.closeSync();
      } on FileSystemException {
        // Already unusable, and the failure is what is being reported.
      }
      _flusher?.send('exit');
    }
    _commands?.close();
  }

  void _report(String message, int? code, String? osMessage) =>
      _reportMessage(<Object?>['error', message, code, osMessage]);

  void _reportMessage(List<Object?> message) => _inbox.send(message);
}

/// The flusher isolate: forces page cache out while the writer keeps writing.
///
/// It opens its own handle of the same path — append mode, so opening it can
/// never truncate the artifact the writer is producing — because an
/// `RandomAccessFile` is not sendable and needs no handoff: `fsync` on any
/// descriptor of a file flushes that file's dirty pages. It is a separate
/// isolate rather than an async `flush()` on the writer's handle because an
/// async file call is serviced by the same IO isolate a synchronous write waits
/// on, so the two would still queue behind each other. Two isolates are two OS
/// threads.
void _flusherMain(List<Object> args) {
  final writer = args[0] as SendPort;
  final path = args[1] as String;
  final commands = ReceivePort();
  RandomAccessFile? file;
  try {
    file = File(path).openSync(mode: FileMode.append);
  } on FileSystemException catch (error) {
    writer.send(<Object?>[
      'flush error',
      error.message,
      error.osError?.errorCode,
      error.osError?.message,
    ]);
    commands.close();
    return;
  }
  writer.send(commands.sendPort);
  commands.listen((Object? message) {
    if (message == 'flush') {
      try {
        file!.flushSync();
        writer.send('flushed');
      } on FileSystemException catch (error) {
        writer.send(<Object?>[
          'flush error',
          error.message,
          error.osError?.errorCode,
          error.osError?.message,
        ]);
        commands.close();
      }
      return;
    }
    if (message == 'exit') {
      try {
        file!.closeSync();
      } on FileSystemException {
        // A handle that will not close is already unusable.
      }
      commands.close();
    }
  });
}

/// Same contract, in-process: the seam unit tests drive.
///
/// It exists so a test can inject a [SttWriteSink] that stalls, counts, or
/// fails while the *shipped* writeback rule ([_FlushGovernor]) still runs.
/// Production never takes this path, but the rule is the same one the writer and
/// flusher isolates implement — including the overlap: [SttWriteSink.flush] is
/// started and not awaited, and the two-window bound is what stops the pump.
class InProcessWritePipeline implements SttWritePipeline {
  InProcessWritePipeline(
    this._sink, {
    int flushWindowBytes = kSttFlushWindowBytes,
  }) : _flushWindowBytes = flushWindowBytes;

  final SttWriteSink _sink;
  final int _flushWindowBytes;
  late final _FlushGovernor _flush = _FlushGovernor(
    window: _flushWindowBytes,
    onRequest: _startFlush,
  );
  final _WriteWindow _window = _WriteWindow();
  final List<Uint8List> _pending = <Uint8List>[];
  final List<Completer<void>> _room = <Completer<void>>[];
  Object? _failure;
  bool _closed = false;
  bool _pumping = false;

  /// Bytes accepted but not yet written; the test's window probe.
  int get queuedBytes => _window.queuedBytes;

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

  /// Starts writeback and returns without waiting for it.
  ///
  /// This is the whole point of the shape: the pump releases the reader's window
  /// right after the write, so an fsync never becomes a pause in the socket. A
  /// failure still has to stop the pipeline, so it is recorded and every waiter
  /// is released.
  void _startFlush() {
    unawaited(
      _sink.flush().then(
        (_) {
          _flush.completed();
          _wakeRoom();
        },
        onError: (Object error) {
          _failure ??= _asFailure(error);
          _flush.abandoned();
          _window.wakeAll();
          _wakeRoom();
        },
      ),
    );
  }

  void _wakeRoom() {
    for (final waiter in _room) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _room.clear();
  }

  /// Waits until the two-window bound allows [bytes] more.
  Future<void> _awaitRoom(int bytes) async {
    while (_failure == null && !_flush.canAccept(bytes)) {
      final waiter = Completer<void>();
      _room.add(waiter);
      await waiter.future;
    }
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
    try {
      while (_pending.isNotEmpty) {
        final bytes = _pending.removeAt(0);
        try {
          if (_failure == null) await _awaitRoom(bytes.length);
          if (_failure == null) {
            await _sink.writeFrom(bytes);
            // Requested, not awaited: writeback overlaps the next writes, and
            // the bound in the governor is what keeps it from running away.
            _flush.wrote(bytes.length);
          }
        } on Object catch (error) {
          _failure ??= _asFailure(error);
          _flush.abandoned();
          _window.wakeAll();
          _wakeRoom();
        } finally {
          _window.release(bytes.length);
        }
      }
    } finally {
      // Also on an unexpected throw: a pump left marked as running would never
      // restart, and every later `add` would queue bytes nobody writes.
      _pumping = false;
    }
  }

  @override
  Future<void> add(List<int> chunk) async {
    _throwIfFailed();
    if (chunk.isEmpty || _closed) return;
    final source = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    for (var offset = 0; offset < source.length;) {
      final take = source.length - offset < kSttWriteWindowBytes
          ? source.length - offset
          : kSttWriteWindowBytes;
      await _window.reserve(take);
      _throwIfFailed();
      if (_closed) return;
      _window.accept(take);
      // Copied because the caller may reuse its buffer as soon as `add` returns
      // and the write happens after that.
      _pending.add(
        Uint8List.fromList(
          Uint8List.sublistView(source, offset, offset + take),
        ),
      );
      unawaited(_pump());
      offset += take;
    }
  }

  @override
  Future<void> drain() async {
    _throwIfFailed();
    await _window.idle();
    _throwIfFailed();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _window.idle();
    try {
      // The sink is closed even when a write already failed: a refused write
      // must not leak the handle the next attempt resumes from.
      if (_failure == null) {
        // A writeback still running is this artifact's own data: waiting for it
        // here is what makes the final flush, and the digest comparison that
        // follows, describe bytes the disk has.
        await _flush.idle();
        await _sink.flush();
      }
      await _sink.close();
    } on Object catch (error) {
      _failure ??= _asFailure(error);
      _flush.abandoned();
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
  _FileWriteSink(this._handle, this._flushHandle);

  final RandomAccessFile _handle;

  /// A second handle for writeback, like the production flusher isolate holds.
  ///
  /// `RandomAccessFile` refuses a second concurrent async operation, so an
  /// fsync on the writing handle would make the very next write fail with `An
  /// async operation is currently pending`. Two handles is also the shipped
  /// shape.
  final RandomAccessFile _flushHandle;

  @override
  Future<void> writeFrom(List<int> bytes) => _handle.writeFrom(bytes);

  @override
  Future<void> flush() => _flushHandle.flush();

  @override
  Future<void> close() async {
    try {
      await _flushHandle.close();
    } finally {
      await _handle.close();
    }
  }
}

/// The plain file sink: two `RandomAccessFile`s, writes and writeback apart.
Future<SttWriteSink> openFileWriteSink(File file, FileMode mode) async =>
    _FileWriteSink(
      await file.open(mode: mode),
      await file.open(mode: FileMode.append),
    );

/// In-process pipeline for tests and for callers that already hold a sink.
SttWritePipelineFactory inProcessPipeline([
  SttWriteSinkOpener opener = openFileWriteSink,
]) => (file, mode) async => InProcessWritePipeline(await opener(file, mode));


/// Keeps the smallest window above one chunk so a large chunk still fits.
int get effectiveWindowBytes =>
    math.max(kSttWriteWindowBytes, 64 * 1024);
