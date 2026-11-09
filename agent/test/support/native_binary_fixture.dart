import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';

/// Synthetic native binaries for tests that must not build whisper.cpp and must
/// not depend on the host CPU.
///
/// Only the headers are real: `inspectNativeBinary` reads the Mach-O, ELF, or PE
/// magic and the machine field, so a few dozen correct bytes are enough to prove
/// the architecture and deployment-target rules. Everything a test needs to
/// "load" is deliberately absent.

int _cpuType(SttNativeCpu cpu) => switch (cpu) {
  SttNativeCpu.x64 => 0x01000007,
  SttNativeCpu.arm64 => 0x0100000C,
};

int _packedVersion(String version) {
  final parts = version.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final major = parts.isNotEmpty ? parts[0] : 0;
  final minor = parts.length > 1 ? parts[1] : 0;
  final patch = parts.length > 2 ? parts[2] : 0;
  return (major << 16) | (minor << 8) | patch;
}

/// A thin 64-bit Mach-O header, optionally carrying `LC_BUILD_VERSION`.
Uint8List machOThin({required SttNativeCpu cpu, String? minimumMacOs}) {
  final commandBytes = minimumMacOs == null ? 0 : 24;
  final bytes = Uint8List(32 + commandBytes);
  final data = bytes.buffer.asByteData();
  data.setUint32(0, 0xFEEDFACF, Endian.little); // MH_MAGIC_64
  data.setUint32(4, _cpuType(cpu), Endian.little);
  data.setUint32(8, 0, Endian.little); // cpusubtype
  data.setUint32(12, 6, Endian.little); // MH_DYLIB
  data.setUint32(16, commandBytes == 0 ? 0 : 1, Endian.little); // ncmds
  data.setUint32(20, commandBytes, Endian.little); // sizeofcmds
  data.setUint32(24, 0, Endian.little); // flags
  data.setUint32(28, 0, Endian.little); // reserved
  final minimum = minimumMacOs;
  if (minimum != null) {
    data.setUint32(32, 0x32, Endian.little); // LC_BUILD_VERSION
    data.setUint32(36, 24, Endian.little);
    data.setUint32(40, 1, Endian.little); // platform macOS
    data.setUint32(44, _packedVersion(minimum), Endian.little); // minos
    data.setUint32(48, _packedVersion(minimum), Endian.little); // sdk
    data.setUint32(52, 0, Endian.little); // ntools
  }
  return bytes;
}

/// A universal Mach-O header with one slice entry per CPU.
Uint8List machOFat(List<SttNativeCpu> cpus) {
  final bytes = Uint8List(8 + 20 * cpus.length);
  final data = bytes.buffer.asByteData();
  data.setUint32(0, 0xCAFEBABE, Endian.big);
  data.setUint32(4, cpus.length, Endian.big);
  for (var index = 0; index < cpus.length; index++) {
    final offset = 8 + index * 20;
    data.setUint32(offset, _cpuType(cpus[index]), Endian.big);
    data.setUint32(offset + 4, 0, Endian.big); // cpusubtype
    data.setUint32(offset + 8, 0, Endian.big); // offset
    data.setUint32(offset + 12, 0, Endian.big); // size
    data.setUint32(offset + 16, 0, Endian.big); // align
  }
  return bytes;
}

/// A little-endian 64-bit ELF header for [cpu].
Uint8List elfBinary(SttNativeCpu cpu) {
  final bytes = Uint8List(64);
  bytes
    ..[0] = 0x7F
    ..[1] = 0x45
    ..[2] = 0x4C
    ..[3] = 0x46
    ..[4] = 2 // 64-bit
    ..[5] = 1 // little endian
    ..[6] = 1; // current version
  bytes.buffer.asByteData().setUint16(
    18,
    cpu == SttNativeCpu.x64 ? 0x3E : 0xB7,
    Endian.little,
  );
  return bytes;
}

/// A 64-bit ELF library that records [runPaths] as `DT_RUNPATH`.
///
/// The section table is real: the relocatability rule walks `.dynamic` through
/// its `sh_link` to the string table, so a header-only fixture cannot prove it.
/// Passing no [runPaths] writes a `.dynamic` section with only `DT_NULL`, which
/// is the shape a cmake build produces when no install rpath is configured.
Uint8List elfLibrary(SttNativeCpu cpu, {List<String>? runPaths}) {
  const headerSize = 64;
  const sectionHeaderSize = 64;
  const dynamicEntrySize = 16;
  final dynamicOffset = headerSize;
  final dynamicCount = runPaths == null ? 1 : 2;
  final dynamicSize = dynamicEntrySize * dynamicCount;
  final stringTableOffset = dynamicOffset + dynamicSize;
  final stringTable = utf8.encode('\u0000${runPaths?.join(':') ?? ''}\u0000');
  final sectionOffset = stringTableOffset + stringTable.length + 7 & ~7;
  final bytes = Uint8List(sectionOffset + sectionHeaderSize * 3);
  final data = bytes.buffer.asByteData();

  bytes
    ..[0] = 0x7F
    ..[1] = 0x45
    ..[2] = 0x4C
    ..[3] = 0x46
    ..[4] = 2 // 64-bit
    ..[5] = 1 // little endian
    ..[6] = 1; // current version
  data.setUint16(16, 3, Endian.little); // e_type: ET_DYN
  data.setUint16(18, cpu == SttNativeCpu.x64 ? 0x3E : 0xB7, Endian.little);
  data.setUint32(20, 1, Endian.little); // e_version
  data.setUint64(40, sectionOffset, Endian.little); // e_shoff
  data.setUint16(52, headerSize, Endian.little); // e_ehsize
  data.setUint16(58, sectionHeaderSize, Endian.little); // e_shentsize
  data.setUint16(60, 3, Endian.little); // e_shnum

  if (runPaths != null) {
    // DT_RUNPATH points one byte into the string table, past its leading NUL.
    data.setUint64(dynamicOffset, 29, Endian.little);
    data.setUint64(dynamicOffset + 8, 1, Endian.little);
  }
  bytes.setRange(
    stringTableOffset,
    stringTableOffset + stringTable.length,
    stringTable,
  );

  // Section 1: SHT_DYNAMIC, linked to section 2 through sh_link.
  final dynamicHeader = sectionOffset + sectionHeaderSize;
  data.setUint32(dynamicHeader + 4, 6, Endian.little);
  data.setUint64(dynamicHeader + 0x18, dynamicOffset, Endian.little);
  data.setUint64(dynamicHeader + 0x20, dynamicSize, Endian.little);
  data.setUint32(dynamicHeader + 0x28, 2, Endian.little);
  data.setUint64(dynamicHeader + 0x30, 8, Endian.little);
  data.setUint64(dynamicHeader + 0x38, dynamicEntrySize, Endian.little);

  // Section 2: SHT_STRTAB holding the search path.
  final stringHeader = sectionOffset + sectionHeaderSize * 2;
  data.setUint32(stringHeader + 4, 3, Endian.little);
  data.setUint64(stringHeader + 0x18, stringTableOffset, Endian.little);
  data.setUint64(stringHeader + 0x20, stringTable.length, Endian.little);
  data.setUint64(stringHeader + 0x30, 1, Endian.little);

  return bytes;
}

/// A PE header for [cpu].
Uint8List peBinary(SttNativeCpu cpu) {
  final bytes = Uint8List(0x100);
  bytes
    ..[0] = 0x4D
    ..[1] = 0x5A;
  final data = bytes.buffer.asByteData();
  data.setUint32(0x3C, 0x80, Endian.little);
  bytes
    ..[0x80] = 0x50
    ..[0x81] = 0x45
    ..[0x82] = 0x00
    ..[0x83] = 0x00;
  data.setUint16(0x84, cpu == SttNativeCpu.x64 ? 0x8664 : 0xAA64, Endian.little);
  return bytes;
}

/// The right container format for [os] holding [cpu].
Uint8List nativeBinaryFor(
  SttNativeOs os,
  SttNativeCpu cpu, {
  String minimumMacOs = '12.0',
}) {
  return switch (os) {
    SttNativeOs.macos => machOThin(cpu: cpu, minimumMacOs: minimumMacOs),
    // A packaged Linux library carries the `$ORIGIN` search path the build now
    // records, so the fixture matches what the builder produces.
    SttNativeOs.linux => elfLibrary(cpu, runPaths: const [elfOriginRunPath]),
    SttNativeOs.windows => peBinary(cpu),
  };
}

/// FILE bytes that inspect as [target]'s architecture.
///
/// The file name is appended so every library in a fake runtime has distinct
/// bytes and therefore a distinct sha256.
Uint8List fakeLibraryBytes({
  required SttNativeTarget target,
  required String fileName,
  String minimumMacOs = '12.0',
}) {
  final header = nativeBinaryFor(
    target.os,
    target.cpu,
    minimumMacOs: minimumMacOs,
  );
  final trailer = utf8.encode('/$fileName');
  return Uint8List.fromList([...header, ...trailer]);
}

/// Writes a complete fake runtime for [target] into [directory].
///
/// Returns the sha256 of each written file, keyed by file name.
Map<String, String> writeFakeRuntime({
  required Directory directory,
  required SttNativeTarget target,
  String minimumMacOs = '12.0',
}) {
  directory.createSync(recursive: true);
  final hashes = <String, String>{};
  for (final name in target.requiredLibraries) {
    final bytes = fakeLibraryBytes(
      target: target,
      fileName: name,
      minimumMacOs: minimumMacOs,
    );
    File('${directory.path}/$name').writeAsBytesSync(bytes);
    hashes[name] = sha256.convert(bytes).toString();
  }
  return hashes;
}

/// Writes the sherpa-onnx libraries into [directory] with their loader-relative
/// paths, returning their manifest keys and hashes.
///
/// The packaged layout puts them under `sherpa/` because `package:sherpa_onnx` is
/// handed a directory and appends its own per-platform relative path; the keys
/// therefore start with `sherpa/`.
Map<String, String> writeFakeSherpaRuntime({
  required Directory directory,
  required SttNativeTarget target,
}) {
  final hashes = <String, String>{};
  for (final relative in target.sherpaLibraries) {
    final bytes = fakeLibraryBytes(
      target: target,
      fileName: relative.split('/').last,
    );
    final file = File('${directory.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    hashes['${target.sherpaNativeSubdirectory}/$relative'] =
        sha256.convert(bytes).toString();
  }
  return hashes;
}

