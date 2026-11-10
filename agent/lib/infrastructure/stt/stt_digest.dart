/// SHA-256 for the dictation model installer.
///
/// The digest is a per-byte cost on the download's critical path and the one
/// stage a slow CPU can cap: pure-Dart SHA-256 runs at ~196 MB/s on an M4 and
/// ~55 MB/s on a Neoverse-N1 core, which on the owner's 4-core host was the
/// largest reducible term of a 5x-slow download. The OS already ships a
/// hardware-accelerated implementation, so the production digest calls it
/// through `dart:ffi` and keeps the pure-Dart path as a fallback.
///
/// Measured (macOS arm64, 1.2 GB, AOT): 2 578 MB/s and 0.41 CPU-s/GB native
/// against 196 MB/s and 5.25 CPU-s/GB pure Dart — 13x the throughput for 13x
/// less CPU. No byte of this changes the checksum: both paths must produce the
/// same hex digest, which `stt_digest_test.dart` proves against `package:crypto`
/// across chunk boundaries.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

/// Streaming SHA-256 with an explicit finish.
///
/// [finish] ends the stream: the returned value is the lowercase hex digest and
/// the instance must not be used afterwards.
abstract class SttDigest {
  void add(List<int> bytes);

  String finish();

  /// Releases whatever this digest holds, without producing a digest.
  ///
  /// Idempotent, and a no-op once [finish] has run — [finish] releases the same
  /// state. A transfer that is cancelled, refused by the disk, or dropped by the
  /// network never reaches [finish], and native memory is not garbage collected,
  /// so the owner must call this from a `finally`.
  void close();
}

/// Creates the digest an install should use.
typedef SttDigestFactory = SttDigest Function();

/// Whether the OS implementation is available on this host.
///
/// Resolved once: a missing symbol or library is a permanent property of the
/// running executable, not a transient condition, and probing it per artifact
/// would pay the FFI lookup for nothing. What is cached is the *answer*, never a
/// context: the per-stream state is native memory, so every digest owns its own
/// and frees it.
bool get sttNativeDigestAvailable => _nativeFactory() != null;

_OsSha256 Function()? _native;

/// The digest production uses: OS crypto when it loads, pure Dart otherwise.
///
/// The fallback is deliberately silent about *why* it fell back — a daemon that
/// cannot open `libcrypto.so.3` must still install a model — but the choice is
/// observable through [sttNativeDigestAvailable] so a test can assert which one
/// ran.
SttDigest createSttDigest() {
  final factory = _nativeFactory();
  if (factory == null) return PureDartSttDigest();
  try {
    return _NativeSttDigest(factory());
  } on Object {
    // A library that resolved its symbols but refuses a context: keep working.
    _native = null;
    return PureDartSttDigest();
  }
}

_OsSha256 Function()? _nativeFactory() {
  if (_native != null) return _native;
  try {
    _OsSha256.open().probe();
    _native = _OsSha256.open;
    return _native;
  } on Object {
    // A host without the library keeps working at the pure-Dart speed.
    _native = null;
    return null;
  }
}

/// `package:crypto`'s SHA-256: correct everywhere, ~13x the CPU per byte.
class PureDartSttDigest implements SttDigest {
  final _Collector _collector = _Collector();
  late final ByteConversionSink _input = sha256.startChunkedConversion(
    _collector,
  );

  @override
  void add(List<int> bytes) => _input.add(bytes);

  @override
  String finish() {
    _input.close();
    return _collector.value?.toString() ?? '';
  }

  /// Nothing native to free: the hasher is ordinary Dart memory.
  @override
  void close() {}
}

class _Collector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// SHA-256 backed by the OS crypto library.
class _NativeSttDigest implements SttDigest {
  _NativeSttDigest(this._sha) {
    _sha.init();
  }

  final _OsSha256 _sha;
  bool _finished = false;
  bool _closed = false;

  @override
  void add(List<int> bytes) {
    if (bytes is! Uint8List) {
      add(Uint8List.fromList(bytes));
      return;
    }
    // A native context cannot read Dart memory, so bytes are copied into it in
    // windows: the reader hands over whatever the socket or the resumed re-read
    // produced, and a single chunk can be megabytes. The view is passed down and
    // copied exactly once, inside the backend.
    for (var offset = 0; offset < bytes.length;) {
      final take = bytes.length - offset < _OsSha256.chunkBytes
          ? bytes.length - offset
          : _OsSha256.chunkBytes;
      _sha.update(Uint8List.sublistView(bytes, offset, offset + take), take);
      offset += take;
    }
  }

  @override
  String finish() {
    if (_finished) throw StateError('SHA-256 already finished');
    if (_closed) throw StateError('SHA-256 already closed');
    _finished = true;
    return _sha.finish();
  }

  @override
  void close() {
    if (_closed || _finished) return;
    _closed = true;
    _sha.dispose();
  }
}

/// One platform-specific SHA-256 context.
///
/// Each implementation is a thin wrapper: allocate a context, feed bytes, read
/// 32 output bytes, free. Nothing accumulates in Dart memory, which is what
/// keeps the digest from growing the install's footprint.
abstract class _OsSha256 {
  /// Scratch buffer used to hand bytes to the native context.
  static const int chunkBytes = 64 * 1024;

  static _OsSha256 open() {
    if (Platform.isMacOS) return _CommonCryptoSha256();
    if (Platform.isLinux) return _OpenSslSha256();
    if (Platform.isWindows) return _BCryptSha256();
    throw UnsupportedError('no OS SHA-256 on ${Platform.operatingSystem}');
  }

  /// Forces this backend's symbols to resolve, so availability is an answer
  /// rather than an assumption that only surfaces at the first digest of an
  /// install.
  void probe();

  void init();

  void update(List<int> bytes, int length);

  String finish();

  /// Frees the context without finalizing. Idempotent.
  void dispose();
}

/// macOS: CommonCrypto lives in libSystem, so nothing is bundled or signed.
class _CommonCryptoSha256 implements _OsSha256 {
  static final DynamicLibrary _lib = DynamicLibrary.process();
  static final _CcInit _init = _lib.lookupFunction<_CcInitNative, _CcInit>(
    'CC_SHA256_Init',
  );
  static final _CcUpdate _update = _lib
      .lookupFunction<_CcUpdateNative, _CcUpdate>('CC_SHA256_Update');
  static final _CcFinal _final = _lib.lookupFunction<_CcFinalNative, _CcFinal>(
    'CC_SHA256_Final',
  );

  /// `CC_SHA256_CTX` is 26 32-bit words; sized generously to stay valid if
  /// Apple ever grows it.
  static const int _ctxBytes = 128;

  Pointer<Uint8>? _ctx;
  Pointer<Uint8>? _input;

  /// Resolves the first CommonCrypto symbol now instead of mid-install.
  @override
  void probe() => _init;

  @override
  void init() {
    _ctx = calloc<Uint8>(_ctxBytes);
    _input = calloc<Uint8>(_OsSha256.chunkBytes);
    _init(_ctx!);
  }

  @override
  void update(List<int> bytes, int length) {
    assert(length <= _OsSha256.chunkBytes, 'native window exceeded');
    final buffer = _input!.asTypedList(length);
    buffer.setRange(0, length, bytes);
    _update(_ctx!, _input!, length);
  }

  @override
  String finish() {
    final ctx = _ctx;
    if (ctx == null) throw StateError('SHA-256 context already released');
    final out = calloc<Uint8>(32);
    try {
      _final(out, ctx);
      return _hex(out);
    } finally {
      calloc.free(out);
      dispose();
    }
  }

  @override
  void dispose() {
    final ctx = _ctx;
    final input = _input;
    _ctx = null;
    _input = null;
    if (ctx != null) calloc.free(ctx);
    if (input != null) calloc.free(input);
  }
}

/// Linux: OpenSSL's EVP interface from the system `libcrypto`.
class _OpenSslSha256 implements _OsSha256 {
  static final DynamicLibrary _lib = _openLibrary();
  static final _EvpNew _ctxNew = _lib.lookupFunction<_EvpNewNative, _EvpNew>(
    'EVP_MD_CTX_new',
  );
  static final _EvpSha256 _sha256 = _lib
      .lookupFunction<_EvpSha256Native, _EvpSha256>('EVP_sha256');
  static final _EvpInit _initEx = _lib.lookupFunction<_EvpInitNative, _EvpInit>(
    'EVP_DigestInit_ex',
  );
  static final _EvpUpdate _updateEx = _lib
      .lookupFunction<_EvpUpdateNative, _EvpUpdate>('EVP_DigestUpdate');
  static final _EvpFinal _finalEx = _lib
      .lookupFunction<_EvpFinalNative, _EvpFinal>('EVP_DigestFinal_ex');
  static final _EvpFree _ctxFree = _lib
      .lookupFunction<_EvpFreeNative, _EvpFree>('EVP_MD_CTX_free');

  /// Ubuntu 24.04 ships OpenSSL 3 (`libcrypto.so.3`); older images and
  /// non-Debian distributions may only expose the unversioned soname.
  static DynamicLibrary _openLibrary() {
    for (final name in const ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so']) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError {
        continue;
      }
    }
    throw UnsupportedError('no libcrypto found');
  }

  Pointer<Void>? _ctx;
  Pointer<Uint8>? _input;

  /// Resolves the first OpenSSL symbol now instead of mid-install.
  @override
  void probe() => _sha256();

  @override
  void init() {
    final ctx = _ctxNew();
    if (ctx == nullptr) throw StateError('EVP_MD_CTX_new failed');
    _ctx = ctx;
    _input = calloc<Uint8>(_OsSha256.chunkBytes);
    if (_initEx(ctx, _sha256(), nullptr) != 1) {
      throw StateError('EVP_DigestInit_ex failed');
    }
  }

  @override
  void update(List<int> bytes, int length) {
    assert(length <= _OsSha256.chunkBytes, 'native window exceeded');
    final buffer = _input!.asTypedList(length);
    buffer.setRange(0, length, bytes);
    if (_updateEx(_ctx!, _input!, length) != 1) {
      throw StateError('EVP_DigestUpdate failed');
    }
  }

  @override
  String finish() {
    final ctx = _ctx;
    if (ctx == null) throw StateError('SHA-256 context already released');
    final out = calloc<Uint8>(32);
    final size = calloc<Uint32>(1);
    try {
      if (_finalEx(ctx, out, size) != 1) {
        throw StateError('EVP_DigestFinal_ex failed');
      }
      return _hex(out);
    } finally {
      calloc.free(out);
      calloc.free(size);
      dispose();
    }
  }

  @override
  void dispose() {
    final ctx = _ctx;
    final input = _input;
    _ctx = null;
    _input = null;
    if (input != null) calloc.free(input);
    if (ctx != null) _ctxFree(ctx);
  }
}

/// Windows: `bcrypt.dll` is part of the OS, so nothing is bundled or signed.
class _BCryptSha256 implements _OsSha256 {
  static final DynamicLibrary _lib = DynamicLibrary.open('bcrypt.dll');
  static final _BCryptOpen _open = _lib
      .lookupFunction<_BCryptOpenNative, _BCryptOpen>('BCryptOpenAlgorithmProvider');
  static final _BCryptCreate _create = _lib
      .lookupFunction<_BCryptCreateNative, _BCryptCreate>('BCryptCreateHash');
  static final _BCryptHashData _hashData = _lib
      .lookupFunction<_BCryptHashDataNative, _BCryptHashData>('BCryptHashData');
  static final _BCryptFinish _finishHash = _lib
      .lookupFunction<_BCryptFinishNative, _BCryptFinish>('BCryptFinishHash');
  static final _BCryptDestroy _destroy = _lib
      .lookupFunction<_BCryptDestroyNative, _BCryptDestroy>('BCryptDestroyHash');
  static final _BCryptClose _close = _lib
      .lookupFunction<_BCryptCloseNative, _BCryptClose>(
        'BCryptCloseAlgorithmProvider',
      );

  Pointer<Void> _algorithm = nullptr;
  Pointer<Void> _hash = nullptr;
  Pointer<Uint8>? _input;

  /// Resolves the first bcrypt symbol now instead of mid-install.
  @override
  void probe() => _open;

  @override
  void init() {
    final provider = calloc<Pointer<Void>>();
    final hash = calloc<Pointer<Void>>();
    final algId = calloc<Uint16>(7);
    try {
      const name = 'SHA256';
      for (var i = 0; i < name.length; i++) {
        algId[i] = name.codeUnitAt(i);
      }
      algId[name.length] = 0;
      _check(_open(provider, algId, nullptr, 0), 'BCryptOpenAlgorithmProvider');
      _algorithm = provider.value;
      _check(_create(_algorithm, hash, nullptr, 0, nullptr, 0, 0), 'BCryptCreateHash');
      _hash = hash.value;
      _input = calloc<Uint8>(_OsSha256.chunkBytes);
    } finally {
      calloc.free(provider);
      calloc.free(hash);
      calloc.free(algId);
    }
  }

  @override
  void update(List<int> bytes, int length) {
    assert(length <= _OsSha256.chunkBytes, 'native window exceeded');
    final buffer = _input!.asTypedList(length);
    buffer.setRange(0, length, bytes);
    _check(_hashData(_hash, _input!, length, 0), 'BCryptHashData');
  }

  @override
  String finish() {
    if (_hash == nullptr) throw StateError('SHA-256 context already released');
    final out = calloc<Uint8>(32);
    try {
      _check(_finishHash(_hash, out, 32, 0), 'BCryptFinishHash');
      return _hex(out);
    } finally {
      calloc.free(out);
      dispose();
    }
  }

  @override
  void dispose() {
    final input = _input;
    final hash = _hash;
    final algorithm = _algorithm;
    _input = null;
    _hash = nullptr;
    _algorithm = nullptr;
    if (input != null) calloc.free(input);
    if (hash != nullptr) _destroy(hash);
    if (algorithm != nullptr) _close(algorithm, 0);
  }

  static void _check(int status, String call) {
    // A negative NTSTATUS is a failure; the high bit is the severity flag.
    if (status < 0) throw StateError('$call failed ($status)');
  }
}

String _hex(Pointer<Uint8> bytes) {
  final builder = StringBuffer();
  for (var i = 0; i < 32; i++) {
    builder.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return builder.toString();
}

typedef _CcInitNative = Void Function(Pointer<Uint8> context);
typedef _CcInit = void Function(Pointer<Uint8> context);
typedef _CcUpdateNative =
    Void Function(Pointer<Uint8> context, Pointer<Uint8> data, Uint32 length);
typedef _CcUpdate =
    void Function(Pointer<Uint8> context, Pointer<Uint8> data, int length);
typedef _CcFinalNative =
    Void Function(Pointer<Uint8> digest, Pointer<Uint8> context);
typedef _CcFinal = void Function(Pointer<Uint8> digest, Pointer<Uint8> context);

typedef _EvpNewNative = Pointer<Void> Function();
typedef _EvpNew = Pointer<Void> Function();
typedef _EvpSha256Native = Pointer<Void> Function();
typedef _EvpSha256 = Pointer<Void> Function();
typedef _EvpInitNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Void> type, Pointer<Void> params);
typedef _EvpInit =
    int Function(Pointer<Void> ctx, Pointer<Void> type, Pointer<Void> params);
typedef _EvpUpdateNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Uint8> data, UintPtr length);
typedef _EvpUpdate =
    int Function(Pointer<Void> ctx, Pointer<Uint8> data, int length);
typedef _EvpFinalNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Uint8> digest, Pointer<Uint32> len);
typedef _EvpFinal =
    int Function(Pointer<Void> ctx, Pointer<Uint8> digest, Pointer<Uint32> len);
typedef _EvpFreeNative = Void Function(Pointer<Void> ctx);
typedef _EvpFree = void Function(Pointer<Void> ctx);

typedef _BCryptOpenNative =
    Int32 Function(
      Pointer<Pointer<Void>> algorithm,
      Pointer<Uint16> algId,
      Pointer<Uint16> implementation,
      Uint32 flags,
    );
typedef _BCryptOpen =
    int Function(
      Pointer<Pointer<Void>> algorithm,
      Pointer<Uint16> algId,
      Pointer<Uint16> implementation,
      int flags,
    );
typedef _BCryptCreateNative =
    Int32 Function(
      Pointer<Void> algorithm,
      Pointer<Pointer<Void>> hash,
      Pointer<Uint8> object,
      Uint32 objectBytes,
      Pointer<Uint8> secret,
      Uint32 secretBytes,
      Uint32 flags,
    );
typedef _BCryptCreate =
    int Function(
      Pointer<Void> algorithm,
      Pointer<Pointer<Void>> hash,
      Pointer<Uint8> object,
      int objectBytes,
      Pointer<Uint8> secret,
      int secretBytes,
      int flags,
    );
typedef _BCryptHashDataNative =
    Int32 Function(Pointer<Void> hash, Pointer<Uint8> input, Uint32 length, Uint32 flags);
typedef _BCryptHashData =
    int Function(Pointer<Void> hash, Pointer<Uint8> input, int length, int flags);
typedef _BCryptFinishNative =
    Int32 Function(Pointer<Void> hash, Pointer<Uint8> output, Uint32 length, Uint32 flags);
typedef _BCryptFinish =
    int Function(Pointer<Void> hash, Pointer<Uint8> output, int length, int flags);
typedef _BCryptDestroyNative = Int32 Function(Pointer<Void> hash);
typedef _BCryptDestroy = int Function(Pointer<Void> hash);
typedef _BCryptCloseNative = Int32 Function(Pointer<Void> algorithm, Uint32 flags);
typedef _BCryptClose = int Function(Pointer<Void> algorithm, int flags);
