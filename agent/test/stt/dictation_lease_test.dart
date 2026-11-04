import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('dictation-lease-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  DictationService service() => DictationService(
    sanadHome: home.path,
    platformSupported: true,
  );

  group('dictation lease', () {
    test('only one session may hold the engine at a time', () {
      final first = service();
      expect(first.isBusy, isFalse);
      expect(first.acquireSession(), isTrue);
      expect(first.isBusy, isTrue);

      // The lease is daemon-wide: a second connection cannot load the model.
      expect(first.acquireSession(), isFalse);

      first.releaseSession();
      expect(first.isBusy, isFalse);
      expect(first.acquireSession(), isTrue);
    });

    test('status advertises the busy flag', () {
      final stt = service();
      expect(stt.statusPayload()['busy'], isFalse);
      stt.acquireSession();
      expect(stt.statusPayload()['busy'], isTrue);
    });
  });
}
