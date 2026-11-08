/// Reproducible `tar.gz` writer for the staged native dictation runtime.
///
/// The release staging path publishes one archive per platform, and a pinned
/// archive hash is what the download fallback verifies. That only means
/// something if the archive is a pure function of the library bytes: entry
/// order, file mode, ownership, and timestamps are fixed here, and the gzip
/// header carries a zero mtime with an "unknown" OS byte, so re-archiving the
/// same inputs on the same SDK reproduces the same bytes.
///
/// Cross-platform byte-identity is deliberately not claimed: deflate output is
/// the SDK's zlib, and macOS inputs are signed while Linux/Windows inputs are
/// not. The authority is the hash of the bytes a producer actually wrote.
///
/// The system `tar` cannot be used for this: GNU tar and bsdtar disagree about
/// sort/ownership/mtime flags, and both embed filesystem metadata.
library;

import 'dart:io';
import 'dart:typed_data';

/// Result of writing an archive.
class SttRuntimeArchive {
  const SttRuntimeArchive({
    required this.path,
    required this.sha256,
    required this.size,
    required this.entries,
  });

  final String path;
  final String sha256;
  final int size;

  /// Archive entry names, sorted.
  final List<String> entries;
}

/// Builds a deterministic POSIX `ustar` gzip archive from [entries].
///
/// Entry names are sorted, mode is `0644`, owner and group are `0`, and every
/// entry is stamped with [epochSeconds] (default `0`). Names must stay under
/// the 100-byte ustar name field, which is enforced instead of silently
/// truncating; the runtime layout is far below that.
Uint8List buildDeterministicTarGz(
  Map<String, List<int>> entries, {
  int epochSeconds = 0,
}) {
  if (epochSeconds < 0) {
    throw ArgumentError.value(epochSeconds, 'epochSeconds', 'must be >= 0');
  }
  final names = entries.keys.toList()..sort();
  final builder = BytesBuilder(copy: false);
  for (final name in names) {
    final content = entries[name]!;
    builder.add(_tarHeader(name, content.length, epochSeconds));
    builder.add(content);
    final padding = (_tarBlockSize - content.length % _tarBlockSize) % _tarBlockSize;
    if (padding > 0) builder.add(Uint8List(padding));
  }
  // Two zero blocks terminate a tar archive.
  builder.add(Uint8List(_tarBlockSize * 2));
  return Uint8List.fromList(gzipDeterministic(builder.takeBytes()));
}

/// Gzip-compresses [data] with a fixed header and no filename.
Uint8List gzipDeterministic(List<int> data) {
  final deflated = Uint8List.fromList(
    ZLibCodec(raw: true, level: 9).encoder.convert(data),
  );
  final output = BytesBuilder(copy: false)
    ..add(const [0x1F, 0x8B, 0x08, 0x00])
    // mtime = 0: the archive never records when it was produced.
    ..add(const [0x00, 0x00, 0x00, 0x00])
    // XFL = 0, OS = 255 ("unknown") so the platform that produced it cannot
    // change the bytes.
    ..add(const [0x00, 0xFF])
    ..add(deflated)
    ..add(_uint32Le(_crc32(data)))
    ..add(_uint32Le(data.length & 0xFFFFFFFF));
  return Uint8List.fromList(output.takeBytes());
}

const int _tarBlockSize = 512;
const int _tarModeFile = 0x1A4; // 0644
const int _tarChecksumOffset = 148;
const int _tarChecksumWidth = 8;

Uint8List _tarHeader(String name, int size, int epochSeconds) {
  final encoded = Uint8List.fromList(name.codeUnits);
  if (encoded.length > 100) {
    throw ArgumentError.value(
      name,
      'entries',
      'ustar name field is limited to 100 bytes',
    );
  }
  final header = Uint8List(_tarBlockSize);
  _writeText(header, 0, 100, encoded);
  _writeOctal(header, 100, 8, _tarModeFile);
  _writeOctal(header, 108, 8, 0); // uid
  _writeOctal(header, 116, 8, 0); // gid
  _writeOctal(header, 124, 12, size);
  _writeOctal(header, 136, 12, epochSeconds);
  header[156] = 0x30; // typeflag '0': regular file
  _writeText(header, 257, 6, Uint8List.fromList('ustar'.codeUnits));
  _writeText(header, 263, 2, Uint8List.fromList('00'.codeUnits));
  // The checksum is computed with its own field filled by spaces.
  for (var index = _tarChecksumOffset;
      index < _tarChecksumOffset + _tarChecksumWidth;
      index++) {
    header[index] = 0x20;
  }
  var sum = 0;
  for (final byte in header) {
    sum += byte;
  }
  _writeOctal(header, _tarChecksumOffset, 7, sum);
  header[155] = 0x20;
  return header;
}

void _writeText(Uint8List header, int offset, int width, Uint8List value) {
  for (var index = 0; index < value.length && index < width; index++) {
    header[offset + index] = value[index];
  }
}

void _writeOctal(Uint8List header, int offset, int width, int value) {
  final text = value.toRadixString(8).padLeft(width - 1, '0');
  if (text.length > width - 1) {
    throw ArgumentError.value(value, 'value', 'does not fit in $width octal digits');
  }
  _writeText(
    header,
    offset,
    width - 1,
    Uint8List.fromList(text.codeUnits),
  );
}

Uint8List _uint32Le(int value) {
  final bytes = Uint8List(4);
  bytes.buffer.asByteData().setUint32(0, value & 0xFFFFFFFF, Endian.little);
  return bytes;
}

Uint32List? _crcTableCache;

Uint32List get _crcTable => _crcTableCache ??= _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1;
    }
    table[index] = value;
  }
  return table;
}

int _crc32(List<int> data) {
  final table = _crcTable;
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = table[(crc ^ (byte & 0xFF)) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
