/// The two bounds of a dictation model write.
///
/// `stt_download_pipeline.dart` reads a socket into a file, and this file owns the
/// two numbers that decide how: the **write window** — how many accepted bytes may
/// wait ahead of the disk, which is PR391's memory bound — and the **writeback
/// rule**, which decides when page cache is forced out and how far the writer may
/// run ahead of it.
///
/// Both are shared by the shipped isolate pipeline and by the in-process seam the
/// unit tests drive, so the rule has exactly one owner.
library;

import 'dart:async';

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
/// by a separate flusher isolate (`stt_download_pipeline.dart`) while the
/// writer keeps writing,
/// and the writer is held to at most two windows ahead of the last completed
/// flush (`canAccept` in [SttFlushGovernor]) so the dirty page cache stays bounded
/// — about 128 MiB — whatever the artifact size.
const int kSttFlushWindowBytes = 64 * 1024 * 1024;

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
class SttFlushGovernor {
  SttFlushGovernor({required this.onRequest, this.window = kSttFlushWindowBytes})
    : assert(window > 0, 'a flush window must accept at least one byte');

  final int window;

  /// Starts one writeback. Called at most once at a time by this owner.
  final void Function() onRequest;

  int _written = 0;
  int _flushedAt = 0;
  int? _inFlightAt;
  bool _pending = false;
  bool _disabled = false;
  Completer<void>? _idle;

  /// Whether a writeback the owner started has not completed yet.
  bool get flushInFlight => _inFlightAt != null;

  /// Bytes written since the last writeback completed.
  int get unflushedBytes => _written - _flushedAt;

  /// Whether a further [bytes] stay inside the two-window bound.
  bool canAccept(int bytes) =>
      _disabled || _written + bytes - _flushedAt <= 2 * window;

  /// Turns the rule off for good: nothing will complete a writeback.
  ///
  /// Used when the flusher has no handle — either this process could not spawn
  /// one or the platform refused it one. The bound goes with the request: a
  /// writer that kept two windows ahead of a writeback that can never complete
  /// would stall the transfer instead of just losing the overlap.
  void disable() {
    if (_disabled) return;
    _disabled = true;
    _inFlightAt = null;
    _pending = false;
    _completeIdle();
  }

  /// Accounts one write that landed and requests writeback when it is due.
  void wrote(int bytes) {
    if (_disabled) return;
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
class SttWriteWindow {
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


