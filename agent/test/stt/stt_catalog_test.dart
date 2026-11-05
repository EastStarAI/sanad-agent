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

    test('Arabic entries stay batch+VAD because no Arabic streaming model exists', () {
      final arabic = kSttCatalog.where((entry) => entry.language == 'ar');
      expect(arabic.every((entry) => entry.mode == SttModelMode.batchVad), isTrue);
      // The only streaming entry is the English proof model (G5).
      final streaming = kSttCatalog.where(
        (entry) => entry.mode == SttModelMode.streaming,
      );
      expect(streaming.map((entry) => entry.id), ['en-streaming-zipformer-20m']);
      expect(streaming.single.language, 'en');
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
