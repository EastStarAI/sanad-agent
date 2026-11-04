// Temporary G1 probe: drives the real dictation engine over a WAV file.
// Proves the VAD + OfflineRecognizer pipeline (segmenting, finals, isolate
// boundary) without a client.
//
// Usage:
//   fvm dart run tool/stt_stream_probe.dart <model_dir> <vad.onnx> <wav> [lang]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/stt_engine.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: stt_stream_probe.dart <model_dir> <vad> <wav> [lang]');
    exit(64);
  }
  final modelDir = Directory(args[0]);
  final vad = args[1];
  final language = args.length > 3 ? args[3] : 'ar';
  final threads = args.length > 4 ? int.parse(args[4]) : 2;

  String find(String needle, String extension) {
    for (final file in modelDir.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (name.endsWith(extension) && name.contains(needle)) return file.path;
    }
    stderr.writeln('missing $needle$extension in ${modelDir.path}');
    exit(66);
  }

  final files = SttModelFiles(
    modelId: 'probe',
    encoder: find('encoder', '.onnx'),
    decoder: find('decoder', '.onnx'),
    tokens: find('tokens', '.txt'),
    vad: vad,
    language: language,
  );

  final pcm = _readWavPcm(args[2]);
  final seconds = pcm.length / 2 / 16000;
  stdout.writeln('audio ${seconds.toStringAsFixed(1)}s');

  final engine = SherpaSttEngine();
  final done = Completer<void>();
  var segments = 0;
  var words = 0;
  var decodeMs = 0;
  final audioMs = <int>[];

  engine.events.listen((event) {
    switch (event) {
      case SttReadyEvent():
        stdout.writeln('ready in ${event.loadMs}ms (model=${event.modelId})');
      case SttPartialEvent():
        stdout.writeln('partial[${event.seq}]: ${event.text}');
      case SttFinalEvent():
        segments++;
        words += event.text.split(RegExp(r'\s+')).length;
        decodeMs += event.decodeMs;
        audioMs.add(event.audioMs);
        stdout.writeln(
          'final[${event.seq}] ${event.audioMs}ms audio / ${event.decodeMs}ms decode: ${event.text}',
        );
      case SttDoneEvent():
        stdout.writeln('done segments=$segments dropped=${event.droppedChunks}');
        if (!done.isCompleted) done.complete();
      case SttErrorEvent():
        stderr.writeln('error ${event.error.code}: ${event.error.message}');
        if (!done.isCompleted) done.complete();
    }
  });

  final wall = Stopwatch()..start();
  await engine.start(files, modelId: 'probe', threads: threads);

  const chunkBytes = 3200; // 100 ms of 16 kHz mono PCM16
  for (var offset = 0; offset < pcm.length; offset += chunkBytes) {
    final end = (offset + chunkBytes).clamp(0, pcm.length);
    engine.acceptAudio(Uint8List.sublistView(pcm, offset, end));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await engine.finish();
  await done.future.timeout(const Duration(seconds: 180));
  wall.stop();

  stdout.writeln(
    'summary: ${wall.elapsedMilliseconds}ms wall, '
    'segments=$segments words=$words decode=${decodeMs}ms '
    'median_segment_ms=${_median(audioMs)}',
  );
  await engine.dispose();
  exit(0);
}

int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

Uint8List _readWavPcm(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      return Uint8List.sublistView(bytes, offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in $path');
}
