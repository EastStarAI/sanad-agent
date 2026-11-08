import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/dictation_capture_fixture.dart';
import 'package:sanad_client/driver/dictation_driver_extensions.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';

class _ExplodingCapture implements DictationCapture {
  int starts = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() {
    starts++;
    throw StateError('the real microphone must not be opened');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

List<int> _pcm(int bytes) => List<int>.generate(bytes, (index) => index % 256);

void main() {
  test('the production capture factory still builds the real microphone', () {
    // Nothing in this isolate installs the driver seam, so the default is what
    // every real user gets.
    expect(dictationCaptureFactory(), isA<DictationAudioCapture>());
  });

  group('pcm fixture', () {
    test('streams bounded chunks and finishes', () async {
      final fixture = DictationPcmFixture(
        pcm16le: _pcm(960),
        chunkBytes: 320,
        chunkInterval: const Duration(milliseconds: 5),
      );

      final chunks = await fixture.start().toList();

      expect(chunks, hasLength(3));
      expect(chunks.every((chunk) => chunk.length == 320), isTrue);
      expect(fixture.emittedBytes, 960);
      expect(fixture.isFinished, isTrue);
      expect(fixture.duration, const Duration(milliseconds: 30));
    });

    test('cancellation stops every later chunk', () async {
      final fixture = DictationPcmFixture(
        pcm16le: _pcm(3200),
        chunkBytes: 320,
        chunkInterval: const Duration(milliseconds: 10),
      );
      var received = 0;
      final first = Completer<void>();
      final subscription = fixture.start().listen((chunk) {
        received++;
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await subscription.cancel();
      final afterCancel = received;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(received, afterCancel, reason: 'no late chunk after cancellation');
      expect(fixture.isFinished, isFalse);
    });

    test('a fixture is single-use', () async {
      final fixture = DictationPcmFixture(pcm16le: _pcm(320));
      fixture.start();
      expect(fixture.start, throwsStateError);
    });

    test('every bound is enforced before a stream exists', () {
      expect(
        () => DictationPcmFixture(pcm16le: const []),
        throwsArgumentError,
      );
      expect(
        () => DictationPcmFixture(pcm16le: _pcm(321)),
        throwsArgumentError,
      );
      expect(
        () => DictationPcmFixture(pcm16le: _pcm(DictationPcmFixture.maxBytes + 2)),
        throwsArgumentError,
      );
      expect(
        () => DictationPcmFixture(pcm16le: _pcm(320), chunkBytes: 321),
        throwsArgumentError,
      );
      expect(
        () => DictationPcmFixture(
          pcm16le: _pcm(320),
          chunkInterval: const Duration(milliseconds: 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('driver capture wrapper', () {
    test('an armed fixture feeds the existing capture contract', () async {
      final wrapper = DriverDictationCapture(realCapture: _ExplodingCapture.new);
      wrapper.arm(DictationPcmFixture(
        pcm16le: _pcm(640),
        chunkBytes: 320,
        chunkInterval: const Duration(milliseconds: 5),
      ));

      expect(await wrapper.hasPermission(), isTrue);
      final chunks = await (await wrapper.start()).toList();

      expect(chunks, hasLength(2));
      expect(wrapper.isSessionActive, isFalse);
      await wrapper.stop();
    });

    test('arming and disarming are refused during an active session', () async {
      final wrapper = DriverDictationCapture(realCapture: _ExplodingCapture.new);
      final fixture = DictationPcmFixture(
        pcm16le: _pcm(3200),
        chunkBytes: 320,
        chunkInterval: const Duration(milliseconds: 10),
      );
      wrapper.arm(fixture);
      final subscription = (await wrapper.start()).listen((_) {});

      expect(
        () => wrapper.arm(DictationPcmFixture(pcm16le: _pcm(320))),
        throwsStateError,
      );
      expect(wrapper.disarm, throwsStateError);

      await subscription.cancel();
      expect(wrapper.isSessionActive, isFalse);
      wrapper.disarm();
      expect(wrapper.armedFixture, isNull);
      await wrapper.stop();
    });

    test('without a fixture the real capture is the one that starts', () async {
      final real = _ExplodingCapture();
      final wrapper = DriverDictationCapture(realCapture: () => real);

      await expectLater(wrapper.start(), throwsStateError);
      expect(real.starts, 1);
      expect(wrapper.isSessionActive, isFalse);
    });

    test('dispose releases the fixture and the real capture', () async {
      final wrapper = DriverDictationCapture(realCapture: _ExplodingCapture.new);
      wrapper.arm(DictationPcmFixture(pcm16le: _pcm(320)));

      await wrapper.dispose();

      expect(wrapper.armedFixture, isNull);
      expect(wrapper.isSessionActive, isFalse);
    });
  });

  group('composer facts', () {
    test('reports presence, length, and an exact hash match only', () {
      const text = 'hello world';
      final digest = sha256.convert(utf8.encode(text)).toString();

      final matched = composerFacts(text: text, expectedSha256: digest);
      final missed = composerFacts(text: text, expectedSha256: 'a' * 64);
      final empty = composerFacts(text: '');

      expect(matched['present'], isTrue);
      expect(matched['chars'], text.runes.length);
      expect(matched['matches_expected'], isTrue);
      expect(missed['matches_expected'], isFalse);
      expect(empty['present'], isFalse);
      expect(empty['matches_expected'], isFalse);
      // Only facts leave the driver: no text or prefix is ever a value.
      expect(jsonEncode(matched), isNot(contains(text)));
    });
  });
}
