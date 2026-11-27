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

  // The owning resolver for this host's width, so no assertion restates a
  // host-specific literal.
  int resolvedFor(Abi abi) =>
      defaultSttThreadsFor(abi, Platform.numberOfProcessors);

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

    test('an absent use_gpu follows the Intel carve-out on Intel macOS', () {
      // The resolver is host-bound, so the Intel branch is only provable here by
      // naming the host: the same absent config must produce both answers.
      expect(
        SttSettings.load(sanadHome: home.path, abi: Abi.macosX64).useGpu,
        isFalse,
      );
      expect(
        SttSettings.load(sanadHome: home.path, abi: Abi.macosArm64).useGpu,
        isTrue,
      );
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

  group('thread default', () {
    // Windows x64 runs CPU inference. The accepted Windows benchmark had four
    // threads meeting its interactive targets while six cost materially more
    // CPU, so the implicit default must never exceed four there.
    test('Windows x64 caps the implicit default at four', () {
      expect(defaultSttThreadsFor(Abi.windowsX64, 2), 2);
      expect(defaultSttThreadsFor(Abi.windowsX64, 4), 4);
      expect(defaultSttThreadsFor(Abi.windowsX64, 8), 4);
      expect(defaultSttThreadsFor(Abi.windowsX64, 16), 4);
    });

    test('the Windows x64 cap still refuses to oversubscribe small hosts', () {
      expect(defaultSttThreadsFor(Abi.windowsX64, 1), 1);
      expect(defaultSttThreadsFor(Abi.windowsX64, 3), 3);
    });

    test('non-Windows ABIs keep the wide-machine six-thread policy', () {
      // The Metal curve plateaus at five, so the pre-existing policy stays: the
      // whisper.cpp baseline below eight cores, six from eight up.
      for (final abi in [
        Abi.macosArm64,
        Abi.macosX64,
        Abi.linuxX64,
        Abi.linuxArm64,
      ]) {
        expect(
          defaultSttThreadsFor(abi, 2),
          2,
          reason: '$abi must not oversubscribe',
        );
        expect(
          defaultSttThreadsFor(abi, 6),
          4,
          reason: '$abi keeps min(4, cores)',
        );
        expect(
          defaultSttThreadsFor(abi, 8),
          6,
          reason: '$abi keeps the wide policy',
        );
        expect(
          defaultSttThreadsFor(abi, 16),
          6,
          reason: '$abi keeps the wide policy',
        );
      }
    });

    test('an unknown or non-positive core count stays bounded at four', () {
      for (final abi in [Abi.windowsX64, Abi.macosArm64, Abi.linuxX64]) {
        expect(defaultSttThreadsFor(abi, 0), 4, reason: '$abi');
        expect(defaultSttThreadsFor(abi, -1), 4, reason: '$abi');
      }
    });

    test('an absent threads key follows the ABI resolver, not a literal', () {
      expect(SttSettings.load(sanadHome: home.path).threads, defaultSttThreads);
      // The same empty home must resolve differently per named ABI, which a
      // host-bound getter alone cannot prove.
      expect(
        SttSettings.load(sanadHome: home.path, abi: Abi.windowsX64).threads,
        resolvedFor(Abi.windowsX64),
      );
      expect(
        SttSettings.load(sanadHome: home.path, abi: Abi.macosArm64).threads,
        resolvedFor(Abi.macosArm64),
      );
    });

    test('a stt section without threads follows the ABI resolver too', () {
      writeConfig('''
stt:
  enabled: true
''');
      expect(
        SttSettings.load(sanadHome: home.path, abi: Abi.windowsX64).threads,
        resolvedFor(Abi.windowsX64),
      );
      expect(
        SttSettings.load(sanadHome: home.path, abi: Abi.linuxX64).threads,
        resolvedFor(Abi.linuxX64),
      );
    });

    test('an explicit threads value wins over every ABI default', () {
      writeConfig('''
stt:
  threads: 6
''');
      for (final abi in [Abi.windowsX64, Abi.macosArm64, Abi.linuxX64]) {
        expect(
          SttSettings.load(sanadHome: home.path, abi: abi).threads,
          6,
          reason: '$abi must keep the explicit value',
        );
      }
    });
  });

  group('stt settings', () {
    test('defaults are used when config.yaml is absent', () {
      final settings = SttSettings.load(sanadHome: home.path);
      expect(settings.enabled, isTrue);
      expect(settings.effectiveModelId, defaultSttEntry.id);
      expect(settings.language, 'ar');
      expect(settings.threads, defaultSttThreads);
      expect(settings.modelPath, isNull);
      // Metal on by default except on Intel macOS, where the x64 baseline has
      // no GPU backend: the assertion follows the host resolver.
      expect(settings.useGpu, defaultSttUseGpu());
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
