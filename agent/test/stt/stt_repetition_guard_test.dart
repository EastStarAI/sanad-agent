import 'package:sanad_agent/infrastructure/stt/stt_repetition_guard.dart';
import 'package:test/test.dart';

/// A tight encoder window makes whisper repeat one phrase until it runs out of
/// tokens. These are the shapes the measured sweep produced, and the guard has
/// to recover the group without ever reporting a looped transcript.
void main() {
  group('looksRepetitive', () {
    test('the 3 s clip loop is caught', () {
      // `اختبار سريع للميكروفون` came back as 42 words of one 3-word phrase.
      final loop = List.filled(14, 'تماما خلاص كدا').join(' ');
      expect(loop.split(' ').length, 42);
      expect(looksRepetitive(loop), isTrue);
    });

    test('a 4-word phrase repeated three times is caught', () {
      final loop = List.filled(3, 'لا أعرف ماذا أقول').join(' ');
      expect(looksRepetitive(loop), isTrue);
    });

    test('punctuation and case do not hide a loop', () {
      final loop = List.filled(
        3,
        'The same phrase, again',
      ).join('. ').toUpperCase();
      expect(looksRepetitive(loop), isTrue);
    });

    test('Arabic punctuation on the repeated words does not hide it', () {
      final loop = List.filled(5, 'كدا، كدا. كدا!').join(' ');
      expect(looksRepetitive(loop), isTrue);
    });

    test('normal Egyptian dictation is not flagged', () {
      const sentences = [
        'ذكرني بعد ساعة أشتري حاجة من السوبر ماركت',
        'الاجتماع اتأجل للساعة تلاتة',
        'أرسل لي التقرير ده بكره الصبح',
        'عايز أحجز تذكرة طيران للقاهرة',
        'الجو النهاردة حر جدا',
      ];
      for (final sentence in sentences) {
        expect(looksRepetitive(sentence), isFalse, reason: sentence);
      }
    });

    test('normal English dictation is not flagged', () {
      const sentences = [
        'send the report to the team and a copy to me',
        'remind me to call the dentist tomorrow morning at nine',
        'the meeting moved to three in the afternoon',
      ];
      for (final sentence in sentences) {
        expect(looksRepetitive(sentence), isFalse, reason: sentence);
      }
    });

    test('a spoken repeat below the threshold is not flagged', () {
      // Dictating "again, again" is speech, not a decoder loop.
      expect(
        looksRepetitive('شغل الفيديو تاني تاني تاني'),
        isFalse,
      );
      expect(looksRepetitive('one two three four'), isFalse);
      expect(looksRepetitive('one two three'), isFalse);
      expect(looksRepetitive(''), isFalse);
      expect(looksRepetitive('   '), isFalse);
    });

    test('a loop outruns the audio it claims to transcribe', () {
      // 42 words out of 3.0 s is 14 words per second: impossible speech.
      final loop = List.filled(14, 'تماما خلاص كدا').join(' ');
      expect(looksRepetitive(loop, audioSeconds: 3.0), isTrue);
    });

    test('a deliberate repetition is not a loop', () {
      // The measured 24 s group: the same 8 s sentence said three times, 36
      // words in 24 s. Re-decoding it at the full window dropped two of the
      // three sentences, so the guard must not fire here.
      final trio = List.filled(
        3,
        'الجو النهارد حر شوية فقررت أقعد في البيت واشتغل على المشروع الجديد',
      ).join('. ');
      expect(trio.split(' ').length, 36);
      expect(looksRepetitive(trio, audioSeconds: 24.0), isFalse);
    });
  });

  group('decodeGroupGuarded', () {
    test('a clean decode is never repeated', () {
      final windows = <int>[];
      final log = <String>[];
      final text = decodeGroupGuarded(
        audioCtx: 448,
        audioSeconds: 3.87,
        decode: (window) {
          windows.add(window);
          return 'الاجتماع اتأجل للساعة تلاتة';
        },
        log: log.add,
      );
      expect(text, 'الاجتماع اتأجل للساعة تلاتة');
      expect(windows, [448]);
      expect(log, isEmpty);
    });

    test('a looped decode is retried once at the full window', () {
      final windows = <int>[];
      final log = <String>[];
      final text = decodeGroupGuarded(
        audioCtx: 448,
        audioSeconds: 3.01,
        decode: (window) {
          windows.add(window);
          if (window == 0) return 'اختبار سريع للميكروفون';
          return List.filled(14, 'تماما خلاص كدا').join(' ');
        },
        log: log.add,
      );
      expect(text, 'اختبار سريع للميكروفون');
      expect(windows, [448, 0], reason: 'one retry, with the full window');
      expect(log, ['dictation decode: repetition guard re-decoded group']);
    });

    test('a deliberate repetition is decoded once', () {
      var calls = 0;
      final trio = List.filled(
        3,
        'الجو النهارد حر شوية فقررت أقعد في البيت واشتغل على المشروع الجديد',
      ).join('. ');
      final text = decodeGroupGuarded(
        audioCtx: 1248,
        audioSeconds: 24.0,
        decode: (window) {
          calls++;
          return trio;
        },
      );
      expect(calls, 1, reason: 'the full window dropped two of the three');
      expect(text, trio);
    });

    test('the retry is bounded even when it loops again', () {
      var calls = 0;
      final loop = List.filled(4, 'نفس الجملة دي بالظبط').join(' ');
      final text = decodeGroupGuarded(
        audioCtx: 448,
        decode: (window) {
          calls++;
          return loop;
        },
      );
      expect(calls, 2, reason: 'a guard that keeps retrying can hang a session');
      expect(text, loop);
    });

    test('the guard works without a logger', () {
      var calls = 0;
      decodeGroupGuarded(
        audioCtx: 480,
        decode: (window) {
          calls++;
          return window == 0
              ? 'خلاص'
              : List.filled(3, 'كرر نفس الكلام تاني').join(' ');
        },
      );
      expect(calls, 2);
    });
  });
}
