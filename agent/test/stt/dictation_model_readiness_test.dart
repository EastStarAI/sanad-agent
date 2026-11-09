import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:test/test.dart';

import '../support/native_binary_fixture.dart';

/// Readiness is two facts, and the second one is the model.
///
/// A Home with no installed model reported `ready: true`, so the composer
/// started a session that the daemon refused with `model_not_installed`, and the
/// install sheet — which only opens for a device that is not ready — never
/// appeared. These tests pin readiness to the model the session would load.
void main() {
  late Directory home;
  late Directory workdir;
  late Directory previous;

  String platformDir() =>
      SttNativeTarget.tryCurrent()?.nativeDirectory ?? 'macos';

  /// Writes the whisper shim for this CPU so the runtime gate passes and the
  /// only remaining question is the model.
  void installRuntime() {
    final target = SttNativeTarget.tryCurrent();
    if (target == null) return;
    File(
      '${workdir.path}/native/${target.nativeDirectory}/${target.shimFileName}',
    ).writeAsBytesSync(nativeBinaryFor(target.os, target.cpu));
  }

  /// A `stt.model_path` override pointing at one ggml file is a loadable model
  /// without downloading 800 MB in a unit test.
  String installOverrideModel() {
    final dir = Directory('${workdir.path}/manual-model')
      ..createSync(recursive: true);
    File('${dir.path}/ggml-trial.bin').writeAsBytesSync(List<int>.filled(8, 0));
    return dir.path;
  }

  DictationService service({String config = ''}) {
    File('${home.path}/config.yaml').writeAsStringSync(config);
    return DictationService(sanadHome: home.path, platformSupported: true);
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('dictation-model-home-');
    workdir = Directory.systemTemp.createTempSync('dictation-model-cwd-');
    Directory('${workdir.path}/native/${platformDir()}')
        .createSync(recursive: true);
    previous = Directory.current;
    Directory.current = workdir;
  });

  tearDown(() {
    Directory.current = previous;
    for (final dir in [home, workdir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('readiness', () {
    test('a device with no installed model is not ready, and says so', () {
      installRuntime();
      final readiness = service().readiness();

      expect(readiness.isReady, isFalse);
      expect(readiness.reason, 'model_not_installed');
      // The device can dictate; only the model is missing. Keeping `supported`
      // true is what keeps the mic visible and the sheet reachable.
      expect(readiness.isSupported, isTrue);
    });

    test('the status payload repeats the model reason instead of "ready"', () {
      installRuntime();
      final status = service().statusPayload();

      expect(status['supported'], isTrue);
      expect(status['ready'], isFalse);
      expect(status['reason'], 'model_not_installed');
    });

    test('the settings projection cannot call a model-less device ready', () {
      installRuntime();
      final settings = service().settingsSnapshot();

      expect(settings['ready'], isFalse);
      expect(settings['reason'], 'model_not_installed');
    });

    test('an installed override model makes the device ready', () {
      installRuntime();
      final path = installOverrideModel();
      final readiness = service(
        config: 'stt:\n  model_path: $path\n',
      ).readiness();

      expect(readiness.isReady, isTrue);
      expect(readiness.reason, isNull);
    });

    test('an override path that no longer resolves is not ready', () {
      installRuntime();
      final readiness = service(
        config: 'stt:\n  model_path: ${workdir.path}/gone\n',
      ).readiness();

      expect(readiness.isReady, isFalse);
      expect(readiness.reason, 'model_not_installed');
    });

    test('a missing runtime outranks a missing model', () {
      // Both are actionable, but the engine is the one the sheet can install
      // from a developer checkout, so it is the reason worth reporting.
      final readiness = service().readiness();

      expect(readiness.isReady, isFalse);
      expect(readiness.reason, isNot('model_not_installed'));
      expect(readiness.isSupported, isTrue);
    });
  });

  group('catalog rows', () {
    test('every row carries a name, a locale map, and closed-set facts', () {
      installRuntime();
      final rows = (service().statusPayload()['models'] as List)
          .cast<Map<String, dynamic>>();
      final visible = kSttCatalog.where((entry) => !entry.hidden).toList();

      expect(rows, hasLength(visible.length));
      for (final row in rows) {
        expect(row['name'], isA<String>());
        final description = row['description'] as Map<String, dynamic>;
        expect(description['en'], isNotEmpty);
        expect(description['ar'], isNotEmpty);
        expect(row['speed_tier'], inInclusiveRange(1, 4));
        expect(row['streaming'], isA<bool>());
        expect(row['location'], 'local');
        expect(row['size_bytes'], isA<int>());
        // The daemon ships no sentences of its own: no legacy label/note keys.
        expect(row.containsKey('label'), isFalse);
        expect(row.containsKey('note'), isFalse);
        expect(row.containsKey('total_bytes'), isFalse);
      }
    });

    test('the badge set is closed and only the default row is recommended', () {
      installRuntime();
      final rows = (service().statusPayload()['models'] as List)
          .cast<Map<String, dynamic>>();
      final badges = rows
          .map((row) => row['badge'])
          .whereType<String>()
          .toList();

      expect(badges, contains('recommended'));
      expect(badges.where((badge) => badge == 'recommended'), hasLength(1));
      for (final badge in badges) {
        expect(
          {'recommended', 'faster', 'more_accurate', 'custom'},
          contains(badge),
        );
      }
      // The recommended row is the catalog default, so "recommended" and
      // "what the device picks on its own" cannot drift apart.
      final defaultEntry = kSttCatalog.firstWhere((entry) => entry.isDefault);
      expect(defaultEntry.badge.code, 'recommended');
    });

    test('model names are proper nouns, not per-locale copy', () {
      for (final entry in kSttCatalog) {
        expect(entry.name.trim(), isNotEmpty);
        // A name that appears in the Arabic description map would be copy, and
        // copy belongs in the description only.
        expect(
          entry.description.values.any((text) => text == entry.name),
          isFalse,
          reason: '${entry.id} describes itself with its own name',
        );
      }
    });
  });
}
