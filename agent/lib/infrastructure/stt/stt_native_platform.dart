/// Platform, architecture, and on-disk layout of the native dictation runtime.
///
/// The whisper.cpp shim (`libsanad_whisper`) and its ggml siblings are build
/// products of one OS **and** one CPU architecture. Everything that names them
/// therefore lives here, so the daemon loader, `tool/ensure_native_stt.dart`,
/// and the packaging steps cannot disagree:
///
///   * the platform tag (`macos-arm64`, `macos-x64`, `windows-x64`, …) is the
///     same string used as `agent/native/<tag>/`, as the `checksums.json`
///     artifact key, and as the staged runtime directory name;
///   * the architecture comes from [Abi.current], never from a substring of
///     `Platform.version`, because a version string is not an architecture;
///   * macOS Intel is a first-class target: it uses the same dylib family as
///     Apple Silicon but ships the CPU baseline (no Metal library);
///   * the pre-qualification `agent/native/macos/` directory remains readable
///     only for Apple Silicon, where it was the only directory that could ever
///     hold those artifacts.
///
/// This library is deliberately pure Dart with no Flutter import: the agent
/// daemon, the release tools, and the tests all consume it.
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

/// Operating system a native dictation runtime is built for.
enum SttNativeOs { macos, windows, linux }

/// CPU architecture a native dictation runtime is built for.
enum SttNativeCpu { x64, arm64 }

/// One OS + architecture pair the local dictation runtime can be built for.
class SttNativeTarget {
  const SttNativeTarget._(this.os, this.cpu);

  final SttNativeOs os;
  final SttNativeCpu cpu;

  static const SttNativeTarget macosArm64 = SttNativeTarget._(
    SttNativeOs.macos,
    SttNativeCpu.arm64,
  );
  static const SttNativeTarget macosX64 = SttNativeTarget._(
    SttNativeOs.macos,
    SttNativeCpu.x64,
  );
  static const SttNativeTarget windowsX64 = SttNativeTarget._(
    SttNativeOs.windows,
    SttNativeCpu.x64,
  );
  static const SttNativeTarget windowsArm64 = SttNativeTarget._(
    SttNativeOs.windows,
    SttNativeCpu.arm64,
  );
  static const SttNativeTarget linuxX64 = SttNativeTarget._(
    SttNativeOs.linux,
    SttNativeCpu.x64,
  );
  static const SttNativeTarget linuxArm64 = SttNativeTarget._(
    SttNativeOs.linux,
    SttNativeCpu.arm64,
  );

  /// Every target the runtime is buildable for.
  static const List<SttNativeTarget> values = [
    macosArm64,
    macosX64,
    windowsX64,
    windowsArm64,
    linuxX64,
    linuxArm64,
  ];

  /// The target for [abi], or null when the runtime does not exist for it.
  static SttNativeTarget? tryFromAbi(Abi abi) {
    // Identity comparison is the documented way to read `Abi.current()`.
    if (abi == Abi.macosArm64) return macosArm64;
    if (abi == Abi.macosX64) return macosX64;
    if (abi == Abi.windowsX64) return windowsX64;
    if (abi == Abi.windowsArm64) return windowsArm64;
    if (abi == Abi.linuxX64) return linuxX64;
    if (abi == Abi.linuxArm64) return linuxArm64;
    return null;
  }

  /// [tryFromAbi] for the running process, or null when it is unsupported.
  ///
  /// A build that reports an ABI this class cannot map (an exotic target, or a
  /// stubbed `dart:ffi` in a test harness) yields null instead of throwing, so
  /// readiness can report "unsupported" rather than fail the daemon.
  static SttNativeTarget? tryCurrent() {
    try {
      return tryFromAbi(Abi.current());
    } on Object {
      return null;
    }
  }

  /// [tryFromAbi] for the running process, throwing when unsupported.
  static SttNativeTarget fromAbi(Abi abi) {
    final target = tryFromAbi(abi);
    if (target == null) {
      throw UnsupportedError(
        'no native dictation runtime target for $abi',
      );
    }
    return target;
  }

  String get osName => switch (os) {
    SttNativeOs.macos => 'macos',
    SttNativeOs.windows => 'windows',
    SttNativeOs.linux => 'linux',
  };

  String get cpuName => switch (cpu) {
    SttNativeCpu.x64 => 'x64',
    SttNativeCpu.arm64 => 'arm64',
  };

  /// Canonical tag: `macos-x64`, `macos-arm64`, `windows-x64`, …
  ///
  /// One string names the platform everywhere: the native directory, the
  /// `checksums.json` artifact key, and the staged release directory.
  String get tag => '$osName-$cpuName';

  /// Directory name under `agent/native/` that holds this target's runtime.
  String get nativeDirectory => tag;

  /// Read-only compatibility directory used before directories were
  /// architecture-qualified.
  ///
  /// Only Apple Silicon may use it: `agent/native/macos/` was populated by
  /// arm64 builds exclusively, so accepting it cannot select a foreign slice.
  /// Linux and Windows had no such guarantee, and their unqualified directory
  /// could hold either architecture.
  String? get legacyNativeDirectory {
    if (os == SttNativeOs.macos && cpu == SttNativeCpu.arm64) return 'macos';
    return null;
  }

  /// Probe order for this target: canonical directory first, then the bounded
  /// legacy alias.
  List<String> get nativeDirectoryNames => [
    nativeDirectory,
    ?legacyNativeDirectory,
  ];

  /// File name of the shim the daemon opens through `dart:ffi`.
  String get shimFileName => switch (os) {
    SttNativeOs.macos => 'libsanad_whisper.dylib',
    SttNativeOs.windows => 'sanad_whisper.dll',
    SttNativeOs.linux => 'libsanad_whisper.so',
  };

  /// True when the runtime exists for this target at all.
  ///
  /// The local engine is CPU-baseline everywhere; Apple Silicon additionally
  /// builds the Metal backend. Intel macOS is therefore supported, but without
  /// a GPU backend.
  bool get dictationSupported => true;

  /// Metal is an Apple Silicon build product; every other target is CPU-only.
  bool get usesMetal => os == SttNativeOs.macos && cpu == SttNativeCpu.arm64;

  /// Libraries the daemon needs beside the shim, in manifest order.
  List<String> get requiredLibraries => switch (os) {
    SttNativeOs.macos => usesMetal
        ? _macosMetalLibraries
        : _macosLibraries,
    SttNativeOs.windows => _windowsLibraries,
    SttNativeOs.linux => _linuxLibraries,
  };

  /// Directory name under `native/<tag>/` that holds the sherpa-onnx runtime.
  ///
  /// It is a separate subdirectory because `package:sherpa_onnx` is given a
  /// directory and appends its own per-platform relative path to it (see
  /// [sherpaLibraries]); keeping the whisper shim flat beside it means the
  /// whisper loader is untouched.
  String get sherpaNativeSubdirectory => 'sherpa';

  /// Files `package:sherpa_onnx` opens inside [sherpaNativeSubdirectory],
  /// relative to that directory, in the order the loader probes them.
  ///
  /// These are the exact strings `loadDylib()` in sherpa_onnx 2.0.1 appends to
  /// the directory it is handed, so the packaged layout and the loader cannot
  /// disagree. The macOS entry is the xcframework path the library hard-codes.
  List<String> get sherpaLibraries => switch (os) {
    SttNativeOs.macos => const [
      'sherpa_onnx_macos/sherpa-onnx.xcframework/macos-arm64_x86_64/'
          'libsherpa-onnx-c-api.dylib',
    ],
    SttNativeOs.windows => const [
      'sherpa-onnx-c-api.dll',
      'onnxruntime.dll',
    ],
    SttNativeOs.linux => const [
      'libsherpa-onnx-c-api.so',
      'libonnxruntime.so',
    ],
  };

  /// CMake architecture for a macOS build, or null when the platform does not
  /// take one (Linux and Windows build for the host toolchain).
  String? get cmakeArchitecture => os == SttNativeOs.macos
      ? (cpu == SttNativeCpu.x64 ? 'x86_64' : 'arm64')
      : null;

  /// Minimum macOS version the runtime is built for.
  ///
  /// Matches the shipped Client's own floor (`client/macos/Podfile`), so the
  /// dylibs load on every macOS the Intel and Apple Silicon Client can run on
  /// instead of inheriting the newer build runner's SDK default.
  String? get macosDeploymentTarget =>
      os == SttNativeOs.macos ? macosMinimumDeploymentTarget : null;

  /// Version recorded by [macosDeploymentTarget]; also the value the build
  /// scripts receive when they are invoked from the tool.
  static const String macosMinimumDeploymentTarget = '12.0';

  @override
  String toString() => 'SttNativeTarget($tag)';
}

/// Apple Silicon dylibs: Metal backend included, unchanged from the original
/// Apple Silicon delivery.
const List<String> _macosLibraries = [
  'libsanad_whisper.dylib',
  'libwhisper.1.dylib',
  'libggml.0.dylib',
  'libggml-base.0.dylib',
  'libggml-cpu.0.dylib',
  'libggml-blas.0.dylib',
];

/// Apple Silicon with the Metal backend library.
const List<String> _macosMetalLibraries = [
  ..._macosLibraries,
  'libggml-metal.0.dylib',
];

const List<String> _windowsLibraries = [
  'sanad_whisper.dll',
  'whisper.dll',
  'ggml.dll',
  'ggml-base.dll',
  'ggml-cpu.dll',
];

const List<String> _linuxLibraries = [
  'libsanad_whisper.so',
  'libwhisper.so.1',
  'libggml.so.0',
  'libggml-base.so.0',
  'libggml-cpu.so.0',
];

/// Name of the marker `tool/ensure_native_stt.dart` writes while it builds or
/// downloads, so readiness can report "preparing" instead of "missing".
const String sttPreparingMarkerName = '.stt-preparing';

/// Absolute candidate paths for the shim, in probe order.
///
/// The packaged layout puts `native/<tag>/` beside the executable; a source
/// checkout keeps it under `agent/native/<tag>/`. For every location the
/// canonical architecture-qualified directory is probed before the bounded
/// Apple Silicon legacy alias.
List<String> nativeLibraryCandidates({
  required SttNativeTarget target,
  required String executableDirectory,
  required String workingDirectory,
  String? overridePath,
}) {
  final override = overridePath?.trim() ?? '';
  if (override.isNotEmpty) return [override];
  final locations = <String>{
    executableDirectory,
    '$executableDirectory/..',
    workingDirectory,
    '$workingDirectory/agent',
  };
  return [
    for (final location in locations)
      for (final directory in target.nativeDirectoryNames)
        '$location/native/$directory/${target.shimFileName}',
  ];
}

/// Candidate locations of the "preparing" marker, in probe order.
///
/// The marker lives in the native root (`native/.stt-preparing`) because the
/// tool writes it before the architecture directory exists. The per-directory
/// form stays in the list so a checkout that already has a marker there keeps
/// reporting "preparing".
List<String> preparingMarkerCandidates({
  required SttNativeTarget target,
  required String executableDirectory,
  required String workingDirectory,
}) {
  final roots = <String>{
    '$executableDirectory/native',
    '$executableDirectory/../native',
    '$workingDirectory/native',
    '$workingDirectory/agent/native',
  };
  return [
    for (final root in roots) '$root/$sttPreparingMarkerName',
    for (final root in roots)
      for (final directory in target.nativeDirectoryNames)
        '$root/$directory/$sttPreparingMarkerName',
  ];
}

/// Executable format of a native library.
enum SttNativeBinaryFormat { machO, elf, pe, unknown }

/// What a native library file says about itself.
class SttNativeBinaryInfo {
  const SttNativeBinaryInfo({
    required this.format,
    this.cpus = const {},
    this.minimumMacOsVersion,
  });

  final SttNativeBinaryFormat format;

  /// Architectures present in the file (both slices for a universal binary).
  final Set<SttNativeCpu> cpus;

  /// Minimum macOS version, when the file records one.
  final String? minimumMacOsVersion;

  bool supports(SttNativeCpu cpu) => cpus.contains(cpu);

  bool get isRecognized => format != SttNativeBinaryFormat.unknown;

  @override
  String toString() =>
      'SttNativeBinaryInfo(${format.name}, '
      '${cpus.map((cpu) => cpu.name).join('+')}, '
      'minMacOS=$minimumMacOsVersion)';
}

/// Reads up to [maxBytes] of [path] and reports its format and architectures.
///
/// A missing or unreadable file is reported as [SttNativeBinaryFormat.unknown]
/// rather than thrown, because readiness probes run on every status request.
SttNativeBinaryInfo inspectNativeLibraryFile(String path, {int maxBytes = 65536}) {
  final file = File(path);
  if (!file.existsSync()) {
    return const SttNativeBinaryInfo(format: SttNativeBinaryFormat.unknown);
  }
  final RandomAccessFile handle;
  try {
    handle = file.openSync();
  } on FileSystemException {
    return const SttNativeBinaryInfo(format: SttNativeBinaryFormat.unknown);
  }
  try {
    final length = handle.lengthSync();
    final read = length < maxBytes ? length : maxBytes;
    if (read <= 0) {
      return const SttNativeBinaryInfo(format: SttNativeBinaryFormat.unknown);
    }
    return inspectNativeBinary(handle.readSync(read));
  } on FileSystemException {
    return const SttNativeBinaryInfo(format: SttNativeBinaryFormat.unknown);
  } finally {
    handle.closeSync();
  }
}

/// True when [path] is a recognizable native library built for [target].
///
/// The default read window covers a Mach-O header plus its universal-slice
/// table, which is all the architecture question needs.
bool nativeLibraryMatchesTarget(
  String path,
  SttNativeTarget target, {
  int maxBytes = 4096,
}) {
  final info = inspectNativeLibraryFile(path, maxBytes: maxBytes);
  return info.isRecognized && info.supports(target.cpu);
}

/// Parses the header of a Mach-O, ELF, or PE library.
SttNativeBinaryInfo inspectNativeBinary(Uint8List bytes) {
  return _inspectMachO(bytes) ??
      _inspectElf(bytes) ??
      _inspectPe(bytes) ??
      const SttNativeBinaryInfo(format: SttNativeBinaryFormat.unknown);
}

const int _machOMagic32 = 0xFEEDFACE;
const int _machOMagic64 = 0xFEEDFACF;
const int _machoCpuTypeX86_64 = 0x01000007;
const int _machoCpuTypeArm64 = 0x0100000C;
const int _lcVersionMinMacOsX = 0x24;
const int _lcBuildVersion = 0x32;
const int _platformMacOs = 1;

SttNativeBinaryInfo? _inspectMachO(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final magic = _readUint32Le(bytes, 0);
  if (magic == _machOMagic64 || magic == _machOMagic32) {
    final cpu = _machOCpu(_readUint32Le(bytes, 4));
    return SttNativeBinaryInfo(
      format: SttNativeBinaryFormat.machO,
      cpus: {?cpu},
      // Only a thin 64-bit image can be walked for a deployment target here;
      // universal binaries would need the slice table and are reported as
      // architectures only.
      minimumMacOsVersion: magic == _machOMagic64
          ? _thinMacOsMinimum(bytes)
          : null,
    );
  }
  // Universal (big-endian) header: 0xCAFEBABE, or 0xCAFEBABF for 64-bit
  // slice offsets. The slice table is enough to know the architectures.
  if (bytes[0] == 0xCA &&
      bytes[1] == 0xFE &&
      bytes[2] == 0xBA &&
      (bytes[3] == 0xBE || bytes[3] == 0xBF)) {
    final entrySize = bytes[3] == 0xBF ? 32 : 20;
    final count = _readUint32Be(bytes, 4);
    final cpus = <SttNativeCpu>{};
    for (var index = 0; index < count; index++) {
      final offset = 8 + index * entrySize;
      if (offset + 4 > bytes.length) break;
      final cpu = _machOCpu(_readUint32Be(bytes, offset));
      if (cpu != null) cpus.add(cpu);
    }
    return SttNativeBinaryInfo(
      format: SttNativeBinaryFormat.machO,
      cpus: cpus,
    );
  }
  return null;
}

SttNativeCpu? _machOCpu(int cpuType) {
  if (cpuType == _machoCpuTypeX86_64) return SttNativeCpu.x64;
  if (cpuType == _machoCpuTypeArm64) return SttNativeCpu.arm64;
  return null;
}

/// Walks the load commands of a thin 64-bit Mach-O for its macOS minimum.
///
/// Returns null when the window is too small to finish the walk, so a truncated
/// read is never mistaken for "no deployment target".
String? _thinMacOsMinimum(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final commandCount = _readUint32Le(bytes, 16);
  var offset = 32;
  for (var index = 0; index < commandCount; index++) {
    if (offset + 8 > bytes.length) return null;
    final command = _readUint32Le(bytes, offset);
    final size = _readUint32Le(bytes, offset + 4);
    if (size < 8) return null;
    if (command == _lcBuildVersion && offset + 16 <= bytes.length) {
      if (_readUint32Le(bytes, offset + 8) == _platformMacOs) {
        return _formatPackedVersion(_readUint32Le(bytes, offset + 12));
      }
    }
    if (command == _lcVersionMinMacOsX && offset + 12 <= bytes.length) {
      return _formatPackedVersion(_readUint32Le(bytes, offset + 8));
    }
    offset += size;
  }
  return null;
}

SttNativeBinaryInfo? _inspectElf(Uint8List bytes) {
  if (bytes.length < 20) return null;
  if (bytes[0] != 0x7F ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4C ||
      bytes[3] != 0x46) {
    return null;
  }
  final littleEndian = bytes[5] != 2;
  final machine = littleEndian
      ? _readUint16Le(bytes, 18)
      : _readUint16Be(bytes, 18);
  final cpu = switch (machine) {
    0x3E => SttNativeCpu.x64,
    0xB7 => SttNativeCpu.arm64,
    _ => null,
  };
  return SttNativeBinaryInfo(
    format: SttNativeBinaryFormat.elf,
    cpus: {?cpu},
  );
}

SttNativeBinaryInfo? _inspectPe(Uint8List bytes) {
  if (bytes.length < 0x40) return null;
  if (bytes[0] != 0x4D || bytes[1] != 0x5A) return null;
  final headerOffset = _readUint32Le(bytes, 0x3C);
  if (headerOffset + 6 > bytes.length) return null;
  if (bytes[headerOffset] != 0x50 || bytes[headerOffset + 1] != 0x45) {
    return null;
  }
  final machine = _readUint16Le(bytes, headerOffset + 4);
  final cpu = switch (machine) {
    0x8664 => SttNativeCpu.x64,
    0xAA64 => SttNativeCpu.arm64,
    _ => null,
  };
  return SttNativeBinaryInfo(
    format: SttNativeBinaryFormat.pe,
    cpus: {?cpu},
  );
}

String _formatPackedVersion(int value) {
  final major = (value >> 16) & 0xFFFF;
  final minor = (value >> 8) & 0xFF;
  final patch = value & 0xFF;
  return patch == 0 ? '$major.$minor' : '$major.$minor.$patch';
}

int _readUint32Le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _readUint32Be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readUint16Le(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _readUint16Be(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];
