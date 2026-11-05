/// Background isolate that owns the sherpa-onnx recognizer and the VAD.
///
/// Speech recognition is CPU bound (≈0.5× real time for the Egyptian model), so
/// it must never run on the daemon's event-loop isolate. The worker owns all
/// native handles; the daemon only forwards audio and reads typed events.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'stt_types.dart';

/// Mandatory entry point for the dictation worker isolate.
void sttWorkerEntry(SendPort out) {
  final inbox = ReceivePort();
  out.send({'evt': 'port', 'port': inbox.sendPort});
  final worker = _SttWorker(out);
  inbox.listen((message) {
    if (message is! Map) return;
    try {
      worker.handle(message);
    } on SttException catch (error) {
      out.send({'evt': 'error', 'code': error.code, 'message': error.message});
    } on Object catch (error) {
      out.send({
        'evt': 'error',
        'code': 'decode_failed',
        'message': '$error',
      });
    }
  });
}

class _SttWorker {
  _SttWorker(this._out);

  final SendPort _out;
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  String _modelId = '';
  int _seq = 0;
  bool _disposed = false;

  /// Speech segments collected for the whole utterance, in order.
  ///
  /// Nothing is decoded while the user speaks: a cut mid-word is what produced
  /// fragmented transcripts, so the session holds the audio and decodes once at
  /// the end. The VAD is only used to trim silence and to find silence-aligned
  /// group boundaries, never to publish text.
  final List<Float32List> _speech = <Float32List>[];
  int _bufferedSamples = 0;

  /// Whisper's decoder rejects a single decode longer than 30 s, so groups are
  /// kept well below that and joined into one transcript afterwards.
  static const int _maxGroupSamples = 24 * 16000;

  /// Hard ceiling on buffered audio: 5 minutes of 16 kHz mono PCM16.
  static const int _maxBufferedSamples = 5 * 60 * 16000;

  void handle(Map message) {
    switch (message['cmd']) {
      case 'init':
        _init(message);
      case 'audio':
        _audio(message['pcm'] as Uint8List);
      case 'finish':
        _finish();
      case 'cancel':
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

  void _init(Map message) {
    final stopwatch = Stopwatch()..start();
    _modelId = message['modelId'] as String? ?? '';
    sherpa.initBindings();
    _recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: message['encoder'] as String,
            decoder: message['decoder'] as String,
            language: message['language'] as String? ?? 'ar',
            task: 'transcribe',
            // A segment that ends exactly on the last phoneme makes the decoder
            // drop the final word; one second of trailing silence is what the
            // upstream examples use, and it is what makes the last word survive.
            tailPaddings: 1000,
          ),
          tokens: message['tokens'] as String,
          modelType: 'whisper',
          numThreads: message['threads'] as int? ?? 2,
          debug: false,
        ),
      ),
    );
    _vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: message['vad'] as String,
          threshold: 0.5,
          // 0.6 s of silence ends a segment: typical dictation utterances stay
          // short, which keeps per-segment decode latency low.
          minSilenceDuration: 0.6,
          minSpeechDuration: 0.2,
          windowSize: 512,
          // Keep every segment well under the decoder's 30 s ceiling.
          maxSpeechDuration: 10.0,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 60,
    );
    stopwatch.stop();
    _out.send({
      'evt': 'ready',
      'modelId': _modelId,
      'loadMs': stopwatch.elapsedMilliseconds,
    });
    _out.send({'evt': 'idle'});
  }

  void _audio(Uint8List pcm16) {
    final vad = _vad;
    if (vad == null || _recognizer == null) {
      throw const SttException('not_ready', 'recognizer is not loaded');
    }
    if (_bufferedSamples >= _maxBufferedSamples) {
      // The session ceiling is enforced by the caller too; this is the last
      // guard so a stuck session can never grow without bound.
      _out.send({'evt': 'idle'});
      return;
    }
    vad.acceptWaveform(_pcm16ToFloat32(pcm16));
    _collectSpeech();
    _out.send({'evt': 'idle'});
  }

  /// Moves every finished VAD segment into the session buffer. The segments are
  /// concatenated again at decode time, so VAD boundaries only remove silence.
  void _collectSpeech() {
    final vad = _vad;
    if (vad == null) return;
    while (!vad.isEmpty()) {
      final segment = vad.front();
      final samples = segment.samples;
      vad.pop();
      if (samples.isEmpty) continue;
      if (_bufferedSamples >= _maxBufferedSamples) continue;
      _speech.add(samples);
      _bufferedSamples += samples.length;
    }
  }

  void _finish() {
    final vad = _vad;
    if (vad == null || _recognizer == null) {
      _out.send({'evt': 'done', 'segments': 0});
      return;
    }
    vad.flush();
    _collectSpeech();
    final decode = Stopwatch()..start();
    final text = _transcribeAll();
    decode.stop();
    var audioSamples = 0;
    for (final segment in _speech) {
      audioSamples += segment.length;
    }
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

  /// Decodes the buffered utterance in silence-aligned groups and joins the
  /// results into the one transcript the user sees.
  String _transcribeAll() {
    final recognizer = _recognizer;
    if (recognizer == null || _speech.isEmpty) return '';

    final parts = <String>[];
    var group = <Float32List>[];
    var groupSamples = 0;

    void decodeGroup() {
      if (group.isEmpty) return;
      // Trailing silence is part of the contract with the decoder: a segment
      // that ends on the last phoneme loses its final word, and VAD hands us
      // segments that end exactly there.
      const tailPad = 8000; // 0.5 s at 16 kHz
      final total = groupSamples + tailPad;
      final samples = Float32List(total);
      var offset = 0;
      for (final chunk in group) {
        samples.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      group = <Float32List>[];
      groupSamples = 0;
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: 16000);
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text.trim();
        if (text.isNotEmpty) parts.add(text);
      } finally {
        stream.free();
      }
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
    _vad?.free();
    _vad = null;
    _recognizer?.free();
    _recognizer = null;
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
