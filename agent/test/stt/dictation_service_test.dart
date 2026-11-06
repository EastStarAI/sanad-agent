import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('dictation-service-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  void writeConfig(String contents) {
    File('${home.path}/config.yaml').writeAsStringSync(contents);
  }

  DictationService service({bool platformSupported = true}) => DictationService(
    sanadHome: home.path,
    platformSupported: platformSupported,
  );

  group('dictation readiness', () {
    test('an unsupported platform reports a machine readable reason', () {
      final readiness = service(platformSupported: false).readiness();
      expect(readiness.isSupported, isFalse);
      expect(readiness.reason, 'unsupported_platform');
    });

    test('a supported platform with default config is ready', () {
      expect(service().readiness().isSupported, isTrue);
    });

    test('stt.enabled=false disables dictation', () {
      writeConfig('''
stt:
  enabled: false
''');
      final readiness = service().readiness();
      expect(readiness.isSupported, isFalse);
      expect(readiness.reason, 'dictation_disabled');
    });

    test('an invalid stt section is reported instead of crashing', () {
      writeConfig('''
stt:
  threads: 99
''');
      final readiness = service().readiness();
      expect(readiness.isSupported, isFalse);
      expect(readiness.reason, contains('stt.threads'));
    });
  });

  group('dictation selection', () {
    test('the catalog default is selected initially', () {
      final subject = service();
      expect(subject.selectedModelId, defaultSttEntry.id);
      expect(subject.selectedEntry, isNotNull);
    });

    test('a persisted selection survives a new service instance', () async {
      final first = service();
      // Write a selection the way the socket handler does.
      await Directory(first.store.modelsRoot).create(recursive: true);
      await File(
        '${first.store.modelsRoot}/selection.json',
      ).writeAsString(jsonEncode({'model_id': 'whisper-base-int8'}));

      expect(service().selectedModelId, 'whisper-base-int8');
    });

    test('explicit config beats the persisted selection', () async {
      final subject = service();
      await Directory(subject.store.modelsRoot).create(recursive: true);
      await File(
        '${subject.store.modelsRoot}/selection.json',
      ).writeAsString(jsonEncode({'model_id': 'whisper-base-int8'}));
      writeConfig('''
stt:
  model_id: egy-whisper-turbo-int8
''');

      expect(service().selectedModelId, 'egy-whisper-turbo-int8');
    });

    test('a corrupt selection falls back to the default', () async {
      final subject = service();
      await Directory(subject.store.modelsRoot).create(recursive: true);
      await File(
        '${subject.store.modelsRoot}/selection.json',
      ).writeAsString('{not json');
      expect(service().selectedModelId, defaultSttEntry.id);
    });

    test('model_path override wins over everything', () {
      writeConfig('''
stt:
  model_id: whisper-base-int8
  model_path: /tmp/manual-model
''');
      expect(service().selectedModelId, 'path-override');
    });
  });

  group('dictation status payload', () {
    test('lists every visible catalog entry with install state', () {
      final payload = service().statusPayload();
      expect(payload['supported'], isTrue);
      final models = payload['models'] as List<Object?>;
      final visible = kSttCatalog.where((entry) => !entry.hidden).toList();
      expect(models, hasLength(visible.length));
      for (final model in models.cast<Map<String, Object?>>()) {
        expect(model['installed'], isFalse);
        expect(model['id'], isNotNull);
        expect(model['total_bytes'], greaterThan(0));
      }
      // Hidden entries stay usable through stt.model_id but never reach the UI.
      final ids = models
          .cast<Map<String, Object?>>()
          .map((model) => model['id'])
          .toSet();
      for (final entry in kSttCatalog.where((entry) => entry.hidden)) {
        expect(ids, isNot(contains(entry.id)));
      }
      expect(payload['selected'], defaultSttEntry.id);
    });

    test('installation of an unknown model fails with model_unknown', () async {
      await expectLater(
        service().install('nope'),
        throwsA(
          isA<Object>().having(
            (error) => error.toString(),
            'message',
            contains('model_unknown'),
          ),
        ),
      );
    });

    test('an unhosted model reports not_hosted instead of hanging', () async {
      const unhosted = SttCatalogEntry(
        id: 'unhosted-entry',
        label: 'Unhosted',
        note: 'no pinned URL',
        mode: SttModelMode.batchVad,
        language: 'ar',
        hosted: false,
        files: [
          SttModelFile(
            name: 'missing.onnx',
            url: '',
            sizeBytes: 1,
            sha256:
                '0000000000000000000000000000000000000000000000000000000000000000',
          ),
        ],
      );
      await expectLater(
        SttModelStore(sanadHome: home.path).install(unhosted),
        throwsA(
          isA<Object>().having(
            (error) => error.toString(),
            'message',
            contains('not_hosted'),
          ),
        ),
      );
    });
  });
}
