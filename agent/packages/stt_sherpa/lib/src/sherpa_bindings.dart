import 'dart:ffi';
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Loads the engine's native library into the current isolate.
///
/// [directory] is the packaged `native/<tag>/sherpa/` directory or the checkout
/// directory the release tool stages from; null lets the engine resolve the
/// library from this process's package resolution.
///
/// It lives here rather than in the worker so the one preload rule below is
/// shared by the worker and by the packaging smoke test, instead of the test
/// proving a code path the daemon never takes.
void loadSherpaBindings([String? directory]) {
  if (directory != null && Platform.isWindows) {
    // Windows resolves a DLL's imports from the process search path, not from
    // the DLL's own directory, so the runtime must be loaded by path first. The
    // same reason made the whisper shim preload its siblings.
    final onnxruntime = File('$directory/onnxruntime.dll');
    if (onnxruntime.existsSync()) DynamicLibrary.open(onnxruntime.path);
  }
  sherpa.initBindings(directory);
}
