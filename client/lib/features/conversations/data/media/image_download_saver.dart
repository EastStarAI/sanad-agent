import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:sanad_client/utils/app_platform.dart';
import 'package:universal_io/io.dart';

/// How a saved image reached the user.
enum ImageDownloadOutcome {
  /// Written to the platform Downloads directory (desktop).
  saved,

  /// Handed to the browser as a download (Web); the browser owns the target.
  started,
}

final class ImageDownloadResult {
  const ImageDownloadResult({required this.fileName, required this.outcome});

  /// The final file name, including any clash suffix.
  final String fileName;
  final ImageDownloadOutcome outcome;
}

final class ImageDownloadException implements Exception {
  const ImageDownloadException(this.code);

  final String code;

  @override
  String toString() => 'ImageDownloadException($code)';
}

/// Saves already-loaded image bytes for the user. Implementations never fetch:
/// callers pass the bytes the lightbox already holds.
abstract interface class ImageDownloadSaver {
  Future<ImageDownloadResult> save({required Uint8List bytes, String? preferredName});

  /// The saver for the running platform: Downloads on desktop, a browser
  /// download on Web, and `null` on mobile, where there is no user-visible
  /// Downloads folder and no existing save/share path, so the lightbox hides
  /// its Download control.
  static ImageDownloadSaver? forPlatform() {
    if (AppPlatform.isWeb) return BrowserImageDownloadSaver();
    if (AppPlatform.isDesktop) return DownloadsDirectoryImageSaver();
    return null;
  }
}

/// Desktop saver that writes into the platform Downloads directory only.
final class DownloadsDirectoryImageSaver implements ImageDownloadSaver {
  DownloadsDirectoryImageSaver({
    Future<Directory?> Function()? downloadsDirectory,
    DateTime Function()? clock,
  }) : _downloadsDirectory = downloadsDirectory ?? path_provider.getDownloadsDirectory,
       _clock = clock ?? DateTime.now;

  /// Upper bound of numeric clash suffixes tried before giving up.
  static const int maximumClashSuffix = 999;

  final Future<Directory?> Function() _downloadsDirectory;
  final DateTime Function() _clock;

  @override
  Future<ImageDownloadResult> save({required Uint8List bytes, String? preferredName}) async {
    final directory = await _downloadsDirectory();
    if (directory == null || !await directory.exists()) {
      throw const ImageDownloadException('downloads_unavailable');
    }
    final root = p.normalize(directory.absolute.path);
    final baseName = ImageDownloadFileName.build(bytes: bytes, preferredName: preferredName, now: _clock());
    for (var suffix = 0; suffix <= maximumClashSuffix; suffix++) {
      final name = ImageDownloadFileName.withClashSuffix(baseName, suffix);
      final target = p.join(root, name);
      // The sanitized name has no separators; this guard keeps any future
      // regression from ever writing outside the Downloads directory.
      if (!p.isWithin(root, target) || p.dirname(target) != root) {
        throw const ImageDownloadException('unsafe_target');
      }
      final file = File(target);
      try {
        // Exclusive creation never overwrites, including against a racing writer.
        await file.create(exclusive: true);
      } on FileSystemException {
        if (await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) continue;
        rethrow;
      }
      try {
        await file.writeAsBytes(bytes, flush: true);
      } catch (_) {
        // Remove only the file this call just created.
        try {
          await file.delete();
        } catch (_) {}
        rethrow;
      }
      return ImageDownloadResult(fileName: name, outcome: ImageDownloadOutcome.saved);
    }
    throw const ImageDownloadException('name_exhausted');
  }
}

/// Starts a browser download of [bytes] named [name].
typedef BrowserDownloadTrigger = Future<void> Function(Uint8List bytes, String name, String? mimeType);

/// Web saver: hands the bytes to the browser as a download through
/// `cross_file`'s anchor download (no new network path).
final class BrowserImageDownloadSaver implements ImageDownloadSaver {
  BrowserImageDownloadSaver({
    BrowserDownloadTrigger? trigger,
    DateTime Function()? clock,
  }) : _trigger = trigger ?? _anchorDownload,
       _clock = clock ?? DateTime.now;

  final BrowserDownloadTrigger _trigger;
  final DateTime Function() _clock;

  @override
  Future<ImageDownloadResult> save({required Uint8List bytes, String? preferredName}) async {
    final name = ImageDownloadFileName.build(bytes: bytes, preferredName: preferredName, now: _clock());
    await _trigger(bytes, name, ImageDownloadFileName.mimeTypeFor(bytes));
    return ImageDownloadResult(fileName: name, outcome: ImageDownloadOutcome.started);
  }

  static Future<void> _anchorDownload(Uint8List bytes, String name, String? mimeType) =>
      XFile.fromData(bytes, name: name, mimeType: mimeType).saveTo(name);
}

/// Safe download file naming.
abstract final class ImageDownloadFileName {
  static const int maximumStemLength = 120;

  static final RegExp _unsafeCharacters = RegExp(
    // Path separators, Windows-reserved punctuation, C0/C1 controls, DEL, and
    // bidirectional overrides that could disguise the extension.
    '[/\\\\:*?"<>|\\u0000-\\u001f\\u007f-\\u009f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]',
  );
  static final RegExp _windowsReserved = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$', caseSensitive: false);

  /// Builds the base name: the sanitized [preferredName] when usable, else
  /// `image-<yyyyMMdd-HHmmss>`; the extension follows the real bytes.
  static String build({required Uint8List bytes, required DateTime now, String? preferredName}) {
    final detected = extensionFor(bytes);
    final sanitized = sanitize(preferredName ?? '');
    var stem = sanitized.isEmpty ? '' : p.basenameWithoutExtension(sanitized);
    var extension = sanitized.isEmpty ? '' : p.extension(sanitized).replaceFirst('.', '').toLowerCase();
    if (stem.isEmpty || stem.startsWith('.')) {
      stem = 'image-${_timestamp(now)}';
      extension = '';
    }
    if (_windowsReserved.hasMatch(stem)) stem = '_$stem';
    if (stem.length > maximumStemLength) stem = stem.substring(0, maximumStemLength);
    if (detected != null) {
      final sameFamily = extension == detected || (detected == 'jpg' && extension == 'jpeg');
      if (!sameFamily) extension = detected;
    }
    return extension.isEmpty ? stem : '$stem.$extension';
  }

  /// Strips unsafe characters and leading/trailing dots and spaces.
  static String sanitize(String name) {
    final stripped = name.replaceAll(_unsafeCharacters, '');
    return stripped.replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  }

  /// `name (n).ext` for `n > 0`.
  static String withClashSuffix(String name, int suffix) {
    if (suffix == 0) return name;
    final extension = p.extension(name);
    final stem = extension.isEmpty ? name : name.substring(0, name.length - extension.length);
    return '$stem ($suffix)$extension';
  }

  /// Extension implied by the image magic bytes, or `null` when unknown.
  static String? extensionFor(Uint8List bytes) {
    bool startsWith(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'jpg';
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
    if (startsWith(const [0x42, 0x4D])) return 'bmp';
    return null;
  }

  static String? mimeTypeFor(Uint8List bytes) => switch (extensionFor(bytes)) {
    'png' => 'image/png',
    'jpg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => null,
  };

  static String _timestamp(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
