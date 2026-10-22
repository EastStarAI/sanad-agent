import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/loopback_policy.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:sanad_agent/core/sanad_home/test_runtime_isolation.dart';

/// The live local-gateway endpoint that a Home's daemon published when it
/// bound its listener.
///
/// The record lives inside the Home it describes, so a Home-selected CLI call
/// resolves its endpoint from the Home itself instead of probing the default
/// port or scanning a port range. Because the record carries
/// [sanadHomeIdentity], a caller detects a record that belongs to a different
/// (for example copied) Home and fails closed instead of probing it.
///
/// A record is *evidence*, not authentication: the fields are filesystem
/// state that any process running as this user can write. Discovery therefore
/// also requires that the record is owner-only, points at a loopback host, and
/// names a live owner process. That reduces mis-routing; it does not prove
/// which server answers on the port.
class LocalGatewayEndpointRecord {
  const LocalGatewayEndpointRecord({
    required this.homeId,
    required this.host,
    required this.port,
    required this.ownerProcessId,
  });

  /// Canonical relative path under the Sanad Home.
  static const String relativePath = '.local_gateway_endpoint.json';

  /// Schema version of the persisted record. A record with any other version
  /// is ignored so an older or newer writer can never be misread.
  static const int schemaVersion = 1;

  final String homeId;
  final String host;
  final int port;

  /// Process that published (and is bound to) [port].
  final int ownerProcessId;

  @override
  String toString() =>
      'LocalGatewayEndpointRecord(host: $host, port: $port, homeId: $homeId)';

  /// Whether the process that published this record still exists.
  ///
  /// A record left behind by a crashed or stopped daemon keeps pointing at a
  /// port that another process may since have taken, so callers must treat a
  /// dead owner as a stale record rather than as an endpoint.
  bool get ownerProcessIsAlive => isProcessAlive(ownerProcessId);

  /// Publishes the endpoint this process bound for the active Home.
  ///
  /// The file is written owner-only through [SanadHomeBootstrap] and replaced
  /// atomically, so a concurrent reader sees either the previous complete
  /// record or the new one.
  static Future<void> write({
    required String host,
    required int port,
    int? processId,
  }) async {
    // The record belongs to one Home root; a test that has not isolated its
    // Home must never publish into the OS user's real Sanad Home.
    rejectUnisolatedTestHomeAccess(
      'publish the local gateway runtime record',
      path: getSanadHome(),
    );
    final boundary = SanadHomeBootstrap.identity();
    final payload = jsonEncode({
      'schema': schemaVersion,
      'home_id': sanadHomeIdentity(boundary.canonicalRoot()),
      'host': host,
      'port': port,
      'pid': processId ?? pid,
    });
    await boundary.writeSecretBytes(relativePath, utf8.encode(payload));
  }

  /// Reads the record of [homePath], or of the active Home when omitted.
  ///
  /// Returns null when there is no usable record: missing file, a symlink, a
  /// file that is not owner-only, an unreadable or malformed payload, a
  /// non-loopback host, an unverifiable owner process id, or a schema this
  /// build does not own.
  static LocalGatewayEndpointRecord? tryRead({String? homePath}) {
    final String path;
    try {
      path = homePath == null
          ? SanadHomeBootstrap.resolveChild(relativePath)
          : p.join(p.normalize(p.absolute(homePath)), relativePath);
    } catch (_) {
      return null;
    }

    return readFile(File(path));
  }

  /// Parses one record file, returning null for anything this build must not
  /// treat as an endpoint: a missing file, a file that is not owner-only, an
  /// unreadable or malformed payload, a non-loopback host, an unverifiable
  /// owner process id, or a schema this build does not own.
  static LocalGatewayEndpointRecord? readFile(File file) {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    if (!SanadHomeBootstrap.isOwnerOnlyFile(file)) return null;

    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['schema'] != schemaVersion) return null;

      final homeId = decoded['home_id'];
      final host = decoded['host'];
      final port = decoded['port'];
      final processId = decoded['pid'];
      if (homeId is! String || homeId.isEmpty) return null;
      if (host is! String || host.isEmpty) return null;
      // The daemon binds loopback only (SEC-02 / INV-1), so a record naming
      // any other host cannot describe a Sanad gateway and must not receive
      // the credential.
      if (!LoopbackPolicy.isLoopbackHost(host)) return null;
      if (port is! int || port <= 0 || port > 65535) return null;
      // `write` always persists a pid, so a record without one is corrupt or
      // hand-written and its liveness cannot be checked.
      if (processId is! int || processId <= 0) return null;

      return LocalGatewayEndpointRecord(
        homeId: homeId,
        host: host,
        port: port,
        ownerProcessId: processId,
      );
    } catch (_) {
      return null;
    }
  }

  /// Removes the record when it still describes this process's endpoint.
  ///
  /// [port] is optional: a daemon shutting down knows which pid must still be
  /// named, while a caller that only owns the process id can pass none.
  /// [processId] defaults to this process.
  ///
  /// The removal is atomic in the two senses that matter here. The record is
  /// first *claimed* with a rename to a sibling path, so the identity check and
  /// the delete cannot interleave with a concurrent publish at [relativePath],
  /// and the claimed copy is re-read before it is deleted. A record that names
  /// another publisher is therefore never deleted: if the rename raced a newer
  /// runtime's publish, the claimed copy names that runtime and is restored
  /// instead of removed. A `SIGKILL` in the microseconds between the claim and
  /// the delete can leave a `<record>.removing-<pid>` sibling behind; it is not
  /// a record and no caller reads it.
  ///
  /// Returns whether a record was removed.
  static Future<bool> removeIfOwned({int? port, int? processId}) async {
    try {
      rejectUnisolatedTestHomeAccess(
        'remove the local gateway runtime record',
        path: getSanadHome(),
      );
    } on StateError {
      return false;
    }
    final owner = processId ?? pid;
    bool isOurs(LocalGatewayEndpointRecord? candidate) =>
        candidate != null &&
        candidate.ownerProcessId == owner &&
        (port == null || candidate.port == port);

    final String path;
    try {
      path = SanadHomeBootstrap.resolveChild(relativePath);
    } catch (_) {
      return false;
    }
    final record = File(path);
    // Cheap pre-check: an absent or foreign record is never touched, so this
    // path cannot disturb another runtime on the common case.
    if (!isOurs(readFile(record))) return false;

    final claim = File('$path.removing-$owner');
    try {
      await record.rename(claim.path);
    } catch (_) {
      return false;
    }

    // Put a claimed record back without overwriting a fresher publish: if the
    // successor already wrote a new record, the claimed copy is an older
    // generation and is dropped instead.
    Future<void> restoreClaim() async {
      try {
        if (record.existsSync()) {
          await claim.delete();
        } else {
          await claim.rename(path);
        }
      } catch (_) {}
    }

    if (isOurs(readFile(claim))) {
      try {
        await claim.delete();
        return true;
      } catch (_) {
        // A record that could not be removed only costs the next caller one
        // clear failure message; restore it so the Home keeps describing the
        // endpoint that actually answered.
        await restoreClaim();
        return false;
      }
    }

    // The claim captured a newer runtime's record: leave it in place.
    await restoreClaim();
    return false;
  }
}

/// Whether [processId] names a live process.
///
/// Liveness only: it answers "is something there", never "is that something
/// the daemon of this Home". A pid can also be reused by an unrelated process,
/// so this is one more signal for detecting a stale record, not proof of
/// identity. A check that cannot run at all (a missing `kill`/`tasklist`)
/// reports "not alive", so an unverifiable record fails closed. See the
/// challenge/HMAC follow-up in
/// `docs/technical/user_data_protection_and_minimization.md`.
bool isProcessAlive(int processId) {
  if (processId <= 0) return false;
  if (processId == pid) return true;
  try {
    if (Platform.isWindows) {
      final result = Process.runSync('tasklist', [
        '/FI',
        'PID eq $processId',
        '/FO',
        'CSV',
        '/NH',
      ]);
      final fields = result.stdout.toString().split(',');
      return result.exitCode == 0 &&
          fields.length > 1 &&
          fields[1].replaceAll('"', '').trim() == '$processId';
    }
    // POSIX: signal 0 performs the existence and permission checks without
    // delivering a signal. Dart exposes no signal-0 constant, so the `kill`
    // utility is used: exit 0 means the process exists for this user. A
    // non-zero exit also covers "exists but owned by another user", which a
    // daemon serving this Home cannot be.
    final result = Process.runSync('kill', ['-0', '$processId']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
