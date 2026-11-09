import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/stt_catalog.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  /// The engines this build was compiled with. The service answers from the
  /// same object, so every expectation below holds on the sherpa build and on
  /// the whisper-only build: a literal id or count encodes only one of them.
  const availability = SttEngineAvailability.build();

  /// The rows this build offers: usable here, and not hidden from the surface.
  List<SttCatalogEntry> visibleUsableEntries() =>
      usableSttEntries(availability).where((entry) => !entry.hidden).toList();

  /// A visible entry that is not the resolved default, so honoring a selection
  /// is observable on both builds.
  String alternativeUsableId() => visibleUsableEntries()
      .firstWhere((entry) => entry.id != defaultUsableSttEntry(availability)?.id)
      .id;

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
      expect(
        readiness.reason,
        'config_invalid',
        reason: 'the event carries a stable code, never a parser message',
      );
    });
  });

  group('dictation selection', () {
    test('the catalog default is selected initially', () {
      final subject = service();
      // The default *for this build*: a whisper-only build never starts on a
      // model whose engine it does not have.
      expect(subject.selectedModelId, defaultUsableSttEntry(availability)!.id);
      expect(subject.selectedEntry, isNotNull);
    });

    test('a persisted selection survives a new service instance', () async {
      final first = service();
      final persisted = alternativeUsableId();
      // Write a selection the way the socket handler does.
      await Directory(first.store.modelsRoot).create(recursive: true);
      await File(
        '${first.store.modelsRoot}/selection.json',
      ).writeAsString(jsonEncode({'model_id': persisted}));

      expect(service().selectedModelId, persisted);
    });

    test('explicit config beats the persisted selection', () async {
      final subject = service();
      final configured = visibleUsableEntries().first.id;
      final persisted = alternativeUsableId();
      await Directory(subject.store.modelsRoot).create(recursive: true);
      await File(
        '${subject.store.modelsRoot}/selection.json',
      ).writeAsString(jsonEncode({'model_id': persisted}));
      writeConfig('''
stt:
  model_id: $configured
''');

      expect(service().selectedModelId, configured);
    });

    test('a corrupt selection falls back to the default', () async {
      final subject = service();
      await Directory(subject.store.modelsRoot).create(recursive: true);
      await File(
        '${subject.store.modelsRoot}/selection.json',
      ).writeAsString('{not json');
      expect(service().selectedModelId, defaultUsableSttEntry(availability)!.id);
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

  group('dictation runtime settings', () {
    test('the enabled toggle persists and is reported back', () async {
      final subject = service();
      expect(subject.settingsSnapshot()['enabled'], isTrue);

      await subject.applyEnabled(false);

      expect(subject.settings.enabled, isFalse);
      expect(subject.settingsSnapshot()['enabled'], isFalse);
      expect(
        subject.readiness().reason,
        'dictation_disabled',
        reason: 'the capability follows the persisted toggle',
      );
      // Persisted, not just in memory: a new daemon reads the same value.
      expect(service().settings.enabled, isFalse);
    });

    test('an explicit config.yaml value owns the toggle', () async {
      writeConfig('''
stt:
  enabled: true
''');
      final subject = service();
      expect(subject.settingsSnapshot()['managed_externally'], isTrue);
      await expectLater(
        subject.applyEnabled(false),
        throwsA(
          isA<Object>().having(
            (error) => error.toString(),
            'message',
            contains('managed_externally'),
          ),
        ),
      );
      expect(subject.settings.enabled, isTrue);
    });

    test('the settings projection reports the installed model and size', () {
      // A batch entry: streaming is a sherpa feature, so a build without it
      // publishes batch rows only and this row must still be there.
      final selectedEntry = visibleUsableEntries().firstWhere(
        (entry) => entry.mode == SttModelMode.batchVad,
      );
      writeConfig('''
stt:
  model_id: ${selectedEntry.id}
''');
      final snapshot = service().settingsSnapshot();
      expect(snapshot['selected_model_id'], selectedEntry.id);
      final models = (snapshot['models'] as List).cast<Map<String, dynamic>>();
      final selected = models.firstWhere(
        (model) => model['id'] == selectedEntry.id,
      );
      expect(selected['size_bytes'], greaterThan(0));
      expect(selected['installed'], isFalse);
      expect(selected['streaming'], isFalse);
      expect(selected['name'], isNotEmpty);
    });

    test('selecting a model from settings uses the one selection owner', () async {
      final subject = service();
      final chosen = alternativeUsableId();
      await subject.selectModel(chosen);
      expect(subject.selectedModelId, chosen);
      expect(service().selectedModelId, chosen);
      await expectLater(
        subject.selectModel('nope'),
        throwsA(
          isA<Object>().having(
            (error) => error.toString(),
            'message',
            contains('model_unknown'),
          ),
        ),
      );
    });

    test('the authored status rows ship no user-facing prose', () {
      // The legacy catalog's Arabic labels/notes are a pre-existing
      // localization-ownership drift recorded in the run REPORT; this change
      // must not add another one, and the new override row must stay
      // translation-free and path-free.
      writeConfig('stt:\n  model_path: /tmp/manual-model\n');
      final status = service().statusPayload();
      expect(status.containsKey('model_path'), isFalse);
      expect(status['has_model_path'], isTrue);
      final override = (status['models'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((model) => model['id'] == 'path-override');
      expect(override['label'], isNull);
      expect(override['label_code'], 'path_override');
      // A host filesystem path must never be part of a status payload, local or
      // hosted: the row identity is enough for every surface.
      expect(override.containsKey('note'), isFalse);
      expect(service().settingsSnapshot().containsKey('model_path'), isFalse);
    });

    test('lists every visible catalog entry with install state', () {
      final payload = service().statusPayload();
      expect(payload['supported'], isTrue);
      final models = payload['models'] as List<Object?>;
      final usable = usableSttEntries(availability);
      final visible = visibleUsableEntries();
      expect(models, hasLength(visible.length));
      for (final model in models.cast<Map<String, Object?>>()) {
        expect(model['installed'], isFalse);
        expect(model['id'], isNotNull);
        expect(model['size_bytes'], greaterThan(0));
      }
      // Hidden entries stay usable through stt.model_id but never reach the UI.
      final ids = models
          .cast<Map<String, Object?>>()
          .map((model) => model['id'])
          .toSet();
      for (final entry in usable.where((entry) => entry.hidden)) {
        expect(ids, isNot(contains(entry.id)));
      }
      expect(payload['selected'], defaultUsableSttEntry(availability)!.id);
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
  });

  group('native platform gate', () {
    // These read the owning table through the service. The table's own test
    // (`stt_native_platform_test.dart`) asserts every ABI mapping, including
    // `macosX64.dictationSupported`; here the question is only whether the
    // service still answers from that table instead of a private catalog.
    test('an injected verdict is the whole platform gate', () {
      final refused = service(platformSupported: false).readiness();
      final allowed = service(platformSupported: true).readiness();

      expect(refused.reason, 'unsupported_platform');
      expect(allowed.isSupported, isTrue);
    });

    test(
      'the default gate lets a buildable host through to its real blocker',
      () {
        // A second `Platform`/`Abi` catalog in the service is what made a
        // buildable Intel runtime report `unsupported_platform`. On a supported
        // host the default verdict must never be that reason.
        final readiness = service().readiness();

        expect(readiness.reason, isNot('unsupported_platform'));
      },
      skip: Platform.isMacOS && Abi.current() == Abi.macosArm64
          ? false
          : 'Host ABI is not covered by the macOS arm64 regression',
    );

    test('a whisper model without its shim is supported but not ready', () {
      if (WhisperCppLibrary.isAvailable) {
        // A checkout with a built runtime cannot exercise the missing case; the
        // readiness reason for it is asserted in the platform-gate test above.
        return;
      }
      writeConfig('''
stt:
  model_id: egy-whisper-turbo-ggml-f16
''');
      final readiness = service().readiness();

      expect(readiness.isSupported, isTrue);
      expect(readiness.reason, 'native_runtime_missing');
    });
  });
}

