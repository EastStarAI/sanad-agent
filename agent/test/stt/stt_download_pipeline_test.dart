// Contract tests for the bounded write half of a dictation model download.
//
// The store's own backpressure test proves the *download* stays bounded. This
// file proves the thing that made it unbounded while staying fast, which is the
// pipeline underneath it:
//
// 1. **The window is real.** A sink whose first write never returns must stop
//    the reader after `kSttWriteWindowBytes`; a bounded queue that is not
//    actually consulted is the whole defect back again.
// 2. **One write in flight.** The old `IOSink.add` defect was a fire-and-forget
//    sink; the pipeline must await each write before starting the next, so the
//    window measures bytes ahead of the disk, not bytes ahead of a queue.
// 3. **A refused write is typed.** `storage_full` is a different remedy from
//    `download_failed`, and the writer now reports failures from another
//    isolate, where a `FileSystemException` cannot cross. The store's mapping is
//    asserted end to end against a real loopback server rather than inferred.
// 4. **The page cache does not wait for close, and writeback does not stop the
//    writer.** Every `kSttFlushWindowBytes` of written bytes is forced out from
//    a second isolate while the writer keeps writing, so the reader is never
//    paused for an fsync and the kernel's deferred writeback cannot become one
//    serial tail at the end of the install (measured: 36.0 s transfer + 23.8 s
//    tail on a 1.62 GB artifact, and a synchronous flush only re-serialized the
//    two phases). The writer is held to two windows ahead of the last completed
//    flush, which is what bounds the dirty page cache and paces a slow disk.
// 5. **The isolate hop is the shipped one, and it is cheap.** The default
//    factory is asserted structurally, and the hop is timed against the same
//    file sink in-process so a regression that serialises on it shows up as a
//    ratio rather than as a slow download nobody measures again.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

const int _chunk = 64 * 1024;

Uint8List _block(int seed) {
  final bytes = Uint8List(_chunk);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (i + seed) & 0xFF;
  }
  return bytes;
}

/// Sink whose writes park until released, so the reader's backpressure is
/// observable instead of racing a fast disk.
class _GatedSink implements SttWriteSink {
  _GatedSink(this._handle);

  final RandomAccessFile _handle;
  final Completer<void> _gate = Completer<void>();
  final List<Completer<void>> _waiters = <Completer<void>>[];
  int writes = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  bool closed = false;

  /// Waits until [count] writes have started.
  Future<void> startedWrites(int count) {
    if (writes >= count) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<void> writeFrom(List<int> bytes) async {
    writes++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted && writes >= 1) waiter.complete();
    }
    _waiters.clear();
    try {
      await _gate.future;
      await _handle.writeFrom(bytes);
    } finally {
      inFlight--;
    }
  }

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() async {
    closed = true;
    await _handle.close();
  }
}

/// Sink that records concurrency and writes straight through.
class _CountingSink implements SttWriteSink {
  _CountingSink(this._handle);

  final RandomAccessFile _handle;
  int inFlight = 0;
  int maxInFlight = 0;
  int bytes = 0;

  @override
  Future<void> writeFrom(List<int> bytes) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await _handle.writeFrom(bytes);
      this.bytes += bytes.length;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() => _handle.close();
}

/// Sink that records forced writebacks, and can park or refuse one.
///
/// It holds two handles for the same reason the shipped flusher isolate does:
/// `RandomAccessFile` refuses a second concurrent async operation on one handle,
/// so an fsync and a write must not share it.
class _FlushingSink implements SttWriteSink {
  _FlushingSink._(this._handle, this._flushHandle, this.flushGate, this.failWith);

  static Future<_FlushingSink> open(
    File file, {
    Object? failWith,
    Completer<void>? flushGate,
  }) async => _FlushingSink._(
    await file.open(mode: FileMode.write),
    await file.open(mode: FileMode.append),
    flushGate,
    failWith,
  );

  final RandomAccessFile _handle;
  final RandomAccessFile _flushHandle;

  /// Thrown from [flush] instead of flushing.
  final Object? failWith;

  /// Parks [flush] until completed, so a caller's wait is observable.
  final Completer<void>? flushGate;

  int flushes = 0;
  int bytes = 0;

  @override
  Future<void> writeFrom(List<int> bytes) async {
    await _handle.writeFrom(bytes);
    this.bytes += bytes.length;
  }

  @override
  Future<void> flush() async {
    flushes++;
    final gate = flushGate;
    if (gate != null) await gate.future;
    final failure = failWith;
    if (failure != null) throw failure;
    await _flushHandle.flush();
  }

  @override
  Future<void> close() async {
    try {
      await _flushHandle.close();
    } finally {
      await _handle.close();
    }
  }
}

/// Sink that refuses every write the way a full volume does.
class _RefusingSink implements SttWriteSink {
  _RefusingSink(this._handle, this._error);

  final RandomAccessFile _handle;
  final Object _error;

  @override
  Future<void> writeFrom(List<int> bytes) async => throw _error;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() => _handle.close();
}

/// Every path this process currently has a descriptor on, as the OS reports it.
///
/// Windows exposes no descriptor table, so it contributes nothing here and its
/// guards use the rename probe in [_holdsOpenHandle] instead; Linux lists
/// `/proc/self/fd` and macOS prints one `n<path>` record per descriptor with
/// `lsof -F n`.
Future<List<String>> _descriptorTargets() async {
  if (Platform.isLinux) {
    final fds = Directory('/proc/self/fd');
    if (!fds.existsSync()) return const <String>[];
    final targets = <String>[];
    for (final entry in fds.listSync(followLinks: false)) {
      if (entry is! Link) continue;
      try {
        targets.add(entry.targetSync());
      } on FileSystemException {
        continue;
      }
    }
    return targets;
  }
  if (Platform.isMacOS) {
    final lsof = Process.runSync('lsof', <String>['-n', '-F', 'n', '-p', '$pid']);
    return '${lsof.stdout}'
        .split('\n')
        .where((String line) => line.startsWith('n') && line.length > 1)
        .map((String line) => line.substring(1))
        .toList();
  }
  return const <String>[];
}

/// Whether this process still holds an open descriptor on [path].
///
/// The property `close()` has to leave behind is the same everywhere — the
/// artifact can be renamed or deleted the moment it returns — but each platform
/// answers it through the channel it has. Windows refuses to delete or rename a
/// file that any handle has open, and a rename is used because it fails exactly
/// like a delete and can be undone; macOS and Linux are asked through their
/// descriptor table. A host that offers neither reports `false`, and the lane
/// that owns that platform still covers it.
Future<bool> _holdsOpenHandle(String path) async {
  if (!File(path).existsSync()) return false;
  final resolved = File(path).resolveSymbolicLinksSync();
  if (Platform.isWindows) {
    final probe = '$resolved.handle-probe';
    try {
      File(resolved).renameSync(probe);
    } on FileSystemException {
      return true;
    }
    File(probe).renameSync(resolved);
    return false;
  }
  return (await _descriptorTargets()).contains(resolved);
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('stt-pipeline-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('window', () {
    test('accepts a window of bytes and then waits for the disk', () async {
      final file = File('${dir.path}/window.bin');
      final sink = _GatedSink(await file.open(mode: FileMode.write));
      final pipeline = InProcessWritePipeline(sink);

      final blocks = kSttWriteWindowBytes ~/ _chunk;
      for (var i = 0; i < blocks; i++) {
        await pipeline.add(_block(i));
      }
      expect(
        pipeline.queuedBytes,
        kSttWriteWindowBytes,
        reason: 'the pipeline did not fill the window it advertises',
      );

      // The next chunk cannot be accepted while the window is full and the
      // sink has not returned from its first write.
      var accepted = false;
      final overflow = pipeline.add(_block(blocks)).whenComplete(() {
        accepted = true;
      });
      await sink.startedWrites(1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        accepted,
        isFalse,
        reason: 'the pipeline accepted bytes beyond kSttWriteWindowBytes',
      );
      expect(pipeline.queuedBytes, kSttWriteWindowBytes);

      sink.release();
      await overflow;
      expect(
        pipeline.queuedBytes,
        lessThanOrEqualTo(kSttWriteWindowBytes),
        reason: 'the queue grew past the window once the disk drained',
      );
      await pipeline.close();
      expect(sink.closed, isTrue);
    });

    test('never hands the sink two writes at once', () async {
      final file = File('${dir.path}/serial.bin');
      final sink = _CountingSink(await file.open(mode: FileMode.write));
      final pipeline = InProcessWritePipeline(sink);

      for (var i = 0; i < 48; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      await pipeline.close();

      expect(
        sink.maxInFlight,
        1,
        reason: 'the pipeline chained writes without awaiting the previous one',
      );
      expect(sink.bytes, 48 * _chunk);
      expect(file.lengthSync(), 48 * _chunk);
    });

    test('splits a chunk bigger than the window instead of taking it whole', () async {
      // The reader does not choose its chunk size. A socket hands over whatever
      // it has buffered — megabytes after a pause, and more on a Linux loopback
      // stack than on macOS — so a single `add` larger than the window must be
      // split. Taking it whole breaks the bound; waiting for room that can never
      // exist for it deadlocks the download, which is what a 4 MiB window and a
      // 13 MiB chunk did on CI.
      final file = File('${dir.path}/oversize.bin');
      final sink = _GatedSink(await file.open(mode: FileMode.write));
      final pipeline = InProcessWritePipeline(sink);
      final big = Uint8List(kSttWriteWindowBytes * 5 ~/ 2);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 13) & 0xFF;
      }

      var peak = pipeline.queuedBytes;
      final sampler = Timer.periodic(const Duration(milliseconds: 2), (_) {
        if (pipeline.queuedBytes > peak) peak = pipeline.queuedBytes;
      });
      try {
        final adding = pipeline.add(big);
        await sink.startedWrites(1);
        // Long enough for a bad implementation to accept the rest of the chunk.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          peak,
          lessThanOrEqualTo(kSttWriteWindowBytes),
          reason: 'the pipeline admitted ${peak ~/ 1024} KB of one '
              '${big.length ~/ 1024} KB chunk past a '
              '${kSttWriteWindowBytes ~/ 1024} KB window',
        );

        sink.release();
        await adding.timeout(const Duration(seconds: 30));
        await pipeline.drain();
        await pipeline.close();
      } finally {
        sampler.cancel();
      }

      expect(file.lengthSync(), big.length);
      expect(
        file.readAsBytesSync(),
        big,
        reason: 'the split pieces must land whole and in order',
      );
    });
  });

  group('flush', () {
    // Two chunks, so a window and the two-window bound are reachable with a few
    // hundred KB instead of the shipped 64 MiB. The rule is the same one.
    const int small = 2 * _chunk;

    test('forces writeback every window and once more at close', () async {
      final file = File('${dir.path}/flush.bin');
      final sink = await _FlushingSink.open(file);
      const int window = 4 * _chunk;
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: window);

      for (var i = 0; i < 10; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      expect(
        sink.flushes,
        2,
        reason: '10 chunks over a 4-chunk window is two forced writebacks',
      );

      await pipeline.close();
      expect(
        sink.flushes,
        3,
        reason: 'the tail after the last window is what close must force',
      );
      expect(sink.bytes, 10 * _chunk);
      expect(file.lengthSync(), 10 * _chunk);
    });

    test('a short artifact is flushed once, at close', () async {
      final file = File('${dir.path}/short.bin');
      final sink = await _FlushingSink.open(file);
      final pipeline = InProcessWritePipeline(sink);
      for (var i = 0; i < 3; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      expect(
        sink.flushes,
        0,
        reason:
            'the shipped flush window is ${kSttFlushWindowBytes ~/ (1024 * 1024)}'
            ' MiB, so a 192 KB artifact must not force writeback mid-transfer',
      );

      await pipeline.close();
      expect(sink.flushes, 1);
      expect(file.lengthSync(), 3 * _chunk);
    });

    test('keeps writing while writeback runs', () async {
      // The defect this shape exists for: an fsync on the writer's own thread
      // stops the writer, the 4 MiB window fills in a fraction of the flush, and
      // the phases become sequential again. Two chunks are written past the
      // window here while the flush is still parked.
      final file = File('${dir.path}/overlap.bin');
      final gate = Completer<void>();
      final sink = await _FlushingSink.open(file, flushGate: gate);
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: small);

      for (var i = 0; i < 4; i++) {
        await pipeline.add(_block(i));
      }
      // `drain` returns once everything handed over has been written; it does not
      // wait for writeback, which is exactly what the parked gate must survive.
      await pipeline.drain();
      expect(sink.flushes, 1, reason: 'one window is written, so one writeback');
      expect(
        sink.bytes,
        4 * _chunk,
        reason: 'the writer stopped at the first window while the flush ran',
      );

      gate.complete();
      await pipeline.drain();
      await pipeline.close();
      expect(file.lengthSync(), 4 * _chunk);
    });

    test('never runs more than two windows ahead of a completed writeback', () async {
      // Past two windows the reader gets no further ack, which is what bounds the
      // dirty page cache whatever the artifact size — and what paces the read to
      // a disk slower than the link.
      final file = File('${dir.path}/bound.bin');
      final gate = Completer<void>();
      final sink = await _FlushingSink.open(file, flushGate: gate);
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: small);

      // Enough chunks to fill the reader's write window past the bound.
      final blocks = kSttWriteWindowBytes ~/ _chunk + 16;
      var accepted = 0;
      final feeding = () async {
        for (var i = 0; i < blocks; i++) {
          await pipeline.add(_block(i));
          accepted++;
        }
      }();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        sink.bytes,
        2 * small,
        reason: 'the writer went past the two-window bound while the flush ran',
      );
      expect(
        accepted,
        lessThan(blocks),
        reason: 'the reader kept handing over bytes while the bound held',
      );

      gate.complete();
      await feeding.timeout(const Duration(seconds: 10));
      await pipeline.drain();
      await pipeline.close();
      expect(file.lengthSync(), blocks * _chunk);
    });

    test('coalesces to one running flush plus at most one remembered', () async {
      // Nothing written after the running flush, so its completion must not
      // re-arm a second one for the same bytes: close is then the only other.
      final file = File('${dir.path}/coalesce-one.bin');
      final gate = Completer<void>();
      final sink = await _FlushingSink.open(file, flushGate: gate);
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: small);
      for (var i = 0; i < 2; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      expect(sink.flushes, 1);

      gate.complete();
      await pipeline.close();
      expect(
        sink.flushes,
        2,
        reason: 'a flush was re-armed for bytes the running one already covered',
      );
    });

    test('a second window written during a flush is one request, not a queue', () async {
      final file = File('${dir.path}/coalesce-two.bin');
      final gate = Completer<void>();
      final sink = await _FlushingSink.open(file, flushGate: gate);
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: small);
      for (var i = 0; i < 4; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      expect(
        sink.flushes,
        1,
        reason: 'the second window is remembered, not started, while one runs',
      );

      gate.complete();
      await pipeline.close();
      expect(
        sink.flushes,
        3,
        reason: 'two windows and a close is exactly three writebacks',
      );
      expect(file.lengthSync(), 4 * _chunk);
    });

    test('close waits for the writeback it forced', () async {
      // `drain` may return with writeback still running; the digest comparison
      // and the rename must not.
      final file = File('${dir.path}/flush-gated.bin');
      final gate = Completer<void>();
      final sink = await _FlushingSink.open(file, flushGate: gate);
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: small);
      await pipeline.add(_block(0));
      await pipeline.add(_block(1));

      var closed = false;
      final closing = pipeline.close().whenComplete(() => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        closed,
        isFalse,
        reason: 'close returned while a forced writeback was still running',
      );

      gate.complete();
      await closing.timeout(const Duration(seconds: 5));
      expect(
        sink.flushes,
        2,
        reason: 'close forced the tail once after the running writeback',
      );
    });

    test('a refused flush is typed like a refused write', () async {
      final file = File('${dir.path}/flush-failed.bin');
      final sink = await _FlushingSink.open(
        file,
        failWith: const FileSystemException(
          'Cannot flush file',
          '/tmp/flush-failed.bin',
          OSError('No space left on device', 28),
        ),
      );
      final pipeline = InProcessWritePipeline(sink, flushWindowBytes: small);
      await pipeline.add(_block(0));
      await pipeline.add(_block(1));

      Object? caught;
      try {
        await pipeline.close();
      } on Object catch (error) {
        caught = error;
      }
      expect(
        caught,
        isA<SttWriteFailure>(),
        reason: 'a writeback the disk refused must not read as a failure the '
            'store cannot classify',
      );
      final failure = caught! as SttWriteFailure;
      expect(failure.osErrorCode, 28);
      expect(
        SttModelStore.mapWriteFailure(
          failure.toFileSystemException(path: '/tmp/flush-failed.bin.partial'),
          'flush-failed.bin',
        ).code,
        'storage_full',
      );
    });
  });

  group('degraded writeback', () {
    // A platform that will not give the flusher a second handle (a stricter
    // Windows sharing mode, an AV lock) must cost the overlap, not the install.
    // The pipeline tests run on one OS, so the refusal is injected where the
    // handle would be opened and the rest of the path is the real one.
    const int small = 2 * _chunk;

    test('falls back to one flush at close when the background handle is refused', () async {
      final file = File('${dir.path}/degraded.bin');
      final sink = await _FlushingSink.open(file);
      // Two chunks is a window, so the pre-degradation rule would have forced a
      // writeback mid-transfer: zero here is the fallback, not a small artifact.
      final pipeline = InProcessWritePipeline(
        sink,
        flushWindowBytes: small,
        writeback: false,
      );

      for (var i = 0; i < 10; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      expect(
        sink.flushes,
        0,
        reason: 'writeback was requested after the background handle was refused',
      );
      expect(file.lengthSync(), 10 * _chunk);

      await pipeline.close();
      expect(
        sink.flushes,
        1,
        reason: 'the close-only fallback must still force the artifact out once',
      );
      expect(file.lengthSync(), 10 * _chunk);
    });

    test('an install whose writeback is unavailable still lands byte-exact', () async {
      // The shipped path: the flusher is really spawned and really refuses its
      // open, so the message hop, the governor's disabled mode, the lifecycle
      // line and the close flush are all the production ones. Anything worse than
      // a lost overlap fails here.
      final records = <LogRecord>[];
      final logged = Completer<void>();
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.loggerName != 'SttWritePipeline') return;
        records.add(record);
        if (!logged.isCompleted) logged.complete();
      });
      addTearDown(subscription.cancel);

      final file = File('${dir.path}/isolate-degraded.bin');
      final pipeline = await IsolateWritePipeline.open(
        file,
        FileMode.write,
        flushWindowBytes: _chunk,
        writeback: false,
      );
      final blocks = <Uint8List>[for (var i = 0; i < 8; i++) _block(i)];
      for (final block in blocks) {
        await pipeline.add(block);
      }
      await pipeline.drain();
      await pipeline.close();

      final expected = <int>[for (final block in blocks) ...block];
      expect(file.lengthSync(), expected.length);
      expect(file.readAsBytesSync(), expected);

      // A refused open still leaves an isolate running, and ending it is part of
      // the close contract even though it holds no file. Read synchronously: an
      // awaited future would concede the event-loop turn the exit needs.
      expect(
        pipeline.flusherIsolateEnded,
        isTrue,
        reason: 'the refused-open flusher outlived close()',
      );

      await logged.future.timeout(const Duration(seconds: 5));
      expect(
        records,
        hasLength(1),
        reason: 'the fallback is one lifecycle line, not one per artifact chunk',
      );
      expect(
        records.single.message,
        allOf(
          contains('background writeback unavailable'),
          contains('close-only flush'),
        ),
      );
      expect(records.single.level, Level.INFO);
    });

    test('a model install completes when writeback is unavailable', () async {
      // What the user sees on such a platform: the store's own install path, its
      // digest check and its atomic activation, with no writeback in the middle.
      // A typed failure here would be an install that never completes at all.
      final root = Directory.systemTemp.createTempSync('stt-degraded-install-');
      addTearDown(() => root.deleteSync(recursive: true));
      final body = Uint8List(384 * 1024);
      for (var i = 0; i < body.length; i++) {
        body[i] = (i * 11) & 0xFF;
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });

      final store = SttModelStore(
        sanadHome: root.path,
        createPipeline: (file, mode) =>
            IsolateWritePipeline.open(file, mode, writeback: false),
      );
      final entry = SttCatalogEntry(
        id: 'degraded-probe',
        name: 'Degraded probe',
        description: const {'en': 'Degraded probe.'},
        mode: SttModelMode.batchVad,
        engine: SttEngineKind.whisperCpp,
        files: <SttModelFile>[
          SttModelFile(
            name: 'probe.bin',
            url: 'http://${server.address.address}:${server.port}/probe.bin',
            sizeBytes: body.length,
            sha256: sha256.convert(body).toString(),
          ),
        ],
      );

      await store.install(entry);
      final installed = File('${root.path}/models/stt/degraded-probe/probe.bin');
      expect(installed.existsSync(), isTrue, reason: 'the artifact was activated');
      expect(installed.readAsBytesSync(), body);
    });
  });

  group('failures', () {
    test('a refused write surfaces as SttWriteFailure with its errno', () async {
      final file = File('${dir.path}/refused.bin');
      final sink = _RefusingSink(
        await file.open(mode: FileMode.write),
        const FileSystemException(
          'Cannot write to file',
          '/tmp/refused.bin',
          OSError('No space left on device', 28),
        ),
      );
      final pipeline = InProcessWritePipeline(sink);
      await pipeline.add(_block(0));

      Object? caught;
      try {
        await pipeline.drain();
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<SttWriteFailure>());
      final failure = caught! as SttWriteFailure;
      expect(failure.osErrorCode, 28);
      // The store maps a full volume from this shape, so the round trip has to
      // survive the isolate boundary it exists for.
      expect(failure.toFileSystemException().osError?.errorCode, 28);
    });

    test('closing a refused write releases the handle it opened', () async {
      // The same failure, taken one step further: a caller that closes what it
      // opened must get the typed error back *and* its handle released. This is
      // the path the store takes in a `finally` after a refused write, and the
      // next attempt resumes from that very file.
      final file = File('${dir.path}/refused-close.bin');
      final sink = _RefusingSink(
        await file.open(mode: FileMode.write),
        const FileSystemException(
          'Cannot write to file',
          '/tmp/refused.bin',
          OSError('No space left on device', 28),
        ),
      );
      final pipeline = InProcessWritePipeline(sink);
      await pipeline.add(_block(0));
      await expectLater(pipeline.drain(), throwsA(isA<SttWriteFailure>()));

      // Reaches the caller through the same channel a caller that only closes
      // uses, and releases the sink even though the write already failed.
      await expectLater(pipeline.close(), throwsA(isA<SttWriteFailure>()));
      expect(await _holdsOpenHandle(file.path), isFalse);
      expect(file.existsSync(), isTrue, reason: 'the bytes are resumable');
      file.deleteSync();
      expect(file.existsSync(), isFalse);
    });

    test('close after a stalled write drains what was accepted', () async {
      final file = File('${dir.path}/close.bin');
      final sink = _GatedSink(await file.open(mode: FileMode.write));
      final pipeline = InProcessWritePipeline(sink);
      await pipeline.add(_block(0));
      await pipeline.add(_block(1));

      var closed = false;
      final closing = pipeline.close().whenComplete(() => closed = true);
      await sink.startedWrites(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        closed,
        isFalse,
        reason: 'close must wait for the bytes it already accepted',
      );

      sink.release();
      await closing.timeout(const Duration(seconds: 5));
      expect(sink.closed, isTrue);
      expect(
        file.lengthSync(),
        2 * _chunk,
        reason: 'the accepted bytes must land, or a resume restarts from zero',
      );
    });

    test('a write failure over a real response is still typed', () async {
      // The typed code is decided by the store's catch chain, and the chain now
      // has a branch for a failure that crossed the writer isolate. Driving it
      // with the real pipeline over a real response is what proves the branch is
      // reached: a `SttWriteFailure` that never matched would surface as
      // `download_failed` and spend the retry budget on a full volume.
      final dir = Directory.systemTemp.createTempSync('stt-typed-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final body = Uint8List(256 * 1024);
      for (var i = 0; i < body.length; i++) {
        body[i] = (i * 7) & 0xFF;
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });

      final store = SttModelStore(
        sanadHome: dir.path,
        createPipeline: inProcessPipeline(
          (file, mode) async => _RefusingSink(
            await file.open(mode: mode),
            const FileSystemException(
              'Cannot write to file',
              '',
              OSError('No space left on device', 28),
            ),
          ),
        ),
      );
      final entry = SttCatalogEntry(
        id: 'typed-probe',
        name: 'Typed probe',
        description: const {'en': 'Typed probe.'},
        mode: SttModelMode.batchVad,
        engine: SttEngineKind.whisperCpp,
        files: <SttModelFile>[
          SttModelFile(
            name: 'probe.bin',
            url: 'http://${server.address.address}:${server.port}/probe.bin',
            sizeBytes: body.length,
            sha256: sha256.convert(body).toString(),
          ),
        ],
      );

      await expectLater(
        store.install(entry),
        throwsA(
          isA<SttException>().having((e) => e.code, 'code', 'storage_full'),
        ),
      );
    });

    test('a full volume survives the isolate boundary as storage_full', () {
      // The writer runs in another isolate, where a `FileSystemException`
      // cannot cross. The store keeps mapping ENOSPC to `storage_full` exactly
      // where it always did; this asserts the whole chain a failed write takes
      // from the sink to the typed code the daemon reports.
      const failure = SttWriteFailure(
        'Cannot write to file',
        28,
        'No space left on device',
      );
      final mapped = SttModelStore.mapWriteFailure(
        failure.toFileSystemException(path: '/tmp/probe.bin.partial'),
        'probe.bin',
      );
      expect(mapped.code, 'storage_full');
    });

    test('a write failure that is not a full volume stays retryable-ish', () {
      // Anything else keeps the generic code: the remedy is a retry, not a
      // message telling the user to free space.
      final mapped = SttModelStore.mapWriteFailure(
        const SttWriteFailure('Input/output error', 5, 'Input/output error')
            .toFileSystemException(),
        'probe.bin',
      );
      expect(mapped.code, 'download_failed');
    });
  });

  group('handles', () {
    test('close releases the artifact so it can be renamed and deleted', () async {
      // The store activates a download by renaming its `.partial` the moment the
      // pipeline closes (stt_model_store.dart), and deletes it when the bytes
      // cannot be trusted. Windows refuses both while any handle is open —
      // including the writeback handle, which lives in its own isolate — so
      // `close()` must have every handle closed before it returns, not merely
      // ended the isolates that held them: a killed isolate releases nothing.
      final file = File('${dir.path}/release.bin');
      final pipeline = await IsolateWritePipeline.open(
        file,
        FileMode.write,
        flushWindowBytes: _chunk,
      );
      for (var i = 0; i < 8; i++) {
        await pipeline.add(_block(i));
      }
      await pipeline.drain();
      await pipeline.close();

      expect(
        await _holdsOpenHandle(file.path),
        isFalse,
        reason: 'close() is the handle boundary, not just the durability one',
      );
      final activated = File('${dir.path}/release.activated');
      file.renameSync(activated.path);
      expect(activated.lengthSync(), 8 * _chunk);
      activated.deleteSync();
      expect(activated.existsSync(), isFalse);
    });

    test('a pipeline that already failed still tears down and closes twice', () async {
      // A deterministic writer failure: the destination's directory does not
      // exist, so the writer isolate reports the refusal and ends on its own.
      // That is the state `close()` used to short-circuit on, leaving the
      // writeback isolate and its handle to the daemon's lifetime.
      final missing = File('${dir.path}/missing/deep/artifact.bin');
      final pipeline = await IsolateWritePipeline.open(missing, FileMode.write);

      await expectLater(() async {
        await pipeline.add(_block(0));
        await pipeline.drain();
      }(), throwsA(isA<SttWriteFailure>()));

      // The writer reports the refusal and then ends. The state this guards
      // against — a pipeline whose writer already exited — only exists once that
      // isolate is gone, so wait for the exact lifecycle event and not for a
      // duration: the deadline is a failure bound, never the synchronization.
      await pipeline.writerIsolateExited.timeout(const Duration(seconds: 10));

      await expectLater(pipeline.close(), throwsA(isA<SttWriteFailure>()));
      // Idempotent: a second close is a no-op, not a second teardown.
      await pipeline.close();

      expect(missing.existsSync(), isFalse);
      expect(await _holdsOpenHandle(missing.path), isFalse);
    });

    test('an immediate close never strands the flusher handle', () async {
      // Cancel-right-away: `open()` returns before the flusher has sent its
      // command channel, so `close()` runs while that message is still in
      // flight. Reading the channel once and treating "not here yet" as "no
      // handle" stranded the append descriptor on roughly one close in twelve
      // (17/200 measured by review, 63/200 on another host), and a killed
      // isolate does not release it — so on Windows the `.partial` stayed
      // undeletable and a resumed install could never repair it.
      final root = Directory(dir.path).resolveSymbolicLinksSync();
      for (var i = 0; i < 64; i++) {
        final pipeline = await IsolateWritePipeline.open(
          File('${dir.path}/immediate-$i.bin'),
          FileMode.write,
        );
        await pipeline.close();
      }

      final leaked = (await _descriptorTargets())
          .where((String path) => path.startsWith(root))
          .toList();
      expect(
        leaked,
        isEmpty,
        reason: 'close() returned with these descriptors still open: $leaked',
      );
      // The same property as the user feels it: every artifact is removable, and
      // on Windows that is only true when no handle survived the close.
      for (final entity in Directory(root).listSync()) {
        expect(entity.deleteSync, returnsNormally);
      }
    });

    test('a concurrent close waits for the same teardown', () async {
      // Two callers must not race: the one that arrives second may not treat the
      // first one's work as done, or it renames or deletes while the flusher is
      // still inside `closeSync`.
      final file = File('${dir.path}/concurrent.bin');
      final pipeline = await IsolateWritePipeline.open(file, FileMode.write);
      await pipeline.add(_block(0));

      var firstSettled = false;
      final first = pipeline.close().whenComplete(() => firstSettled = true);
      await pipeline.close();

      expect(
        firstSettled,
        isTrue,
        reason: 'a concurrent close must not return before the shared teardown',
      );
      await first;
      expect(await _holdsOpenHandle(file.path), isFalse);
      // Sequential closes stay no-ops rather than repeating the teardown.
      await pipeline.close();
    });

    test('a concurrent failed close rethrows its typed failure once', () async {
      final missing = File('${dir.path}/missing-concurrent/artifact.bin');
      final pipeline = await IsolateWritePipeline.open(missing, FileMode.write);
      await expectLater(() async {
        await pipeline.add(_block(0));
        await pipeline.drain();
      }(), throwsA(isA<SttWriteFailure>()));
      await pipeline.writerIsolateExited.timeout(const Duration(seconds: 10));

      final first = pipeline.close();
      final second = pipeline.close();
      await expectLater(first, throwsA(isA<SttWriteFailure>()));
      await expectLater(second, completes);
      // A later sequential close remains a no-op.
      await pipeline.close();
    });

    test('close ends the flusher isolate, not only its handle', () async {
      // The writer is already gone before `close()` runs, so nothing else in the
      // teardown can mask the flusher's own exit: the zero timeout asks exactly
      // "has this already completed?" with no delay and no room for scheduling
      // luck. A close that only waited for the `gone` message fails here.
      final missing = File('${dir.path}/missing-exit/artifact.bin');
      final pipeline = await IsolateWritePipeline.open(missing, FileMode.write);
      await expectLater(() async {
        await pipeline.add(_block(0));
        await pipeline.drain();
      }(), throwsA(isA<SttWriteFailure>()));
      await pipeline.writerIsolateExited.timeout(const Duration(seconds: 10));

      await expectLater(pipeline.close(), throwsA(isA<SttWriteFailure>()));
      // Read synchronously, at the instant close() returned: awaiting a future
      // here would give the exit event the very turn it needs, which is what made
      // this unobservable before.
      expect(
        pipeline.flusherIsolateEnded,
        isTrue,
        reason: 'close() returned before the flusher isolate had ended',
      );
      expect(
        pipeline.writerIsolateEnded,
        isTrue,
        reason: 'close() returned before the writer isolate had ended',
      );
    });
  });

  group('production pipeline', () {
    test('is the isolate pipeline', () {
      final store = SttModelStore(sanadHome: dir.path);
      expect(
        store.pipelineFactory,
        same(IsolateWritePipeline.open),
        reason: 'the shipped default must not be the in-process pipeline',
      );
    });

    test('writes the bytes it accepts, in order', () async {
      final file = File('${dir.path}/isolate.bin');
      final pipeline = await IsolateWritePipeline.open(file, FileMode.write);
      final blocks = <Uint8List>[_block(1), _block(2), _block(3)];
      for (final block in blocks) {
        await pipeline.add(block);
      }
      await pipeline.drain();
      await pipeline.close();

      final expected = <int>[...blocks[0], ...blocks[1], ...blocks[2]];
      expect(file.lengthSync(), expected.length);
      expect(file.readAsBytesSync(), expected);
    });

    test('splits one chunk bigger than the window', () async {
      // The shipped pipeline has its own window accounting across the isolate
      // boundary (bytes are accepted on send and released on ack), and it must
      // split an oversized chunk exactly like the in-process one: the reader
      // hands it whatever the socket produced.
      final file = File('${dir.path}/isolate-big.bin');
      final pipeline = await IsolateWritePipeline.open(file, FileMode.write);
      final big = Uint8List(kSttWriteWindowBytes * 2 + 1024);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 37) & 0xFF;
      }

      await pipeline.add(big).timeout(const Duration(seconds: 30));
      await pipeline.drain();
      await pipeline.close();

      expect(file.lengthSync(), big.length);
      expect(file.readAsBytesSync(), big);
    });

    test('forces writeback repeatedly and keeps writing in order', () async {
      // A window of one chunk makes the shipped writer/flusher pair cross a
      // writeback boundary on every piece, which is the interleaving that has to
      // stay correct: the flusher holds its own handle of the same file while the
      // writer appends to it, and the writer's own final flush still owns the
      // durability. The cadence and the bound are asserted in-process, where a
      // sink can count them.
      final file = File('${dir.path}/isolate-flush.bin');
      final pipeline = await IsolateWritePipeline.open(
        file,
        FileMode.write,
        flushWindowBytes: _chunk,
      );
      final blocks = <Uint8List>[for (var i = 0; i < 8; i++) _block(i)];
      for (final block in blocks) {
        await pipeline.add(block);
      }
      await pipeline.drain();
      await pipeline.close();

      final expected = <int>[for (final block in blocks) ...block];
      expect(file.lengthSync(), expected.length);
      expect(file.readAsBytesSync(), expected);
    });

    test('costs little against the same sink in-process', () async {
      // 64 MiB through each pipeline: the in-process one is the shape the old
      // loop had (write awaited in the reader's isolate), so the ratio is what
      // the isolate buys on this host. It is a regression guard, not the win:
      // the win is against network latency (29.1 -> 61.2 MB/s measured on the
      // Neoverse host), which a loopback test cannot reproduce.
      //
      // The transfer deliberately stops one block short of the writeback window
      // so neither path forces page cache out mid-transfer: this guard compares
      // the isolate hop against the same sink, and a 64 MiB fsync on a CI runner
      // is disk latency that would swamp it. The flush cadence has its own tests
      // above, and the close flush both paths still pay is unchanged.
      const int total = kSttFlushWindowBytes - _chunk;
      final block = _block(0);

      Future<Duration> run(bool isolate) async {
        final file = File('${dir.path}/ratio-${isolate ? 'i' : 'p'}.bin');
        final stopwatch = Stopwatch()..start();
        final pipeline = isolate
            ? await IsolateWritePipeline.open(file, FileMode.write)
            : await inProcessPipeline()(file, FileMode.write);
        for (var written = 0; written < total; written += block.length) {
          await pipeline.add(block);
        }
        await pipeline.drain();
        await pipeline.close();
        stopwatch.stop();
        expect(file.lengthSync(), total);
        await file.delete();
        return stopwatch.elapsed;
      }

      await run(true); // warm the isolate spawn and the page cache
      await run(false);
      final inProcess = await run(false);
      final isolate = await run(true);
      final ratio =
          inProcess.inMicroseconds /
          (isolate.inMicroseconds == 0 ? 1 : isolate.inMicroseconds);
      expect(
        ratio,
        greaterThan(0.5),
        reason:
            'the isolate pipeline ran at ${(1 / ratio).toStringAsFixed(2)}x the '
            'in-process cost (${isolate.inMilliseconds} ms vs '
            '${inProcess.inMilliseconds} ms for 64 MiB)',
      );
    });
  });
}
