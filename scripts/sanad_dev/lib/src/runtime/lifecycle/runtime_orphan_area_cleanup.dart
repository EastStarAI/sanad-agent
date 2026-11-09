part of '../../../sanad_dev_cli.dart';

/// Schema version of the `sanad-dev cleanup-orphans --json` document.
const sanadDevOrphanCleanupSchemaVersion = 1;

/// What the plan will do with one orphan target.
enum OrphanCleanupAction { delete, refuse }

/// What happened to one planned target when the plan ran.
enum OrphanCleanupStatus { deleted, absent, failed, notAttempted }

/// One orphan target and the decision the plan made about it.
class SanadDevOrphanCleanupEntry {
  const SanadDevOrphanCleanupEntry({
    required this.kind,
    required this.target,
    required this.reason,
    required this.action,
    this.refusal,
    this.detail,
  });

  final InventoryOrphanKind kind;
  final String target;

  /// The read-only inventory's own reason for calling this target an orphan.
  final String reason;
  final OrphanCleanupAction action;

  /// Why the plan refuses this target, when it does.
  final String? refusal;
  final String? detail;

  bool get deletable => action == OrphanCleanupAction.delete;

  Map<String, Object?> toJson() => {
    'kind': switch (kind) {
      InventoryOrphanKind.devHome => 'dev_home',
      InventoryOrphanKind.runtimeRecord => 'runtime_record',
      InventoryOrphanKind.endpointRecord => 'endpoint_record',
    },
    'target': target,
    'reason': reason,
    'action': action.name,
    'refusal': refusal,
    'detail': detail,
  };
}

/// The complete dry-run decision for one projection of the dev area.
class SanadDevOrphanCleanupPlan {
  const SanadDevOrphanCleanupPlan({
    required this.generatedAt,
    required this.devArea,
    required this.userHome,
    required this.primaryHome,
    required this.entries,
  });

  final DateTime generatedAt;
  final String devArea;
  final String userHome;
  final String primaryHome;
  final List<SanadDevOrphanCleanupEntry> entries;

  Iterable<SanadDevOrphanCleanupEntry> get deletable =>
      entries.where((entry) => entry.deletable);

  Iterable<SanadDevOrphanCleanupEntry> get refused =>
      entries.where((entry) => !entry.deletable);

  Map<String, Object?> toJson({bool confirm = false}) => {
    'schema': sanadDevOrphanCleanupSchemaVersion,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'confirm': confirm,
    'dev_area': devArea,
    'user_home': userHome,
    'primary_home': primaryHome,
    'summary': {
      'targets': entries.length,
      'deletable': deletable.length,
      'refused': refused.length,
    },
    'targets': [for (final entry in entries) entry.toJson()],
  };
}

/// What happened to one deletable target.
class SanadDevOrphanCleanupResult {
  const SanadDevOrphanCleanupResult({
    required this.entry,
    required this.status,
    this.error,
  });

  final SanadDevOrphanCleanupEntry entry;
  final OrphanCleanupStatus status;
  final String? error;

  Map<String, Object?> toJson() => {
    'kind': entry.toJson()['kind'],
    'target': entry.target,
    'status': switch (status) {
      OrphanCleanupStatus.notAttempted => 'not_attempted',
      OrphanCleanupStatus.deleted => 'deleted',
      OrphanCleanupStatus.absent => 'absent',
      OrphanCleanupStatus.failed => 'failed',
    },
    'error': error,
  };
}

/// The confirmed run of one plan.
class SanadDevOrphanCleanupOutcome {
  const SanadDevOrphanCleanupOutcome({
    required this.plan,
    required this.results,
  });

  final SanadDevOrphanCleanupPlan plan;
  final List<SanadDevOrphanCleanupResult> results;

  int count(OrphanCleanupStatus status) =>
      results.where((result) => result.status == status).length;

  Map<String, Object?> toJson() {
    final base = plan.toJson(confirm: true);
    final summary = Map<String, Object?>.from(base['summary']! as Map);
    return {
      ...base,
      'summary': {
        ...summary,
        'deleted': count(OrphanCleanupStatus.deleted),
        'absent': count(OrphanCleanupStatus.absent),
        'failed': count(OrphanCleanupStatus.failed),
        'not_attempted': count(OrphanCleanupStatus.notAttempted),
      },
      'results': [for (final result in results) result.toJson()],
    };
  }
}

/// The nearest `~/.sanad-test*` ancestor of [target], including itself.
///
/// A Test Home is a whole Home directory the operator owns; nothing inside one
/// is an orphan this command may delete.
String? inventoryTestHomeAncestor(String target, String userHome) {
  final canonicalUserHome = inventoryContainmentPath(userHome);
  var current = inventoryContainmentPath(target);
  while (true) {
    if (p.basename(current).startsWith('.sanad-test') &&
        p.isWithin(canonicalUserHome, current)) {
      return current;
    }
    final parent = p.dirname(current);
    if (parent == current) return null;
    if (!p.equals(parent, canonicalUserHome) &&
        !p.isWithin(canonicalUserHome, parent)) {
      return null;
    }
    current = parent;
  }
}

/// Resolves one path for containment checks without requiring it to exist.
///
/// The parent directory is resolved through the filesystem so a platform alias
/// (`/var` to `/private/var` on macOS) is compared consistently, and the leaf is
/// appended unresolved so a symbolic link target itself is never followed.
String inventoryContainmentPath(String path) {
  final absolute = p.canonicalize(p.absolute(path));
  final parent = p.dirname(absolute);
  if (parent == absolute) return absolute;
  return p.join(canonicalComparablePath(parent), p.basename(absolute));
}

/// Builds the dry-run decision from one read-only inventory projection.
///
/// Deletion is allowed only for a target strictly inside `<primary home>/dev`,
/// below the `homes`/`runtimes` group directory, that is not a symbolic link and
/// that no live runtime or lease claims. Everything else is refused by name.
Future<SanadDevOrphanCleanupPlan> buildSanadDevOrphanCleanupPlan(
  SanadDevInventory inventory, {
  required DateTime now,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final devArea = p.join(inventory.primaryHome, 'dev');
  final entries = <SanadDevOrphanCleanupEntry>[];
  for (final orphan in inventory.orphans) {
    final refusal = await inventoryOrphanCleanupRefusal(
      orphan,
      inventory: inventory,
      devArea: devArea,
      processRunning: processRunning,
    );
    entries.add(
      SanadDevOrphanCleanupEntry(
        kind: orphan.kind,
        target: orphan.target,
        reason: orphan.reason,
        action: refusal == null
            ? OrphanCleanupAction.delete
            : OrphanCleanupAction.refuse,
        refusal: refusal,
        detail: orphan.detail,
      ),
    );
  }
  return SanadDevOrphanCleanupPlan(
    generatedAt: now,
    devArea: devArea,
    userHome: inventory.userHome,
    primaryHome: inventory.primaryHome,
    entries: entries,
  );
}

/// Returns the reason one orphan target may not be deleted, or null.
Future<String?> inventoryOrphanCleanupRefusal(
  InventoryOrphan orphan, {
  required SanadDevInventory inventory,
  required String devArea,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final target = orphan.target.trim();
  if (target.isEmpty) return 'target is empty';
  final canonicalTarget = inventoryContainmentPath(target);
  if (p.equals(
    canonicalTarget,
    inventoryContainmentPath(inventory.primaryHome),
  )) {
    return 'target is the primary Home';
  }
  if (inventoryTestHomeAncestor(target, inventory.userHome) != null) {
    return 'target is a Test Home';
  }
  final canonicalDevArea = inventoryContainmentPath(devArea);
  if (p.equals(canonicalDevArea, canonicalTarget)) {
    return 'target is the dev area itself';
  }
  if (!p.isWithin(canonicalDevArea, canonicalTarget)) {
    return 'outside the sanad-dev dev area';
  }
  final segments = p
      .split(p.relative(canonicalTarget, from: canonicalDevArea))
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (segments.length < 2) return 'target is a dev-area group directory';
  if (FileSystemEntity.typeSync(target, followLinks: false) ==
      FileSystemEntityType.link) {
    return 'target is a symbolic link';
  }
  final liveRuntime = inventoryLiveRuntimeFor(orphan, inventory);
  if (liveRuntime != null) return 'live runtime ($liveRuntime)';
  // Two layers agree here on purpose: the projection never lists a record that
  // names a live process, and the plan re-reads the record before deleting it,
  // because a process can appear between the dry run and the confirmation. A
  // record is evidence, so a live pid is a refusal and never a stale record.
  final livePid = await firstLiveRecordedPid(
    await inventoryRecordedPids(target),
    processRunning: processRunning,
  );
  if (livePid != null) {
    return 'recorded process pid $livePid is still running';
  }
  return null;
}

/// Process ids the record at [target] still names, if any.
///
/// A legacy `runtime.json` records `agent_pid`/`client_pid`; an endpoint record
/// records the daemon `pid`. Neither carries a process-start identity, so pid
/// existence is the strongest check the record allows — which errs towards
/// keeping a record, the safe direction. A target that is absent or unreadable
/// names no process.
Future<List<int>> inventoryRecordedPids(String target) async {
  try {
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    final String path;
    if (type == FileSystemEntityType.directory) {
      path = p.join(target, 'runtime.json');
      if (!await File(path).exists()) return const [];
    } else if (type == FileSystemEntityType.file &&
        p.basename(target) == '.local_gateway_endpoint.json') {
      path = target;
    } else {
      return const [];
    }
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map) return const [];
    int? asInt(Object? value) =>
        value is int ? value : int.tryParse('${value ?? ''}');
    final pids = <int>[];
    for (final key in const ['agent_pid', 'client_pid', 'pid']) {
      final value = asInt(decoded[key]);
      if (value != null && value > 0) pids.add(value);
    }
    return pids;
  } on Object {
    return const [];
  }
}

/// Names the live runtime group that still owns [orphan]'s Home or record.
String? inventoryLiveRuntimeFor(
  InventoryOrphan orphan,
  SanadDevInventory inventory,
) {
  bool isLive(InventoryRuntime runtime) =>
      runtime.runtimeClass != InventoryRuntimeClass.stopped;
  String? matchHome(String home) {
    for (final runtime in inventory.runtimes) {
      if (!isLive(runtime)) continue;
      if (equivalentPaths(runtime.home, home)) {
        return 'agent port ${runtime.agentPort ?? '-'}';
      }
    }
    return null;
  }

  switch (orphan.kind) {
    case InventoryOrphanKind.devHome:
      return matchHome(orphan.target);
    case InventoryOrphanKind.endpointRecord:
      return matchHome(p.dirname(orphan.target));
    case InventoryOrphanKind.runtimeRecord:
      final name = p.basename(orphan.target);
      for (final runtime in inventory.runtimes) {
        if (!isLive(runtime)) continue;
        if (runtime.worktreeId == name) {
          return 'worktree ${runtime.worktreeId}';
        }
        // A record directory that still carries a branch-derived name ends with
        // its worktree's path hash, so the live group claims it by hash even
        // when the canonical `primary-<hash>` directory does not exist yet.
        final worktreePath = runtime.worktreePath;
        if (worktreePath != null &&
            worktreePath.isNotEmpty &&
            name.endsWith('-${worktreeHashSuffix(worktreePath)}')) {
          return 'worktree ${runtime.worktreeId}';
        }
      }
      return null;
  }
}

/// Deletes one planned target without ever following a link.
///
/// The target is re-checked immediately before deletion: it must still resolve
/// inside the dev area and must still not be a symbolic link, so a link or a
/// replaced parent directory created after the plan is refused instead of
/// followed.
Future<String> deleteSanadDevOrphanTarget(
  String target, {
  required String devArea,
}) async {
  if (!p.isWithin(
    inventoryContainmentPath(devArea),
    inventoryContainmentPath(target),
  )) {
    throw FileSystemException(
      'refusing to delete outside the sanad-dev dev area',
      target,
    );
  }
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.notFound) return 'absent';
  if (type == FileSystemEntityType.link) {
    throw FileSystemException('refusing to delete a symbolic link', target);
  }
  if (type == FileSystemEntityType.directory) {
    await Directory(target).delete(recursive: true);
  } else {
    await File(target).delete();
  }
  if (FileSystemEntity.typeSync(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('target still exists after deletion', target);
  }
  return 'deleted';
}

/// Runs a plan, stopping at the first failure and never touching a refusal.
///
/// The default deletion re-checks the plan's dev area for every target; a test
/// seam may replace it entirely.
Future<SanadDevOrphanCleanupOutcome> applySanadDevOrphanCleanup(
  SanadDevOrphanCleanupPlan plan, {
  Future<String> Function(String target)? deleteTarget,
}) async {
  final delete =
      deleteTarget ??
      (String target) =>
          deleteSanadDevOrphanTarget(target, devArea: plan.devArea);
  final results = <SanadDevOrphanCleanupResult>[];
  var failed = false;
  for (final entry in plan.entries) {
    // A refusal is already reported by the plan and is never attempted.
    if (!entry.deletable) continue;
    if (failed) {
      results.add(
        SanadDevOrphanCleanupResult(
          entry: entry,
          status: OrphanCleanupStatus.notAttempted,
        ),
      );
      continue;
    }
    try {
      final outcome = await delete(entry.target);
      results.add(
        SanadDevOrphanCleanupResult(
          entry: entry,
          status: outcome == 'absent'
              ? OrphanCleanupStatus.absent
              : OrphanCleanupStatus.deleted,
        ),
      );
    } on Object catch (error) {
      failed = true;
      results.add(
        SanadDevOrphanCleanupResult(
          entry: entry,
          status: OrphanCleanupStatus.failed,
          error: error.toString(),
        ),
      );
    }
  }
  return SanadDevOrphanCleanupOutcome(plan: plan, results: results);
}

/// `sanad-dev cleanup-orphans` deletes only what it listed, and only on demand.
///
/// The command is dry-run by default. `--confirm` re-reads the projection first,
/// so a runtime, lease, or worktree that appeared after the dry run is honored
/// instead of deleted.
Future<void> handleSanadDevOrphanCleanup({
  required bool confirm,
  required bool json,
  Future<SanadDevInventory> Function()? collect,
  DateTime Function()? clock,
  Future<String> Function(String target)? deleteTarget,
}) async {
  final now = (clock ?? DateTime.now)().toUtc();
  Future<SanadDevInventory> readProjection() async {
    if (collect != null) return collect();
    return collectSanadDevInventory(callerDirectory: _callerDirectory);
  }

  final SanadDevInventory planned;
  try {
    planned = await readProjection();
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

  if (!confirm) {
    final plan = await buildSanadDevOrphanCleanupPlan(planned, now: now);
    if (json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(plan.toJson()));
      return;
    }
    printSanadDevOrphanCleanupPlan(plan, confirm: false);
    return;
  }

  final SanadDevInventory fresh;
  try {
    fresh = await readProjection();
  } on Object catch (error) {
    stderr.writeln('Error: could not re-verify the dev area: $error');
    exitCode = 1;
    return;
  }
  final plan = await buildSanadDevOrphanCleanupPlan(fresh, now: now);
  if (plan.deletable.isEmpty) {
    if (json) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(
          SanadDevOrphanCleanupOutcome(plan: plan, results: const []).toJson(),
        ),
      );
      return;
    }
    print('Nothing to clean: no deletable orphan in ${plan.devArea}.');
    for (final entry in plan.refused) {
      print(
        '  kept ${_orphanCleanupKindLabel(entry.kind)} ${entry.target}'
        '${entry.refusal == null ? '' : ' (${entry.refusal})'}',
      );
    }
    return;
  }

  final outcome = await applySanadDevOrphanCleanup(
    plan,
    deleteTarget: deleteTarget,
  );
  if (json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(outcome.toJson()),
    );
  } else {
    printSanadDevOrphanCleanupPlan(plan, confirm: true);
    printSanadDevOrphanCleanupOutcome(outcome);
  }
  if (outcome.count(OrphanCleanupStatus.failed) > 0) exitCode = 1;
}

String _orphanCleanupKindLabel(InventoryOrphanKind kind) => switch (kind) {
  InventoryOrphanKind.devHome => 'dev_home',
  InventoryOrphanKind.runtimeRecord => 'runtime_record',
  InventoryOrphanKind.endpointRecord => 'endpoint_record',
};

void printSanadDevOrphanCleanupPlan(
  SanadDevOrphanCleanupPlan plan, {
  required bool confirm,
}) {
  String abbreviate(String path) => abbreviateUserHome(path, plan.userHome);
  print(
    'Orphan cleanup (${confirm ? 'confirmed' : 'dry run'}) - '
    '${plan.generatedAt.toIso8601String()}',
  );
  print('Dev area: ${abbreviate(plan.devArea)}');
  if (!confirm) {
    print('Nothing is deleted without --confirm.');
  }
  print('');
  if (plan.entries.isEmpty) {
    print('No orphan targets found.');
    return;
  }
  final kindWidth = _orphanCleanupColumnWidth([
    for (final entry in plan.entries) _orphanCleanupKindLabel(entry.kind),
  ]);
  for (final entry in plan.entries) {
    final action = entry.deletable ? 'delete' : 'refuse';
    final suffix = entry.refusal != null
        ? ' -> ${entry.refusal}'
        : ' (${entry.reason})';
    print(
      '  ${action.padRight(7)}  '
      '${_orphanCleanupKindLabel(entry.kind).padRight(kindWidth)}  '
      '${abbreviate(entry.target)}$suffix',
    );
  }
  print('');
  print(
    '${plan.entries.length} targets: '
    '${plan.deletable.length} deletable, ${plan.refused.length} refused.',
  );
  if (!confirm && plan.deletable.isNotEmpty) {
    print(
      'Run "sanad-dev cleanup-orphans --confirm" to delete '
      '${plan.deletable.length} target'
      '${plan.deletable.length == 1 ? '' : 's'}.',
    );
  }
}

void printSanadDevOrphanCleanupOutcome(SanadDevOrphanCleanupOutcome outcome) {
  final plan = outcome.plan;
  String abbreviate(String path) => abbreviateUserHome(path, plan.userHome);
  print('');
  for (final result in outcome.results) {
    if (result.status == OrphanCleanupStatus.notAttempted) continue;
    final label = switch (result.status) {
      OrphanCleanupStatus.deleted => 'deleted',
      OrphanCleanupStatus.absent => 'absent ',
      OrphanCleanupStatus.failed => 'failed ',
      OrphanCleanupStatus.notAttempted => 'skipped',
    };
    final error = result.error == null ? '' : ': ${result.error}';
    print(
      '  $label  '
      '${_orphanCleanupKindLabel(result.entry.kind).padRight(14)}  '
      '${abbreviate(result.entry.target)}$error',
    );
  }
  final failed = outcome.count(OrphanCleanupStatus.failed);
  print('');
  print(
    'Deleted ${outcome.count(OrphanCleanupStatus.deleted)}, '
    'absent ${outcome.count(OrphanCleanupStatus.absent)}, '
    'failed $failed. '
    '${outcome.count(OrphanCleanupStatus.notAttempted)} not attempted.',
  );
  if (failed > 0) {
    print('Stopped at the first failure; nothing else was touched.');
  }
}

int _orphanCleanupColumnWidth(List<String> values) {
  var width = 0;
  for (final value in values) {
    if (value.length > width) width = value.length;
  }
  return width;
}
