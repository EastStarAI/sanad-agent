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

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'stt_write_bounds.dart';

/// The two bounds own their own file; they stay reachable from here because this
/// is the library the store and the tests import.
export 'stt_write_bounds.dart'
    show SttFlushGovernor, SttWriteWindow, kSttFlushWindowBytes, kSttWriteWindowBytes;


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
/// * [close] is also the **handle** boundary: when it returns, every descriptor
///   this artifact opened is closed — including on a failure path — so the caller
///   may delete or rename the `.partial` immediately. Windows refuses both while
///   any handle is open, and neither killing an isolate nor dropping a reference
///   releases one, so the handles are closed by their own isolates and awaited.
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
  final Logger _logger = Logger('SttWritePipeline');
  final SttWriteWindow _window = SttWriteWindow();

  /// The flusher's command channel, once it has one.
  ///
  /// It is sent to this pipeline as well as to the writer so the artifact can be
  /// closed from here: a killed isolate releases nothing (Dart closes a file only
  /// from inside the isolate that opened it), so `close()` has to be able to ask
  /// the flusher, not only end it.
  SendPort? _flusherCommands;

  /// The flusher handoff has settled one way or another.
  ///
  /// The channel arrives asynchronously after [Isolate.spawn], so `close()` may
  /// run before it does. That is **not** the same as "there is no flusher handle":
  /// deciding on the absence of the port is what stranded descriptors. This
  /// completes when the channel arrives, when the flusher reports that it has no
  /// handle, when it exits, or when it was never spawned at all.
  final Completer<void> _flusherReady = Completer<void>();

  /// The flusher closed its own handle (`'gone'`), or is gone entirely.
  final Completer<void> _flusherClosed = Completer<void>();

  /// The flusher isolate has ended.
  ///
  /// Kept apart from [_flusherClosed] on purpose: the handle is closed first and
  /// the isolate ends after it, so only this one proves the process no longer
  /// runs that thread.
  final Completer<void> _flusherExited = Completer<void>();

  /// The writer isolate has ended, whatever the reason.
  final Completer<void> _writerExited = Completer<void>();

  SttWriteFailure? _failure;
  Isolate? _isolate;
  Isolate? _flusher;
  bool _closing = false;
  bool _done = false;
  bool _writebackUnavailable = false;

  /// The one teardown, shared by every caller of [close].
  Future<void>? _teardown;
  bool _tornDown = false;

  /// [writeback] is `false` only for the seam that proves a platform refusing
  /// the background handle does not fail an install: the flusher is still
  /// spawned, and it reports that its own `open` was refused.
  ///
  /// The return type is the concrete pipeline rather than [SttWritePipeline] so a
  /// caller that owns one can observe its lifecycle; it is still a valid
  /// [SttWritePipelineFactory], which is what the store assigns it to.
  static Future<IsolateWritePipeline> open(
    File file,
    FileMode mode, {
    int flushWindowBytes = kSttFlushWindowBytes,
    @visibleForTesting bool writeback = true,
  }) async {
    final inbox = ReceivePort();
    final closed = Completer<void>();
    final ready = Completer<SendPort>();
    late IsolateWritePipeline pipeline;
    inbox.listen((Object? message) {
      if (message is SendPort) {
        // The writer hands over its command channel, then the flusher hands over
        // its own: the first one completes the open, every later one is the
        // flusher (spawned after this pipeline exists).
        if (!ready.isCompleted) {
          ready.complete(message);
        } else {
          pipeline._onFlusherChannel(message);
        }
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
      if (!pipeline._writerExited.isCompleted) {
        pipeline._writerExited.complete();
      }
    });
    final commands = await ready.future;
    pipeline = IsolateWritePipeline._(commands, inbox, closed);
    pipeline._isolate = isolate;
    await pipeline._startFlusher(file.path, refuseOpen: !writeback);
    return pipeline;
  }

  /// Starts the isolate that owns writeback, wired to this writer directly.
  ///
  /// It is spawned from here rather than from the writer so this pipeline owns
  /// both isolates and can end either of them: a nested isolate would outlive a
  /// killed writer. It acks a completion to the writer's own channel, so a
  /// completion never travels through the reader's isolate, and hands its command
  /// channel to this pipeline as well, which is what lets [close] ask it to close
  /// its handle instead of only killing it.
  Future<void> _startFlusher(String path, {bool refuseOpen = false}) async {
    final exit = ReceivePort();
    final Isolate flusher;
    try {
      flusher = await Isolate.spawn(
        _flusherMain,
        <Object>[_commands, path, refuseOpen, _inbox.sendPort],
        onExit: exit.sendPort,
        errorsAreFatal: true,
      );
    } on Object catch (error) {
      // A platform that will not give the flusher a thread is a slow install, not
      // a broken one: keep writing, force everything at close. There is no flusher
      // to wait for, so every flusher state is settled now.
      exit.close();
      _settleFlusher(settle: _FlusherState.all);
      _degradeWriteback('$error');
      return;
    }
    _flusher = flusher;
    exit.listen((Object? _) {
      exit.close();
      // No handle can outlive a flusher that ended, and no thread either.
      _settleFlusher(settle: _FlusherState.all);
      if (_done || _closing || _writebackUnavailable) return;
      // Writeback stopped while the artifact was still being written: the page
      // cache is no longer bounded by anything, so this is a failed install.
      _fail(const SttWriteFailure('the download flusher exited unexpectedly'));
      _finishClosing();
    });
  }

  /// The flusher's command channel arrived: it has a handle (or, on a refused
  /// open, it still takes commands and will answer them).
  void _onFlusherChannel(SendPort commands) {
    _flusherCommands = commands;
    _settleFlusher(settle: _FlusherState.ready);
  }

  /// Completes the flusher state that has become true, once each.
  void _settleFlusher({required _FlusherState settle}) {
    if (!_flusherReady.isCompleted) _flusherReady.complete();
    if (settle == _FlusherState.ready) return;
    if (!_flusherClosed.isCompleted) _flusherClosed.complete();
    if (!_flusherExited.isCompleted) _flusherExited.complete();
  }

  void _onMessage(Object? message) {
    if (message is int) {
      _window.release(message);
      return;
    }
    if (message is String) {
      if (message == 'closed') {
        _finishClosing();
      } else if (message == 'gone') {
        // The flusher closed its own handle: no kill can do that for it.
        _settleFlusher(settle: _FlusherState.handle);
      }
      return;
    }
    if (message is List) {
      if (message.isNotEmpty && message.first == 'flush unavailable') {
        // The platform refused the background handle. That is not this install's
        // failure: log it once and stay on the close-only flush.
        _degradeWriteback(
          message.length > 2
              ? '${message[2]}'
              : '${message.length > 1 ? message[1] : 'unknown'}',
        );
        return;
      }
      _fail(
        SttWriteFailure(
          message.length > 1 ? '${message[1]}' : 'write failed',
          message.length > 2 ? message[2] as int? : null,
          message.length > 3 ? '${message[3]}' : null,
        ),
      );
    }
  }

  /// Keeps installing without background writeback.
  ///
  /// The flush is an optimisation, not a requirement: the artifact is written and
  /// acknowledged exactly as before, `close()` forces all of it out on the
  /// writer's own handle, and durability is unchanged. Only the overlap is lost,
  /// which is the behaviour before this pipeline forced writeback at all — on a
  /// platform that will not give the flusher a second handle of the `.partial`.
  void _degradeWriteback(String reason) {
    if (_writebackUnavailable) return;
    _writebackUnavailable = true;
    // The writer drops its bound and stops requesting; anything it already
    // queued is written straight through.
    _commands.send('no writeback');
    _logger.info(
      'dictation download: background writeback unavailable ($reason), '
      'using close-only flush',
    );
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
  Future<void> close() {
    // One teardown, shared by every caller. A caller that arrives while it runs
    // waits for the same handles to be closed — including the flusher's, which is
    // what makes the caller's own delete or rename safe — and one that arrives
    // after it settled gets a no-op: the failure belongs to the close that ran it.
    if (_tornDown) return Future<void>.value();
    final active = _teardown;
    if (active != null) {
      return active.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    return _teardown = _teardownOnce().whenComplete(() => _tornDown = true);
  }

  /// The one teardown: every handle closed, both isolates ended, then the
  /// recorded failure rethrown.
  Future<void> _teardownOnce() async {
    _closing = true;
    // A writer that already ended closes its own handle on its way out (see
    // `_stop`/`_maybeFinish`); one that is still running is asked to finish.
    if (!_writerExited.isCompleted) _commands.send('close');
    await _closed.future;
    // The handoff settles before anything is decided about the flusher. Its
    // channel can still be in flight when `close()` is called, and "not here
    // yet" is not "no handle": reading the port once and giving up is exactly
    // what stranded an append descriptor on every immediate cancel.
    await _flusherReady.future;
    final flusher = _flusherCommands;
    if (flusher != null && !_flusherClosed.isCompleted) {
      flusher.send('exit');
      await _flusherClosed.future;
    }
    // The descriptor lives in the isolate, so only its exit proves nothing is
    // left holding the artifact open.
    await _flusherExited.future;
    await _writerExited.future;
    _inbox.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    // The net for a flusher that never took a command channel. A kill releases
    // nothing, so this only ends a thread that has nothing left to close.
    _flusher?.kill(priority: Isolate.immediate);
    _flusher = null;
    _throwIfFailed();
  }

  /// Completes when the writer isolate has ended, whatever the reason.
  ///
  /// A guard needs the state `close()` sees after a failed writer, and a delay
  /// cannot establish it: this is that exact lifecycle event.
  @visibleForTesting
  Future<void> get writerIsolateExited => _writerExited.future;

  /// Whether the flusher isolate has ended **at this instant**.
  ///
  /// [close] waits for it, so this is already true when [close] returns. A future
  /// cannot answer that question: awaiting one yields to the event loop, which is
  /// exactly the turn the exit event would arrive in anyway.
  @visibleForTesting
  bool get flusherIsolateEnded => _flusherExited.isCompleted;

  /// Whether the writer isolate has ended at this instant.
  @visibleForTesting
  bool get writerIsolateEnded => _writerExited.isCompleted;
}

/// How far the flusher handoff has got.
enum _FlusherState {
  /// The command channel arrived; the isolate may still hold a handle.
  ready,

  /// The handle is closed, but the isolate may still be running.
  handle,

  /// Nothing is left: no handle and no isolate running.
  all,
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

  late final SttFlushGovernor _flush = SttFlushGovernor(
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
      } else if (message == 'no writeback') {
        // No flusher handle exists: nothing will ever complete a writeback, so
        // holding two windows ahead of one would only stall the transfer.
        _flush.disable();
        _resume();
        _maybeFinish();
      }
      return;
    }
    if (message is List) {
      if (message.isNotEmpty && message.first == 'flush unavailable') {
        _flush.disable();
        _inbox.send(message);
        _resume();
        _maybeFinish();
        return;
      }
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
///
/// Its handle is closed here, on every path it can take: nothing outside this
/// isolate can close it — not even killing the isolate, which leaves the
/// descriptor open — so a flush failure closes it before exiting and an `exit`
/// closes it before reporting back to the pipeline that asked.
void _flusherMain(List<Object> args) {
  final writer = args[0] as SendPort;
  final path = args[1] as String;
  final refuseOpen = args.length > 2 && args[2] == true;
  final owner = args.length > 3 ? args[3] as SendPort? : null;
  final commands = ReceivePort();
  RandomAccessFile? file;
  try {
    if (refuseOpen) {
      throw FileSystemException(
        'the background handle was refused',
        path,
        const OSError('Operation not permitted', 1),
      );
    }
    file = File(path).openSync(mode: FileMode.append);
  } on FileSystemException catch (error) {
    // Stay alive without a handle. Exiting here would look like a mid-transfer
    // crash to the parent; the write itself is unaffected, so this is only the
    // loss of the overlap. The parent drops its bound and `close()` forces the
    // rest out on the writer's own handle.
    writer.send(<Object?>[
      'flush unavailable',
      error.message,
      error.osError?.errorCode,
      error.osError?.message,
    ]);
  }
  final handle = file;
  if (handle != null) {
    writer.send(commands.sendPort);
  }
  // The same channel to the pipeline that owns this isolate, whether or not it
  // got a handle: it can then ask for the handle to be closed rather than only
  // ending the isolate, and it always learns that the handoff happened.
  owner?.send(commands.sendPort);

  /// Closes the writeback handle once and tells the owner it is gone.
  void release() {
    try {
      handle?.closeSync();
    } on FileSystemException {
      // A handle that will not close is already unusable.
    }
    owner?.send('gone');
  }

  commands.listen((Object? message) {
    if (message == 'flush') {
      if (handle == null) return;
      try {
        handle.flushSync();
        writer.send('flushed');
      } on FileSystemException catch (error) {
        writer.send(<Object?>[
          'flush error',
          error.message,
          error.osError?.errorCode,
          error.osError?.message,
        ]);
        // The disk is gone, so nothing will be written back again, and this
        // isolate must not take its handle with it.
        release();
        commands.close();
      }
      return;
    }
    if (message == 'exit') {
      release();
      commands.close();
    }
  });
}

/// Same contract, in-process: the seam unit tests drive.
///
/// It exists so a test can inject a [SttWriteSink] that stalls, counts, or
/// fails while the *shipped* writeback rule ([SttFlushGovernor]) still runs.
/// Production never takes this path, but the rule is the same one the writer and
/// flusher isolates implement — including the overlap: [SttWriteSink.flush] is
/// started and not awaited, and the two-window bound is what stops the pump.
class InProcessWritePipeline implements SttWritePipeline {
  InProcessWritePipeline(
    this._sink, {
    int flushWindowBytes = kSttFlushWindowBytes,
    bool writeback = true,
  }) : _flushWindowBytes = flushWindowBytes {
    if (!writeback) _flush.disable();
  }

  final SttWriteSink _sink;
  final int _flushWindowBytes;
  late final SttFlushGovernor _flush = SttFlushGovernor(
    window: _flushWindowBytes,
    onRequest: _startFlush,
  );
  final SttWriteWindow _window = SttWriteWindow();
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
