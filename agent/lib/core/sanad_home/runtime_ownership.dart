import 'sanad_home_bootstrap.dart';
import 'sanad_home_boundary.dart';

/// Raised when another process already owns the mutable Sanad state root.
class SanadRuntimeOwnershipConflict implements Exception {
  const SanadRuntimeOwnershipConflict();

  @override
  String toString() => 'Another Sanad runtime already owns this Sanad Home.';
}

/// Exclusive process-lifetime ownership of the state root shared by the daemon
/// and in-process standalone CLI.
class SanadRuntimeOwnership {
  static const String lockRelativePath = '.runtime-owner.lock';

  static Future<SanadHomeFileLockLease> acquire({
    Duration timeout = const Duration(milliseconds: 100),
  }) async {
    try {
      return await SanadHomeBootstrap.state().acquireFileLock(
        lockRelativePath,
        timeout: timeout,
      );
    } on SanadHomeWriteFailure catch (error) {
      if (error.code == 'lock_timeout' || error.code == 'lock_unavailable') {
        throw const SanadRuntimeOwnershipConflict();
      }
      rethrow;
    }
  }
}
