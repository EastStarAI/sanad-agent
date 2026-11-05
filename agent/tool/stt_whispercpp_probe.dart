/// Measures the whisper.cpp engine the way G7 asks: load time, decode time and
/// resident memory for one buffer, in a clean process.
///
/// Usage:
///   `fvm dart run tool/stt_whispercpp_probe.dart <ggml-model> <wav16k> [lang] [threads]`
///
/// Prints one line per metric so a run can be compared with the sherpa numbers
/// in the plan (`stt_probe.dart`).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage: stt_whispercpp_probe.dart <ggml-model> <wav16k> [lang] [threads]',
    );
    exit(2);
  }
  final modelPath = args[0];
  final wavPath = args[1];
  final language = args.length > 2 ? args[2] : 'ar';
  final threads = args.length > 3 ? int.parse(args[3]) : 4;

  final library = WhisperCppLibrary.open();
  final loadWatch = Stopwatch()..start();
  final context = library.loadModel(modelPath);
  loadWatch.stop();
  stdout.writeln(
    'model loaded in ${loadWatch.elapsedMilliseconds}ms, '
    'rss=${_rssMb()}MB',
  );

  final samples = _readWav16kMono(wavPath);
  final watch = Stopwatch()..start();
  final result = library.run(
    context,
    samples,
    language: language,
    threads: threads,
  );
  watch.stop();
  final audioSeconds = samples.length / 16000;
  final decodeSeconds = watch.elapsedMilliseconds / 1000;
  stdout.writeln(
    'decoded in ${watch.elapsedMilliseconds}ms '
    '(rtf=${(decodeSeconds / audioSeconds).toStringAsFixed(3)}) '
    'rss=${_rssMb()}MB threads=$threads',
  );
  stdout.writeln('text: ${result.text}');

  library.freeModel(context);
  stdout.writeln('freed, rss=${_rssMb()}MB');
}

String _rssMb() =>
    (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0);

/// Minimal 16 kHz mono PCM16 WAV reader; the fixtures are already converted.
Float32List _readWav16kMono(String path) {
  final bytes = File(path).readAsBytesSync();
  var offset = 12;
  var dataOffset = -1;
  var dataLength = 0;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = ByteData.sublistView(bytes, offset + 4, offset + 8)
        .getUint32(0, Endian.little);
    if (id == 'data') {
      dataOffset = offset + 8;
      dataLength = size;
      break;
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (dataOffset < 0) {
    throw const FormatException('wav file has no data chunk');
  }
  final count = dataLength ~/ 2;
  final samples = Float32List(count);
  final view = ByteData.sublistView(bytes, dataOffset, dataOffset + count * 2);
  for (var i = 0; i < count; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
