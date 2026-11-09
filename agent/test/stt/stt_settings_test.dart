import 'dart:ffi';
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

  group('gpu default', () {
    // Intel macOS is the one carve-out: the x64 whisper.cpp baseline has no
    // usable Metal path, so the default must not turn it on. Linux/Windows and
    // Apple Silicon keep their previous behaviour.
    test('the Intel macOS default is CPU', () {
      expect(defaultSttUseGpuFor(Abi.macosX64), isFalse);
    });

    test('every other mapped target keeps the GPU default', () {
      for (final abi in [
        Abi.macosArm64,
        Abi.linuxX64,
        Abi.linuxArm64,
        Abi.windowsX64,
        Abi.windowsArm64,
      ]) {
        expect(
          defaultSttUseGpuFor(abi),
          isTrue,
          reason: '$abi must keep the pre-existing default',
        );
      }
    });

    test('an absent use_gpu follows the default for this host', () {
      final settings = SttSettings.load(sanadHome: home.path);
      expect(settings.useGpu, defaultSttUseGpu());
    });

    test('an explicit use_gpu wins in both directions', () {
      writeConfig('''
stt:
  use_gpu: true
''');
      expect(SttSettings.load(sanadHome: home.path).useGpu, isTrue);

      writeConfig('''
stt:
  use_gpu: false
''');
      expect(SttSettings.load(sanadHome: home.path).useGpu, isFalse);
    });
  });

  group('stt settings', () {
    test('the default thread count follows the machine width', () {
      // Small machines never oversubscribe; wide ones stop at the measured knee.
      expect(sttThreadsFor(2), 2);
      expect(sttThreadsFor(4), 4);
      expect(sttThreadsFor(6), 4);
      expect(sttThreadsFor(8), 6);
      expect(sttThreadsFor(10), 6);
      expect(sttThreadsFor(0), 4);
    });

    test('defaults are used when config.yaml is absent', () {
      final settings = SttSettings.load(sanadHome: home.path);
      expect(settings.enabled, isTrue);
      expect(settings.effectiveModelId, defaultSttEntry.id);
      expect(settings.language, 'ar');
      expect(settings.threads, 4);
      expect(settings.modelPath, isNull);
      // Metal on by default on macOS arm64; the model stays warm for 5 minutes.
      expect(settings.useGpu, isTrue);
      expect(settings.modelIdleMinutes, 5);
      expect(settings.keepsModelWarm, isTrue);
    });

    test('a full stt section is parsed', () {
      writeConfig('''
stt:
  enabled: false
  model_id: whisper-base-int8
  model_path: /tmp/models/whisper-x
  language: en
  threads: 4
  use_gpu: false
  model_idle_minutes: 0
''');
      final settings = SttSettings.load(sanadHome: home.path);
      expect(settings.enabled, isFalse);
      expect(settings.effectiveModelId, 'whisper-base-int8');
      expect(settings.modelPath, '/tmp/models/whisper-x');
      expect(settings.language, 'en');
      expect(settings.threads, 4);
      expect(settings.useGpu, isFalse);
      expect(settings.modelIdleMinutes, 0);
      expect(settings.keepsModelWarm, isFalse);
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
