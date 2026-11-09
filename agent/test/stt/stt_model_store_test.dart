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

  /// Bytes this server serves, keyed by request path.
  final served = <String, List<int>>{};

  String urlFor(List<int> payload) {
    final path = '/${sha256.convert(payload)}.onnx';
    served[path] = payload;
    return 'http://${server.address.address}:${server.port}$path';
  }

  setUp(() async {
    home = Directory.systemTemp.createTempSync('stt-store-');
    served.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final payload = served[request.uri.path];
      if (payload == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(payload);
      }
      await request.response.close();
    });
    // The shared VAD is the one artifact a catalog entry does not carry, so the
    // store is handed a loopback descriptor with the production asset's name: a
    // unit test must never fetch the live third-party release URL.
    final vadPayload = utf8.encode('fake silero vad');
    store = SttModelStore(
      sanadHome: home.path,
      sharedVadAsset: SttModelFile(
        name: kSileroVadFile.name,
        url: urlFor(vadPayload),
        sizeBytes: vadPayload.length,
        sha256: sha256.convert(vadPayload).toString(),
      ),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  SttCatalogEntry entryFor(List<int> payload, {String? sha, String url = ''}) {
    return SttCatalogEntry(
      id: 'test-model',
      name: 'Test model',
      description: const {'en': 'A test model.'},
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

  /// Materialises a catalog entry on disk as sparse files: only the declared
  /// length matters to `statusOf()`, so no model bytes are involved.
  void installCatalogEntry(SttCatalogEntry entry) {
    Directory(store.modelDir(entry.id)).createSync(recursive: true);
    for (final file in entry.files) {
      final handle = File(
        '${store.modelDir(entry.id)}/${file.name}',
      ).openSync(mode: FileMode.write);
      handle.truncateSync(file.sizeBytes);
      handle.closeSync();
    }
  }

  group('stt model store', () {
    test('resolve returns real on-disk paths for an installed catalog model', () {
      final entry = kSttCatalog.firstWhere((e) => e.id == 'whisper-base-int8');
      Directory(store.modelDir(entry.id)).createSync(recursive: true);
      for (final file in entry.files) {
        final handle = File(
          '${store.modelDir(entry.id)}/${file.name}',
        ).openSync(mode: FileMode.write);
        // Sparse files: only the declared length matters to statusOf().
        handle.truncateSync(file.sizeBytes);
        handle.closeSync();
      }
      writeVadAsset();

      final files = store.resolve(
        const SttSettings(),
        selectedModelId: 'whisper-base-int8',
      );

      expect(files, isNotNull);
      expect(files!.modelId, 'whisper-base-int8');
      expect(File(files.encoder).existsSync(), isTrue);
      expect(File(files.decoder).existsSync(), isTrue);
      expect(File(files.tokens).existsSync(), isTrue);
      expect(File(files.vad).existsSync(), isTrue);
    });

    test('resolveModelId prefers config, then the selection, then the default', () {
      const fromConfig = SttSettings(modelId: 'whisper-base-int8');
      const noConfig = SttSettings();

      expect(
        store.resolveModelId(fromConfig, selectedModelId: 'egy-whisper-turbo-int8'),
        'whisper-base-int8',
      );
      expect(
        store.resolveModelId(noConfig, selectedModelId: 'whisper-base-int8'),
        'whisper-base-int8',
      );
      expect(store.resolveModelId(noConfig), defaultSttEntry.id);
    });
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
      final entry = entryFor(payload, url: urlFor(payload));
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

    test('install reports one cumulative total across artifacts', () async {
      final payload = utf8.encode('cumulative payload');
      final entry = entryFor(payload, url: urlFor(payload));
      final pairs = <String>[];

      await store.install(
        entry,
        onProgress: (_, received, total) => pairs.add('$received/$total'),
      );

      expect(pairs, isNotEmpty);
      final receivedValues = pairs
          .map((pair) => int.parse(pair.split('/').first))
          .toList();
      final totals = pairs.map((pair) => int.parse(pair.split('/').last)).toSet();
      // One grand total for the whole install, so the client bar is monotonic
      // instead of restarting per file.
      expect(totals, hasLength(1));
      expect(receivedValues.last, totals.first);
      for (var i = 1; i < receivedValues.length; i++) {
        expect(receivedValues[i], greaterThanOrEqualTo(receivedValues[i - 1]));
      }
    });

    test('a checksum mismatch never activates the file', () async {
      final payload = utf8.encode('payload');
      final entry = entryFor(
        payload,
        url: urlFor(payload),
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
      final entry = entryFor(payload, url: urlFor(payload));

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

    test('resolve returns the ggml file for a whisper.cpp entry', () {
      final entry = kSttCatalog.firstWhere(
        (e) => e.engine == SttEngineKind.whisperCpp,
      );
      installCatalogEntry(entry);

      final files = store.resolve(
        const SttSettings(),
        selectedModelId: entry.id,
      );

      expect(files, isNotNull);
      expect(files!.engine, SttEngineKind.whisperCpp);
      expect(files.model, endsWith(entry.files.single.name));
      expect(File(files.model).existsSync(), isTrue);
      // The sherpa artifacts are not part of a whisper.cpp entry.
      expect(files.encoder, isEmpty);
      expect(files.vad, isEmpty);
      // A catalog row decodes the language it declares. The daemon-wide
      // `stt.language` describes a `stt.model_path` override, which has no
      // catalog metadata, and must never override a catalog row.
      expect(files.language, entry.language);
    });

    test('an English entry decodes English while stt.language defaults to Arabic', () {
      final entry = sttEntryById('whisper-small-en-ggml-q8')!;
      installCatalogEntry(entry);

      final files = store.resolve(
        const SttSettings(),
        selectedModelId: entry.id,
      );

      expect(files, isNotNull);
      // `SttSettings()` defaults to 'ar'. Handing that to an English-only
      // checkpoint is the defect this pins: the decode came back as Arabic text
      // with no error at all.
      expect(files!.language, 'en');
    });

    test('a model_path holding one ggml file resolves to whisper.cpp', () {
      final dir = Directory('${home.path}/ggml-model')..createSync();
      File('${dir.path}/ggml-custom-turbo-q5_0.bin').writeAsBytesSync(
        const [1],
      );

      final files = store.resolve(SttSettings(modelPath: dir.path));

      expect(files, isNotNull);
      expect(files!.engine, SttEngineKind.whisperCpp);
      expect(files.model, endsWith('ggml-custom-turbo-q5_0.bin'));
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
