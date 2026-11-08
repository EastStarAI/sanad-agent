/// Background isolate that owns a whisper.cpp context.
///
/// Same protocol as the sherpa worker (`stt_isolate.dart`), so the daemon-side
/// engine, session and events are unchanged: only the decode call differs.
/// Recognition is CPU bound and must never run on the daemon's event loop.
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'stt_speech_gate.dart';
import 'stt_types.dart';
import 'whispercpp_bindings.dart';

/// Mandatory entry point for the whisper.cpp worker isolate.
void whisperCppWorkerEntry(SendPort out) {
  final inbox = ReceivePort();
  out.send({'evt': 'port', 'port': inbox.sendPort});
  final worker = _WhisperCppWorker(out);
  inbox.listen((message) {
    if (message is! Map) return;
    try {
      worker.handle(message);
    } on SttException catch (error) {
      out.send({'evt': 'error', 'code': error.code, 'message': error.message});
    } on Object catch (error) {
      out.send({'evt': 'error', 'code': 'decode_failed', 'message': '$error'});
    }
  });
}

class _WhisperCppWorker {
  _WhisperCppWorker(this._out);

  final SendPort _out;

  Pointer<Void> _context = nullptr;
  WhisperCppLibrary? _library;
  String _modelId = '';

  /// Decode language of the loaded entry (`stt.language` / catalog language).
  ///
  /// The worker runs in its own isolate with no config access, so the value
  /// travels with `init`; hardcoding one language silently mistranscribed every
  /// other catalog entry.
  String _language = 'ar';
  int _seq = 0;
  bool _disposed = false;

  /// The whole utterance is held and decoded once on stop, exactly like the
  /// sherpa path: a decode per chunk is what cut words in half.
  final List<Float32List> _speech = <Float32List>[];
  int _bufferedSamples = 0;

  /// whisper.cpp decodes in 30 s windows; keep groups well under that.
  static const int _maxGroupSamples = 24 * 16000;

  /// Hard ceiling: 5 minutes of 16 kHz mono PCM16.
  static const int _maxBufferedSamples = 5 * 60 * 16000;

  /// Trailing silence so the last phoneme is not dropped by the decoder.
  static const int _tailPadSamples = 8000;

  void handle(Map message) {
    switch (message['cmd']) {
      case 'init':
        _init(message);
      case 'audio':
        _audio(message['pcm'] as Uint8List);
      case 'finish':
        _finish(message['threads'] as int? ?? 0);
      case 'cancel':
        _speech.clear();
        _bufferedSamples = 0;
        _out.send({'evt': 'idle'});
      case 'reset':
        // The loaded context survives; only this session's audio goes away.
        _speech.clear();
        _bufferedSamples = 0;
        _out.send({'evt': 'idle'});
      case 'dispose':
        _dispose();
      default:
        _out.send({
          'evt': 'error',
          'code': 'protocol',
          'message': 'unknown command ${message['cmd']}',
        });
    }
  }

  /// Forwards one metadata line to the daemon's own logger.
  ///
  /// A worker isolate does not share the daemon's log listener, and printing
  /// here duplicated nothing while it polluted stdout: the line travels back
  /// over the existing port instead. Numbers and codes only — never audio or
  /// transcript text.
  void _log(String message) =>
      _out.send({'evt': 'log', 'message': message});

  void _init(Map message) {
    final stopwatch = Stopwatch()..start();
    _modelId = message['modelId'] as String? ?? '';
    final language = message['language'] as String?;
    if (language != null && language.trim().isNotEmpty) {
      _language = language.trim();
    }
    final library = WhisperCppLibrary.open(message['library'] as String?);
    _library = library;
    final modelPath = message['model'] as String;
    final useGpu = message['useGpu'] as bool? ?? true;
    try {
      _context = library.loadModel(modelPath, useGpu: useGpu);
    } on SttException catch (error) {
      // A model that cannot open on Metal must still dictate: reopen on the CPU
      // rather than failing the session. The reason is a code, never audio.
      if (!useGpu) rethrow;
      _log('metal load failed (${error.code}); falling back to CPU');
      _context = library.loadModel(modelPath, useGpu: false);
    }
    stopwatch.stop();
    _out.send({
      'evt': 'ready',
      'modelId': _modelId,
      'loadMs': stopwatch.elapsedMilliseconds,
    });
    _out.send({'evt': 'idle'});
  }

  void _audio(Uint8List pcm16) {
    if (_context == nullptr) {
      throw const SttException('not_ready', 'whisper context is not loaded');
    }
    if (_bufferedSamples >= _maxBufferedSamples) {
      _out.send({'evt': 'idle'});
      return;
    }
    final samples = _pcm16ToFloat32(pcm16);
    _speech.add(samples);
    _bufferedSamples += samples.length;
    _out.send({'evt': 'idle'});
  }

  void _finish(int threads) {
    final library = _library;
    if (library == null || _context == nullptr) {
      _out.send({'evt': 'done', 'segments': 0});
      return;
    }
    final audioSamples = _bufferedSamples;
    final stats = _stats();
    final gate = evaluateSpeechGate(peak: stats.peak, rms: stats.rms);
    if (!gate.decode) {
      // whisper invents text on silence ("شكراً للمشاهدة" and friends), which
      // would insert junk into the composer. The guard is scale-invariant: a
      // muted mic has no peak, and steady noise is not peaky.
      _log(
        'dictation gate blocked: reason=${gate.reason} '
        'samples=$audioSamples ms=${audioSamples * 1000 ~/ 16000} '
        'peak=${gate.peak.toStringAsFixed(4)} '
        'rms=${gate.rms.toStringAsFixed(4)} '
        'crest=${gate.crest.toStringAsFixed(2)} minCrest=$kSpeechMinCrest '
        'minPeak=$kSpeechMinPeak',
      );
      _speech.clear();
      _bufferedSamples = 0;
      _out.send({'evt': 'done', 'segments': 0});
      return;
    }
    final gain = _normaliseForDecode(stats.peak);
    _log(
      'dictation gate passed: samples=$audioSamples '
      'peak=${gate.peak.toStringAsFixed(4)} '
      'rms=${gate.rms.toStringAsFixed(4)} '
      'crest=${gate.crest.toStringAsFixed(2)} gain=${gain.toStringAsFixed(2)}x',
    );
    final decode = Stopwatch()..start();
    final text = _transcribeAll(library, threads);
    decode.stop();
    _speech.clear();
    _bufferedSamples = 0;
    if (text.isNotEmpty) {
      _out.send({
        'evt': 'final',
        'seq': _seq++,
        'text': text,
        'audioMs': audioSamples * 1000 ~/ 16000,
        'decodeMs': decode.elapsedMilliseconds,
      });
    }
    _out.send({'evt': 'done', 'segments': text.isEmpty ? 0 : 1});
    _out.send({'evt': 'idle'});
  }

  /// Cheap energy gate: a session that never rose above the noise floor is not
  /// worth a decode, and decoding it would hallucinate text.
  ///
  /// A plain average is not enough: steady room noise (music, a fan, traffic)
  /// lifts the mean while containing no speech. So this counts the share of
  /// loud frames instead — speech always has peaks, noise does not.
  /// Peak and RMS over the buffered utterance.
  ///
  /// Sampling every 8th frame is plenty for a level decision and keeps the
  /// measurement cheaper than the decode it guards.
  ({double peak, double rms}) _stats() {
    var peak = 0.0;
    var sum = 0.0;
    var count = 0;
    for (final chunk in _speech) {
      for (var i = 0; i < chunk.length; i += 8) {
        final value = chunk[i];
        final magnitude = value.abs();
        if (magnitude > peak) peak = magnitude;
        sum += value * value;
        count++;
      }
    }
    return (peak: peak, rms: count == 0 ? 0.0 : math.sqrt(sum / count));
  }

  /// Scales the buffered utterance to a fixed peak and returns the gain used.
  ///
  /// Applied in place before decoding: whisper.cpp has no automatic gain, so a
  /// quiet take (this microphone delivers peaks around 0.05–0.09) reached the
  /// decoder at a level it transcribes poorly.
  double _normaliseForDecode(double peak) {
    if (peak <= 0) return 1;
    final gain = decodeGain(peak);
    if ((gain - 1).abs() < 0.01) return 1;
    for (final chunk in _speech) {
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = chunk[i] * gain;
      }
    }
    return gain;
  }

  /// Decodes the buffered utterance in groups and joins the results into the
  /// single transcript the user sees.
  String _transcribeAll(WhisperCppLibrary library, int threads) {
    if (_speech.isEmpty) return '';
    final parts = <String>[];
    var group = <Float32List>[];
    var groupSamples = 0;

    void decodeGroup() {
      if (group.isEmpty) return;
      final total = groupSamples + _tailPadSamples;
      final samples = Float32List(total);
      var offset = 0;
      for (final chunk in group) {
        samples.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      group = <Float32List>[];
      groupSamples = 0;
      final result = library.run(
        _context,
        samples,
        language: _language,
        threads: threads,
      );
      if (result.text.isNotEmpty) parts.add(result.text);
    }

    for (final segment in _speech) {
      if (groupSamples > 0 && groupSamples + segment.length > _maxGroupSamples) {
        decodeGroup();
      }
      group.add(segment);
      groupSamples += segment.length;
    }
    decodeGroup();
    return parts.join(' ').trim();
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    final library = _library;
    if (_context != nullptr && library != null) {
      library.freeModel(_context);
    }
    _context = nullptr;
    _out.send({'evt': 'closed'});
    Isolate.exit();
  }

  static Float32List _pcm16ToFloat32(Uint8List pcm16) {
    final count = pcm16.lengthInBytes ~/ 2;
    final samples = Float32List(count);
    final view = ByteData.sublistView(pcm16, 0, count * 2);
    for (var i = 0; i < count; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }
}
