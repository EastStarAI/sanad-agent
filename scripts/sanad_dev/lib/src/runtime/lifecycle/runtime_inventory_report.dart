part of '../../../sanad_dev_cli.dart';

/// `sanad-dev inventory` is strictly read-only.
///
/// It builds one projection of every worktree, its runtime, its Clients, its
/// Test Home slots, and the records that no longer belong to anything, then
/// prints it. It never starts, stops, deletes, repairs, or rewrites runtime
/// state, so it is always safe to run while another agent is working.
Future<void> handleSanadDevInventory({
  required bool showAll,
  required bool json,
  bool pullRequests = false,
}) async {
  final SanadDevInventory inventory;
  try {
    inventory = await collectSanadDevInventory(
      callerDirectory: _callerDirectory,
      pullRequests: pullRequests,
    );
  } on ProcessException {
    stderr.writeln(
      'Error: Git is not installed or could not be found in your PATH.',
    );
    stderr.writeln('Please install Git to use the sanad-dev CLI.');
    exitCode = 1;
    return;
  } on SanadDevInventoryException catch (error) {
    stderr.writeln('Error: ${error.message}');
    exitCode = 1;
    return;
  } on FileSystemException catch (error) {
    stderr.writeln('Error: ${error.message}');
    exitCode = 1;
    return;
  }
  if (json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(inventory.toJson()),
    );
    return;
  }
  printSanadDevInventory(inventory, showAll: showAll);
}

/// Renders the compact table by default and the full detail with `--all`.
void printSanadDevInventory(
  SanadDevInventory inventory, {
  required bool showAll,
}) {
  String abbreviate(String path) =>
      abbreviateUserHome(path, inventory.userHome);
  final runtimesByWorktree = {
    for (final runtime in inventory.runtimes) runtime.worktreeId: runtime,
  };
  final idWidth = _inventoryColumnWidth(
    [
      ...inventory.worktrees.map((worktree) => worktree.worktreeId),
      ...inventory.runtimes.map((runtime) => runtime.worktreeId),
      ...inventory.testHomes.map((slot) => slot.worktreeId),
      for (final client in inventory.clients) client.worktreeId ?? 'unknown',
    ],
    maximum: 40,
  );
  final branchWidth = _inventoryColumnWidth(
    [for (final worktree in inventory.worktrees) worktree.displayBranch],
    maximum: 24,
  );

  print('Inventory (read-only) - ${inventory.generatedAt.toIso8601String()}');
  print('Repository: ${abbreviate(inventory.repositoryRoot)}');
  print('Caller worktree: ${inventory.callerWorktreeId}');
  if (inventory.agentProbeTimedOut) {
    print(
      'Agent probe: timed out after '
      '${inventoryAgentProbeTimeout.inSeconds}s '
      '(runtime classes may read stopped)',
    );
  }
  if (inventory.clientProbeTimedOut) {
    print(
      'Client probe: timed out after '
      '${inventoryAgentProbeTimeout.inSeconds}s',
    );
  }
  print(_inventoryPullRequestLookupLine(inventory));

  if (inventory.worktrees.isNotEmpty) {
    print('');
    print('Worktrees (${inventory.worktrees.length})');
    for (final worktree in inventory.worktrees) {
      final runtime = runtimesByWorktree[worktree.worktreeId];
      final flags = <String>[
        'dirty=${worktree.dirtyCount}',
        'ahead=${worktree.ahead ?? '-'}',
        'behind=${worktree.behind ?? '-'}',
        'age=${formatInventoryAge(worktree.lastCommitAgeSeconds)}',
        'disk=${_inventoryDiskLabel(worktree)}',
        'upstream=${_inventoryUpstreamLabel(worktree)}',
        if (worktree.pullRequestLookup !=
            InventoryPullRequestLookup.notRequested)
          'pr=${_inventoryPullRequestLabel(worktree)}',
        'remove=${worktree.removal.verdict.name}',
        if (worktree.locked) 'locked',
        if (worktree.prunable) 'prunable',
        if (worktree.missing) 'missing',
      ];
      print(
        '  ${_inventoryCell(worktree.worktreeId, idWidth)}  '
        '${_inventoryCell(worktree.displayBranch, branchWidth)}  '
        '${worktree.shortHead}  '
        '${flags.join(' ')}  '
        'home=${abbreviate(runtime?.home ?? worktree.home)}  '
        'runtime=${runtime?.runtimeClass.name ?? 'stopped'}',
      );
      if (!showAll) continue;
      print('    head: ${worktree.head}');
      print('    path: ${worktree.path}');
      if (worktree.lockReason != null) {
        print('    locked: ${worktree.lockReason}');
      }
      if (worktree.prunableReason != null) {
        print('    prunable: ${worktree.prunableReason}');
      }
      print(
        '    tracking: ahead=${worktree.ahead ?? '-'} '
        'behind=${worktree.behind ?? '-'} of origin/main',
      );
      print(
        '    last commit: '
        '${worktree.lastCommitAt?.toIso8601String() ?? '-'} '
        '(${formatInventoryAge(worktree.lastCommitAgeSeconds)} ago)',
      );
      final diskLabel = worktree.diskBytes == null
          ? worktree.diskScan.name
          : '${formatInventoryBytes(worktree.diskBytes!)} '
                '(${worktree.diskScan.name})';
      print('    disk: $diskLabel');
      print('    upstream: ${_inventoryUpstreamDetail(worktree)}');
      if (worktree.pullRequest case final pullRequest?) {
        print(
          '    pull request: #${pullRequest.number} '
          '${pullRequest.state.toLowerCase()} '
          '${pullRequest.url ?? ''} '
          '(${pullRequest.source})',
        );
      } else if (worktree.pullRequestLookup ==
          InventoryPullRequestLookup.ok) {
        print('    pull request: none reported');
      }
      print(
        '    removal: ${worktree.removal.verdict.name} - '
        '${worktree.removal.reason}',
      );
      print(
        '    derived home: ${abbreviate(worktree.home)}'
        '${worktree.recordedHome == null ? '' : ' (recorded: ${abbreviate(worktree.recordedHome!)})'}',
      );
    }
  }

  final shownRuntimes = showAll
      ? inventory.runtimes
      : inventory.liveRuntimes.toList(growable: false);
  if (shownRuntimes.isNotEmpty) {
    print('');
    print(
      'Runtimes (${inventory.liveRuntimes.length} live'
      '${showAll ? ', ${inventory.runtimes.length} total' : ''})',
    );
    for (final runtime in shownRuntimes) {
      final devices = runtime.devices.isEmpty
          ? ''
          : ' (${runtime.devices.join(',')})';
      print(
        '  ${_inventoryCell(runtime.worktreeId, idWidth)}  '
        '${runtime.runtimeClass.name.padRight(8)}  '
        'agent=${runtime.agentPort ?? '-'}  '
        'pid=${_inventoryPidLabel(runtime)}  '
        'vm=${runtime.vmServicePort ?? '-'}  '
        'commit=${runtime.shortCommit.isEmpty ? '-' : runtime.shortCommit}  '
        'clients=${runtime.clients.length}$devices  '
        'lease=${_inventoryLeaseLabel(runtime)}  '
        'home=${abbreviate(runtime.home)}'
        '${runtime.primary ? '  primary' : ''}',
      );
      if (!showAll) continue;
      print('    detail: ${runtime.detail}');
      if (runtime.worktreePath != null) {
        print('    source: ${runtime.worktreePath}');
      }
      if (runtime.sourceCommit.isNotEmpty) {
        print('    source commit: ${runtime.sourceCommit}');
      }
      if (runtime.leasePid != null) {
        print(
          '    lease: ${runtime.leaseOwner ?? '-'} '
          'status=${runtime.leaseStatus ?? '-'} '
          'pid=${runtime.leasePid} '
          '${runtime.leaseAlive ? 'live' : 'stale'}',
        );
      }
    }
  }

  if (inventory.clients.isNotEmpty) {
    print('');
    print('Clients (${inventory.clients.length})');
    for (final client in inventory.clients) {
      print(
        '  ${_inventoryCell(client.worktreeId ?? 'unknown', idWidth)}  '
        'device=${client.deviceId ?? '-'}  '
        'vm=${client.vmServicePort}  '
        'pid=${client.pid ?? '-'}  '
        'gateway=${client.gatewayPort ?? '-'}  '
        '${client.managed ? 'lease-owned' : 'unmanaged'}'
        '${client.leasePidMismatch ? '  lease-pid-drift' : ''}',
      );
      if (!showAll) continue;
      print('    source: ${client.source}');
      if (client.home != null) {
        print('    home: ${abbreviate(client.home!)}');
      }
    }
  }

  if (inventory.testHomes.isNotEmpty) {
    print('');
    print('Test Homes (${inventory.testHomes.length})');
    for (final slot in inventory.testHomes) {
      print(
        '  ${_inventoryCell(slot.worktreeId, idWidth)}  '
        'home=${abbreviate(slot.home)}  '
        'agent=${slot.agentPort ?? '-'}  '
        'state=${slot.state.name}',
      );
      if (showAll) print('    path: ${slot.home}');
    }
  }

  if (inventory.orphans.isNotEmpty) {
    print('');
    print('Orphans (${inventory.orphans.length})');
    final reasonWidth = _inventoryColumnWidth(
      [for (final orphan in inventory.orphans) orphan.reason],
      maximum: 32,
    );
    for (final orphan in inventory.orphans) {
      final kind = _inventoryOrphanKindLabel(orphan.kind);
      if (showAll) {
        print('  ${kind.padRight(15)}  ${orphan.reason}');
        print('    target: ${orphan.target}');
        if (orphan.detail != null) print('    detail: ${orphan.detail}');
        print('    cleanup: ${orphan.cleanupCommand}');
        continue;
      }
      print(
        '  ${kind.padRight(15)}  '
        '${orphan.reason.padRight(reasonWidth)}  '
        '${orphan.cleanupCommand}',
      );
    }
    print('');
    print(
      'Orphans are reported only; sanad-dev inventory never prunes a record.',
    );
  }

  print('');
  print(
    'Total: ${inventory.worktrees.length} worktrees, '
    '${inventory.liveRuntimes.length} live runtimes, '
    '${inventory.clients.length} clients, '
    '${inventory.testHomes.length} test homes, '
    '${inventory.orphans.length} orphans, '
    '${inventory.removableWorktrees.length} safe to remove.',
  );
}

String _inventoryPidLabel(InventoryRuntime runtime) {
  if (runtime.agentPid == null) return '-';
  return '${runtime.agentPid}${runtime.agentAlive ? '/live' : '/dead'}';
}

String _inventoryLeaseLabel(InventoryRuntime runtime) {
  final owner = runtime.leaseOwner;
  if (owner == null || owner.isEmpty) return '-';
  final trimmed = owner.startsWith('launcher-')
      ? owner.substring('launcher-'.length)
      : owner;
  final short = trimmed.length <= 8 ? trimmed : trimmed.substring(0, 8);
  return '$short/${runtime.leaseStatus ?? '-'}';
}

String _inventoryOrphanKindLabel(InventoryOrphanKind kind) => switch (kind) {
  InventoryOrphanKind.devHome => 'dev_home',
  InventoryOrphanKind.runtimeRecord => 'runtime_record',
  InventoryOrphanKind.endpointRecord => 'endpoint_record',
};

/// One line that states whether the optional `gh` pull-request pass ran.
String _inventoryPullRequestLookupLine(SanadDevInventory inventory) {
  switch (inventory.pullRequestLookup) {
    case InventoryPullRequestLookup.notRequested:
      return 'PR lookup: skipped (pass --pr to query gh; answers are cached)';
    case InventoryPullRequestLookup.ok:
      return 'PR lookup: ok';
    case InventoryPullRequestLookup.timeout:
      return 'PR lookup: timed out after '
          '${inventoryPullRequestBudget.inSeconds}s';
    case InventoryPullRequestLookup.unavailable:
      final reason = inventory.pullRequestUnavailableReason;
      return 'PR lookup: unavailable${reason == null ? '' : ' ($reason)'}';
  }
}

String _inventoryDiskLabel(InventoryWorktree worktree) {
  if (worktree.diskScan == InventoryDiskScan.missing) return 'missing';
  final bytes = worktree.diskBytes;
  if (bytes == null) return worktree.diskScan.name;
  return formatInventoryBytes(bytes);
}

String _inventoryUpstreamLabel(InventoryWorktree worktree) {
  final upstream = worktree.upstream;
  if (upstream == null) return 'none';
  if (worktree.upstreamState == InventoryUpstreamState.gone) {
    return '$upstream/gone';
  }
  return '$upstream/+${worktree.upstreamAhead ?? '-'}/-${worktree.upstreamBehind ?? '-'}';
}

String _inventoryUpstreamDetail(InventoryWorktree worktree) {
  final upstream = worktree.upstream;
  if (upstream == null) return 'none configured';
  if (worktree.upstreamState == InventoryUpstreamState.gone) {
    return '$upstream (gone)';
  }
  return '$upstream (ahead ${worktree.upstreamAhead ?? '-'}, '
      'behind ${worktree.upstreamBehind ?? '-'})';
}

String _inventoryPullRequestLabel(InventoryWorktree worktree) {
  final pullRequest = worktree.pullRequest;
  final lookup = worktree.pullRequestLookup;
  if (lookup == InventoryPullRequestLookup.unavailable) return 'unavailable';
  if (lookup == InventoryPullRequestLookup.timeout) return 'timeout';
  if (pullRequest == null) return 'none';
  return '#${pullRequest.number}/${pullRequest.state.toLowerCase()}';
}

int _inventoryColumnWidth(Iterable<String> values, {required int maximum}) {
  var width = 0;
  for (final value in values) {
    if (value.length > width) width = value.length;
  }
  return width > maximum ? maximum : width;
}

/// Keeps a fixed-width column aligned while preserving a long row's suffix.
///
/// Worktree ids end with their eight-character path hash, so a truncated id
/// keeps the hash and drops the middle of the readable branch name.
String _inventoryCell(String value, int width) {
  if (value.length <= width) return value.padRight(width);
  if (width <= 1) return value.substring(value.length - width);
  return '…${value.substring(value.length - (width - 1))}';
}
