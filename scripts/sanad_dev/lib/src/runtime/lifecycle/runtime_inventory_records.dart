part of '../../../sanad_dev_cli.dart';

/// One `~/.sanad/dev/runtimes/<worktree id>` diagnostics record.
///
/// `runtime.json` is legacy metadata, so it contributes configuration only
/// (Home, recorded ports). Liveness always comes from the live Agent probe and
/// the launcher lease, never from this record.
class InventoryRuntimeRecord {
  const InventoryRuntimeRecord({
    required this.worktreeId,
    required this.directory,
    this.recordedHome,
    this.recordedAgentPort,
    this.recordedVmServicePort,
    this.workspaceHash,
  });

  final String worktreeId;
  final String directory;
  final String? recordedHome;
  final int? recordedAgentPort;
  final int? recordedVmServicePort;
  final String? workspaceHash;
}

/// One `.local_gateway_endpoint.json` record as read-only evidence.
///
/// The record names the daemon process that published its loopback endpoint, so
/// it is the only local surface that reports an Agent PID. It never carries a
/// credential here: inventory reads `pid`, `port`, and loopback `host` only.
class InventoryEndpointRecord {
  const InventoryEndpointRecord({
    required this.pid,
    required this.port,
    required this.alive,
  });

  final int pid;
  final int? port;
  final bool alive;
}

/// One Home's read-only state: its launcher leases and its endpoint record.
class InventoryHomeState {
  const InventoryHomeState({
    required this.home,
    required this.leases,
    required this.endpoint,
  });

  final String home;
  final List<RuntimeLauncherRecord> leases;
  final InventoryEndpointRecord? endpoint;

  /// Owner PID of an endpoint record that names a dead process, or null when
  /// the record is absent, unreadable, or live.
  int? get staleEndpointPid =>
      endpoint != null && !endpoint!.alive ? endpoint!.pid : null;
}

/// Reads one Home's launcher leases and endpoint record without mutating it.
///
/// Leases are read through [readRuntimeLauncherRecord], which performs a plain
/// file read (no permission repair), so inventory stays strictly read-only.
Future<InventoryHomeState> readInventoryHomeState(
  String home, {
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final leases = <RuntimeLauncherRecord>[];
  final devDirectory = Directory(p.join(home, 'dev'));
  if (await devDirectory.exists()) {
    await for (final entity in devDirectory.list(followLinks: false)) {
      final match = RegExp(
        r'^runtime-launcher-(\d+)\.json$',
      ).firstMatch(p.basename(entity.path));
      if (match == null) continue;
      final port = int.tryParse(match.group(1)!);
      if (port == null) continue;
      try {
        final record = await readRuntimeLauncherRecord(home, port);
        if (record != null) leases.add(record);
      } on Object {
        // An unreadable lease is doctor territory; inventory reports only
        // records it can classify without guessing.
      }
    }
  }
  leases.sort((left, right) => left.agentPort.compareTo(right.agentPort));
  return InventoryHomeState(
    home: home,
    leases: leases,
    endpoint: await readInventoryEndpointRecord(
      home,
      processRunning: processRunning,
    ),
  );
}

/// Reads a Home's `.local_gateway_endpoint.json` as bounded evidence.
///
/// The record is evidence only. Inventory reads its loopback `pid`/`port` to
/// report the Agent PID and a stale endpoint, and never sends or prints the
/// Home credential it implies.
Future<InventoryEndpointRecord?> readInventoryEndpointRecord(
  String home, {
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final file = File(p.join(home, '.local_gateway_endpoint.json'));
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    if (decoded['schema'] != 1) return null;
    final host = decoded['host']?.toString() ?? '';
    if (!host.startsWith('127.0.0.1') && host != 'localhost' && host != '::1') {
      return null;
    }
    final rawPid = decoded['pid'];
    final ownerPid = rawPid is int ? rawPid : int.tryParse('$rawPid');
    if (ownerPid == null || ownerPid <= 0) return null;
    final rawPort = decoded['port'];
    return InventoryEndpointRecord(
      pid: ownerPid,
      port: rawPort is int ? rawPort : int.tryParse('$rawPort'),
      alive: await processRunning(ownerPid),
    );
  } on Object {
    return null;
  }
}

/// Reads every runtime diagnostics record below the runtime root.
Future<List<InventoryRuntimeRecord>> readInventoryRuntimeRecords(
  String runtimeRoot,
) async {
  final directories = await listInventoryDirectories(runtimeRoot);
  return mapBounded(directories, inventoryGitConcurrency, (directory) async {
    Map? locator;
    Map? legacy;
    try {
      final locatorFile = File(p.join(directory, 'startup-attempt.json'));
      if (await locatorFile.exists()) {
        final decoded = jsonDecode(await locatorFile.readAsString());
        if (decoded is Map) locator = decoded;
      }
    } on Object {
      locator = null;
    }
    try {
      final legacyFile = File(p.join(directory, 'runtime.json'));
      if (await legacyFile.exists()) {
        final decoded = jsonDecode(await legacyFile.readAsString());
        if (decoded is Map) legacy = decoded;
      }
    } on Object {
      legacy = null;
    }
    int? asInt(Object? value) =>
        value is int ? value : int.tryParse('${value ?? ''}');
    String? asHome(Object? value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    return InventoryRuntimeRecord(
      worktreeId: p.basename(directory),
      directory: directory,
      recordedHome: asHome(locator?['resolved_home']) ?? asHome(legacy?['sanad_home']),
      recordedAgentPort:
          asInt(locator?['agent_port']) ?? asInt(legacy?['agent_port']),
      recordedVmServicePort: asInt(legacy?['vm_service_port']),
      workspaceHash: locator?['workspace_hash']?.toString(),
    );
  });
}

