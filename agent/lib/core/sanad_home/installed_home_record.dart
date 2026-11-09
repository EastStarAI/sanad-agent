import 'dart:io';

import 'package:path/path.dart' as p;

/// The Sanad Home an installed Agent belongs to, read from the install record
/// that sits beside its executable.
///
/// `scripts/install.sh` and `scripts/install.ps1` place the Agent at
/// `<home>/bin/sanad`, and `sanad service install` writes the non-secret
/// ownership metadata `<home>/service.json` next to it. That pair is the only
/// local evidence of which Home a binary serves, and it is the evidence a
/// service-management CLI needs when the Agent runs as a dedicated account:
/// for that account `$HOME` *is* the Sanad Home, so the `$HOME/.sanad` default
/// names a second, empty Home and reports a healthy unit as broken.
///
/// Discovery is deliberately read-only and metadata-only: it stats
/// `service.json` (refusing a symlink) and never reads `.env`, a credential,
/// or any other Home file.
abstract final class InstalledHomeRecord {
  /// The installed artifact name, with and without the Windows suffix.
  static const String executableName = 'sanad';
  static const String windowsExecutableName = 'sanad.exe';

  /// The directory that holds the artifact inside a Home.
  static const String binaryDirectoryName = 'bin';

  /// The non-secret ownership metadata `service install` records in a Home.
  static const String metadataFileName = 'service.json';

  /// The Home recorded beside this process's executable, or null when the
  /// process is not an installed `<home>/bin/sanad`.
  ///
  /// Resolved once: the executable path and its Home are fixed for the life of
  /// the process, and `getSanadHome()` is a per-operation path that must not
  /// stat the record on every call.
  static String? current() {
    if (_currentResolved) return _current;
    _current = homeOf(Platform.resolvedExecutable);
    _currentResolved = true;
    return _current;
  }

  static String? _current;
  static bool _currentResolved = false;

  /// The Home recorded beside [executablePath].
  ///
  /// A Home is returned only when all three facts hold: the executable is named
  /// [executableName], it sits in a [binaryDirectoryName] directory, and the
  /// directory above that carries a regular [metadataFileName]. Anything else —
  /// a source run whose executable is the Dart VM, a copy outside a Home, a Home
  /// installed without the record, or a symlinked record — yields null so the
  /// caller keeps its own fallback instead of guessing a Home.
  static String? homeOf(String executablePath) {
    if (executablePath.trim().isEmpty) return null;
    final resolved = p.normalize(p.absolute(executablePath));
    final name = p.basename(resolved).toLowerCase();
    if (name != executableName && name != windowsExecutableName) return null;
    final binaryDirectory = p.dirname(resolved);
    if (p.basename(binaryDirectory).toLowerCase() != binaryDirectoryName) {
      return null;
    }
    final home = p.dirname(binaryDirectory);
    if (home == binaryDirectory) return null;
    final record = p.join(home, metadataFileName);
    if (FileSystemEntity.typeSync(record, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return home;
  }
}
