// Backpressure guard for the dictation model download path.
//
// The defect this pins was measured, not hypothesized: `IOSink.add` is `void`,
// and while `_FileStreamConsumer` has the subscription paused every arriving
// chunk is queued in the Dart heap, so a producer faster than the sink retained
// most of the artifact — 723 MB untagged for an 823 MB file, 187 MB once the
// write was awaited.
//
// Two guards, because one measure is not enough:
//
// 1. **Contract** — hold a write open and prove the download waits for it. The
//    artifact is served from a real loopback HTTP server, so this is the shipped
//    path with one injected sink; a producer that kept reading would push the
//    whole file, and the assertion is that it stops instead.
// 2. **Envelope** — with the real file sink, sample "bytes the server handed
//    over" minus "bytes on disk" and assert the gap stays a small fraction of
//    the artifact. The gap is the queue, independent of page-cache accounting
//    (RSS cannot separate a Dart queue from file-cache pages: writing 96 MB to
//    `/dev/null` peaks 31 MB lower than writing it to a file).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

/// Sink that really writes, except that its first write waits for the test.
///
/// The file is the production destination, so the rest of the install — digest,
/// size check, atomic rename — runs exactly as it ships.
class _StalledSink implements SttWriteSink {
  _StalledSink(this._handle);

  final RandomAccessFile _handle;
  final Completer<void> release = Completer<void>();
  final List<int> writtenLengths = <int>[];
  bool closed = false;

  @override
  Future<void> writeFrom(List<int> bytes) async {
    writtenLengths.add(bytes.length);
    if (writtenLengths.length == 1) await release.future;
    await _handle.writeFrom(bytes);
  }

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() async {
    closed = true;
    await _handle.close();
  }
}

void main() {
  /// Big enough that a queue would be visible, small enough to keep two focused
  /// tests inside a few seconds on CI.
  const int fileSize = 32 * 1024 * 1024;

  /// Socket buffers absorb this much without the peer reading anything, so a
  /// blocked download may still see a few hundred KB in flight and nothing more.
  const int stalledQueueLimit = 4 * 1024 * 1024;

  /// The envelope a healthy transfer stays inside: an eighth of the artifact.
  const int transferGapLimit = fileSize ~/ 8;

  late Directory home;
  late File artifact;
  late String digest;
  late HttpServer server;
  late int sent;

  setUpAll(() {
    home = Directory.systemTemp.createTempSync('stt-bound-');
    artifact = File('${home.path}/served.bin');
    final sink = artifact.openSync(mode: FileMode.write);
    final block = Uint8List(64 * 1024);
    for (var index = 0; index < block.length; index++) {
      block[index] = index & 0xff;
    }
    for (var written = 0; written < fileSize; written += block.length) {
      sink.writeFromSync(block);
    }
    sink.closeSync();
    digest = sha256.convert(artifact.readAsBytesSync()).toString();
  });

  setUp(() async {
    sent = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.contentLength = fileSize;
      // Chunked and flushed per block: the server paces itself to the socket, so
      // `sent` measures what the client accepted rather than what the server
      // buffered.
      await for (final chunk in artifact.openRead()) {
        sent += chunk.length;
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  tearDownAll(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  SttCatalogEntry entryFor(String modelId) => SttCatalogEntry(
    id: modelId,
    name: 'Backpressure probe',
    description: const {'en': 'Backpressure probe.'},
    mode: SttModelMode.batchVad,
    engine: SttEngineKind.whisperCpp,
    files: [
      SttModelFile(
        name: 'probe.bin',
        url: 'http://${server.address.address}:${server.port}/model.bin',
        sizeBytes: fileSize,
        sha256: digest,
      ),
    ],
  );

  test('a stalled write stops the download instead of queueing it', () async {
    final opened = Completer<_StalledSink>();
    final store = SttModelStore(
      sanadHome: home.path,
      openWrite: (file, mode) async {
        final sink = _StalledSink(await file.open(mode: mode));
        opened.complete(sink);
        return sink;
      },
    );
    final entry = entryFor('stalled-probe');
    final install = store.install(entry);
    final stalled = await opened.future;

    // Let the transfer run until the first write is pending.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (stalled.writtenLengths.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(stalled.writtenLengths, hasLength(1));

    // While the write is open, the producer must stop: only socket buffers may
    // fill. A download that kept reading would deliver most of the artifact.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      sent,
      lessThan(stalledQueueLimit),
      reason:
          'the download read ${sent ~/ (1024 * 1024)} MB while the file write '
          'was blocked; the sink must apply backpressure',
    );
    expect(stalled.writtenLengths, hasLength(1));

    stalled.release.complete();
    await install;

    expect(stalled.closed, isTrue);
    expect(store.statusOf(entry).installed, isTrue);
    expect(
      File('${store.modelDir(entry.id)}/probe.bin').lengthSync(),
      fileSize,
    );
  });

  test('the real file sink never holds a share of the artifact', () async {
    final store = SttModelStore(sanadHome: home.path);
    final entry = entryFor('envelope-probe');
    final partial = File('${store.modelDir(entry.id)}/probe.bin.partial');

    var maxGap = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final written = partial.existsSync() ? partial.lengthSync() : 0;
      final gap = sent - written;
      if (gap > maxGap) maxGap = gap;
    });

    var ticks = 0;
    try {
      await store.install(entry, onProgress: (_, _, _) => ticks++);
    } finally {
      sampler.cancel();
    }

    expect(ticks, greaterThan(0));
    expect(store.statusOf(entry).installed, isTrue);
    expect(
      maxGap,
      lessThan(transferGapLimit),
      reason:
          'the transfer queued ${maxGap ~/ 1024} KB ahead of the disk for a '
          '${fileSize ~/ (1024 * 1024)} MB artifact',
    );
  });
}
