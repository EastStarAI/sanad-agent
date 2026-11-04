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

    test('v1 entries are batch+VAD because no Arabic streaming model exists', () {
      expect(
        kSttCatalog.every((entry) => entry.mode == SttModelMode.batchVad),
        isTrue,
      );
    });

    test('the egyptian default and the light fallback are both present', () {
      expect(sttEntryById('egy-whisper-turbo-int8'), isNotNull);
      expect(sttEntryById('whisper-base-int8'), isNotNull);
      expect(defaultSttEntry.id, 'egy-whisper-turbo-int8');
      final light = sttEntryById('whisper-base-int8')!;
      expect(light.isDefault, isFalse);
      expect(light.hosted, isTrue);
      expect(light.totalBytes, lessThan(defaultSttEntry.totalBytes));
    });
  });
}
