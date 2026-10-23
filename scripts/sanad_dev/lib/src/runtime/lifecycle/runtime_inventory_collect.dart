part of '../../../sanad_dev_cli.dart';

/// Bound for the read-only Agent `/health` probe and the Client process scan.
///
/// `sanad-dev inventory` must never block on a hung port: the probe reuses the
/// existing 150 ms loopback timeouts per attempt and is abandoned as a whole
/// after this deadline.
const inventoryAgentProbeTimeout = Duration(seconds: 5);

/// Maximum number of concurrent Git children, Home reads, and record reads.
const inventoryGitConcurrency = 8;

/// Upper bound on the loopback `/health` ports one inventory may probe.
///
/// Only ports named by a live lease or a runtime record are candidates; the cap
/// keeps a long history of stale records from growing the probe.
const inventoryMaxProbePorts = 64;

/// Raised when the read-only inventory cannot be built at all.
class SanadDevInventoryException implements Exception {
  const SanadDevInventoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds the complete read-only projection for `sanad-dev inventory`.
///
/// The collector never starts, stops, repairs, deletes, or rewrites runtime
/// state: it reads Git metadata, Home records, leases, and endpoint records,
/// then probes loopback `/health` and the OS process table under one bounded
/// deadline.
Future<SanadDevInventory> collectSanadDevInventory({
  required String callerDirectory,
  Map<String, String>? environment,
  SanadDevGitRunner git = runSanadDevGit,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<List<AgentInstance>> Function(
    SanadDevRuntime runtime,
    Iterable<int> ports,
  )?
  probeAgents,
  Future<List<ClientInstance>> Function(SanadDevRuntime runtime)?
  discoverClients,
  Duration probeTimeout = inventoryAgentProbeTimeout,
  DateTime Function()? clock,
}) async {
  final env = environment ?? Platform.environment;
  final userHome = resolveUserHomeDirectory(env);
  final primaryHome = resolveDefaultUserSanadHome(env);
  final runtimeRoot = resolveSanadDevRuntimeRoot(env);
  final devHomesRoot = p.join(primaryHome, 'dev', 'homes');

  final callerToplevel =
      await readInventoryGitText(git, callerDirectory, [
        'rev-parse',
        '--show-toplevel',
      ]) ??
      callerDirectory;
  final commonDirectory = await readInventoryGitText(git, callerDirectory, [
    'rev-parse',
    '--git-common-dir',
  ]);
  final mainCheckout = resolveInventoryMainCheckout(
    commonDirectory: commonDirectory,
    callerToplevel: callerToplevel,
  );
  final listOutput = await readInventoryGitText(git, callerDirectory, [
    'worktree',
    'list',
    '--porcelain',
  ]);
  if (listOutput == null) {
    throw const SanadDevInventoryException(
      'Could not read "git worktree list --porcelain" for this repository.',
    );
  }
  final entries = parseWorktreeListPorcelain(listOutput);
  if (entries.isEmpty) {
    throw const SanadDevInventoryException(
      'Git reported no worktrees for this repository.',
    );
  }
  final repositoryRoot = resolveInventoryRepositoryRoot(
    mainCheckout,
    callerToplevel,
  );

  final records = await readInventoryRuntimeRecords(runtimeRoot);
  final devHomes = await listInventoryDirectories(devHomesRoot);
  final testHomeDirectories = await listInventoryTestHomes(userHome);
  final recordedHomes = records
      .map((record) => record.recordedHome)
      .whereType<String>();
  final homes = <String>{
    primaryHome,
    ...devHomes,
    ...testHomeDirectories,
    ...recordedHomes,
  }.toList()..sort();

  final homeStates = await mapBounded(
    homes,
    inventoryGitConcurrency,
    (home) => readInventoryHomeState(home, processRunning: processRunning),
  );
  final homeStatesByPath = {for (final state in homeStates) state.home: state};
  final leases = [for (final state in homeStates) ...state.leases];
  final leaseLiveness = <String, bool>{};
  final liveness = await mapBounded(
    leases,
    inventoryGitConcurrency,
    (lease) => processRunning(lease.launcherPid),
  );
  for (var index = 0; index < leases.length; index++) {
    leaseLiveness[inventoryLeaseKey(leases[index])] = liveness[index];
  }
  bool leaseIsAlive(RuntimeLauncherRecord? lease) =>
      lease != null && (leaseLiveness[inventoryLeaseKey(lease)] ?? false);

  // Probing is bounded twice: only ports that some record or lease names are
  // probed (never the whole 58085-58185 range), and the candidate list is
  // capped so a long history of stale records cannot grow the probe.
  final candidatePorts = <int>{canonicalPrimaryAgentPort};
  for (final lease in leases) {
    candidatePorts.add(lease.agentPort);
  }
  for (final record in records) {
    final port = record.recordedAgentPort;
    if (port != null && port > 0) candidatePorts.add(port);
  }
  final probePorts = candidatePorts.toList()..sort();
  final boundedPorts = probePorts.length <= inventoryMaxProbePorts
      ? probePorts
      : probePorts.sublist(0, inventoryMaxProbePorts);

  final callerEntry = entries
      .where((entry) => equivalentPaths(entry.path, callerToplevel))
      .firstOrNull;
  final callerBranch =
      callerEntry?.branch ??
      await readInventoryGitText(git, callerDirectory, [
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ]) ??
      'HEAD';
  final callerIsLinked = callerEntry != null
      ? !equivalentPaths(callerEntry.path, mainCheckout)
      : !equivalentPaths(callerToplevel, mainCheckout);
  final callerWorktreeId = deriveWorktreeId(callerToplevel, callerBranch);
  // Built without allocating a port: the collector never binds a socket, so the
  // runtime carries zero ports and exists only to give discovery its credential
  // candidate set and workspace identity.
  final callerRuntime = SanadDevRuntime(
    workspaceRoot: callerToplevel,
    repositoryRoot: repositoryRoot,
    worktreeId: callerWorktreeId,
    isLinkedWorktree: callerIsLinked,
    usesPrimaryResources: !callerIsLinked,
    agentPort: 0,
    vmServicePort: 0,
    sanadHome: resolveSanadDevHome(
      isLinkedWorktree: callerIsLinked,
      userHome: userHome,
      worktreeId: callerWorktreeId,
    ),
    runtimeDirectory: p.join(runtimeRoot, callerWorktreeId),
    branch: callerBranch,
  );
  final additionalHomes = <String>{
    ...testHomeDirectories,
    ...recordedHomes,
    ...devHomes,
  }.toList()..sort();

  var agentProbeTimedOut = false;
  var clientProbeTimedOut = false;
  var agents = const <AgentInstance>[];
  var clients = const <ClientInstance>[];
  try {
    agents = await (probeAgents?.call(callerRuntime, boundedPorts) ??
            discoverAgentInstances(
              runtime: callerRuntime,
              candidatePorts: boundedPorts,
              additionalHomes: additionalHomes,
            ))
        .timeout(probeTimeout);
  } on TimeoutException {
    agentProbeTimedOut = true;
  }
  try {
    clients = await (discoverClients?.call(callerRuntime) ??
            discoverClientInstances(runtime: callerRuntime))
        .timeout(probeTimeout);
  } on TimeoutException {
    clientProbeTimedOut = true;
  }

  final recordsById = {
    for (final record in records) record.worktreeId: record,
  };
  final rows = await mapBounded(entries, inventoryGitConcurrency, (entry) async {
    final missing = !Directory(entry.path).existsSync();
    final isLinked = !equivalentPaths(entry.path, mainCheckout);
    final worktreeId = deriveWorktreeId(entry.path, entry.branch ?? 'HEAD');
    var dirtyCount = 0;
    int? ahead;
    int? behind;
    if (!missing && !entry.bare) {
      final statusOutput = await readInventoryGitText(git, entry.path, [
        '--no-optional-locks',
        'status',
        '--porcelain',
      ]);
      if (statusOutput != null) {
        dirtyCount = statusOutput
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .length;
      }
      final tracking = await readInventoryGitText(git, entry.path, [
        'rev-list',
        '--left-right',
        '--count',
        'origin/main...HEAD',
      ]);
      final counts = tracking
          ?.split(RegExp(r'\s+'))
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      if (counts != null && counts.length == 2) {
        behind = int.tryParse(counts[0]);
        ahead = int.tryParse(counts[1]);
      }
    }
    return InventoryWorktree(
      path: entry.path,
      branch: entry.branch,
      head: entry.head,
      detached: entry.detached,
      locked: entry.locked,
      lockReason: entry.lockReason,
      prunable: entry.prunable,
      prunableReason: entry.prunableReason,
      missing: missing,
      isLinked: isLinked,
      primaryCheckout: equivalentPaths(entry.path, mainCheckout),
      dirtyCount: dirtyCount,
      ahead: ahead,
      behind: behind,
      worktreeId: worktreeId,
      home: resolveSanadDevHome(
        isLinkedWorktree: isLinked,
        userHome: userHome,
        worktreeId: worktreeId,
      ),
      recordedHome: recordsById[worktreeId]?.recordedHome,
    );
  });

  final inventoryClients = [
    for (final client in clients)
      buildInventoryClient(
        client: client,
        leases: leases,
        agents: agents,
        rows: rows,
        records: records,
      ),
  ]..sort((left, right) => left.vmServicePort.compareTo(right.vmServicePort));

  final runtimes = <InventoryRuntime>[];
  for (final row in rows) {
    runtimes.add(
      await buildInventoryWorktreeRuntime(
        row: row,
        primaryHome: primaryHome,
        leases: leases,
        agents: agents,
        clients: inventoryClients,
        homeStatesByPath: homeStatesByPath,
        leaseIsAlive: leaseIsAlive,
      ),
    );
  }
  final knownIds = rows.map((row) => row.worktreeId).toSet();
  final claimedHashes = {
    for (final row in rows) worktreeHashSuffix(row.path),
  };
  for (final record in records) {
    if (knownIds.contains(record.worktreeId)) continue;
    // A record for another branch of an existing worktree shares that
    // worktree's path hash, so its live Agent already belongs to that worktree
    // row; it is a stale record, not a second runtime.
    if (claimedHashes.contains(record.workspaceHash)) continue;
    final runtime = await buildInventoryDetachedRuntime(
      record: record,
      primaryHome: primaryHome,
      agents: agents,
      leases: leases,
      clients: inventoryClients,
      homeStatesByPath: homeStatesByPath,
      leaseIsAlive: leaseIsAlive,
    );
    if (runtime != null) runtimes.add(runtime);
  }

  final testHomes = <InventoryTestHome>[];
  for (final record in records) {
    final home = record.recordedHome;
    if (home == null || !isInventoryTestHome(home, userHome)) continue;
    final state = homeStatesByPath[home];
    final running =
        agents.any(
          (agent) =>
              equivalentPaths(agent.sanadHome, home) &&
              (record.recordedAgentPort == null ||
                  agent.port == record.recordedAgentPort),
        ) ||
        (state?.leases.any(leaseIsAlive) ?? false);
    // A Test Home slot belongs to a worktree: a stale record of a deleted
    // worktree is reported once as an orphan, not as a slot.
    if (!knownIds.contains(record.worktreeId) && !running) continue;
    testHomes.add(
      InventoryTestHome(
        worktreeId: record.worktreeId,
        home: home,
        agentPort: record.recordedAgentPort,
        state: running ? InventorySlotState.running : InventorySlotState.stopped,
      ),
    );
  }
  testHomes.sort((left, right) => left.worktreeId.compareTo(right.worktreeId));

  return SanadDevInventory(
    generatedAt: (clock ?? DateTime.now)().toUtc(),
    userHome: userHome,
    primaryHome: primaryHome,
    repositoryRoot: repositoryRoot,
    callerWorktreeId: callerWorktreeId,
    worktrees: rows,
    runtimes: runtimes,
    clients: inventoryClients,
    testHomes: testHomes,
    orphans: buildInventoryOrphans(
      userHome: userHome,
      devHomes: devHomes,
      records: records,
      homeStates: homeStates,
      worktrees: rows,
      leases: leases,
      agents: agents,
      leaseIsAlive: leaseIsAlive,
    ),
    agentProbeTimedOut: agentProbeTimedOut,
    clientProbeTimedOut: clientProbeTimedOut,
  );
}

/// Runs one Git command and returns trimmed stdout, or null on a nonzero exit.
Future<String?> readInventoryGitText(
  SanadDevGitRunner git,
  String workingDirectory,
  List<String> args,
) async {
  final result = await git(workingDirectory, args);
  if (result.exitCode != 0) return null;
  return result.stdout.toString().trim();
}

/// Resolves the primary checkout from `git rev-parse --git-common-dir`.
String resolveInventoryMainCheckout({
  required String? commonDirectory,
  required String callerToplevel,
}) {
  final raw = commonDirectory?.trim();
  if (raw == null || raw.isEmpty) return callerToplevel;
  final absolute = isAbsoluteFileSystemPath(raw)
      ? raw
      : p.join(callerToplevel, raw);
  final normalized = p.canonicalize(absolute);
  return p.basename(normalized) == '.git' ? p.dirname(normalized) : normalized;
}

/// Product repository root below the primary checkout, or the checkout itself.
String resolveInventoryRepositoryRoot(
  String mainCheckout,
  String callerToplevel,
) {
  try {
    return resolveRepositoryRoot(mainCheckout);
  } on StateError {
    return callerToplevel;
  }
}

/// Lists the immediate subdirectories of [path]; missing paths yield no rows.
Future<List<String>> listInventoryDirectories(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) return const [];
  final entries = <String>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    entries.add(entity.path);
  }
  entries.sort();
  return entries;
}

/// Lists absolute Test Home directories directly below the user's home.
Future<List<String>> listInventoryTestHomes(String userHome) async {
  final directory = Directory(userHome);
  if (!await directory.exists()) return const [];
  final entries = <String>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    if (!p.basename(entity.path).startsWith('.sanad-test')) continue;
    entries.add(entity.path);
  }
  entries.sort();
  return entries;
}

/// Whether [home] is an absolute `~/.sanad-test*` Test Home path.
bool isInventoryTestHome(String home, String userHome) =>
    p.isWithin(userHome, home) &&
    p.basename(home).startsWith('.sanad-test');

/// Stable key for one launcher lease across Homes and ports.
String inventoryLeaseKey(RuntimeLauncherRecord lease) =>
    '${canonicalComparablePath(lease.sanadHome)}|${lease.agentPort}';

