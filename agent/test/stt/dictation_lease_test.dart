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
      final owner = Object();
      final second = Object();
      expect(first.isBusy, isFalse);
      expect(first.acquireSession(owner), isTrue);
      expect(first.isBusy, isTrue);

      // The lease is daemon-wide: a second connection cannot load the model.
      expect(first.acquireSession(second), isFalse);

      first.releaseSession(owner);
      expect(first.isBusy, isFalse);
      expect(first.acquireSession(second), isTrue);
    });

    test('a non-owner teardown cannot free the live lease', () {
      final stt = service();
      final owner = Object();
      expect(stt.acquireSession(owner), isTrue);
      stt.releaseSession(Object());
      expect(stt.isBusy, isTrue);
      expect(stt.ownsSession(owner), isTrue);
      stt.releaseSession(owner);
      expect(stt.isBusy, isFalse);
    });

    test('status advertises the busy flag', () {
      final stt = service();
      expect(stt.statusPayload()['busy'], isFalse);
      stt.acquireSession(Object());
      expect(stt.statusPayload()['busy'], isTrue);
    });
  });
}
