// Temporary probe: can sherpa-onnx load the Nawah (NeMo TDT, Arabic) export?
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: nawah_probe.dart <model_dir> <wav>');
    exit(64);
  }
  final dir = args[0];
  sherpa.initBindings();

  final load = Stopwatch()..start();
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: '$dir/encoder.int8.onnx',
          decoder: '$dir/decoder.onnx',
          joiner: '$dir/joiner.onnx',
        ),
        tokens: '$dir/tokens.txt',
        modelType: 'nemo_transducer',
        numThreads: 4,
        debug: false,
      ),
    ),
  );
  load.stop();
  stdout.writeln('loaded in ${load.elapsedMilliseconds}ms');

  final wave = sherpa.readWave(args[1]);
  stdout.writeln(
    'audio ${(wave.samples.length / wave.sampleRate).toStringAsFixed(1)}s',
  );
  final decode = Stopwatch()..start();
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
  recognizer.decode(stream);
  final text = recognizer.getResult(stream).text;
  decode.stop();
  stdout.writeln(
    'decoded in ${decode.elapsedMilliseconds}ms '
    '(rtf=${(decode.elapsedMilliseconds / (wave.samples.length / wave.sampleRate * 1000)).toStringAsFixed(3)})',
  );
  stdout.writeln('text: $text');
  stream.free();
  recognizer.free();
}
