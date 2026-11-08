/// Public surface of the sherpa-onnx dictation engine.
///
/// The Sanad Agent depends on **this package name**, and the engine behind it is
/// swappable: `packages/stt_sherpa` is the real sherpa-onnx worker, and
/// `packages/stt_sherpa_stub` is a build-time stand-in for lanes that cannot
/// resolve `sherpa_onnx` (it requires the Flutter SDK). Both expose exactly the
/// names below, so nothing outside this package knows which one it got.
///
/// This library carries no engine code itself: it only re-exports the worker
/// entry point and the availability flag the daemon asks for.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

export 'src/sherpa_worker.dart' show sherpaWorkerEntry;

/// Whether this build can run sherpa-onnx at all.
///
/// A `false` build is not broken: local dictation still runs through the
/// whisper.cpp runtime, batch-only. Everything that picks a model or reports
/// readiness reads this flag instead of testing the platform.
const bool sherpaEngineAvailable = true;

/// Directory in this checkout that holds the sherpa native libraries, or null.
///
/// It is the same directory `initBindings` is handed, so packaging copies
/// exactly the files the loader opens: the release tool asks this instead of
/// knowing the plugin layout, and a build without sherpa answers null.
String? sherpaNativeSourceDirectory() => sherpa.resolveSherpaOnnxPathSync();

/// Loads the engine's native library.
///
/// [directory] is the packaged `native/<tag>/sherpa/` directory, or null to let
/// the engine resolve the library from this checkout's package resolution. It is
/// the only entry point callers get: the raw `sherpa_onnx` import stays inside
/// this package so a build without the engine cannot reference it.
void sherpaInitBindings([String? directory]) {
  if (directory != null && Platform.isWindows) {
    // Windows resolves a DLL's imports from the process search path, not from
    // the DLL's own directory, so the runtime must be loaded by path first. The
    // same reason made the whisper shim preload its siblings.
    final onnxruntime = File('$directory/onnxruntime.dll');
    if (onnxruntime.existsSync()) DynamicLibrary.open(onnxruntime.path);
  }
  sherpa.initBindings(directory);
}
