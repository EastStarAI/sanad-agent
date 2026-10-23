part of '../../sanad_dev_cli.dart';

/// Schema version of the cached `sanad-dev ui` target resolution.
const int uiDriverTargetCacheVersion = 1;

/// Bound on how long a cached target may be trusted without a full re-scan.
///
/// Expiry is a safety net for the validation gaps a cheap check cannot cover
/// (for example a Client that changed device without changing its lease), not a
/// correctness requirement: every use is revalidated against live evidence.
const Duration uiDriverTargetCacheMaxAge = Duration(hours: 12);

/// Where one worktree's last resolved `ui` target is remembered.
///
/// The file lives inside the worktree-scoped runtime directory, so two
/// worktrees can never read each other's entry, and it carries both the
/// worktree id and the resolved Sanad Home so a Home change invalidates it even
/// inside one worktree.
String uiDriverTargetCachePath(String runtimeDirectory) =>
    '$runtimeDirectory${Platform.pathSeparator}ui-driver-target.json';

/// The single managed driver Client `ui` resolved last time for one worktree
/// and Home.
///
/// This is discovery evidence only. It never proves liveness, ownership, or
/// mutation authority: every field is re-read from the live operating system and
/// the launcher lease before use, and any mismatch drops the entry.
class UiDriverTargetCache {
  const UiDriverTargetCache({
    required this.worktreeId,
    required this.sanadHome,
    required this.agentPort,
    required this.devServicePid,
    required this.clientPid,
    required this.vmServicePort,
    required this.updatedAt,
  });

  final String worktreeId;
  final String sanadHome;
  final int agentPort;
  final int devServicePid;
  final int clientPid;
  final int vmServicePort;
  final DateTime updatedAt;

  /// Process ids a narrowed revalidation has to re-read from the OS.
  List<int> get candidatePids => [devServicePid, clientPid];

  Map<String, Object?> toJson() => {
    'version': uiDriverTargetCacheVersion,
    'worktree_id': worktreeId,
    'sanad_home': sanadHome,
    'agent_port': agentPort,
    'dev_service_pid': devServicePid,
    'client_pid': clientPid,
    'vm_service_port': vmServicePort,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static UiDriverTargetCache? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    if (decoded['version'] != uiDriverTargetCacheVersion) return null;
    final worktreeId = decoded['worktree_id'];
    final sanadHome = decoded['sanad_home'];
    final agentPort = decoded['agent_port'];
    final devServicePid = decoded['dev_service_pid'];
    final clientPid = decoded['client_pid'];
    final vmServicePort = decoded['vm_service_port'];
    final updatedAt = DateTime.tryParse('${decoded['updated_at'] ?? ''}');
    if (worktreeId is! String ||
        worktreeId.isEmpty ||
        sanadHome is! String ||
        sanadHome.isEmpty ||
        agentPort is! int ||
        devServicePid is! int ||
        clientPid is! int ||
        vmServicePort is! int ||
        updatedAt == null) {
      return null;
    }
    return UiDriverTargetCache(
      worktreeId: worktreeId,
      sanadHome: sanadHome,
      agentPort: agentPort,
      devServicePid: devServicePid,
      clientPid: clientPid,
      vmServicePort: vmServicePort,
      updatedAt: updatedAt.toUtc(),
    );
  }
}

/// Builds the entry for a successfully resolved managed driver Client.
///
/// Returns null when the client carries no development-service pid, because
/// then nothing can narrow a later scan to the same endpoint.
UiDriverTargetCache? uiDriverTargetCacheFor({
  required SanadDevRuntime runtime,
  required ClientInstance client,
  required String sanadHome,
  required int agentPort,
  DateTime? now,
}) {
  final devServicePid = client.devServicePid;
  final clientPid = client.pid;
  if (devServicePid == null || devServicePid <= 0) return null;
  if (clientPid == null || clientPid <= 0) return null;
  return UiDriverTargetCache(
    worktreeId: runtime.worktreeId,
    sanadHome: sanadHome,
    agentPort: agentPort,
    devServicePid: devServicePid,
    clientPid: clientPid,
    vmServicePort: client.port,
    updatedAt: now ?? DateTime.now().toUtc(),
  );
}

/// Explains why [cache] cannot describe this invocation's target.
///
/// Returns null when the entry still belongs to this worktree and Home and is
/// inside its freshness bound. A rejected entry is discarded by the caller; a
/// rejected or missing entry only costs the full discovery scan.
String? validateUiDriverTargetCache(
  UiDriverTargetCache? cache, {
  required SanadDevRuntime runtime,
  required String resolvedSanadHome,
  DateTime? now,
}) {
  if (cache == null) return 'no cached target';
  if (cache.worktreeId != runtime.worktreeId) {
    return 'cached target belongs to another worktree';
  }
  if (!equivalentPaths(cache.sanadHome, resolvedSanadHome)) {
    return 'cached target belongs to another Sanad Home';
  }
  final age = (now ?? DateTime.now().toUtc()).difference(cache.updatedAt);
  if (age.isNegative || age > uiDriverTargetCacheMaxAge) {
    return 'cached target is stale';
  }
  return null;
}

/// Reads the cached target, or null when it is absent, unreadable, or belongs
/// to another context.
Future<UiDriverTargetCache?> readUiDriverTargetCache(
  SanadDevRuntime runtime,
) async {
  final path = uiDriverTargetCachePath(runtime.runtimeDirectory);
  try {
    if (!await File(path).exists()) return null;
    final decoded = jsonDecode(
      await secureRuntimeReadText(runtime.runtimeDirectory, path),
    );
    return UiDriverTargetCache.fromJson(decoded);
  } on Object {
    return null;
  }
}

/// Records one resolved target for later cheap revalidation.
///
/// A failure to persist is never fatal: the next invocation simply discovery
/// scans again.
Future<void> writeUiDriverTargetCache(
  SanadDevRuntime runtime,
  UiDriverTargetCache cache,
) async {
  final path = uiDriverTargetCachePath(runtime.runtimeDirectory);
  try {
    await secureRuntimeAtomicWrite(
      runtime.runtimeDirectory,
      path,
      '${jsonEncode(cache.toJson())}\n',
    );
  } on Object {
    // The cache is an optimization; never fail a resolved action to keep it.
  }
}

/// Drops a cached target that no longer matches live state.
Future<void> deleteUiDriverTargetCache(SanadDevRuntime runtime) async {
  try {
    final file = File(uiDriverTargetCachePath(runtime.runtimeDirectory));
    if (await file.exists()) await file.delete();
  } on Object {
    // A cache that cannot be deleted is still revalidated before the next use.
  }
}

/// True when [port] accepts a loopback connection.
///
/// Used together with the live development-service process and the launcher
/// lease; it proves only that the cached endpoint still answers.
Future<bool> uiDriverVmServiceReachable(
  int port, {
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  if (port <= 0) return false;
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
