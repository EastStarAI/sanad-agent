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

  /// Samples fed since the last forced cut. Whisper's own VAD only ends a
  /// segment on silence, so continuous narration could otherwise produce 20 s
  /// segments and multi-second decode latency. A forced cut every ~6 s bounds
  /// first-text latency for every model.
  int _samplesSinceCut = 0;
  static const int _forcedCutSamples = 4 * 16000;

  void handle(Map message) {
    switch (message['cmd']) {
      case 'init':
        _init(message);
      case 'audio':
        _audio(message['pcm'] as Uint8List);
      case 'finish':
        _finish();
      case 'cancel':
        _drain(discard: true);
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
    final recognizer = _recognizer;
    if (vad == null || recognizer == null) {
      throw const SttException('not_ready', 'recognizer is not loaded');
    }
    vad.acceptWaveform(_pcm16ToFloat32(pcm16));
    _samplesSinceCut += pcm16.lengthInBytes ~/ 2;
    if (_samplesSinceCut >= _forcedCutSamples) {
      vad.flush();
      _samplesSinceCut = 0;
    }
    _drain();
    _out.send({'evt': 'idle'});
  }

  void _finish() {
    final vad = _vad;
    if (vad == null) {
      _out.send({'evt': 'done'});
      return;
    }
    vad.flush();
    _samplesSinceCut = 0;
    _drain();
    _out.send({'evt': 'done'});
    _out.send({'evt': 'idle'});
  }

  void _drain({bool discard = false}) {
    final vad = _vad;
    final recognizer = _recognizer;
    if (vad == null || recognizer == null) return;
    while (!vad.isEmpty()) {
      final segment = vad.front();
      final samples = segment.samples;
      vad.pop();
      if (discard || samples.isEmpty) continue;
      final decode = Stopwatch()..start();
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: 16000);
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text.trim();
        decode.stop();
        if (text.isEmpty) continue;
        _out.send({
          'evt': 'final',
          'seq': _seq++,
          'text': text,
          'audioMs': samples.length * 1000 ~/ 16000,
          'decodeMs': decode.elapsedMilliseconds,
        });
      } finally {
        stream.free();
      }
    }
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
