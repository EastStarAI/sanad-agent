part of '../../../sanad_dev_cli.dart';

/// How `sanad-dev inventory` classifies one worktree's runtime group.
enum InventoryRuntimeClass { managed, manual, stopped }

/// Liveness of one Test Home slot.
enum InventorySlotState { running, stopped }

/// Kind of record that `sanad-dev inventory` reports as an orphan.
enum InventoryOrphanKind { devHome, runtimeRecord, endpointRecord }

/// One Git worktree row.
///
/// Every field is read-only evidence: the row is a projection of
/// `git worktree list --porcelain`, one bounded `git status`, one bounded
/// `git rev-list`, and the deterministic Home the launcher would derive.
class InventoryWorktree {
  const InventoryWorktree({
    required this.path,
    required this.branch,
    required this.head,
    required this.detached,
    required this.locked,
    required this.lockReason,
    required this.prunable,
    required this.prunableReason,
    required this.missing,
    required this.isLinked,
    required this.primaryCheckout,
    required this.dirtyCount,
    required this.ahead,
    required this.behind,
    required this.worktreeId,
    required this.home,
    required this.recordedHome,
  });

  final String path;
  final String? branch;
  final String head;
  final bool detached;
  final bool locked;
  final String? lockReason;
  final bool prunable;
  final String? prunableReason;

  /// Whether the worktree directory itself is absent (pruned or moved).
  final bool missing;
  final bool isLinked;
  final bool primaryCheckout;
  final int dirtyCount;

  /// Commits behind and ahead of `origin/main`; null when it cannot be
  /// computed (no `origin/main`, no Git metadata, or a missing directory).
  final int? ahead;
  final int? behind;

  /// Worktree id the launcher derives for this path and branch.
  final String worktreeId;

  /// Home the launcher derives when no explicit Home is supplied.
  final String home;

  /// Home recorded by this worktree's runtime record, when one exists.
  final String? recordedHome;

  String get shortHead => head.length <= 8 ? head : head.substring(0, 8);

  String get displayBranch => detached ? 'detached' : (branch ?? '-');

  Map<String, Object?> toJson() => {
    'path': path,
    'branch': branch,
    'detached': detached,
    'head': head,
    'short_head': shortHead,
    'locked': locked,
    'lock_reason': lockReason,
    'prunable': prunable,
    'prunable_reason': prunableReason,
    'missing': missing,
    'is_linked': isLinked,
    'primary_checkout': primaryCheckout,
    'dirty_count': dirtyCount,
    'ahead': ahead,
    'behind': behind,
    'worktree_id': worktreeId,
    'home': home,
    'recorded_home': recordedHome,
  };
}

/// One discovered Flutter/DDS Client, attributed to the worktree id it is
/// registered under.
///
/// The attribution order is the launcher lease's recorded client PID, then the
/// same lease's launcher id/nonce pair, then the live Agent workspace hash of
/// the runtime record, then the source path. A Client whose live PID is not the
/// lease-recorded PID still resolves to its registered worktree and reports
/// [leasePidMismatch], because a stale Client PID in the lease must not hide a
/// running Client from the operator.
class InventoryClient {
  const InventoryClient({
    required this.worktreeId,
    required this.source,
    required this.deviceId,
    required this.vmServicePort,
    required this.pid,
    required this.gatewayPort,
    required this.home,
    required this.managed,
    required this.leasePidMismatch,
  });

  final String? worktreeId;
  final String source;
  final String? deviceId;
  final int vmServicePort;
  final int? pid;
  final int? gatewayPort;
  final String? home;

  /// Whether one live launcher lease claims this Client's identity.
  final bool managed;

  /// Whether the live Client PID differs from the PID the lease recorded.
  final bool leasePidMismatch;

  Map<String, Object?> toJson() => {
    'worktree_id': worktreeId,
    'source': source,
    'device': deviceId,
    'vm_service_port': vmServicePort,
    'pid': pid,
    'gateway_port': gatewayPort,
    'home': home,
    'managed': managed,
    'lease_pid_mismatch': leasePidMismatch,
  };
}

/// The runtime group of one worktree, including the primary runtime.
class InventoryRuntime {
  const InventoryRuntime({
    required this.worktreeId,
    required this.worktreePath,
    required this.home,
    required this.primary,
    required this.runtimeClass,
    required this.agentPort,
    required this.agentPid,
    required this.agentAlive,
    required this.vmServicePort,
    required this.sourceCommit,
    required this.clients,
    required this.leaseOwner,
    required this.leaseStatus,
    required this.leasePid,
    required this.leaseAlive,
    required this.detail,
  });

  final String worktreeId;

  /// Source root the runtime was launched from; null when no live evidence
  /// names one.
  final String? worktreePath;

  final String home;

  /// Whether this is the canonical `~/.sanad` runtime on port 58085.
  final bool primary;

  final InventoryRuntimeClass runtimeClass;
  final int? agentPort;
  final int? agentPid;
  final bool agentAlive;
  final int? vmServicePort;

  /// Short commit the runtime source started from; empty when unknown.
  final String sourceCommit;
  final List<InventoryClient> clients;
  final String? leaseOwner;
  final String? leaseStatus;
  final int? leasePid;
  final bool leaseAlive;

  /// Bounded, secret-free explanation of the classification.
  final String detail;

  String get shortCommit => sourceCommit.length <= 8
      ? sourceCommit
      : sourceCommit.substring(0, 8);

  List<String> get devices => clients
      .map((client) => client.deviceId ?? 'unknown')
      .toSet()
      .toList(growable: false)
    ..sort();

  Map<String, Object?> toJson() => {
    'worktree_id': worktreeId,
    'worktree_path': worktreePath,
    'home': home,
    'primary': primary,
    'class': runtimeClass.name,
    'agent_port': agentPort,
    'agent_pid': agentPid,
    'agent_alive': agentAlive,
    'vm_service_port': vmServicePort,
    'source_commit': sourceCommit,
    'lease_owner': leaseOwner,
    'lease_status': leaseStatus,
    'lease_pid': leasePid,
    'lease_alive': leaseAlive,
    'detail': detail,
    'clients': [for (final client in clients) client.toJson()],
  };
}

/// One absolute `~/.sanad-test*` Home slot and its recorded port.
class InventoryTestHome {
  const InventoryTestHome({
    required this.worktreeId,
    required this.home,
    required this.agentPort,
    required this.state,
  });

  final String worktreeId;
  final String home;
  final int? agentPort;
  final InventorySlotState state;

  Map<String, Object?> toJson() => {
    'worktree_id': worktreeId,
    'home': home,
    'agent_port': agentPort,
    'state': state.name,
  };
}

/// One orphaned record plus the exact command that would remove it.
///
/// `sanad-dev inventory` only prints the command; pruning stays a separate
/// decision.
class InventoryOrphan {
  const InventoryOrphan({
    required this.kind,
    required this.target,
    required this.reason,
    required this.cleanupCommand,
    required this.detail,
  });

  final InventoryOrphanKind kind;
  final String target;
  final String reason;
  final String cleanupCommand;
  final String? detail;

  Map<String, Object?> toJson() => {
    'kind': switch (kind) {
      InventoryOrphanKind.devHome => 'dev_home',
      InventoryOrphanKind.runtimeRecord => 'runtime_record',
      InventoryOrphanKind.endpointRecord => 'endpoint_record',
    },
    'target': target,
    'reason': reason,
    'cleanup_command': cleanupCommand,
    'detail': detail,
  };
}

/// The complete read-only inventory projection.
class SanadDevInventory {
  const SanadDevInventory({
    required this.generatedAt,
    required this.userHome,
    required this.primaryHome,
    required this.repositoryRoot,
    required this.callerWorktreeId,
    required this.worktrees,
    required this.runtimes,
    required this.clients,
    required this.testHomes,
    required this.orphans,
    required this.agentProbeTimedOut,
    required this.clientProbeTimedOut,
  });

  final DateTime generatedAt;
  final String userHome;
  final String primaryHome;
  final String repositoryRoot;
  final String callerWorktreeId;
  final List<InventoryWorktree> worktrees;
  final List<InventoryRuntime> runtimes;
  final List<InventoryClient> clients;
  final List<InventoryTestHome> testHomes;
  final List<InventoryOrphan> orphans;

  /// Whether the bounded Agent `/health` probe was abandoned.
  final bool agentProbeTimedOut;

  /// Whether the bounded Client process scan was abandoned.
  final bool clientProbeTimedOut;

  Iterable<InventoryRuntime> get liveRuntimes =>
      runtimes.where((runtime) => runtime.runtimeClass != InventoryRuntimeClass.stopped);

  Map<String, Object?> toJson() => {
    'schema': sanadDevInventorySchemaVersion,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'user_home': userHome,
    'primary_home': primaryHome,
    'repository_root': repositoryRoot,
    'caller_worktree_id': callerWorktreeId,
    'agent_probe_timed_out': agentProbeTimedOut,
    'client_probe_timed_out': clientProbeTimedOut,
    'summary': {
      'worktrees': worktrees.length,
      'runtimes': runtimes.length,
      'live_runtimes': liveRuntimes.length,
      'clients': clients.length,
      'test_homes': testHomes.length,
      'orphans': orphans.length,
    },
    'worktrees': [for (final worktree in worktrees) worktree.toJson()],
    'runtimes': [for (final runtime in runtimes) runtime.toJson()],
    'clients': [for (final client in clients) client.toJson()],
    'test_homes': [for (final slot in testHomes) slot.toJson()],
    'orphans': [for (final orphan in orphans) orphan.toJson()],
  };
}

/// Schema version of the `sanad-dev inventory --json` document.
const sanadDevInventorySchemaVersion = 1;

/// One parsed `git worktree list --porcelain` block.
class GitWorktreeEntry {
  const GitWorktreeEntry({
    required this.path,
    this.head = '',
    this.branch,
    this.detached = false,
    this.bare = false,
    this.locked = false,
    this.lockReason,
    this.prunable = false,
    this.prunableReason,
  });

  final String path;
  final String head;
  final String? branch;
  final bool detached;
  final bool bare;
  final bool locked;
  final String? lockReason;
  final bool prunable;
  final String? prunableReason;
}

/// Parses `git worktree list --porcelain` output into ordered entries.
///
/// Git emits one attribute per line and one blank line per worktree, with
/// `worktree <path>` first. `locked` and `prunable` carry an optional reason,
/// and a detached worktree emits `detached` instead of a branch ref.
List<GitWorktreeEntry> parseWorktreeListPorcelain(String output) {
  final entries = <GitWorktreeEntry>[];
  String? path;
  var head = '';
  String? branch;
  var detached = false;
  var bare = false;
  var locked = false;
  String? lockReason;
  var prunable = false;
  String? prunableReason;

  void flush() {
    final current = path;
    if (current == null) return;
    entries.add(
      GitWorktreeEntry(
        path: current,
        head: head,
        branch: branch,
        detached: detached,
        bare: bare,
        locked: locked,
        lockReason: lockReason,
        prunable: prunable,
        prunableReason: prunableReason,
      ),
    );
    path = null;
    head = '';
    branch = null;
    detached = false;
    bare = false;
    locked = false;
    lockReason = null;
    prunable = false;
    prunableReason = null;
  }

  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trimRight();
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (line.startsWith('worktree ')) {
      flush();
      path = line.substring('worktree '.length);
      continue;
    }
    if (line.startsWith('HEAD ')) {
      head = line.substring('HEAD '.length).trim();
      continue;
    }
    if (line.startsWith('branch ')) {
      final ref = line.substring('branch '.length).trim();
      branch = ref.startsWith('refs/heads/')
          ? ref.substring('refs/heads/'.length)
          : ref;
      continue;
    }
    if (line == 'detached') {
      detached = true;
      continue;
    }
    if (line == 'bare') {
      bare = true;
      continue;
    }
    if (line == 'locked') {
      locked = true;
      continue;
    }
    if (line.startsWith('locked ')) {
      locked = true;
      lockReason = line.substring('locked '.length).trim();
      continue;
    }
    if (line == 'prunable') {
      prunable = true;
      continue;
    }
    if (line.startsWith('prunable ')) {
      prunable = true;
      prunableReason = line.substring('prunable '.length).trim();
    }
  }
  flush();
  return entries;
}

/// Runs Git without a shell so paths with spaces never need quoting.
typedef SanadDevGitRunner =
    Future<ProcessResult> Function(String workingDirectory, List<String> args);

Future<ProcessResult> runSanadDevGit(
  String workingDirectory,
  List<String> args,
) => Process.run('git', ['-C', workingDirectory, ...args]);

/// Runs [action] over [items] with at most [limit] concurrent operations.
///
/// Inventory probes are bounded so a hung port or a large worktree set can
/// never serialize the whole report behind one slow child.
Future<List<R>> mapBounded<T, R>(
  List<T> items,
  int limit,
  Future<R> Function(T item) action,
) async {
  if (items.isEmpty) return const [];
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next;
      next = index + 1;
      if (index >= items.length) return;
      results[index] = await action(items[index]);
    }
  }

  final workers = <Future<void>>[
    for (var index = 0; index < (limit < items.length ? limit : items.length); index++)
      worker(),
  ];
  await Future.wait(workers);
  return results.cast<R>();
}

/// Quotes [value] for the platform shell of the printed cleanup command.
String inventoryShellQuote(String value) {
  if (Platform.isWindows) return "'${value.replaceAll("'", "''")}'";
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// The exact command that would remove one orphan target.
///
/// Inventory prints it and never runs it: pruning stale records stays a
/// separate, human-owned decision.
String inventoryRemoveCommand(String path, {required bool recursive}) {
  if (Platform.isWindows) {
    final literal = path.replaceAll("'", "''");
    return recursive
        ? "Remove-Item -LiteralPath '$literal' -Recurse -Force"
        : "Remove-Item -LiteralPath '$literal' -Force";
  }
  return 'rm ${recursive ? '-rf' : '-f'} ${inventoryShellQuote(path)}';
}

/// Collapses the user's home directory prefix to `~` for compact output.
String abbreviateUserHome(String path, String userHome) {
  if (userHome.isEmpty) return path;
  return equivalentPaths(path, userHome)
      ? '~'
      : p.isWithin(userHome, path)
      ? '~${path.substring(userHome.length)}'
      : path;
}
