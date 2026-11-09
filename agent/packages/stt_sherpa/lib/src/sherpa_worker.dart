/// Background isolate that owns the sherpa-onnx recognizer and the VAD.
///
/// Speech recognition is CPU bound (≈0.5× real time for the Egyptian model), so
/// it must never run on the daemon's event-loop isolate. The worker owns all
/// native handles; the daemon only forwards audio and reads typed events.
///
/// This file is the **real** engine behind `package:sanad_stt_sherpa`. A build
/// that cannot resolve `sherpa_onnx` links the stand-in package instead, which
/// exposes the same entry point and reports the engine unavailable, so the
/// daemon-side protocol below is the only shared contract.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'sherpa_bindings.dart';

/// Typed failure raised inside the worker and reported as one error event.
///
/// The daemon maps `code` onto its own exception type, so this package never
/// imports daemon types (that would make the two packages depend on each
/// other).
class SherpaWorkerException implements Exception {
  const SherpaWorkerException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'SherpaWorkerException($code): $message';
}

/// Mandatory entry point for the dictation worker isolate.
void sherpaWorkerEntry(SendPort out) {
  // The daemon's log listener lives on the main isolate, so this worker wires
  // its own: otherwise the streaming measurements are written into a void.
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.loggerName}: ${record.message}');
  });
  final inbox = ReceivePort();
  out.send({'evt': 'port', 'port': inbox.sendPort});
  final worker = _SttWorker(out);
  inbox.listen((message) {
    if (message is! Map) return;
    try {
      worker.handle(message);
    } on SherpaWorkerException catch (error) {
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

  /// Streaming recognizer, built instead of [_recognizer] when the catalog entry
  /// is `mode: streaming`. One long-lived stream carries the whole session so
  /// partial text can be replaced in place.
  sherpa.OnlineRecognizer? _online;
  sherpa.OnlineStream? _onlineStream;

  /// True when this session drives the streaming recognizer.
  ///
  /// The mode arrives as the daemon's `SttModelMode.name`; the package keeps a
  /// bool so it stays independent of the daemon's type catalog.
  bool _streaming = false;
  String _lastPartial = '';
  int _partialSeq = 0;

  /// Streaming diagnostics: the owner reported the first word of a session
  /// disappearing on streaming models only. Numbers only — never text — so the
  /// log can tell a late first partial (audio path) from a short one (merge).
  static final _logger = Logger('SttStreaming');
  final Stopwatch _streamClock = Stopwatch()..start();
  int _audioChunks = 0;
  int _acceptedSamples = 0;
  int _endpoints = 0;
  int _partialCount = 0;

  /// Automatic gain for the streaming path.
  ///
  /// sherpa's online recognizer applies no input normalisation, and this
  /// microphone delivers speech around 0.08 peak: measured on a real session,
  /// the recognizer produced its first character 3.5 s in, i.e. it skipped the
  /// opening words entirely. The gain starts from the first chunk that carries
  /// audible audio and then follows the level slowly, so the loudness a user
  /// speaks at never decides whether their first word is transcribed.
  double _streamGain = 1;
  bool _gainSeeded = false;
  double _streamPeak = 0;
  static const double _targetLevel = 0.75;
  static const double _maxStreamGain = 10;
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
      case 'reset':
        // A warm engine starts the next session from a clean slate: the model
        // and the online stream stay allocated, only the session counters go.
        _speech.clear();
        _bufferedSamples = 0;
        _lastPartial = '';
        _audioChunks = 0;
        _acceptedSamples = 0;
        _partialCount = 0;
        _endpoints = 0;
        _streamPeak = 0;
        _streamGain = 0;
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
    _streaming = message['mode'] == 'streaming';
    // The daemon resolves the directory (packaged payload, else this checkout's
    // package resolution) and passes it in, so the loader never has to fall back
    // to a null path — on macOS that would be `DynamicLibrary.process()`, which
    // only works inside a Flutter host.
    loadSherpaBindings(message['sherpaNativeDir'] as String?);
    if (_streaming) {
      _initStreaming(message);
      stopwatch.stop();
      _out.send({
        'evt': 'ready',
        'modelId': _modelId,
        'loadMs': stopwatch.elapsedMilliseconds,
      });
      _out.send({'evt': 'idle'});
      return;
    }
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

  /// Builds the native streaming recognizer and its session-long stream.
  ///
  /// Endpointing is left to sherpa (rule1/rule2 trailing silence): a segment
  /// closes on real silence, which is what makes the final replace the partial
  /// instead of duplicating it.
  void _initStreaming(Map message) {
    final joiner = message['joiner'] as String? ?? '';
    if (joiner.isEmpty) {
      throw const SherpaWorkerException(
        'model_incomplete',
        'a streaming model needs encoder, decoder, joiner and tokens',
      );
    }
    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: message['encoder'] as String,
            decoder: message['decoder'] as String,
            joiner: joiner,
          ),
          tokens: message['tokens'] as String,
          numThreads: message['threads'] as int? ?? 2,
          // The model's own dialect: 2023-06-26 exports are zipformer2 and
          // reject the older metadata parsing with "'attention_dims' does not
          // exist in the metadata".
          modelType: message['streamingModelType'] as String? ?? 'zipformer2',
          debug: false,
        ),
        // 0.8 s of silence closes a segment: long enough not to split a
        // sentence on a breath, short enough that the final feels immediate.
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 0.8,
        rule3MinUtteranceLength: 20,
      ),
    );
    _online = recognizer;
    _onlineStream = recognizer.createStream();
  }

  void _audio(Uint8List pcm16) {
    if (_streaming) {
      _streamAudio(pcm16);
      return;
    }
    _audioBatch(pcm16);
  }

  /// Feeds one chunk to the streaming recognizer and publishes whatever the
  /// decoder now believes the open segment says.
  void _streamAudio(Uint8List pcm16) {
    final recognizer = _online;
    final stream = _onlineStream;
    if (recognizer == null || stream == null) {
      throw const SherpaWorkerException('not_ready', 'recognizer is not loaded');
    }
    final samples = _pcm16ToFloat32(pcm16);
    _audioChunks++;
    _acceptedSamples += samples.length;
    final gain = _applyStreamGain(samples);
    if (_audioChunks == 1) {
      _logger.info(
        'streaming first audio atMs=${_streamClock.elapsedMilliseconds} '
        'samples=${samples.length} gain=${gain.toStringAsFixed(2)}x',
      );
    }
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final text = _sentenceCase(recognizer.getResult(stream).text);
    if (text.isNotEmpty && text != _lastPartial) {
      _lastPartial = text;
      _partialCount++;
      if (_partialCount == 1 || _partialCount % 20 == 0) {
        _logger.info(
          'streaming partial n=$_partialCount '
          'atMs=${_streamClock.elapsedMilliseconds} chars=${text.length}',
        );
      }
      _out.send({'evt': 'partial', 'seq': _partialSeq, 'text': text});
    }
    if (recognizer.isEndpoint(stream)) {
      _closeStreamingSegment(text);
    }
    _out.send({'evt': 'idle'});
  }

  /// Publishes the final for the open segment and starts a fresh one.
  void _closeStreamingSegment(String text) {
    final recognizer = _online;
    final stream = _onlineStream;
    if (recognizer == null || stream == null) return;
    if (text.isNotEmpty) {
      _endpoints++;
      _logger.info(
        'streaming endpoint n=$_endpoints '
        'atMs=${_streamClock.elapsedMilliseconds} chars=${text.length}',
      );
      _out.send({
        'evt': 'final',
        'seq': _partialSeq,
        'text': text,
        // Streaming reports text as audio is consumed, so a closed segment has
        // no decode pass of its own to measure.
        'audioMs': 0,
        'decodeMs': 0,
      });
      _partialSeq++;
    }
    _lastPartial = '';
    recognizer.reset(stream);
  }

  /// Scales the chunk in place for the recognizer and returns the gain used.
  ///
  /// The first chunk that carries audible audio seeds the gain, so the opening
  /// word is already normalised; afterwards the gain follows changes slowly so
  /// a breath cannot pump the whole stream.
  double _applyStreamGain(Float32List samples) {
    var peak = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final magnitude = samples[i].abs();
      if (magnitude > peak) peak = magnitude;
    }
    if (peak > _streamPeak) _streamPeak = peak;
    if (!_gainSeeded && peak > 0.01) {
      _gainSeeded = true;
      _streamGain = (_targetLevel / peak).clamp(1.0, _maxStreamGain);
      _logger.info(
        'streaming agc seeded: chunkPeak=${peak.toStringAsFixed(4)} '
        'gain=${_streamGain.toStringAsFixed(2)}x',
      );
    } else if (_gainSeeded && peak > 0.01) {
      final wanted = (_targetLevel / peak).clamp(1.0, _maxStreamGain);
      if (wanted < _streamGain) {
        // Instant attack: a louder syllable must never be clipped, and clipping
        // itself adds the harmonics that make recognition worse.
        _streamGain = wanted;
      } else {
        // 15% per chunk release: follows a turn away from the mic without
        // modulating on every syllable.
        _streamGain = _streamGain + (wanted - _streamGain) * 0.15;
      }
    }
    if (_streamGain > 1.01) {
      for (var i = 0; i < samples.length; i++) {
        samples[i] = (samples[i] * _streamGain).clamp(-1.0, 1.0);
      }
    }
    return _streamGain;
  }

  void _audioBatch(Uint8List pcm16) {
    final vad = _vad;
    if (vad == null || _recognizer == null) {
      throw const SherpaWorkerException('not_ready', 'recognizer is not loaded');
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
    if (_streaming) {
      _finishStreaming();
      return;
    }
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

  /// Flushes the open streaming segment at stop.
  ///
  /// The last words live in the decoder's tail, so a short silence is pushed
  /// through before reading the result; without it the final word of the
  /// utterance is lost.
  void _finishStreaming() {
    final recognizer = _online;
    final stream = _onlineStream;
    if (recognizer == null || stream == null) {
      _out.send({'evt': 'done', 'segments': 0});
      return;
    }
    stream.acceptWaveform(
      samples: Float32List(16000 ~/ 2),
      sampleRate: 16000,
    );
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final text = _sentenceCase(recognizer.getResult(stream).text);
    _logger.info(
      'streaming done: chunks=$_audioChunks '
      'audioMs=${_acceptedSamples * 1000 ~/ 16000} '
      'partials=$_partialCount endpoints=$_endpoints '
      'tailChars=${text.length} peak=${_streamPeak.toStringAsFixed(4)} '
      'gain=${_streamGain.toStringAsFixed(2)}x',
    );
    if (text.isNotEmpty) {
      _out.send({
        'evt': 'final',
        'seq': _partialSeq,
        'text': text,
        'audioMs': 0,
        'decodeMs': 0,
      });
      _partialSeq++;
    }
    _lastPartial = '';
    recognizer.reset(stream);
    _out.send({'evt': 'done', 'segments': text.isEmpty ? 0 : 1});
    _out.send({'evt': 'idle'});
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _onlineStream?.free();
    _onlineStream = null;
    _online?.free();
    _online = null;
    _vad?.free();
    _vad = null;
    _recognizer?.free();
    _recognizer = null;
    _out.send({'evt': 'closed'});
    Isolate.exit();
  }

  /// Streaming zipformer models emit upper-case tokens. The composer is a text
  /// field, not a caption, so the text is normalized to sentence case: lower-case
  /// everywhere, capital first letter. Batch whisper already returns cased text.
  static String _sentenceCase(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1);
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
