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
// 4. **The isolate hop is the shipped one, and it is cheap.** The default
//    factory is asserted structurally, and the hop is timed against the same
//    file sink in-process so a regression that serialises on it shows up as a
//    ratio rather than as a slow download nobody measures again.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

    test('costs little against the same sink in-process', () async {
      // 64 MiB through each pipeline: the in-process one is the shape the old
      // loop had (write awaited in the reader's isolate), so the ratio is what
      // the isolate buys on this host. It is a regression guard, not the win:
      // the win is against network latency (29.1 -> 61.2 MB/s measured on the
      // Neoverse host), which a loopback test cannot reproduce.
      const int total = 64 * 1024 * 1024;
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
