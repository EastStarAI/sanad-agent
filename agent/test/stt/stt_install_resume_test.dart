// Resume, retry, and the low-disk guard for dictation model downloads.
//
// A 874 MB model on the owner's 27 Mbit/s link is a 4.5-minute download, and the
// shipped code deleted the partial before every attempt: one dropped connection
// at 99 % restarted from zero. These tests pin the replacement contract —
// `Range` resume that keeps the bytes, bounded retry, and a refusal before the
// first byte when the volume cannot hold the artifact.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

/// Loopback server that honours `Range`, and can cut the first body short.
class _RangeServer {
  _RangeServer(this.bytes);

  final Uint8List bytes;
  final List<String?> ranges = <String?>[];
  int requests = 0;

  /// Abort the first response after half of the requested slice.
  bool dropFirstBody = false;

  late HttpServer server;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var start = 0;
      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
        expect(match, isNotNull, reason: 'unexpected range header: $range');
        start = int.parse(match!.group(1)!);
      }
      final slice = bytes.sublist(start);
      final response = request.response;
      response.statusCode = start > 0
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      if (start > 0) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      response.contentLength = slice.length;
      if (!(dropFirstBody && requests == 1)) {
        response.add(slice);
        await response.close();
        return;
      }
      // Deliver a third and kill the connection: the client has to keep those
      // bytes and ask for the rest. The socket is detached before anything is
      // written, because a response that already flushed its headers cannot be
      // detached.
      final socket = await response.detachSocket(writeHeaders: false);
      final status = start > 0 ? '206 Partial Content' : '200 OK';
      final contentRange = start > 0
          ? 'Content-Range: bytes $start-${bytes.length - 1}/${bytes.length}\r\n'
          : '';
      socket.add(
        utf8.encode(
          'HTTP/1.1 $status\r\n$contentRange'
          'Content-Length: ${slice.length}\r\n\r\n',
        ),
      );
      socket.add(slice.sublist(0, slice.length ~/ 3));
      await socket.flush();
      socket.destroy();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  late Directory home;
  late Uint8List payload;
  late String digest;
  late _RangeServer source;

  setUp(() {
    home = Directory.systemTemp.createTempSync('stt-resume-');
    // Small but multi-chunk, so the cut lands inside the body.
    payload = Uint8List.fromList(
      List<int>.generate(256 * 1024, (index) => (index * 7) & 0xff),
    );
    digest = sha256.convert(payload).toString();
    source = _RangeServer(payload);
  });

  tearDown(() async {
    await source.stop();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  SttCatalogEntry entryFor(String id, {String? url}) => SttCatalogEntry(
    id: id,
    name: 'Resume probe',
    description: const {'en': 'Resume probe.'},
    mode: SttModelMode.batchVad,
    engine: SttEngineKind.whisperCpp,
    files: [
      SttModelFile(
        name: 'probe.bin',
        url: url ?? 'http://${source.server.address.address}:${source.server.port}/m.bin',
        sizeBytes: payload.length,
        sha256: digest,
      ),
    ],
  );

  test('an interrupted download resumes from the bytes it kept', () async {
    source.dropFirstBody = true;
    await source.start();
    final store = SttModelStore(sanadHome: home.path);
    final entry = entryFor('resume-probe');

    await store.install(entry);

    expect(source.requests, greaterThanOrEqualTo(2));
    // The first request had nothing to resume; the second must address the bytes
    // already on disk instead of starting over.
    expect(source.ranges.first, isNull);
    final resumed = source.ranges
        .skip(1)
        .whereType<String>()
        .where((value) => value != 'bytes=0-')
        .toList();
    expect(
      resumed,
      isNotEmpty,
      reason: 'the retry must send a Range header; saw ${source.ranges}',
    );
    expect(resumed.first, matches(RegExp(r'^bytes=\d+-$')));

    final installed = File('${store.modelDir(entry.id)}/probe.bin');
    expect(installed.existsSync(), isTrue);
    expect(installed.lengthSync(), payload.length);
    expect(sha256.convert(installed.readAsBytesSync()).toString(), digest);
    expect(store.statusOf(entry).installed, isTrue);
  });

  test('a cancelled download keeps its resumable partial', () async {
    // A few MB so the cancel lands mid-transfer rather than after the last
    // chunk of a loopback-fast artifact.
    payload = Uint8List.fromList(
      List<int>.generate(4 * 1024 * 1024, (index) => (index * 7) & 0xff),
    );
    digest = sha256.convert(payload).toString();
    source = _RangeServer(payload);
    await source.start();
    final store = SttModelStore(sanadHome: home.path);
    final entry = entryFor('cancel-probe');
    var received = 0;

    await expectLater(
      store.install(
        entry,
        onProgress: (_, bytes, _) {
          received = bytes;
        },
        // Cancel once half the artifact is on disk: loopback delivers large
        // chunks, so counting chunks is not a reliable mid-transfer point.
        isCancelled: () => received > payload.length ~/ 2,
      ),
      throwsA(
        isA<SttException>().having((error) => error.code, 'code', 'cancelled'),
      ),
    );

    final partial = File('${store.modelDir(entry.id)}/probe.bin.partial');
    expect(
      partial.existsSync(),
      isTrue,
      reason: 'a cancel is not a corruption: the bytes stay for the next press',
    );
    expect(partial.lengthSync(), greaterThan(0));
    expect(store.statusOf(entry).installed, isFalse);
  });

  test('a volume that cannot hold the artifact refuses before writing', () async {
    await source.start();
    final store = SttModelStore(
      sanadHome: home.path,
      // 1 MB free against a margin of 256 MB: the refusal must not wait for a
      // write to fail.
      freeSpaceProbe: (_) async => 1024 * 1024,
    );
    final entry = entryFor('storage-probe');

    await expectLater(
      store.install(entry),
      throwsA(
        isA<SttException>().having((error) => error.code, 'code', 'storage_full'),
      ),
    );
    expect(source.requests, 0, reason: 'nothing may be requested');
    expect(File('${store.modelDir(entry.id)}/probe.bin.partial').existsSync(), isFalse);
  });

  test('an unknown free space never refuses an install', () async {
    await source.start();
    final store = SttModelStore(
      sanadHome: home.path,
      freeSpaceProbe: (_) async => null,
    );
    final entry = entryFor('unknown-space-probe');

    await store.install(entry);
    expect(store.statusOf(entry).installed, isTrue);
  });

  test('an artifact already on disk is not downloaded again', () async {
    await source.start();
    final store = SttModelStore(sanadHome: home.path);
    final entry = entryFor('complete-probe');
    await store.install(entry);
    final afterFirst = source.requests;

    await store.install(entry);

    expect(
      source.requests,
      afterFirst,
      reason: 'a second install must not re-download a complete artifact',
    );
    expect(store.statusOf(entry).installed, isTrue);
  });

  test('a digest mismatch discards the bytes it cannot trust', () async {
    await source.start();
    final store = SttModelStore(sanadHome: home.path);
    final entry = SttCatalogEntry(
      id: 'digest-probe',
      name: 'Digest probe',
      description: const {'en': 'Digest probe.'},
      mode: SttModelMode.batchVad,
      engine: SttEngineKind.whisperCpp,
      files: [
        SttModelFile(
          name: 'probe.bin',
          url: entryFor('unused').files.first.url,
          sizeBytes: payload.length,
          sha256: '0' * 64,
        ),
      ],
    );

    await expectLater(
      store.install(entry),
      throwsA(
        isA<SttException>().having(
          (error) => error.code,
          'code',
          'checksum_mismatch',
        ),
      ),
    );
    expect(
      File('${store.modelDir(entry.id)}/probe.bin.partial').existsSync(),
      isFalse,
      reason: 'bytes that hash wrong can never resume into a valid file',
    );
    // Bounded retry: a checksum failure is not transient, so it is not repeated.
    expect(source.requests, 1);
  });
}
