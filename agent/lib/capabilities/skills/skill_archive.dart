import 'dart:io';

/// Raised when an archive is malformed or contains an unsafe entry.
class SkillArchiveException implements Exception {
  SkillArchiveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One file extracted from a skill payload.
class SkillArchiveEntry {
  const SkillArchiveEntry({
    required this.path,
    required this.bytes,
    this.mode = 0x1A4,
  });

  final String path;
  final List<int> bytes;

  /// POSIX permission bits. Defaults to 0644.
  final int mode;

  bool get isExecutable => mode & 0x49 != 0;
}

/// Minimal, strict reader for `.tar.gz` payloads.
///
/// Deliberately supports only what a source archive needs: regular files and
/// directories, plus GNU long names. Links, devices, and unsafe paths fail
/// closed so a hostile archive can never write outside the install directory.
class SkillArchive {
  static const int maxEntries = 5000;

  static Map<String, SkillArchiveEntry> decode(
    List<int> gzipped, {
    int maxExtractedBytes = 20 * 1024 * 1024,
  }) {
    final List<int> tar;
    try {
      tar = gzip.decode(gzipped);
    } on FormatException {
      throw SkillArchiveException('The downloaded payload is not gzip data.');
    }

    final entries = <String, SkillArchiveEntry>{};
    var offset = 0;
    var totalBytes = 0;
    String? pendingLongName;

    while (offset + 512 <= tar.length) {
      final header = tar.sublist(offset, offset + 512);
      if (_isZeroBlock(header)) break;
      offset += 512;

      final typeFlag = header[156];
      final size = _parseOctal(header, 124, 12);
      if (size < 0) {
        throw SkillArchiveException('Archive entry has an invalid size field.');
      }
      final contentEnd = offset + size;
      if (contentEnd > tar.length) {
        throw SkillArchiveException('Archive entry is truncated.');
      }

      if (typeFlag == 0x4C) {
        pendingLongName = String.fromCharCodes(
          tar.sublist(offset, contentEnd),
        ).replaceAll('\x00', '');
        offset = contentEnd + _padding(size);
        continue;
      }

      if (typeFlag == 0x78 || typeFlag == 0x67 || typeFlag == 0x4B) {
        // pax headers and GNU sparse metadata carry no installable content.
        offset = contentEnd + _padding(size);
        continue;
      }

      final rawName = pendingLongName ?? _headerName(header);
      pendingLongName = null;
      final name = _safePath(rawName);

      switch (typeFlag) {
        case 0x32:
        case 0x31:
          throw SkillArchiveException(
            'Archive entry "$name" is a link; links are not allowed in skills.',
          );
        case 0x33:
        case 0x34:
        case 0x36:
          throw SkillArchiveException(
            'Archive entry "$name" is a device or fifo; not allowed in skills.',
          );
      }

      if (size > 0 && typeFlag != 0x35) {
        totalBytes += size;
        if (totalBytes > maxExtractedBytes) {
          throw SkillArchiveException(
            'Archive expands beyond ${maxExtractedBytes ~/ (1024 * 1024)} MB.',
          );
        }
        if (entries.length >= maxEntries) {
          throw SkillArchiveException('Archive contains too many entries.');
        }
        entries[name] = SkillArchiveEntry(
          path: name,
          bytes: tar.sublist(offset, contentEnd),
          mode: _parseMode(header),
        );
      }

      offset = contentEnd + _padding(size);
    }

    if (entries.isEmpty) {
      throw SkillArchiveException('The archive contains no files.');
    }
    return entries;
  }

  /// Validates an archive or on-disk relative path and returns its normalized
  /// form. Throws for absolute paths, drive letters, and `..` segments.
  static String _safePath(String raw) {
    var value = raw.replaceAll('\\', '/');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw SkillArchiveException('Archive entry "$raw" is an absolute path.');
    }
    final segments = value.split('/');
    if (segments.contains('..')) {
      throw SkillArchiveException(
        'Archive entry "$raw" escapes the install directory.',
      );
    }
    final normalized = segments
        .where((segment) => segment.isNotEmpty && segment != '.')
        .join('/');
    if (normalized.isEmpty) {
      throw SkillArchiveException('Archive entry "$raw" has an empty path.');
    }
    return normalized;
  }

  /// Exposed for callers that validate on-disk names before installing.
  static String? safeRelativePath(String raw) {
    try {
      return _safePath(raw);
    } on SkillArchiveException {
      return null;
    }
  }

  static int _padding(int size) => (512 - (size % 512)) % 512;

  static bool _isZeroBlock(List<int> block) => block.every((byte) => byte == 0);

  static String _headerName(List<int> header) {
    final name = _readString(header, 0, 100);
    final prefix = _readString(header, 345, 155);
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  static String _readString(List<int> header, int start, int length) {
    final end = (start + length).clamp(0, header.length);
    final slice = header.sublist(start, end);
    final zeroIndex = slice.indexOf(0);
    final bytes = zeroIndex >= 0 ? slice.sublist(0, zeroIndex) : slice;
    return String.fromCharCodes(bytes).trim();
  }

  static int _parseOctal(List<int> header, int start, int length) {
    final value = _readString(header, start, length).trim();
    if (value.isEmpty) return 0;
    if (value.startsWith('0x') || value.startsWith('0X')) {
      return int.tryParse(value.substring(2), radix: 16) ?? -1;
    }
    return int.tryParse(value, radix: 8) ?? -1;
  }

  static int _parseMode(List<int> header) {
    final mode = _parseOctal(header, 100, 8);
    if (mode <= 0) return 0x1A4;
    return mode & 0x1FF;
  }
}
