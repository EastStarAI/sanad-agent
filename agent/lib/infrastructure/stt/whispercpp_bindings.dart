/// dart:ffi binding to `libsanad_whisper` (a thin C shim over whisper.cpp).
///
/// whisper.cpp returns `struct whisper_full_params` by value, so binding it
/// directly would break on every upstream bump. The shim keeps the ABI to four
/// flat functions and lives in `agent/native/whispercpp/sanad_whisper.c`.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'stt_types.dart';

typedef _LoadNative =
    Pointer<Void> Function(Pointer<Utf8>, Int32, Pointer<Uint8>, Int32);
typedef _LoadDart =
    Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Uint8>, int);

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

typedef _RunNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Float>,
      Int32,
      Pointer<Utf8>,
      Int32,
      Bool,
      Bool,
      Int32,
      Pointer<Uint8>,
      Int32,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _RunDart =
    int Function(
      Pointer<Void>,
      Pointer<Float>,
      int,
      Pointer<Utf8>,
      int,
      bool,
      bool,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Int32>,
      Pointer<Int32>,
    );

/// Loads the shim once per process and exposes the two calls the worker needs.
class WhisperCppLibrary {
  WhisperCppLibrary._(this._lib, this._load, this._free, this._run);

  final DynamicLibrary _lib;
  final _LoadDart _load;
  final _FreeDart _free;
  final _RunDart _run;

  /// Kept alive so the underlying handle is never closed while in use.
  DynamicLibrary get library => _lib;

  static WhisperCppLibrary? _instance;
  static String? _loadedFrom;

  /// Where the shim is expected: an explicit env override, next to the running
  /// executable, or inside the checkout (tests and `dart run`).
  static String get defaultLibraryPath {
    final override = Platform.environment['SANAD_WHISPER_LIB'];
    if (override != null && override.isNotEmpty) return override;
    for (final candidate in _candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return _candidates.first;
  }

  static const String _libraryBase = 'libsanad_whisper';

  /// Native extension differs per OS; the shim is the same C file everywhere.
  static String get libraryFileName {
    if (Platform.isMacOS) return '$_libraryBase.dylib';
    if (Platform.isWindows) return 'sanad_whisper.dll';
    return '$_libraryBase.so';
  }

  /// Directory that holds the prebuilt shim and its ggml/whisper libraries.
  static String get platformDir {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'linux';
  }

  static List<String> get _candidates {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;
    final name = libraryFileName;
    final dir = platformDir;
    final override = Platform.environment['SANAD_WHISPER_LIBRARY']?.trim();
    return <String>[
      if (override != null && override.isNotEmpty) override,
      '$exeDir/native/$dir/$name',
      '$exeDir/../native/$dir/$name',
      '$cwd/native/$dir/$name',
      '$cwd/agent/native/$dir/$name',
    ];
  }

  /// True when the shim (and therefore its ggml/whisper siblings) is on disk.
  ///
  /// Readiness uses this instead of opening the library: a missing runtime must
  /// be reportable without loading anything into the daemon.
  static bool get isAvailable {
    for (final candidate in _candidates) {
      if (File(candidate).existsSync()) return true;
    }
    return false;
  }

  /// True when the shim is being built or downloaded right now.
  ///
  /// `ensure_native_stt` writes this marker while it works and removes it when
  /// it finishes, so the UI can show "preparing" instead of "missing". Stale
  /// markers (a killed build) expire so the state never sticks.
  static bool get isBeingPrepared {
    for (final candidate in _candidates) {
      final marker = File('${File(candidate).parent.path}/.stt-preparing');
      if (!marker.existsSync()) continue;
      final age = DateTime.now().difference(marker.lastModifiedSync());
      if (age < const Duration(minutes: 30)) return true;
    }
    return false;
  }

  static WhisperCppLibrary open([String? path]) {
    final target = path ?? defaultLibraryPath;
    final cached = _instance;
    if (cached != null && _loadedFrom == target) return cached;
    if (!File(target).existsSync()) {
      throw SttException(
        'engine_missing',
        'the whisper.cpp library is missing at $target',
      );
    }
    final lib = DynamicLibrary.open(target);
    final instance = WhisperCppLibrary._(
      lib,
      lib.lookupFunction<_LoadNative, _LoadDart>('sanad_whisper_load'),
      lib.lookupFunction<_FreeNative, _FreeDart>('sanad_whisper_free'),
      lib.lookupFunction<_RunNative, _RunDart>('sanad_whisper_run'),
    );
    _instance = instance;
    _loadedFrom = target;
    return instance;
  }

  /// Opens a ggml model with mmap. Throws [SttException] with the C reason.
  ///
  /// [useGpu] selects Metal; whisper.cpp binds the backend when the model is
  /// created, so a CPU fallback means reopening the model with this flag off.
  Pointer<Void> loadModel(String path, {bool useGpu = true}) {
    final pathPtr = path.toNativeUtf8();
    final error = calloc<Uint8>(256);
    try {
      final handle = _load(pathPtr, useGpu ? 1 : 0, error, 256);
      if (handle == nullptr) {
        throw SttException('model_load_failed', _readCString(error, 256));
      }
      return handle;
    } finally {
      calloc.free(pathPtr);
      calloc.free(error);
    }
  }

  void freeModel(Pointer<Void> handle) => _free(handle);

  /// Decodes one 16 kHz mono buffer and returns the joined segment text.
  WhisperCppResult run(
    Pointer<Void> handle,
    Float32List samples, {
    required String language,
    required int threads,
  }) {
    final languagePtr = language.toNativeUtf8();
    final samplePtr = calloc<Float>(samples.length);
    final out = calloc<Uint8>(_outCapacity);
    final audioMs = calloc<Int32>(1);
    final decodeMs = calloc<Int32>(1);
    final watch = Stopwatch()..start();
    try {
      samplePtr.asTypedList(samples.length).setAll(0, samples);
      final written = _run(
        handle,
        samplePtr,
        samples.length,
        languagePtr,
        threads,
        false,
        true,
        1000,
        out,
        _outCapacity,
        audioMs,
        decodeMs,
      );
      watch.stop();
      if (written < 0) {
        throw const SttException('decode_failed', 'whisper.cpp decode failed');
      }
      return WhisperCppResult(
        text: _readCString(out, written).trim(),
        audioMs: audioMs.value,
        decodeMs: watch.elapsedMilliseconds,
      );
    } finally {
      calloc.free(languagePtr);
      calloc.free(samplePtr);
      calloc.free(out);
      calloc.free(audioMs);
      calloc.free(decodeMs);
    }
  }

  /// 64 KiB of UTF-8 text: a 30 s segment is far below this.
  static const int _outCapacity = 64 * 1024;

  static String _readCString(Pointer<Uint8> ptr, int length) {
    final bytes = ptr.asTypedList(length);
    var end = 0;
    while (end < length && bytes[end] != 0) {
      end++;
    }
    // whisper.cpp emits UTF-8; decoding byte-by-byte would break Arabic.
    return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
  }
}

class WhisperCppResult {
  const WhisperCppResult({
    required this.text,
    required this.audioMs,
    required this.decodeMs,
  });

  final String text;
  final int audioMs;
  final int decodeMs;
}
