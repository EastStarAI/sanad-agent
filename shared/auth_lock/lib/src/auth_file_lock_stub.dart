/// Web compile-time stub. Web authentication never invokes the native lock.
class AuthFileLockTimeout implements Exception {
  const AuthFileLockTimeout(this.timeout);

  final Duration timeout;
}

class NativeAuthFileLock {
  NativeAuthFileLock(
    this.sanadHomePath, {
    this.acquisitionTimeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(milliseconds: 25),
  });

  static const fileName = 'auth.refresh.lock';

  final String sanadHomePath;
  final Duration acquisitionTimeout;
  final Duration retryDelay;

  Future<T> runExclusive<T>(Future<T> Function() operation) => Future<T>.error(
    UnsupportedError('Native authentication locking is unavailable.'),
  );
}
