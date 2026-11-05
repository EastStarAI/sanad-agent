import 'dart:io';

import 'package:path/path.dart' as p;

/// Guards the test suite against touching the owner's real Sanad Home.
///
/// A helper process that installs, updates, or probes the Agent resolves its
/// Home from environment variables. When a test forgets to redirect one of them,
/// the child falls back to the real user Home and can overwrite a real
/// installation while the test still passes. This guard makes that failure loud
/// and local to the test that caused it.
class HostHomeGuard {
  const HostHomeGuard._();

  /// Environment keys that can select the Home a helper process writes to.
  static const List<String> homeSelectingKeys = <String>[
    'HOME',
    'USERPROFILE',
    'SANAD_HOME',
    'SANAD_INSTALL_SYSTEM_HOME',
  ];

  /// The real user Home of the test process, or `null` when it is unknown.
  static String? realUserHome() {
    final raw =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final trimmed = raw?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Fails when a Home-selecting value of [environment] leaves [allowedRoot].
  ///
  /// An empty value is allowed: it is how a child process clears a variable so
  /// the helper under test decides the Home itself, and it can only resolve
  /// inside [allowedRoot] when the remaining keys do.
  static void assertHomeEnvironmentRedirected(
    Map<String, String> environment, {
    required String allowedRoot,
    List<String> keys = homeSelectingKeys,
  }) {
    final root = p.canonicalize(allowedRoot);
    for (final key in keys) {
      final value = environment[key]?.trim();
      if (value == null || value.isEmpty) continue;
      final resolved = p.canonicalize(value);
      if (resolved == root || p.isWithin(root, resolved)) continue;
      throw StateError(
        'Test environment $key=$value resolves outside $root. A helper process '
        'could write to the real user Home; redirect every Home-selecting '
        'variable into the test root.',
      );
    }
  }
}

/// A stat-only snapshot of the real Home's installed binary.
///
/// It never reads, writes, or deletes the file: it records existence, size, and
/// modification time so a test that leaks into the real Home fails instead of
/// silently replacing the owner's installation.
class RealSanadHomeWatch {
  RealSanadHomeWatch._(
    this._file, {
    required bool existed,
    required int? size,
    required DateTime? modified,
  }) : _existed = existed,
       _size = size,
       _modified = modified;

  /// Starts watching, or returns `null` when the real Home is not resolvable.
  static RealSanadHomeWatch? start() {
    final home = HostHomeGuard.realUserHome();
    if (home == null) return null;
    final file = File(p.join(home, '.sanad', 'bin', 'sanad'));
    final existed = file.existsSync();
    return RealSanadHomeWatch._(
      file,
      existed: existed,
      size: existed ? file.lengthSync() : null,
      modified: existed ? file.lastModifiedSync() : null,
    );
  }

  final File _file;
  final bool _existed;
  final int? _size;
  final DateTime? _modified;

  /// Throws when the watched binary changed during the test.
  void verifyUnchanged() {
    final existed = _file.existsSync();
    if (existed != _existed) {
      throw StateError(
        'The test changed the real Sanad binary at ${_file.path}. '
        'Redirect every Home-selecting variable into the test root.',
      );
    }
    if (!existed) return;
    if (_file.lengthSync() != _size ||
        _file.lastModifiedSync() != _modified) {
      throw StateError(
        'The test modified the real Sanad binary at ${_file.path}. '
        'Redirect every Home-selecting variable into the test root.',
      );
    }
  }
}
