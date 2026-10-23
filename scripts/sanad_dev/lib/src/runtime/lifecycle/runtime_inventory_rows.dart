part of '../../../sanad_dev_cli.dart';

/// Attributes one discovered Client to the worktree id it is registered under.
///
/// A lease that names the live PID is authoritative. When the PID drifted but
/// the launcher id and runtime nonce still match, the Client keeps its
/// registered worktree and reports the mismatch instead of disappearing from
/// the report.
InventoryClient buildInventoryClient({
  required ClientInstance client,
  required List<RuntimeLauncherRecord> leases,
  required List<AgentInstance> agents,
  required List<InventoryWorktree> rows,
  required List<InventoryRuntimeRecord> records,
}) {
  final profile = client.launchProfile;
  final gateway = Uri.tryParse(profile?.define('LOCAL_GATEWAY_URL') ?? '');
  final home = profile?.define('SANAD_HOME');
  final launcherId = profile?.define('SANAD_DEV_LAUNCHER_ID');
  final runtimeNonce = profile?.define('SANAD_DEV_RUNTIME_NONCE');
  final pid = client.pid;

  final byPid = leases
      .where((lease) => pid != null && lease.clientPids.contains(pid))
      .firstOrNull;
  final byIdentity = byPid == null
      ? leases
            .where(
              (lease) =>
                  launcherId != null &&
                  launcherId.isNotEmpty &&
                  runtimeNonce != null &&
                  runtimeNonce.isNotEmpty &&
                  lease.launcherId == launcherId &&
                  lease.runtimeNonce == runtimeNonce,
            )
            .firstOrNull
      : null;
  final lease = byPid ?? byIdentity;
  final agent = gateway?.hasPort == true
      ? agents.where((instance) => instance.port == gateway!.port).firstOrNull
      : null;

  return InventoryClient(
    worktreeId:
        worktreeIdForLease(lease, rows, records) ??
        worktreeIdForWorkspaceHash(agent?.workspaceHash, rows, records) ??
        clientSourceWorktreeId(client.path),
    source: Directory(client.path).parent.path,
    deviceId: client.deviceId,
    vmServicePort: client.port,
    pid: pid,
    gatewayPort: gateway?.hasPort == true ? gateway?.port : null,
    home: home,
    managed: lease != null,
    leasePidMismatch: byIdentity != null,
  );
}

/// Resolves the worktree id one lease was registered under.
String? worktreeIdForLease(
  RuntimeLauncherRecord? lease,
  List<InventoryWorktree> rows,
  List<InventoryRuntimeRecord> records,
) {
  if (lease == null) return null;
  final bySource = rows
      .where((row) => equivalentPaths(lease.sourceRoot, row.path))
      .firstOrNull;
  if (bySource != null) return bySource.worktreeId;
  return worktreeIdForWorkspaceHash(lease.workspaceHash, rows, records);
}

/// Resolves a worktree id from a runtime record or worktree hash suffix.
String? worktreeIdForWorkspaceHash(
  String? workspaceHash,
  List<InventoryWorktree> rows,
  List<InventoryRuntimeRecord> records,
) {
  final hash = workspaceHash?.trim();
  if (hash == null || hash.isEmpty) return null;
  final byRecord = records
      .where((record) => record.workspaceHash == hash)
      .firstOrNull;
  if (byRecord != null) return byRecord.worktreeId;
  return rows
      .where((row) => row.worktreeId.endsWith('-$hash'))
      .firstOrNull
      ?.worktreeId;
}

/// Builds the runtime row for one existing worktree.
Future<InventoryRuntime> buildInventoryWorktreeRuntime({
  required InventoryWorktree row,
  required String primaryHome,
  required List<RuntimeLauncherRecord> leases,
  required List<AgentInstance> agents,
  required List<InventoryClient> clients,
  required Map<String, InventoryHomeState> homeStatesByPath,
  required bool Function(RuntimeLauncherRecord? lease) leaseIsAlive,
}) async {
  final hashSuffix = worktreeHashSuffix(row.path);
  final worktreeLeases =
      leases
          .where(
            (lease) =>
                equivalentPaths(lease.sourceRoot, row.path) ||
                ((row.recordedHome != null) &&
                    equivalentPaths(lease.sanadHome, row.recordedHome!)),
          )
          .toList()
        ..sort((left, right) {
          final byLiveness = (leaseIsAlive(right) ? 1 : 0) - (leaseIsAlive(left) ? 1 : 0);
          return byLiveness != 0
              ? byLiveness
              : right.updatedAt.compareTo(left.updatedAt);
        });
  final lease = worktreeLeases.firstOrNull;
  final agent =
      agents.where((instance) => instance.workspaceHash == hashSuffix).firstOrNull ??
      (lease == null
          ? null
          : agents
                .where(
                  (instance) =>
                      instance.port == lease.agentPort &&
                      equivalentPaths(instance.sanadHome, lease.sanadHome),
                )
                .firstOrNull);
  final home = lease?.sanadHome ?? row.recordedHome ?? row.home;
  final attached = clients
      .where(
        (client) =>
            client.worktreeId == row.worktreeId ||
            (agent != null && client.gatewayPort == agent.port),
      )
      .toList(growable: false);
  return buildInventoryRuntimeRow(
    worktreeId: row.worktreeId,
    worktreePath: lease?.sourceRoot ?? row.path,
    home: home,
    primaryHome: primaryHome,
    lease: lease,
    leaseAlive: leaseIsAlive(lease),
    agent: agent,
    endpoint: homeStatesByPath[home]?.endpoint,
    sourceCommit: await resolveStatusSourceCommit(
      recordedCommit: lease?.sourceCommit ?? '',
      readHeadCommit: () async => row.head,
    ),
    clients: attached,
  );
}

/// Builds a runtime row for a record whose worktree no longer exists.
Future<InventoryRuntime?> buildInventoryDetachedRuntime({
  required InventoryRuntimeRecord record,
  required String primaryHome,
  required List<AgentInstance> agents,
  required List<RuntimeLauncherRecord> leases,
  required List<InventoryClient> clients,
  required Map<String, InventoryHomeState> homeStatesByPath,
  required bool Function(RuntimeLauncherRecord? lease) leaseIsAlive,
}) async {
  final agent = agents
      .where((instance) => instance.workspaceHash == record.workspaceHash)
      .firstOrNull;
  final lease =
      leases
          .where(
            (candidate) =>
                candidate.workspaceHash == record.workspaceHash &&
                (record.recordedAgentPort == null ||
                    candidate.agentPort == record.recordedAgentPort),
          )
          .firstOrNull;
  if (agent == null && !leaseIsAlive(lease)) return null;
  final attached = clients
      .where(
        (client) =>
            client.worktreeId == record.worktreeId ||
            (agent != null && client.gatewayPort == agent.port),
      )
      .toList(growable: false);
  final home = lease?.sanadHome ?? record.recordedHome ?? '';
  return buildInventoryRuntimeRow(
    worktreeId: record.worktreeId,
    worktreePath: lease?.sourceRoot ?? record.recordedHome,
    home: home,
    primaryHome: primaryHome,
    lease: lease,
    leaseAlive: leaseIsAlive(lease),
    agent: agent,
    endpoint: homeStatesByPath[home]?.endpoint,
    sourceCommit: lease?.sourceCommit ?? '',
    clients: attached,
  );
}

/// Shared runtime classification used by both worktree and detached rows.
InventoryRuntime buildInventoryRuntimeRow({
  required String worktreeId,
  required String? worktreePath,
  required String home,
  required String primaryHome,
  required RuntimeLauncherRecord? lease,
  required bool leaseAlive,
  required AgentInstance? agent,
  required InventoryEndpointRecord? endpoint,
  required String sourceCommit,
  required List<InventoryClient> clients,
}) {
  final live = agent != null || clients.isNotEmpty;
  final leaseHealthy =
      lease != null &&
      leaseAlive &&
      const {
        'running',
        'agent-only',
        'client-only',
        'switching',
      }.contains(lease.status);
  final InventoryRuntimeClass runtimeClass;
  final String detail;
  if (!live) {
    runtimeClass = InventoryRuntimeClass.stopped;
    detail = lease == null
        ? 'no live Agent or Client'
        : 'launcher lease present without a live Agent or Client';
  } else if (leaseHealthy) {
    runtimeClass = InventoryRuntimeClass.managed;
    detail = 'launcher lease is live';
  } else {
    runtimeClass = InventoryRuntimeClass.manual;
    detail = lease == null
        ? 'no launcher lease'
        : leaseAlive
        ? 'launcher lease status is ${lease.status}'
        : 'launcher lease PID ${lease.launcherPid} is not running';
  }
  final agentPort = agent?.port ?? lease?.agentPort;
  final agentPid = endpoint != null &&
          endpoint.alive &&
          agent != null &&
          endpoint.port == agent.port
      ? endpoint.pid
      : null;
  return InventoryRuntime(
    worktreeId: worktreeId,
    worktreePath: worktreePath,
    home: home,
    primary:
        primaryHome.isNotEmpty &&
        equivalentPaths(home, primaryHome) &&
        agentPort == canonicalPrimaryAgentPort &&
        live,
    runtimeClass: runtimeClass,
    agentPort: agentPort,
    agentPid: agentPid,
    agentAlive: agent != null,
    vmServicePort:
        clients.firstOrNull?.vmServicePort ??
        lease?.vmServicePorts.firstOrNull,
    sourceCommit: sourceCommit,
    clients: clients,
    leaseOwner: lease?.launcherId,
    leaseStatus: lease?.status,
    leasePid: lease?.launcherPid,
    leaseAlive: leaseAlive,
    detail: detail,
  );
}

/// Derives a worktree id from a Client source path when no lease names it.
String? clientSourceWorktreeId(String clientPath) {
  final trimmed = clientPath.trim();
  if (trimmed.isEmpty || trimmed == 'Unknown workspace') return null;
  final sourceRoot = Directory(trimmed).parent.path;
  if (sourceRoot == '.' || sourceRoot.isEmpty) return null;
  return deriveWorktreeId(sourceRoot, 'HEAD');
}

/// Builds the orphan list: dead Homes, dead runtime records, dead endpoints.
List<InventoryOrphan> buildInventoryOrphans({
  required String userHome,
  required List<String> devHomes,
  required List<InventoryRuntimeRecord> records,
  required List<InventoryHomeState> homeStates,
  required List<InventoryWorktree> worktrees,
  required List<RuntimeLauncherRecord> leases,
  required List<AgentInstance> agents,
  required bool Function(RuntimeLauncherRecord? lease) leaseIsAlive,
}) {
  final knownIds = worktrees.map((row) => row.worktreeId).toSet();
  final statesByHome = {for (final state in homeStates) state.home: state};
  final orphans = <InventoryOrphan>[];

  for (final home in devHomes) {
    final worktreeId = p.basename(home);
    if (knownIds.contains(worktreeId)) continue;
    final state = statesByHome[home];
    if (state != null && state.leases.any(leaseIsAlive)) continue;
    orphans.add(
      InventoryOrphan(
        kind: InventoryOrphanKind.devHome,
        target: home,
        reason: 'no matching worktree',
        cleanupCommand: inventoryRemoveCommand(home, recursive: true),
        detail: 'Home ${abbreviateUserHome(home, userHome)} belongs to no current worktree id',
      ),
    );
  }

  for (final record in records) {
    final agent = agents
        .where((instance) => instance.workspaceHash == record.workspaceHash)
        .firstOrNull;
    final lease = leases
        .where(
          (candidate) =>
              candidate.workspaceHash == record.workspaceHash &&
              (record.recordedAgentPort == null ||
                  candidate.agentPort == record.recordedAgentPort),
        )
        .firstOrNull;
    if (!knownIds.contains(record.worktreeId)) {
      orphans.add(
        InventoryOrphan(
          kind: InventoryOrphanKind.runtimeRecord,
          target: record.directory,
          reason: 'no matching worktree',
          cleanupCommand: inventoryRemoveCommand(
            record.directory,
            recursive: true,
          ),
          detail: 'Runtime record ${record.worktreeId} belongs to no current worktree id',
        ),
      );
      continue;
    }
    if (lease != null && !leaseIsAlive(lease) && agent == null) {
      orphans.add(
        InventoryOrphan(
          kind: InventoryOrphanKind.runtimeRecord,
          target: record.directory,
          reason: 'dead launcher pid ${lease.launcherPid}',
          cleanupCommand: inventoryRemoveCommand(
            record.directory,
            recursive: true,
          ),
          detail:
              'Stale launcher lease on port ${lease.agentPort}; '
              'run "sanad-dev doctor --fix" before removing this record',
        ),
      );
    }
  }

  for (final state in homeStates) {
    final ownerPid = state.staleEndpointPid;
    if (ownerPid == null) continue;
    final path = p.join(state.home, '.local_gateway_endpoint.json');
    orphans.add(
      InventoryOrphan(
        kind: InventoryOrphanKind.endpointRecord,
        target: path,
        reason: 'dead endpoint pid $ownerPid',
        cleanupCommand: inventoryRemoveCommand(path, recursive: false),
        detail: 'Home ${abbreviateUserHome(state.home, userHome)} names a daemon that is not running',
      ),
    );
  }

  orphans.sort((left, right) {
    final byKind = left.kind.index.compareTo(right.kind.index);
    return byKind != 0 ? byKind : left.target.compareTo(right.target);
  });
  return orphans;
}
