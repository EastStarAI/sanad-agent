// Temporary G0 feasibility probe for local dictation (voice02).
// Proves sherpa_onnx loads and decodes inside the pure-Dart daemon project.
//
// Usage:
//   fvm dart run tool/stt_probe.dart <model_dir> <wav> [language]
//
// model_dir must contain the whisper ONNX files + tokens.txt.
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: stt_probe.dart <model_dir> <wav> [language]');
    exit(64);
  }
  final modelDir = args[0];
  final wavPath = args[1];
  final language = args.length > 2 ? args[2] : 'ar';

  final encoder = _pickFile(modelDir, const [
    'encoder.int8.onnx',
    'base-encoder.int8.onnx',
    'encoder.onnx',
    'base-encoder.onnx',
  ]);
  final decoder = _pickFile(modelDir, const [
    'decoder.int8.onnx',
    'base-decoder.int8.onnx',
    'decoder.onnx',
    'base-decoder.onnx',
  ]);
  final tokens = _pickFile(modelDir, const ['tokens.txt', 'base-tokens.txt']);

  stdout.writeln('sherpa: bindings init (auto path)');
  final loadStart = DateTime.now();
  sherpa.initBindings();

  final config = sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: encoder,
        decoder: decoder,
        language: language,
        task: 'transcribe',
      ),
      tokens: tokens,
      modelType: 'whisper',
      numThreads: 2,
      debug: false,
    ),
  );

  final recognizer = sherpa.OfflineRecognizer(config);
  final loadMs = DateTime.now().difference(loadStart).inMilliseconds;
  stdout.writeln('model loaded in ${loadMs}ms, rss=${_rssMb()}MB');

  final wave = sherpa.readWave(wavPath);
  final seconds = wave.samples.length / wave.sampleRate;
  stdout.writeln(
    'audio ${seconds.toStringAsFixed(2)}s @ ${wave.sampleRate}Hz',
  );

  final decodeStart = DateTime.now();
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
  recognizer.decode(stream);
  final result = recognizer.getResult(stream);
  final decodeMs = DateTime.now().difference(decodeStart).inMilliseconds;

  stdout.writeln(
    'decoded in ${decodeMs}ms (rtf=${(decodeMs / (seconds * 1000)).toStringAsFixed(3)}) rss=${_rssMb()}MB',
  );
  stdout.writeln('text: ${result.text}');

  stream.free();
  recognizer.free();
}

String _pickFile(String dir, List<String> names) {
  for (final name in names) {
    final candidate = File('$dir/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  // Fall back to suffix matching so prefixed exports (e.g.
  // `egy-whisper-turbo-encoder.int8.onnx`) are found.
  final entries = Directory(dir).listSync().whereType<File>().toList();
  for (final name in names) {
    for (final entry in entries) {
      if (entry.uri.pathSegments.last.endsWith(name)) return entry.path;
    }
  }
  stderr.writeln('none of $names found in $dir');
  exit(66);
}

String _rssMb() => (ProcessInfo.currentRss / (1024 * 1024)).round().toString();
