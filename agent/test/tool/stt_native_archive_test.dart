import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../tool/stt_native_archive.dart';

/// The release staging path publishes one archive per platform and pins its
/// sha256, which is only meaningful if identical library bytes always produce
/// identical archive bytes.
void main() {
  final libraries = <String, List<int>>{
    'native/macos-x64/libggml.0.dylib': utf8.encode('ggml payload'),
    'native/macos-x64/libsanad_whisper.dylib': utf8.encode('shim payload'),
    'native/macos-x64/libwhisper.1.dylib': Uint8List(700),
  };

  test('the same entries always produce the same bytes', () {
    final first = buildDeterministicTarGz(libraries);
    final reordered = buildDeterministicTarGz(
      Map.fromEntries(libraries.entries.toList().reversed),
    );
    expect(reordered, first);
    expect(sha256.convert(reordered).toString(), sha256.convert(first).toString());
  });

  test('the gzip header carries no time or platform identity', () {
    final bytes = buildDeterministicTarGz(libraries);
    expect(bytes.sublist(0, 4), [0x1F, 0x8B, 0x08, 0x00]);
    expect(bytes.sublist(4, 8), [0x00, 0x00, 0x00, 0x00]); // mtime
    expect(bytes[8], 0x00); // XFL
    expect(bytes[9], 0xFF); // OS: unknown, so the host cannot change bytes
  });

  test('SOURCE_DATE_EPOCH changes only the recorded mtime', () {
    final zero = buildDeterministicTarGz(libraries);
    final stamped = buildDeterministicTarGz(libraries, epochSeconds: 1700000000);
    expect(stamped, isNot(zero));
    final zeroEntries = _readTar(_gunzip(zero));
    final stampedEntries = _readTar(_gunzip(stamped));
    expect(
      stampedEntries.map((entry) => entry.name),
      zeroEntries.map((entry) => entry.name),
    );
    expect(
      stampedEntries.map((entry) => sha256.convert(entry.content).toString()),
      zeroEntries.map((entry) => sha256.convert(entry.content).toString()),
    );
    expect(stampedEntries.first.mtime, 1700000000);
    expect(zeroEntries.first.mtime, 0);
  });

  test('a member name past 100 bytes uses the ustar prefix field', () {
    // The macOS sherpa library lives four directories deep, and its member name
    // is 113 bytes; without the prefix split the writer would have to truncate
    // the path (refused) and the archive could never ship the engine.
    const long =
        'native/macos-arm64/sherpa/sherpa_onnx_macos/'
        'sherpa-onnx.xcframework/macos-arm64_x86_64/'
        'libsherpa-onnx-c-api.dylib';
    expect(long.length, greaterThan(100));
    final tar = _gunzip(buildDeterministicTarGz({long: [1, 2, 3]}));
    final entries = _readTar(tar);
    expect(entries.single.name, long);
    expect(entries.single.checksumIsValid, isTrue);
    // The split is real, not a single 100-byte field holding a truncated path.
    final header = tar.sublist(0, 512);
    expect(_text(header, 345, 155), isNotEmpty);
  });

  test('a path that cannot be split is refused instead of truncated', () {
    // One slash early in the name leaves a 150-byte tail, which fits neither
    // field; the writer must refuse rather than write a truncated path.
    final name = 'a/${'b' * 150}';
    expect(
      () => buildDeterministicTarGz({name: [1]}),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('entries are sorted, terminated, and checksummed', () {
    final tar = _gunzip(buildDeterministicTarGz(libraries));
    expect(tar.length % 512, 0);
    final entries = _readTar(tar);
    expect(entries.map((entry) => entry.name), [
      'native/macos-x64/libggml.0.dylib',
      'native/macos-x64/libsanad_whisper.dylib',
      'native/macos-x64/libwhisper.1.dylib',
    ]);
    expect(entries[0].content, utf8.encode('ggml payload'));
    expect(entries[1].content, utf8.encode('shim payload'));
    expect(entries[2].content, Uint8List(700));
    for (final entry in entries) {
      expect(entry.mode, '0000644');
      expect(entry.uid, '0000000');
      expect(entry.gid, '0000000');
      expect(entry.typeFlag, '0');
      expect(
        entry.magic,
        [0x75, 0x73, 0x74, 0x61, 0x72, 0x00, 0x30, 0x30], // "ustar\0" + "00"
        reason: entry.name,
      );
      expect(entry.checksumIsValid, isTrue, reason: entry.name);
    }
    // Two zero blocks end the archive.
    expect(tar.sublist(tar.length - 1024), Uint8List(1024));
  });

  test('a name that does not fit the ustar field is refused', () {
    expect(
      () => buildDeterministicTarGz({'a' * 101: const [1]}),
      throwsArgumentError,
    );
  });

  test('a negative timestamp is refused', () {
    expect(
      () => buildDeterministicTarGz(libraries, epochSeconds: -1),
      throwsArgumentError,
    );
  });

  test('the archive size is bounded by its entries', () {
    final bytes = buildDeterministicTarGz(libraries);
    // Three 512-byte headers, two 512-byte content blocks, one 1024-byte
    // content block, plus the terminator: no filesystem metadata is embedded.
    expect(bytes.length, lessThan(4096));
  });
}

Uint8List _gunzip(Uint8List bytes) =>
    Uint8List.fromList(GZipCodec().decode(bytes));

class _TarEntry {
  _TarEntry({
    required this.name,
    required this.mode,
    required this.uid,
    required this.gid,
    required this.mtime,
    required this.typeFlag,
    required this.magic,
    required this.checksumIsValid,
    required this.content,
  });

  final String name;
  final String mode;
  final String uid;
  final String gid;
  final int mtime;
  final String typeFlag;
  final List<int> magic;
  final bool checksumIsValid;
  final List<int> content;
}

List<_TarEntry> _readTar(Uint8List tar) {
  final entries = <_TarEntry>[];
  var offset = 0;
  while (offset + 512 <= tar.length) {
    final header = tar.sublist(offset, offset + 512);
    if (header.every((byte) => byte == 0)) break;
    final size = _octal(header, 124, 12);
    entries.add(
      _TarEntry(
        name: _joinedName(header),
        mode: _text(header, 100, 8),
        uid: _text(header, 108, 8),
        gid: _text(header, 116, 8),
        mtime: _octal(header, 136, 12),
        typeFlag: _text(header, 156, 1),
        magic: header.sublist(257, 265),
        checksumIsValid: _checksumIsValid(header),
        content: tar.sublist(offset + 512, offset + 512 + size),
      ),
    );
    offset += 512 + ((size + 511) ~/ 512) * 512;
  }
  return entries;
}

String _text(List<int> header, int offset, int width) {
  final bytes = header.sublist(offset, offset + width);
  final end = bytes.indexOf(0);
  return String.fromCharCodes(end < 0 ? bytes : bytes.sublist(0, end));
}

/// ustar joins the 155-byte `prefix` field and the 100-byte `name` with `/`.
String _joinedName(List<int> header) {
  final name = _text(header, 0, 100);
  final prefix = _text(header, 345, 155);
  return prefix.isEmpty ? name : '$prefix/$name';
}

int _octal(List<int> header, int offset, int width) =>
    int.parse(_text(header, offset, width).trim(), radix: 8);

bool _checksumIsValid(List<int> header) {
  var sum = 0;
  for (var index = 0; index < header.length; index++) {
    sum += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  return sum == _octal(header, 148, 8);
}
