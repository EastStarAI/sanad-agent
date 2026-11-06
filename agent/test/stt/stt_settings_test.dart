import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_settings.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('stt-settings-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  void writeConfig(String contents) {
    File('${home.path}/config.yaml').writeAsStringSync(contents);
  }

  group('stt settings', () {
    test('defaults are used when config.yaml is absent', () {
      final settings = SttSettings.load(sanadHome: home.path);
      expect(settings.enabled, isTrue);
      expect(settings.effectiveModelId, defaultSttEntry.id);
      expect(settings.language, 'ar');
      expect(settings.threads, 4);
      expect(settings.modelPath, isNull);
    });

    test('a full stt section is parsed', () {
      writeConfig('''
stt:
  enabled: false
  model_id: whisper-base-int8
  model_path: /tmp/models/whisper-x
  language: en
  threads: 4
''');
      final settings = SttSettings.load(sanadHome: home.path);
      expect(settings.enabled, isFalse);
      expect(settings.effectiveModelId, 'whisper-base-int8');
      expect(settings.modelPath, '/tmp/models/whisper-x');
      expect(settings.language, 'en');
      expect(settings.threads, 4);
    });

    test('an unknown model id fails with the offending key', () {
      writeConfig('''
stt:
  model_id: not-a-model
''');
      expect(
        () => SttSettings.load(sanadHome: home.path),
        throwsA(
          isA<SttException>()
              .having((error) => error.code, 'code', 'config_invalid')
              .having((error) => error.message, 'message', contains('stt.model_id')),
        ),
      );
    });

    test('thread counts outside 1..16 are rejected', () {
      writeConfig('''
stt:
  threads: 0
''');
      expect(
        () => SttSettings.load(sanadHome: home.path),
        throwsA(
          isA<SttException>()
              .having((error) => error.message, 'message', contains('stt.threads')),
        ),
      );
    });

    test('a non-boolean enabled flag is rejected', () {
      writeConfig('''
stt:
  enabled: yes-please
''');
      expect(
        () => SttSettings.load(sanadHome: home.path),
        throwsA(
          isA<SttException>()
              .having((error) => error.message, 'message', contains('stt.enabled')),
        ),
      );
    });

    test('a scalar stt section is rejected', () {
      writeConfig('''
stt: disabled
''');
      expect(
        () => SttSettings.load(sanadHome: home.path),
        throwsA(isA<SttException>()),
      );
    });
  });
}
