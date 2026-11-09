import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';
import 'package:test/test.dart';

/// The dictation engine is swappable, so both builds have to be provable on one
/// machine: every case below runs twice, once with the sherpa engine and once
/// without it.
///
/// A build without sherpa is the Linux arm64 Agent, which resolves with the
/// standalone Dart SDK and therefore links `packages/stt_sherpa_stub`. It must be
/// a complete build — whisper batch dictation, no streaming, no VAD — not a
/// build that offers models it cannot load.
void main() {
  const withSherpa = SttEngineAvailability(sherpa: true);
  const withoutSherpa = SttEngineAvailability(sherpa: false);

  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('sanad-stt-availability-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  DictationService serviceFor(SttEngineAvailability availability) =>
      DictationService(
        sanadHome: home.path,
        platformSupported: true,
        availability: availability,
      );

  group('engine availability', () {
    test('a sherpa build advertises streaming and both engines', () {
      expect(withSherpa.supports(SttEngineKind.sherpa), isTrue);
      expect(withSherpa.supports(SttEngineKind.whisperCpp), isTrue);
      expect(withSherpa.streaming, isTrue);
    });

    test('a build without sherpa is batch-only, never broken', () {
      expect(withoutSherpa.supports(SttEngineKind.sherpa), isFalse);
      expect(withoutSherpa.supports(SttEngineKind.whisperCpp), isTrue);
      // Streaming and VAD are sherpa features: without it the daemon publishes
      // finals only, which is exactly what the Client already renders.
      expect(withoutSherpa.streaming, isFalse);
    });
  });

  group('catalog selection', () {
    test('a sherpa build keeps every entry', () {
      final usable = usableSttEntries(withSherpa);
      expect(usable, hasLength(kSttCatalog.length));
      expect(usable.any((entry) => entry.mode == SttModelMode.streaming), isTrue);
    });

    test('a build without sherpa drops every sherpa entry', () {
      final usable = usableSttEntries(withoutSherpa);
      expect(usable, isNotEmpty);
      expect(
        usable.where((entry) => entry.engine != SttEngineKind.whisperCpp),
        isEmpty,
      );
      // The streaming entries are exactly the ones that disappear.
      expect(usable.any((entry) => entry.mode == SttModelMode.streaming), isFalse);
    });

    test('a build without sherpa still offers an English model', () async {
      // The Linux arm64 Agent links no sherpa engine, so English dictation used
      // to be impossible there: every English row was a sherpa one. An English
      // whisper entry has to survive the availability filter.
      final english = usableSttEntries(withoutSherpa).where(
        (entry) => entry.language == 'en',
      );
      expect(
        english.map((entry) => entry.id),
        containsAll(<String>[
          'whisper-small-en-ggml-q8',
          'whisper-medium-en-ggml-q8',
        ]),
      );
      expect(
        english.every((entry) => entry.engine == SttEngineKind.whisperCpp),
        isTrue,
      );
      // ...and it is selectable, which is what a user's English choice needs.
      final service = serviceFor(withoutSherpa);
      await service.selectModel('whisper-small-en-ggml-q8');
      expect(service.selectedModelId, 'whisper-small-en-ggml-q8');
    });

    test('the default follows the build, not the catalog order', () {
      expect(defaultUsableSttEntry(withSherpa)?.id, defaultSttEntry.id);
      expect(defaultUsableSttEntry(withoutSherpa)?.id, defaultSttEntry.id);
      // The catalog default is a whisper entry, so both builds agree today; the
      // fallback still matters for a future sherpa-only default.
      expect(defaultSttEntry.engine, SttEngineKind.whisperCpp);
    });
  });

  group('daemon surface', () {
    test('a stored sherpa selection falls back on a build without sherpa', () {
      final models = Directory('${home.path}/models/stt')
        ..createSync(recursive: true);
      // A visible sherpa entry: a hidden one is filtered for a different reason,
      // so it could not prove the build fallback.
      final sherpaEntry = kSttCatalog.firstWhere(
        (entry) => entry.engine == SttEngineKind.sherpa && !entry.hidden,
      );
      File('${models.path}/selection.json').writeAsStringSync(
        jsonEncode({'model_id': sherpaEntry.id}),
      );

      final without = serviceFor(withoutSherpa);
      expect(without.selectedModelId, isNot(sherpaEntry.id));
      expect(without.selectedModelId, defaultSttEntry.id);

      // The same file on a sherpa build keeps the streaming model, so the
      // fallback is about the build and nothing else.
      final withIt = serviceFor(withSherpa);
      expect(withIt.selectedModelId, sherpaEntry.id);
    });

    test('the model rows never offer an engine this build lacks', () {
      final without = serviceFor(withoutSherpa);
      final rows = (without.statusPayload()['models'] as List)
          .cast<Map<String, dynamic>>();
      expect(rows, isNotEmpty);
      expect(rows.where((row) => row['engine'] == 'sherpa'), isEmpty);
      expect(rows.where((row) => row['mode'] == 'streaming'), isEmpty);

      final withIt = serviceFor(withSherpa);
      final all = (withIt.statusPayload()['models'] as List)
          .cast<Map<String, dynamic>>();
      expect(all.where((row) => row['engine'] == 'sherpa'), isNotEmpty);
    });

    test('selecting a model this build cannot run is refused, not stored', () {
      final sherpaEntry = kSttCatalog.firstWhere(
        (entry) => entry.engine == SttEngineKind.sherpa && !entry.hidden,
      );
      expect(
        () => serviceFor(withoutSherpa).selectModel(sherpaEntry.id),
        throwsA(
          isA<SttException>().having(
            (error) => error.code,
            'code',
            'model_unavailable',
          ),
        ),
      );
      expect(
        File('${home.path}/models/stt/selection.json').existsSync(),
        isFalse,
      );
    });

    test('readiness is unchanged where whisper is installed', () {
      // The runtime is absent in this harness, so readiness names the runtime
      // rather than the build: a build without sherpa is still a dictating build.
      final readiness = serviceFor(withoutSherpa).readiness();
      expect(readiness.isSupported, isTrue);
      if (!WhisperCppLibrary.isAvailable) {
        expect(readiness.isReady, isFalse);
        expect(readiness.reason, isNot('dictation_unavailable'));
      }
    });

    test('no usable engine at all reports the stable refusal', () {
      const nothing = SttEngineAvailability(sherpa: false, whisperCpp: false);
      final readiness = serviceFor(nothing).readiness();
      expect(readiness.isSupported, isFalse);
      expect(readiness.isReady, isFalse);
      expect(readiness.reason, 'dictation_unavailable');
    });
  });
}
