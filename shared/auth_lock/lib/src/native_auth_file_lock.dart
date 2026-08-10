import 'dart:async';
import 'dart:io';

/// Thrown when another native Sanad process keeps the authentication lock
/// longer than the caller's bounded acquisition window.
class AuthFileLockTimeout implements Exception {
  const AuthFileLockTimeout(this.timeout);

  final Duration timeout;

  @override
  String toString() => 'AuthFileLockTimeout(${timeout.inMilliseconds}ms)';
}

/// Serializes authentication read-modify-write transactions across native
/// Sanad processes that share one Sanad Home.
///
/// The lock file is stable and never replaced: replacing a locked file would
/// create a second inode on Unix and break mutual exclusion for later openers.
class NativeAuthFileLock {
  NativeAuthFileLock(
    this.sanadHomePath, {
    this.acquisitionTimeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(milliseconds: 25),
  });

  static const fileName = 'auth.refresh.lock';
  static final Map<String, Future<void>> _localTails = <String, Future<void>>{};

  final String sanadHomePath;
  final Duration acquisitionTimeout;
  final Duration retryDelay;

  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    final key = Directory(sanadHomePath).absolute.path;
    final predecessor = _localTails[key] ?? Future<void>.value();
    final releaseLocal = Completer<void>();
    _localTails[key] = releaseLocal.future;

    await predecessor;
    try {
      return await _runWithOperatingSystemLock(operation);
    } finally {
      releaseLocal.complete();
      if (identical(_localTails[key], releaseLocal.future)) {
        _localTails.remove(key);
      }
    }
  }

  Future<T> _runWithOperatingSystemLock<T>(
    Future<T> Function() operation,
  ) async {
    final handle = await _openStableLockFile();
    var acquired = false;
    try {
      final stopwatch = Stopwatch()..start();
      while (!acquired) {
        try {
          await handle.lock(FileLock.exclusive);
          acquired = true;
        } on FileSystemException {
          if (stopwatch.elapsed >= acquisitionTimeout) {
            throw AuthFileLockTimeout(acquisitionTimeout);
          }
          await Future<void>.delayed(retryDelay);
        }
      }
      return await operation();
    } finally {
      if (acquired) {
        try {
          await handle.unlock();
        } on FileSystemException {
          // Closing the handle also releases the operating-system lock.
        }
      }
      await handle.close();
    }
  }

  Future<RandomAccessFile> _openStableLockFile() async {
    final home = Directory(sanadHomePath).absolute;
    final homeType = await FileSystemEntity.type(home.path, followLinks: false);
    if (homeType != FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Sanad Home must be prepared before opening the auth lock.',
      );
    }

    final lockFile = File('${home.path}${Platform.pathSeparator}$fileName');
    final initialType = await FileSystemEntity.type(
      lockFile.path,
      followLinks: false,
    );
    if (initialType == FileSystemEntityType.link ||
        (initialType != FileSystemEntityType.notFound &&
            initialType != FileSystemEntityType.file)) {
      throw const FileSystemException('Unsafe authentication lock target.');
    }

    if (initialType == FileSystemEntityType.notFound) {
      try {
        await lockFile.create(exclusive: true);
      } on FileSystemException {
        final racedType = await FileSystemEntity.type(
          lockFile.path,
          followLinks: false,
        );
        if (racedType != FileSystemEntityType.file) rethrow;
      }
    }

    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', lockFile.path]);
      if (chmod.exitCode != 0) {
        throw const FileSystemException(
          'Unable to secure authentication lock file.',
        );
      }
    }
    return lockFile.open(mode: FileMode.append);
  }
}
