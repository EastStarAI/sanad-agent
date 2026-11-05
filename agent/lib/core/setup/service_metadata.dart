import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The outcome of reading `<home>/service.json`.
class ServiceMetadataRead {
  const ServiceMetadataRead.missing() : payload = null, error = null;
  const ServiceMetadataRead.found(this.payload) : error = null;
  const ServiceMetadataRead.unreadable(this.error) : payload = null;

  /// The decoded metadata, or null when there is nothing usable to read.
  final Map<String, Object?>? payload;

  /// An actionable message for a file that exists but this process may not
  /// read.
  final String? error;
}

/// The non-secret `<home>/service.json` ownership metadata that `service
/// install` writes and every other service command reads back.
///
/// It records the scope, the definition path, and the account an installation
/// registered, so `uninstall` removes only the definition this Home installed.
/// The file lives in the Sanad Home because the account the unit runs as is one
/// of its readers: that account runs `service status` on the Home it serves.
class ServiceMetadataStore {
  const ServiceMetadataStore({Future<String> Function(File file)? reader})
    : _reader = reader ?? _read;

  static Future<String> _read(File file) => file.readAsString();

  /// The metadata file of [home].
  static String pathIn(String home) => p.join(home, 'service.json');

  final Future<String> Function(File file) _reader;

  /// Replaces the metadata for [home] with [payload].
  ///
  /// The content is staged next to the target and renamed, and a symlinked
  /// target is refused, so no service ever inherits metadata this Home did not
  /// write. A failed write leaves nothing behind: a stray temporary file would
  /// belong to the installing account inside a Home the unit's account owns.
  Future<void> write({
    required String home,
    required Map<String, Object?> payload,
  }) async {
    final file = File(pathIn(home));
    await file.parent.create(recursive: true);
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Refusing symlinked service ownership metadata.');
    }
    final temporary = File('${file.path}.tmp-$pid');
    try {
      final sink = temporary.openWrite(mode: FileMode.writeOnly);
      sink.write(jsonEncode(payload));
      await sink.flush();
      await sink.close();
      await temporary.rename(file.path);
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
  }

  /// Reads the metadata for [home].
  ///
  /// A file this process may not read is reported as such and never folded into
  /// "not installed": the account a system unit runs as owns the Home, so a
  /// permission denial means the wrong account wrote this file, not that the
  /// service is absent.
  Future<ServiceMetadataRead> read(String home) async {
    final file = File(pathIn(home));
    if (!file.existsSync()) return const ServiceMetadataRead.missing();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return const ServiceMetadataRead.missing();
    }
    final String content;
    try {
      content = await _reader(file);
    } on FileSystemException catch (error) {
      if (!_isPermissionDenial(error)) {
        return const ServiceMetadataRead.missing();
      }
      return ServiceMetadataRead.unreadable(
        'Cannot read the Sanad service metadata "${file.path}": permission '
        'denied. Run this command with sudo, or as the account the service '
        'runs as.',
      );
    } catch (_) {
      return const ServiceMetadataRead.missing();
    }
    try {
      final decoded = jsonDecode(content);
      return decoded is Map<String, Object?>
          ? ServiceMetadataRead.found(decoded)
          : const ServiceMetadataRead.missing();
    } catch (_) {
      return const ServiceMetadataRead.missing();
    }
  }

  /// Removes the metadata for [home] when it exists.
  Future<void> remove(String home) async {
    final file = File(pathIn(home));
    if (file.existsSync()) await file.delete();
  }

  static bool _isPermissionDenial(FileSystemException error) {
    switch (error.osError?.errorCode) {
      case 1: // EPERM
      case 5: // ERROR_ACCESS_DENIED on Windows
      case 13: // EACCES
        return true;
    }
    final message = error.message.toLowerCase();
    return message.contains('permission denied') ||
        message.contains('access is denied') ||
        message.contains('operation not permitted');
  }
}
