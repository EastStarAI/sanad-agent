import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_settings.dart';
import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';
import 'package:test/test.dart';

const _q8ModelEnvironment = 'SANAD_STT_Q8_MODEL';
const _fixturePath =
    '../client/test/fixtures/dictation/ar_batch_dictation_check.pcm';
const _expectedTranscriptSha256 =
    '8feb9fc0655d09d64d58c90141f6f83abc3c9870fe2a32e3ccb19a91ed275c28';

void main() {
  test('shrinking audio_ctx cannot inherit a preceding decode state', () {
    final modelPath = Platform.environment[_q8ModelEnvironment]?.trim();
    if (modelPath == null || modelPath.isEmpty) {
      markTestSkipped(
        '$_q8ModelEnvironment is not set; the 834 MiB q8 model is optional.',
      );
      return;
    }
    if (!File(modelPath).existsSync()) {
      markTestSkipped(
        '$_q8ModelEnvironment does not name an installed q8 model: $modelPath',
      );
      return;
    }
    if (!WhisperCppLibrary.isAvailable) {
      markTestSkipped(
        'The native whisper runtime is not built for this checkout.',
      );
      return;
    }

    final raw = _readPcm16(_fixturePath);
    final short = _withTrailingSilence(raw);
    final long = _pairedWithSilence(raw);
    final library = WhisperCppLibrary.open();
    final context = library.loadModel(modelPath, useGpu: defaultSttUseGpu());

    try {
      final reference = _decode(library, context, short, audioCtx: 448);
      expect(reference, isNotEmpty);
      expect(_sha256(reference), _expectedTranscriptSha256);

      final longResult = _decode(library, context, long, audioCtx: 544);
      expect(longResult, isNotEmpty);
      final after544 = _decode(library, context, short, audioCtx: 448);
      expect(after544, reference, reason: '448 must be stable after 544');
      expect(_sha256(after544), _expectedTranscriptSha256);

      final fullWindow = _decode(library, context, short, audioCtx: 1500);
      expect(fullWindow, isNotEmpty);
      final after1500 = _decode(library, context, short, audioCtx: 448);
      expect(after1500, reference, reason: '448 must be stable after 1500');
      expect(_sha256(after1500), _expectedTranscriptSha256);
    } finally {
      library.freeModel(context);
    }
  });
}

String _decode(
  WhisperCppLibrary library,
  Pointer<Void> context,
  Float32List samples, {
  required int audioCtx,
}) => library
    .run(
      context,
      samples,
      language: 'ar',
      threads: defaultSttThreads,
      audioCtx: audioCtx,
    )
    .text;

Float32List _readPcm16(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  final samples = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

Float32List _withTrailingSilence(Float32List source) {
  final result = Float32List(source.length + 8000);
  result.setAll(0, source);
  return result;
}

Float32List _pairedWithSilence(Float32List source) {
  final result = Float32List(source.length * 2 + 16000);
  result.setAll(0, source);
  result.setAll(source.length + 8000, source);
  return result;
}

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();
