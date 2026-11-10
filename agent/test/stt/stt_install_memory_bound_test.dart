// Backpressure guard for the dictation model download path.
//
// The defect this pins was measured, not hypothesized: `IOSink.add` is `void`,
// and while `_FileStreamConsumer` has the subscription paused every arriving
// chunk is queued in the Dart heap, so a producer faster than the sink retained
// most of the artifact — 723 MB untagged for an 823 MB file, 187 MB once the
// write was awaited.
//
// Three guards, because no single measure proves the bound:
//
// 1. **Sealed pipeline** — hold a write open and prove the download stops
//    making progress. The artifact is served from a real loopback HTTP server,
//    so this is the shipped path with one injected sink. What is asserted is
//    the *growth* of the server's accepted byte count once the socket has
//    settled, not its absolute value: that value is a host socket-buffer
//    constant (measured 1856 KiB on macOS idle, 1216-2560 KiB under CPU load,
//    4480 KiB on a Linux CI runner), while a producer that kept reading adds
//    tens of MB in the same window. A ceiling fixed above the healthy value is
//    what made this file host-dependent.
// 2. **Envelope** — with the real file sink, sample "bytes this response handed
//    over" minus "bytes on disk" and assert the gap stays a small fraction of
//    the artifact. The counter restarts with every response, so a retried
//    transfer is never charged the bytes of the attempt it replaced, and the
//    sampler stops as soon as the phase leaves `downloading`, so the atomic
//    rename cannot turn a completed artifact into a zero-length reading. The
//    gap is still partly a socket effect, so its limit is loose and the exact
//    bound is carried by the seam below.
// 3. **Seam** — the injected writer counts concurrent `writeFrom` calls and
//    asserts exactly one. That is the shipped contract, it is independent of
//    any host, and a queueing regression reaches it as a second write in
//    flight.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

/// Size of one produced chunk; the unit the sealed assertion reasons in.
const int _blockBytes = 64 * 1024;

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

/// Production-shaped sink that records how many writes were ever in flight.
///
/// The store awaits one write before reading the next chunk, so [maxInFlight]
/// stays 1. A regression that stopped awaiting — or that buffered chunks behind
/// a fire-and-forget sink — reaches this seam as a concurrent second write.
class _CountingSink implements SttWriteSink {
  _CountingSink(this._handle);

  final RandomAccessFile _handle;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> writeFrom(List<int> bytes) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await _handle.writeFrom(bytes);
    } finally {
      inFlight--;
    }
  }

  @override
  Future<void> flush() => _handle.flush();

  @override
  Future<void> close() => _handle.close();
}

/// Waits until [sample] reports the same value for a whole [window].
///
/// A stalled consumer seals the socket within milliseconds, so this settles on
/// the host's real ceiling instead of assuming it with a fixed sleep. It never
/// outlives [deadline]: a pipeline that keeps growing simply expires here and
/// fails the growth assertion that follows.
Future<void> _waitUntilStable(
  int Function() sample, {
  Duration window = const Duration(milliseconds: 150),
  Duration deadline = const Duration(seconds: 10),
}) async {
  final stop = DateTime.now().add(deadline);
  var value = sample();
  var unchangedSince = DateTime.now();
  while (DateTime.now().isBefore(stop)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final next = sample();
    if (next != value) {
      value = next;
      unchangedSince = DateTime.now();
      continue;
    }
    if (DateTime.now().difference(unchangedSince) >= window) return;
  }
}

void main() {
  /// Big enough that a queue would be visible, small enough to keep the focused
  /// tests inside a few seconds on CI.
  const int fileSize = 32 * 1024 * 1024;

  /// The envelope a healthy transfer stays inside: the write window plus a
  /// socket buffer's worth of slack.
  ///
  /// Sized from measurement, not from a hunch: the reader may now run up to
  /// [kSttWriteWindowBytes] ahead of the disk before it waits, and the socket
  /// adds its own buffer (measured 1 856 KiB idle on macOS, 4 480 KiB on a Linux
  /// CI runner). The `IOSink` defect this file was written for carries ~the
  /// whole artifact (29-30 MiB measured for this 32 MiB file), so this bound
  /// still separates the two bands by a wide margin.
  const int transferGapLimit = kSttWriteWindowBytes + 4 * 1024 * 1024;

  late Directory home;
  late File artifact;
  late String digest;
  late HttpServer server;

  /// Every byte this test ever handed to a response, across all attempts.
  late int sent;

  /// Bytes handed to the response that is currently open.
  late int sentThisResponse;

  late int requests;

  /// When set, the first response dies at 60 % of the artifact.
  late bool truncateFirstResponse;

  setUpAll(() {
    home = Directory.systemTemp.createTempSync('stt-bound-');
    artifact = File('${home.path}/served.bin');
    final sink = artifact.openSync(mode: FileMode.write);
    final block = Uint8List(_blockBytes);
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
    sentThisResponse = 0;
    requests = 0;
    truncateFirstResponse = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final truncated = truncateFirstResponse && requests == 1;
      request.response.contentLength = fileSize;
      // Chunked and flushed per block: the server paces itself to the socket, so
      // the counters measure what the client accepted rather than what the
      // server buffered.
      sentThisResponse = 0;
      final limit = truncated ? fileSize * 3 ~/ 5 : fileSize;
      try {
        await for (final chunk in artifact.openRead(0, limit)) {
          sent += chunk.length;
          sentThisResponse += chunk.length;
          request.response.add(chunk);
          await request.response.flush();
        }
        // A body that ends under a larger declared `contentLength` is a
        // truncated transfer: the store keeps the bytes it received and
        // retries, which is the path the retry test below pins.
        await request.response.close();
      } on Object {
        // The intentionally short response refuses to close cleanly; the
        // client has already seen the truncation, which is the point.
      }
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
      createPipeline: inProcessPipeline((file, mode) async {
        final sink = _StalledSink(await file.open(mode: mode));
        opened.complete(sink);
        return sink;
      }),
    );
    final entry = entryFor('stalled-probe');
    final install = store.install(entry);
    final stalled = await opened.future;

    // Let the transfer run until the first write is pending.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (stalled.writtenLengths.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(stalled.writtenLengths, hasLength(1));

    // The socket buffers and the byte window fill and stop; their size belongs
    // to the host and to `kSttWriteWindowBytes`, so the contract asserted here
    // is that the pipeline is *sealed*: a download that kept reading would add
    // tens of MB (the whole artifact) rather than the window it is allowed.
    await _waitUntilStable(() => sent);
    final sealed = sent;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      sent - sealed,
      lessThanOrEqualTo(kSttWriteWindowBytes),
      reason:
          'the download read ${(sent - sealed) ~/ 1024} KB while the file write '
          'was blocked; the window must cap it at ${kSttWriteWindowBytes ~/ 1024}'
          ' KB',
    );
    expect(
      sent,
      lessThan(fileSize),
      reason:
          'the whole artifact entered the pipeline while the file write was '
          'blocked',
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
    _CountingSink? writer;
    final store = SttModelStore(
      sanadHome: home.path,
      createPipeline: inProcessPipeline((file, mode) async {
        final sink = _CountingSink(await file.open(mode: mode));
        writer = sink;
        return sink;
      }),
    );
    final entry = entryFor('envelope-probe');
    final partial = File('${store.modelDir(entry.id)}/probe.bin.partial');

    // The download phase owns the metric: once the phase leaves `downloading`
    // the artifact is verified and renamed, so the partial this measures no
    // longer exists and any sample taken after it would report the response
    // total alone.
    var downloading = true;
    var maxGap = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (!downloading) return;
      final written = partial.existsSync() ? partial.lengthSync() : 0;
      final gap = sentThisResponse - written;
      if (gap > maxGap) maxGap = gap;
    });

    var ticks = 0;
    try {
      await store.install(
        entry,
        onProgress: (_, _, _) => ticks++,
        onPhase: (phase) {
          if (phase != SttInstallPhase.downloading) downloading = false;
        },
      );
    } finally {
      sampler.cancel();
    }

    expect(ticks, greaterThan(0));
    expect(store.statusOf(entry).installed, isTrue);
    expect(
      writer?.maxInFlight,
      1,
      reason: 'the store handed two chunks to the writer at once',
    );
    expect(
      maxGap,
      lessThan(transferGapLimit),
      reason:
          'the transfer queued ${maxGap ~/ 1024} KB ahead of the disk for a '
          '${fileSize ~/ (1024 * 1024)} MB artifact',
    );
  });

  test('a retried transfer is not charged the bytes it replaced', () async {
    // A dropped connection is transient: the store keeps the bytes it wrote and
    // retries. The server ignores `Range`, so the retry rewrites the partial
    // from zero while the *cumulative* server counter already holds the first
    // attempt. Charging that counter to the current partial reported 1.85
    // artifacts on CI and failed this file with no memory regression at all.
    truncateFirstResponse = true;

    _CountingSink? writer;
    final store = SttModelStore(
      sanadHome: home.path,
      createPipeline: inProcessPipeline((file, mode) async {
        final sink = _CountingSink(await file.open(mode: mode));
        writer = sink;
        return sink;
      }),
    );
    final entry = entryFor('retry-probe');
    final partial = File('${store.modelDir(entry.id)}/probe.bin.partial');

    var downloading = true;
    var maxGap = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (!downloading) return;
      final written = partial.existsSync() ? partial.lengthSync() : 0;
      final gap = sentThisResponse - written;
      if (gap > maxGap) maxGap = gap;
    });

    try {
      await store.install(
        entry,
        onPhase: (phase) {
          if (phase != SttInstallPhase.downloading) downloading = false;
        },
      );
    } finally {
      sampler.cancel();
    }

    expect(requests, 2, reason: 'the truncated first response must be retried');
    expect(store.statusOf(entry).installed, isTrue);
    expect(
      File('${store.modelDir(entry.id)}/probe.bin').lengthSync(),
      fileSize,
    );
    expect(
      writer?.maxInFlight,
      1,
      reason: 'the retry must not queue a second chunk either',
    );
    expect(
      maxGap,
      lessThan(transferGapLimit),
      reason:
          'the retried transfer queued ${maxGap ~/ 1024} KB ahead of the disk '
          'for a ${fileSize ~/ (1024 * 1024)} MB artifact',
    );
  });
}
