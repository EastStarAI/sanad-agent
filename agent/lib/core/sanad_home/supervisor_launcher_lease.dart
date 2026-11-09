import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart'
    show isProcessAlive;

/// Schema version of a `sanad-dev` launcher lease (`runtime-launcher-<port>.json`).
///
/// The lease is written by the owning launcher and is the only local record that
/// ties an Agent port and a Home to one launcher id/nonce pair. `sanad-dev`
/// already treats it as the ownership authority; the supervisor reads the same
/// file so both authorities agree on who owns the runtime.
const int sanadDevLauncherLeaseVersion = 1;

/// Longest lease file considered when the preferred port has no lease.
const int sanadDevLauncherLeaseScanLimit = 8;

/// The identifying fields of one launcher lease.
class SanadDevLauncherLease {
  const SanadDevLauncherLease({
    required this.agentPort,
    required this.launcherId,
    required this.runtimeNonce,
    required this.launcherPid,
  });

  final int agentPort;
  final String launcherId;
  final String runtimeNonce;
  final int launcherPid;

  /// Parses one lease payload, returning null for anything unreadable.
  static SanadDevLauncherLease? fromJson(int agentPort, Object? decoded) {
    if (decoded is! Map) return null;
    if (decoded['version'] != sanadDevLauncherLeaseVersion) return null;
    final rawPid = decoded['launcher_pid'];
    final launcherPid = rawPid is int ? rawPid : int.tryParse('$rawPid');
    final launcherId = decoded['launcher_id']?.toString().trim() ?? '';
    final runtimeNonce = decoded['runtime_nonce']?.toString().trim() ?? '';
    if (launcherPid == null || launcherPid <= 0) return null;
    if (launcherId.isEmpty || runtimeNonce.isEmpty) return null;
    return SanadDevLauncherLease(
      agentPort: agentPort,
      launcherId: launcherId,
      runtimeNonce: runtimeNonce,
      launcherPid: launcherPid,
    );
  }
}

/// Reads the launcher leases recorded under `<home>/dev/`.
///
/// [preferredPort] is read first so the common path stays one file read; the
/// remaining `runtime-launcher-<port>.json` files are read only when it does not
/// exist, and never more than [sanadDevLauncherLeaseScanLimit]. Reading is
/// bounded and non-fatal: an unreadable or malformed lease is skipped.
Future<List<SanadDevLauncherLease>> readSanadDevLauncherLeases({
  required String home,
  int? preferredPort,
}) async {
  final devDirectory = Directory(p.join(home, 'dev'));
  if (FileSystemEntity.typeSync(devDirectory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return const [];
  }
  final leases = <SanadDevLauncherLease>[];
  final readPorts = <int>{};

  Future<void> readPort(int port) async {
    if (!readPorts.add(port)) return;
    final lease = await readSanadDevLauncherLease(home: home, agentPort: port);
    if (lease != null) leases.add(lease);
  }

  if (preferredPort != null) await readPort(preferredPort);

  final ports = <int>[];
  try {
    await for (final entity in devDirectory.list(followLinks: false)) {
      final match = RegExp(
        r'^runtime-launcher-(\d+)\.json$',
      ).firstMatch(p.basename(entity.path));
      final port = int.tryParse(match?.group(1) ?? '');
      if (port == null) continue;
      ports.add(port);
    }
  } on FileSystemException {
    return leases;
  }
  ports.sort();
  for (final port in ports.take(sanadDevLauncherLeaseScanLimit)) {
    await readPort(port);
  }
  return leases;
}

/// Reads one `runtime-launcher-<port>.json`, or null when it is absent/invalid.
Future<SanadDevLauncherLease?> readSanadDevLauncherLease({
  required String home,
  required int agentPort,
}) async {
  final file = File(p.join(home, 'dev', 'runtime-launcher-$agentPort.json'));
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return SanadDevLauncherLease.fromJson(
      agentPort,
      jsonDecode(await file.readAsString()),
    );
  } on Object {
    return null;
  }
}

/// Why the supervisor may or may not respawn its child.
enum SupervisorLauncherVerdictKind {
  /// No managed launcher owns this process: today's unmanaged behaviour.
  unmanaged,

  /// The launcher named by the environment still holds the lease.
  allowed,

  /// The lease is missing, names another launcher, or its launcher is gone.
  denied,
}

/// The supervisor's answer to "is my launcher still the lease holder?".
class SupervisorLauncherVerdict {
  const SupervisorLauncherVerdict._(this.kind, this.reason);

  const SupervisorLauncherVerdict.unmanaged()
    : this._(SupervisorLauncherVerdictKind.unmanaged, '');

  const SupervisorLauncherVerdict.allowed()
    : this._(SupervisorLauncherVerdictKind.allowed, '');

  const SupervisorLauncherVerdict.denied(String reason)
    : this._(SupervisorLauncherVerdictKind.denied, reason);

  final SupervisorLauncherVerdictKind kind;

  /// One bounded, secret-free reason; empty unless the verdict is denied.
  final String reason;

  bool get isDenied => kind == SupervisorLauncherVerdictKind.denied;

  bool get isManaged => kind != SupervisorLauncherVerdictKind.unmanaged;
}

/// Proves that the managed launcher which started this supervisor still owns
/// the runtime.
///
/// A supervisor that outlives its launcher keeps fighting for a Home it can
/// never own: the launcher's death releases the Home lock, the supervisor
/// respawns a child every few seconds, and whichever process reaches the lock
/// first wins. In one incident that was a two-day-old orphan, and every managed
/// restart handed the daemon to it.
///
/// The identity comes from the environment the launcher injects, so a
/// deliberate manual `fvm dart run … daemon` (no `SANAD_DEV_LAUNCHER_ID`) keeps
/// today's behaviour and stays unmanaged.
Future<SupervisorLauncherVerdict> verifySupervisorLauncher({
  Map<String, String>? environment,
  String? sanadHome,
  Future<bool> Function(int pid)? launcherRunning,
}) async {
  final env = environment ?? Platform.environment;
  final launcherId = env['SANAD_DEV_LAUNCHER_ID']?.trim() ?? '';
  if (launcherId.isEmpty) return const SupervisorLauncherVerdict.unmanaged();
  final runtimeNonce = env['SANAD_DEV_RUNTIME_NONCE']?.trim() ?? '';
  if (runtimeNonce.isEmpty) {
    return const SupervisorLauncherVerdict.denied(
      'this process carries a launcher id but no runtime nonce.',
    );
  }

  final String home;
  try {
    home = sanadHome ?? getSanadHome();
  } on Object {
    return const SupervisorLauncherVerdict.denied(
      'the Sanad Home of this process is unknown.',
    );
  }

  final leases = await readSanadDevLauncherLeases(
    home: home,
    preferredPort: int.tryParse(env['LOCAL_GATEWAY_PORT']?.trim() ?? ''),
  );
  if (leases.isEmpty) {
    return const SupervisorLauncherVerdict.denied(
      'no launcher lease exists for the Sanad Home.',
    );
  }
  final owned = leases
      .where((lease) => lease.launcherId == launcherId)
      .toList(growable: false);
  if (owned.isEmpty) {
    return SupervisorLauncherVerdict.denied(
      'no launcher lease names launcher $launcherId '
      '(ports ${_ports(leases)}).',
    );
  }
  SanadDevLauncherLease? matching;
  for (final lease in owned) {
    if (lease.runtimeNonce == runtimeNonce) {
      matching = lease;
      break;
    }
  }
  if (matching == null) {
    final other = owned.first;
    return SupervisorLauncherVerdict.denied(
      'the lease for port ${other.agentPort} carries another runtime nonce '
      '(${other.runtimeNonce}), not $runtimeNonce.',
    );
  }

  final alive = await (launcherRunning ?? _launcherRunning)(
    matching.launcherPid,
  );
  if (!alive) {
    return SupervisorLauncherVerdict.denied(
      'the lease names launcher pid ${matching.launcherPid}, which is not '
      'running.',
    );
  }
  return const SupervisorLauncherVerdict.allowed();
}

Future<bool> _launcherRunning(int pid) async => isProcessAlive(pid);

String _ports(List<SanadDevLauncherLease> leases) =>
    leases.map((lease) => lease.agentPort).join(', ');
