import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

void main() {
  group('stt catalog', () {
    test('ids are unique and non-empty', () {
      final ids = kSttCatalog.map((entry) => entry.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every((id) => id.trim().isNotEmpty), isTrue);
    });

    test('every file pins a 64-char sha256 and a positive size', () {
      for (final entry in kSttCatalog) {
        expect(entry.files, isNotEmpty, reason: entry.id);
        for (final file in entry.files) {
          expect(file.sha256.length, 64, reason: '${entry.id}/${file.name}');
          expect(
            RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256),
            isTrue,
            reason: '${entry.id}/${file.name}',
          );
          expect(file.sizeBytes, greaterThan(0));
        }
        expect(entry.totalBytes, greaterThan(0));
      }
    });

    test('hosted entries carry URLs and unhosted entries do not', () {
      for (final entry in kSttCatalog) {
        final urls = entry.files.map((file) => file.url).toList();
        if (entry.hosted) {
          expect(urls.every((url) => url.startsWith('http')), isTrue);
        } else {
          expect(urls.every((url) => url.isEmpty), isTrue);
        }
      }
    });

    test('exactly one entry is the default and it resolves by id', () {
      final defaults = kSttCatalog.where((entry) => entry.isDefault).toList();
      expect(defaults, hasLength(1));
      expect(defaultSttEntry.id, defaults.single.id);
      expect(sttEntryById(defaults.single.id), same(defaults.single));
      expect(sttEntryById('no-such-model'), isNull);
    });

    test('Arabic now has one honest streaming entry and batch stays batch', () {
      final arabic = kSttCatalog.where((entry) => entry.language == 'ar');
      final batch = arabic.where((entry) => entry.mode == SttModelMode.batchVad);
      final streaming = arabic.where(
        (entry) => entry.mode == SttModelMode.streaming,
      );
      // whisper.cpp remains the Arabic runtime for the default and the lighter
      // builds; the sherpa int8 batch entry is still there as a fallback.
      expect(batch, isNotEmpty);
      expect(
        batch.any((entry) => entry.engine == SttEngineKind.whisperCpp),
        isTrue,
      );
      // ...and exactly one Arabic entry streams, because a sherpa-packaged
      // Arabic export exists (measured: it transcribes Arabic while audio plays).
      expect(streaming.map((entry) => entry.id), [
        'multilingual-streaming-zipformer-2025-02-10',
      ]);
      expect(streaming.single.streamingModelType, 'zipformer2');
    });

    test('visible streaming entries are the probed ones only', () {
      final visible = kSttCatalog
          .where(
            (entry) =>
                entry.mode == SttModelMode.streaming && !entry.hidden,
          )
          .map((entry) => entry.id)
          .toList();
      expect(visible, [
        'en-streaming-zipformer-kroko-2025-08-06',
        'multilingual-streaming-zipformer-2025-02-10',
      ]);
      for (final entry in kSttCatalog.where(
        (entry) => entry.mode == SttModelMode.streaming && !entry.hidden,
      )) {
        // Every shipped streaming model declares its own export dialect, which is
        // what made the 2023 failure possible in the first place.
        expect(entry.streamingModelType, isNotEmpty);
        expect(entry.hosted, isTrue);
      }
    });

    test('the streaming entry supersedes the model that was measured unusable', () {
      final model = sttEntryById('en-streaming-zipformer-2023-06-26')!;
      expect(model.hosted, isTrue);
      expect(model.mode, SttModelMode.streaming);
      // 2023-06-26 left-64 int8: 71,082,637 B encoder + decoder, joiner, tokens.
      expect(model.totalBytes, 72654256);
      final retired = sttEntryById('en-streaming-zipformer-20m')!;
      expect(retired.hidden, isTrue, reason: 'kept only for old installs');
    });

    test('the egyptian default and the light fallback are both present', () {
      expect(sttEntryById('egy-whisper-turbo-ggml-q8'), isNotNull);
      expect(sttEntryById('whisper-base-int8'), isNotNull);
      // The default is the hosted Egyptian ggml build: whisper.cpp keeps the
      // memory peak under 1.2 GB, which the ONNX int8 entry could not.
      expect(defaultSttEntry.id, 'egy-whisper-turbo-ggml-q8');
      expect(defaultSttEntry.engine, SttEngineKind.whisperCpp);
      expect(defaultSttEntry.hosted, isTrue);
      final light = sttEntryById('egy-whisper-turbo-ggml-q5')!;
      expect(light.engine, SttEngineKind.whisperCpp);
      expect(light.totalBytes, lessThan(defaultSttEntry.totalBytes));
    });

    test('the f16 precision entry is offered once its artifact is hosted', () {
      final precise = sttEntryById('egy-whisper-turbo-ggml-f16');
      expect(precise, isNotNull);
      // Hidden entries would never reach the sheet, so a regression here means
      // the 1.62 GB build becomes unreachable again.
      expect(precise!.hidden, isFalse);
      expect(precise.hosted, isTrue);
      expect(precise.totalBytes, greaterThan(defaultSttEntry.totalBytes));
    });
  });
}
