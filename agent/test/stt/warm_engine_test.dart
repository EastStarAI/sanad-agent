import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/stt_engine.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

/// A recogniser whose only job is to record what the service asked of it.
class _FakeEngine implements SttEngine {
  _FakeEngine(this.modelId);

  final String modelId;

  bool started = false;
  bool disposed = false;
  bool resetCalled = false;

  @override
  SttReadyEvent? get ready => null;

  @override
  Stream<SttEvent> get events => const Stream.empty();

  @override
  Future<void> start(
    SttModelFiles files, {
    required String modelId,
    int threads = 2,
    bool useGpu = true,
  }) async {
    started = true;
  }

  @override
  void acceptAudio(Uint8List pcm16) {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> reset() async => resetCalled = true;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory home;
  late List<_FakeEngine> built;

  setUp(() {
    home = Directory.systemTemp.createTempSync('warm-engine-');
    built = <_FakeEngine>[];
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  void writeConfig(String contents) {
    File('${home.path}/config.yaml').writeAsStringSync(contents);
  }

  DictationService service() => DictationService(
    sanadHome: home.path,
    platformSupported: true,
    engineFactory: () {
      final engine = _FakeEngine('model-${built.length}');
      built.add(engine);
      return engine;
    },
  );

  SttModelFiles files(String id) => SttModelFiles(
    modelId: id,
    encoder: 'encoder.onnx',
    decoder: 'decoder.onnx',
    tokens: 'tokens.txt',
    vad: 'vad.onnx',
    language: 'ar',
  );

  group('warm recogniser', () {
    test('the default config keeps the model for five minutes', () {
      final stt = service();
      expect(stt.settings.keepsModelWarm, isTrue);
      expect(stt.settings.modelIdleMinutes, 5);
      expect(stt.settings.useGpu, isTrue);
    });

    test('an immediate unload frees the engine at the end of a session', () async {
      writeConfig('stt:\n  model_idle_minutes: 0\n');
      final stt = service();
      final engine = await stt.acquireEngine(files('m1')) as _FakeEngine;

      await stt.releaseEngine(engine, 'm1');

      expect(engine.disposed, isTrue);
      expect(stt.hasWarmEngine, isFalse);
    });

    test('a warm engine is reused and reset for the next session', () async {
      final stt = service();
      final first = await stt.acquireEngine(files('m1')) as _FakeEngine;
      await stt.releaseEngine(first, 'm1');
      expect(stt.hasWarmEngine, isTrue);
      expect(first.disposed, isFalse);

      final second = await stt.acquireEngine(files('m1')) as _FakeEngine;

      expect(identical(first, second), isTrue);
      expect(first.resetCalled, isTrue);
      // No second model load: the factory built exactly one engine.
      expect(built, hasLength(1));
      expect(stt.hasWarmEngine, isFalse);
    });

    test('switching models drops the warm one instead of stacking', () async {
      final stt = service();
      final first = await stt.acquireEngine(files('m1')) as _FakeEngine;
      await stt.releaseEngine(first, 'm1');

      final second = await stt.acquireEngine(files('m2')) as _FakeEngine;

      expect(identical(first, second), isFalse);
      expect(first.disposed, isTrue);
      expect(second.started, isTrue);
    });

    test('an explicit unload frees the warm model', () async {
      final stt = service();
      final engine = await stt.acquireEngine(files('m1')) as _FakeEngine;
      await stt.releaseEngine(engine, 'm1');

      await stt.unloadWarmEngine();

      expect(engine.disposed, isTrue);
      expect(stt.hasWarmEngine, isFalse);
    });

    test('never unload keeps the engine past the release', () async {
      writeConfig('stt:\n  model_idle_minutes: -1\n');
      final stt = service();
      final engine = await stt.acquireEngine(files('m1')) as _FakeEngine;
      await stt.releaseEngine(engine, 'm1');

      expect(engine.disposed, isFalse);
      expect(stt.hasWarmEngine, isTrue);
    });

    test('a config reload that disables warming frees the engine', () async {
      final stt = service();
      final engine = await stt.acquireEngine(files('m1')) as _FakeEngine;
      await stt.releaseEngine(engine, 'm1');

      writeConfig('stt:\n  model_idle_minutes: 0\n');
      stt.reloadSettings();
      // The unload is scheduled, not awaited by reloadSettings.
      await Future<void>.delayed(Duration.zero);

      expect(engine.disposed, isTrue);
    });
  });
}
