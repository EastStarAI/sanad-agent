/// Repetition detection and one-shot recovery for a whisper decode.
///
/// A window that ends too close to the last speech sample makes whisper repeat
/// one phrase until it runs out of tokens; the guard turns that visible failure
/// into one slow-but-correct answer.
library;

/// Words per repeated phrase.
const int kRepetitionNgram = 4;

/// How often that phrase has to repeat to count as a loop.
///
/// Dictation repeats four words three times only when the speaker is actually
/// repeating them, and a loop repeats far more, so the first occurrence of the
/// third repeat is enough to distrust the group.
const int kRepetitionThreshold = 3;

/// Words per second a speaker can plausibly produce.
///
 /// A repeated phrase is not proof of a loop: a user who says the same sentence
 /// three times produces exactly that. The loop is distinguishable by throughput,
 /// not by repetition — the measured loops emitted 42 words for 3.0 s of audio
 /// (14 words/s), while three repeated 8 s sentences emitted 36 words in 24 s
 /// (1.5 words/s). Five words per second is above any dictation pace and far
 /// below a loop.
const double kMaxPlausibleWordsPerSecond = 5;

/// Whether [text] reads as a decoder repetition loop rather than speech.
///
/// Case and edge punctuation are ignored, so `كدا،` and `كدا` are one word. When
/// [audioSeconds] is given, a repeated phrase only counts as a loop if the
/// transcript also outruns [kMaxPlausibleWordsPerSecond] for that audio;
/// without it the detector answers on repetition alone.
bool looksRepetitive(String text, {double? audioSeconds}) {
  final words = _words(text);
  if (!_repeatsPhrase(words)) return false;
  if (audioSeconds == null || audioSeconds <= 0) return true;
  return words.length > kMaxPlausibleWordsPerSecond * audioSeconds;
}

bool _repeatsPhrase(List<String> words) {
  final span = kRepetitionNgram;
  if (words.length < span * kRepetitionThreshold) return false;
  final counts = <String, int>{};
  for (var i = 0; i + span <= words.length; i++) {
    final key = words.sublist(i, i + span).join(' ');
    final seen = (counts[key] ?? 0) + 1;
    if (seen >= kRepetitionThreshold) return true;
    counts[key] = seen;
  }
  return false;
}

/// Decodes one group, retrying once at the full window when the text looped.
///
/// The retry deliberately asks for the *whole* window ([audioCtx] 0): a loop is
/// evidence that the window ended too close to the audio, so the recovery has to
/// remove that condition instead of shrinking it further. It costs the old
/// decode time and fires only on a transcript the user would otherwise have to
/// delete.
///
/// [audioSeconds] is the speech duration of the group, which keeps a deliberate
/// repetition from being read as a loop. [decode] receives the window to use and
/// returns the group's text. [log] receives the recovery line; it never receives
/// transcript or audio content.
String decodeGroupGuarded({
  required int audioCtx,
  required String Function(int audioCtx) decode,
  double? audioSeconds,
  void Function(String message)? log,
}) {
  final first = decode(audioCtx);
  if (!looksRepetitive(first, audioSeconds: audioSeconds)) return first;
  log?.call('dictation decode: repetition guard re-decoded group');
  return decode(0);
}

/// Edge punctuation of a word in either script (`،` `.` `؟` `!` quotes, …).
final RegExp _edgePunctuation = RegExp(
  r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$',
  unicode: true,
);

List<String> _words(String text) {
  final words = <String>[];
  for (final raw in text.split(RegExp(r'\s+'))) {
    final word = raw.replaceAll(_edgePunctuation, '').toLowerCase();
    if (word.isNotEmpty) words.add(word);
  }
  return words;
}
