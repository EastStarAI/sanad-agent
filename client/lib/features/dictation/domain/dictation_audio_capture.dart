import 'package:record/record.dart';

/// Raised when the OS denies microphone access for dictation.
class DictationMicrophoneDenied implements Exception {
  const DictationMicrophoneDenied();

  @override
  String toString() => 'DictationMicrophoneDenied';
}

/// Microphone capture contract, so the session can be exercised without a
/// platform recorder.
abstract class DictationCapture {
  Future<bool> hasPermission();
  Future<Stream<List<int>>> start();
  Future<void> stop();
  Future<void> dispose();
}

/// Microphone capture for dictation: 16 kHz mono PCM16 little-endian.
///
/// Capture is deliberately separate from the voice-call service so dictation
/// never spins up playback, echo cancellation, or a voice audio session.
class DictationAudioCapture implements DictationCapture {
  DictationAudioCapture({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } on Object {
      return false;
    }
  }

  @override
  Future<Stream<List<int>>> start() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    if (!await hasPermission()) {
      throw const DictationMicrophoneDenied();
    }
    return _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
  }

  @override
  Future<void> stop() async {
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } on Object {
      // Device may have gone away mid-session; nothing left to stop.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    try {
      await _recorder.dispose();
    } on Object {
      // Already disposed.
    }
  }
}
