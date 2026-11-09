/// Stand-in for `packages/stt_sherpa` on builds that cannot resolve sherpa_onnx.
///
/// `sherpa_onnx` requires the Flutter SDK, and the Linux arm64 Agent is built
/// with the standalone Dart SDK, so that lane depends on this package instead
/// (see `agent/tool/pubspec_overrides.no_sherpa.yaml`). It exposes the same
/// library name and the same public names, which is the whole contract:
///
/// * [sherpaEngineAvailable] is `false`, so model selection never offers a
///   sherpa entry and readiness routes local dictation to the whisper.cpp
///   runtime;
/// * [sherpaWorkerEntry] still exists, because the engine registry is shared,
///   but it answers every command with one typed refusal instead of decoding.
///
/// Nothing is copied from the real engine: this file has no recognition code.
library;

import 'dart:isolate';

/// Whether this build can run sherpa-onnx at all. Always false here.
const bool sherpaEngineAvailable = false;

/// Typed refusal this build answers with.
///
/// It is stable and machine-readable, and it can only be observed if something
/// selected a sherpa model anyway: readiness and selection refuse first.
const String sherpaUnavailableCode = 'sherpa_unavailable';

/// This build ships no sherpa libraries, so packaging has none to copy.
String? sherpaNativeSourceDirectory() => null;

/// Never reached: readiness and selection refuse a sherpa session first.
void sherpaInitBindings([String? directory]) {
  throw UnsupportedError(
    'this build has no sherpa-onnx engine; local dictation uses the '
    'whisper.cpp runtime',
  );
}

/// Worker-isolate body with the same protocol as the real engine.
///
/// The daemon spawns the engine it was configured with, so this must speak the
/// handshake (`port`) and answer commands with a typed `error` event rather
/// than dying silently.
void sherpaWorkerEntry(SendPort out) {
  final inbox = ReceivePort();
  out.send({'evt': 'port', 'port': inbox.sendPort});
  inbox.listen((message) {
    if (message is! Map) return;
    out.send({
      'evt': 'error',
      'code': sherpaUnavailableCode,
      'message':
          'this build has no sherpa-onnx engine; local dictation uses the '
          'whisper.cpp runtime',
    });
  });
}
