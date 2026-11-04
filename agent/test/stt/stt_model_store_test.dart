import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_settings.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late SttModelStore store;
  late HttpServer server;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('stt-store-');
    store = SttModelStore(sanadHome: home.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<String> urlFor(List<int> payload) async {
    final path = '/${sha256.convert(payload)}.onnx';
    server.listen((request) async {
      request.response.add(payload);
      await request.response.close();
    });
    return 'http://${server.address.address}:${server.port}$path';
  }

  SttCatalogEntry entryFor(List<int> payload, {String? sha, String url = ''}) {
    return SttCatalogEntry(
      id: 'test-model',
      label: 'Test',
      note: 'test',
      mode: SttModelMode.batchVad,
      files: [
        SttModelFile(
          name: 'test-encoder.int8.onnx',
          url: url,
          sizeBytes: payload.length,
          sha256: sha ?? sha256.convert(payload).toString(),
        ),
      ],
    );
  }

  void writeVadAsset() {
    Directory(store.sharedDir).createSync(recursive: true);
    File(store.vadPath).writeAsBytesSync(const [1, 2, 3]);
  }

  group('stt model store', () {
    test('statusOf reports missing files and a missing vad asset', () {
      final payload = utf8.encode('hello');
      final entry = entryFor(payload);
      expect(store.statusOf(entry).installed, isFalse);

      Directory(store.modelDir(entry.id)).createSync(recursive: true);
      File('${store.modelDir(entry.id)}/test-encoder.int8.onnx')
          .writeAsBytesSync(payload);
      // Still missing the shared VAD asset.
      expect(store.statusOf(entry).installed, isFalse);

      writeVadAsset();
      expect(store.statusOf(entry).installed, isTrue);
      expect(store.statusOf(entry).bytesOnDisk, payload.length);
    });

    test('install downloads, verifies and atomically activates', () async {
      final payload = utf8.encode('server payload');
      final entry = entryFor(payload, url: await urlFor(payload));
      final progress = <int>[];

      await store.install(
        entry,
        onProgress: (_, received, _) => progress.add(received),
      );

      final destination = File('${store.modelDir(entry.id)}/test-encoder.int8.onnx');
      expect(destination.existsSync(), isTrue);
      expect(destination.readAsBytesSync(), payload);
      expect(File('${destination.path}.partial').existsSync(), isFalse);
      expect(progress, isNotEmpty);
      expect(store.statusOf(entry).installed, isTrue);
    });

    test('a checksum mismatch never activates the file', () async {
      final payload = utf8.encode('payload');
      final entry = entryFor(
        payload,
        url: await urlFor(payload),
        sha: '0' * 64,
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
        File('${store.modelDir(entry.id)}/test-encoder.int8.onnx').existsSync(),
        isFalse,
      );
    });

    test('cancelling a download leaves nothing behind', () async {
      final payload = utf8.encode('cancel me');
      final entry = entryFor(payload, url: await urlFor(payload));

      await expectLater(
        store.install(entry, isCancelled: () => true),
        throwsA(
          isA<SttException>().having((error) => error.code, 'code', 'cancelled'),
        ),
      );
      expect(
        File('${store.modelDir(entry.id)}/test-encoder.int8.onnx').existsSync(),
        isFalse,
      );
    });

    test('an unhosted entry refuses to download', () async {
      final entry = entryFor(utf8.encode('x'));
      await expectLater(
        store.install(entry),
        throwsA(
          isA<SttException>().having((error) => error.code, 'code', 'not_hosted'),
        ),
      );
    });

    test('resolve returns null for a catalog model that is not installed', () {
      final entry = kSttCatalog.first;
      final settings = SttSettings(modelId: entry.id);
      expect(store.resolve(settings), isNull);
    });

    test('model_path override discovers files by name and skips checksums', () {
      writeVadAsset();
      final dir = Directory('${home.path}/manual-model')..createSync();
      File('${dir.path}/my-encoder.int8.onnx').writeAsBytesSync(const [1]);
      File('${dir.path}/my-decoder.int8.onnx').writeAsBytesSync(const [2]);
      File('${dir.path}/my-tokens.txt').writeAsStringSync('a 0');

      final files = store.resolve(
        SttSettings(modelPath: dir.path, language: 'ar'),
      );

      expect(files, isNotNull);
      expect(files!.modelId, 'path-override');
      expect(files.encoder, endsWith('my-encoder.int8.onnx'));
      expect(files.decoder, endsWith('my-decoder.int8.onnx'));
      expect(files.tokens, endsWith('my-tokens.txt'));
      expect(files.vad, store.vadPath);
    });

    test('an incomplete model_path names the missing artifact', () {
      writeVadAsset();
      final dir = Directory('${home.path}/manual-model')..createSync();
      File('${dir.path}/my-encoder.int8.onnx').writeAsBytesSync(const [1]);

      expect(
        () => store.resolve(SttSettings(modelPath: dir.path)),
        throwsA(
          isA<SttException>().having((error) => error.code, 'code', 'model_incomplete'),
        ),
      );
    });

    test('a model_path override without the shared vad asset is rejected', () {
      final dir = Directory('${home.path}/manual-model')..createSync();
      File('${dir.path}/e-encoder.int8.onnx').writeAsBytesSync(const [1]);
      File('${dir.path}/e-decoder.int8.onnx').writeAsBytesSync(const [2]);
      File('${dir.path}/e-tokens.txt').writeAsStringSync('a 0');

      expect(
        () => store.resolve(SttSettings(modelPath: dir.path)),
        throwsA(
          isA<SttException>().having((error) => error.code, 'code', 'vad_missing'),
        ),
      );
    });
  });
}
