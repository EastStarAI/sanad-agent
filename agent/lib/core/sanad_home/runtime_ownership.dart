import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart'
    show isProcessAlive;

import 'sanad_home_bootstrap.dart';
import 'sanad_home_boundary.dart';

/// Schema version of the lock-holder record beside the runtime lock.
const int runtimeOwnershipHolderSchemaVersion = 1;

/// The process that owns the mutable Sanad state root, as recorded beside it.
///
/// The lock itself is an anonymous `flock`: a loser learns only that the lock
/// is taken, and the lock file stays empty. That is how one incident ran a
/// foreign supervisor against a Home for two days while every losing daemon
/// printed the same constant sentence and nothing could name the winner. This
/// record gives the lock a face.
///
/// It is discovery evidence for diagnostics, never a second authority:
/// acquisition remains the exclusive lock, and a record whose process is gone
/// is reported as stale instead of being trusted.
class SanadRuntimeOwnershipHolder {
  const SanadRuntimeOwnershipHolder({
    required this.pid,
    required this.launcherId,
    required this.runtimeNonce,
    required this.acquiredAt,
  });

  /// Owner process id.
  final int pid;

  /// `SANAD_DEV_LAUNCHER_ID` of the owner, or empty for an unmanaged runtime.
  final String launcherId;

  /// `SANAD_DEV_RUNTIME_NONCE` of the owner, or empty for an unmanaged runtime.
  final String runtimeNonce;

  /// When the owner acquired the lock.
  final DateTime acquiredAt;

  Map<String, Object?> toJson() => {
    'schema': runtimeOwnershipHolderSchemaVersion,
    'pid': pid,
    'launcher_id': launcherId,
    'runtime_nonce': runtimeNonce,
    'acquired_at': acquiredAt.toUtc().toIso8601String(),
  };

  /// Parses one recorded holder, returning null for anything unreadable.
  static SanadRuntimeOwnershipHolder? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    if (decoded['schema'] != runtimeOwnershipHolderSchemaVersion) return null;
    final rawPid = decoded['pid'];
    final ownerPid = rawPid is int ? rawPid : int.tryParse('$rawPid');
    if (ownerPid == null || ownerPid <= 0) return null;
    final acquiredAt = DateTime.tryParse(
      decoded['acquired_at']?.toString() ?? '',
    );
    if (acquiredAt == null) return null;
    return SanadRuntimeOwnershipHolder(
      pid: ownerPid,
      launcherId: decoded['launcher_id']?.toString().trim() ?? '',
      runtimeNonce: decoded['runtime_nonce']?.toString().trim() ?? '',
      acquiredAt: acquiredAt.toUtc(),
    );
  }

  /// Whether the recorded owner process still exists.
  bool get isAlive => isProcessAlive(pid);

  /// Bounded, secret-free description for one diagnostic line.
  String describe() {
    final parts = <String>['pid $pid'];
    if (launcherId.isNotEmpty) parts.add('launcher $launcherId');
    if (runtimeNonce.isNotEmpty) parts.add('nonce $runtimeNonce');
    return parts.join(', ');
  }
}

/// Raised when another process already owns the mutable Sanad state root.
class SanadRuntimeOwnershipConflict implements Exception {
  const SanadRuntimeOwnershipConflict({this.holder, this.holderStale = false});

  /// The recorded owner, when its holder record could be read.
  final SanadRuntimeOwnershipHolder? holder;

  /// Whether the recorded owner process is gone, so the record is stale.
  final bool holderStale;

  /// One bounded reason that names the holder when it is readable.
  String get message {
    const base = 'Another Sanad runtime already owns this Sanad Home.';
    final recorded = holder;
    if (recorded == null) {
      return '$base The holder is not recorded, so it cannot be named.';
    }
    if (holderStale) {
      return '$base The recorded holder (${recorded.describe()}) is no longer '
          'running, so the record is stale.';
    }
    return '$base Holder: ${recorded.describe()}.';
  }

  @override
  String toString() => message;
}

/// Exclusive process-lifetime ownership of the state root shared by the daemon
/// and in-process standalone CLI.
class SanadRuntimeOwnership {
  static const String lockRelativePath = '.runtime-owner.lock';

  /// Owner record written immediately after the lock is acquired.
  static const String holderRelativePath = '.runtime-owner.json';

  static Future<SanadHomeFileLockLease> acquire({
    Duration timeout = const Duration(milliseconds: 100),
  }) async {
    final boundary = SanadHomeBootstrap.state();
    try {
      final lease = await boundary.acquireFileLock(
        lockRelativePath,
        timeout: timeout,
      );
      _recordHolder(boundary);
      return lease;
    } on SanadHomeWriteFailure catch (error) {
      if (error.code == 'lock_timeout' || error.code == 'lock_unavailable') {
        throw _conflict();
      }
      rethrow;
    }
  }

  /// Reads the recorded holder of the active Home, or null when unreadable.
  static SanadRuntimeOwnershipHolder? readHolder() {
    try {
      final file = File(SanadHomeBootstrap.state().child(holderRelativePath));
      if (!file.existsSync()) return null;
      return SanadRuntimeOwnershipHolder.fromJson(
        jsonDecode(file.readAsStringSync()),
      );
    } on Object {
      return null;
    }
  }

  /// Publishes this process as the holder.
  ///
  /// Best effort by design: the exclusive lock is the authority, and a
  /// diagnostic record must never fail a startup that already won it. The
  /// record carries a pid and the launcher id/nonce correlation evidence, never
  /// a credential.
  static void _recordHolder(SanadHomeBootstrap boundary) {
    try {
      final environment = Platform.environment;
      // `pid` here is the `dart:io` process id of this process, not a field.
      final ownerProcessId = pid;
      final holder = SanadRuntimeOwnershipHolder(
        pid: ownerProcessId,
        launcherId: environment['SANAD_DEV_LAUNCHER_ID']?.trim() ?? '',
        runtimeNonce: environment['SANAD_DEV_RUNTIME_NONCE']?.trim() ?? '',
        acquiredAt: DateTime.now().toUtc(),
      );
      boundary.writeSecretBytesSync(
        holderRelativePath,
        utf8.encode('${jsonEncode(holder.toJson())}\n'),
      );
    } on Object {
      // The lock is held; a missing or unwritable record only costs a name.
    }
  }

  static SanadRuntimeOwnershipConflict _conflict() {
    final holder = readHolder();
    return SanadRuntimeOwnershipConflict(
      holder: holder,
      holderStale: holder != null && !holder.isAlive,
    );
  }
}
