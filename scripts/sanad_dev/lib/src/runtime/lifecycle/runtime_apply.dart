part of '../../../sanad_dev_cli.dart';

/// Runtime action selected for the files changed since the runtime started.
enum SanadDevApplyAction {
  reloadClient,
  restartClient,
  restartAgent,
  restartRuntime,
}

String sanadDevApplyActionLabel(SanadDevApplyAction action) => switch (action) {
  SanadDevApplyAction.reloadClient => 'reload client',
  SanadDevApplyAction.restartClient => 'restart client',
  SanadDevApplyAction.restartAgent => 'restart agent',
  SanadDevApplyAction.restartRuntime => 'stop + run',
};

/// One row of the changed-path decision table.
///
/// The table is the single authority for `sanad-dev apply`: it is evaluated in
/// order, the first matching row wins for a path, and the printed reason is the
/// row's label plus one example path.
class SanadDevApplyRule {
  const SanadDevApplyRule({
    required this.id,
    required this.label,
    required this.actions,
    required this.matches,
  });

  final String id;
  final String label;
  final List<SanadDevApplyAction> actions;
  final bool Function(String path) matches;
}

bool _isUnder(String path, String prefix) =>
    path == prefix || path.startsWith('$prefix/');

bool _matchesSanadDevItself(String path) =>
    _isUnder(path, 'scripts/sanad_dev') ||
    path == 'scripts/sanad-dev' ||
    path == 'scripts/sanad-dev.ps1' ||
    path == 'scripts/sanad_dev.dart';

bool _matchesAgent(String path) => _isUnder(path, 'agent');

bool _matchesClientStartupOrNative(String path) {
  if (_isUnder(path, 'client/pubspec.yaml') ||
      _isUnder(path, 'client/pubspec.lock') ||
      _isUnder(path, 'client/assets') ||
      _isUnder(path, 'client/macos') ||
      _isUnder(path, 'client/windows') ||
      _isUnder(path, 'client/linux') ||
      _isUnder(path, 'client/web') ||
      _isUnder(path, 'client/ios') ||
      _isUnder(path, 'client/android')) {
    return true;
  }
  if (!_isUnder(path, 'client/lib') || !path.endsWith('.dart')) return false;
  final segments = path.split('/');
  final file = segments.last;
  if (file == 'main.dart' || file == 'driver_main.dart') return true;
  if (file.contains('bootstrap') || file.contains('startup')) return true;
  return segments.any((segment) => segment == 'di' || segment == 'startup');
}

bool _matchesClientDart(String path) =>
    _isUnder(path, 'client/lib') && path.endsWith('.dart');

bool _matchesNonRuntime(String path) {
  const prefixes = [
    'docs',
    '.github',
    '.agents',
    'client/test',
    'agent/test',
    'scripts/sanad_dev/test',
  ];
  if (prefixes.any((prefix) => _isUnder(path, prefix))) return true;
  return path.endsWith('.md');
}

bool _matchesSharedSource(String path) =>
    _isUnder(path, 'shared') || _isUnder(path, 'release/contract');

/// Ordered decision table for `sanad-dev apply`.
///
/// | Changed path | Action |
/// | --- | --- |
/// | docs, tests, `.github/**`, `**.md` | none |
/// | `scripts/sanad_dev/**`, `scripts/sanad-dev*` | `stop + run` |
/// | `agent/**` | `restart agent` |
/// | `client/pubspec.*`, `client/assets/**`, native/Web directories, `client/lib/main.dart`, startup/DI files | `restart client` |
/// | other `client/lib/**.dart` | `reload client` |
/// | `shared/**`, `release/contract/**` | `restart agent` + `restart client` |
/// | anything else | `restart agent` + `restart client` |
///
/// `stop + run` subsumes every other action and `restart client` subsumes
/// `reload client`.
const sanadDevApplyRules = <SanadDevApplyRule>[
  SanadDevApplyRule(
    id: 'non-runtime',
    label: 'Documentation, tests or CI only',
    actions: [],
    matches: _matchesNonRuntime,
  ),
  SanadDevApplyRule(
    id: 'sanad-dev-source',
    label: 'sanad-dev source, ports, Home, environment or driver mode changed',
    actions: [SanadDevApplyAction.restartRuntime],
    matches: _matchesSanadDevItself,
  ),
  SanadDevApplyRule(
    id: 'agent-source',
    label: 'Agent source changed',
    actions: [SanadDevApplyAction.restartAgent],
    matches: _matchesAgent,
  ),
  SanadDevApplyRule(
    id: 'client-startup-or-native',
    label: 'Client startup, DI, pubspec, asset or native source changed',
    actions: [SanadDevApplyAction.restartClient],
    matches: _matchesClientStartupOrNative,
  ),
  SanadDevApplyRule(
    id: 'client-ui-dart',
    label: 'Dart UI-only Client change',
    actions: [SanadDevApplyAction.reloadClient],
    matches: _matchesClientDart,
  ),
  SanadDevApplyRule(
    id: 'shared-source',
    label: 'Shared package source changed',
    actions: [
      SanadDevApplyAction.restartAgent,
      SanadDevApplyAction.restartClient,
    ],
    matches: _matchesSharedSource,
  ),
  SanadDevApplyRule(
    id: 'unknown-source',
    label: 'Unclassified source change',
    actions: [
      SanadDevApplyAction.restartAgent,
      SanadDevApplyAction.restartClient,
    ],
    matches: _alwaysMatches,
  ),
];

bool _alwaysMatches(String path) => true;

class SanadDevApplyDecision {
  const SanadDevApplyDecision({
    required this.actions,
    required this.reasons,
    required this.changedPaths,
  });

  final List<SanadDevApplyAction> actions;
  final List<String> reasons;
  final List<String> changedPaths;

  String get actionLabel => actions.isEmpty
      ? 'none'
      : actions.map(sanadDevApplyActionLabel).join(', ');
}

/// Applies the [sanadDevApplyRules] table to [changedPaths].
///
/// `stop + run` subsumes every other action; otherwise the actions are the
/// deduplicated union of every matched row, ordered lightest first.
SanadDevApplyDecision decideSanadDevApply({
  required Iterable<String> changedPaths,
  bool driverModeChange = false,
}) {
  final normalized =
      changedPaths
          .map((path) => path.replaceAll('\\', '/').trim())
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  final actions = <SanadDevApplyAction>[];
  final reasons = <String>[];
  if (driverModeChange) {
    actions.add(SanadDevApplyAction.restartRuntime);
    reasons.add(
      'Driver-mode change requested: the running runtime was not started '
      'with --driver',
    );
  }
  final examplesByRule = <String, List<String>>{};
  for (final path in normalized) {
    for (final rule in sanadDevApplyRules) {
      if (!rule.matches(path)) continue;
      examplesByRule.putIfAbsent(rule.id, () => []).add(path);
      for (final action in rule.actions) {
        if (!actions.contains(action)) actions.add(action);
      }
      break;
    }
  }
  for (final rule in sanadDevApplyRules) {
    final examples = examplesByRule[rule.id];
    if (examples == null || examples.isEmpty) continue;
    reasons.add(
      '${rule.label}: ${examples.take(3).join(', ')}'
      '${examples.length > 3 ? ' (+${examples.length - 3} more)' : ''}',
    );
  }
  final ordered = <SanadDevApplyAction>[];
  if (actions.contains(SanadDevApplyAction.restartRuntime)) {
    ordered.add(SanadDevApplyAction.restartRuntime);
  } else {
    for (final action in const [
      SanadDevApplyAction.reloadClient,
      SanadDevApplyAction.restartClient,
      SanadDevApplyAction.restartAgent,
    ]) {
      // A client restart subsumes a hot reload.
      if (action == SanadDevApplyAction.reloadClient &&
          actions.contains(SanadDevApplyAction.restartClient)) {
        continue;
      }
      if (actions.contains(action)) ordered.add(action);
    }
  }
  return SanadDevApplyDecision(
    actions: List.unmodifiable(ordered),
    reasons: List.unmodifiable(reasons),
    changedPaths: List.unmodifiable(normalized),
  );
}

/// Paths changed since [startCommit], plus the current working tree.
Future<List<String>> changedPathsSince({
  required String repositoryRoot,
  required String? startCommit,
}) async {
  final paths = <String>{};
  if (startCommit != null && startCommit.trim().isNotEmpty) {
    paths.addAll(
      await _gitChangedPaths(repositoryRoot, [
        'diff',
        '--name-only',
        startCommit.trim(),
      ]),
    );
  }
  paths.addAll(
    await _gitChangedPaths(repositoryRoot, [
      'status',
      '--porcelain',
      '--untracked-files=all',
    ], porcelain: true),
  );
  final sorted = paths.toList()..sort();
  return sorted;
}

Future<List<String>> _gitChangedPaths(
  String repositoryRoot,
  List<String> arguments, {
  bool porcelain = false,
}) async {
  final result = await Process.run('git', ['-C', repositoryRoot, ...arguments]);
  if (result.exitCode != 0) return const [];
  final paths = <String>[];
  for (final raw in const LineSplitter().convert(result.stdout.toString())) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final path = porcelain
        ? (line.length > 3 ? line.substring(3).trim() : '')
        : line;
    if (path.isEmpty) continue;
    final renamed = path.contains(' -> ')
        ? path.split(' -> ').last.trim()
        : path;
    paths.add(renamed.replaceAll('"', ''));
  }
  return paths;
}

/// Inspects the runtime, decides the lightest correct action, and runs it.
Future<void> handleRuntimeApply({
  required bool dryRun,
  required bool driverMode,
  required bool force,
  String? sanadHomePath,
  bool? driverClientsPresent,
  Future<List<ForeignWorktreeActivity>> Function(String workspaceRoot)?
  detectActivity,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
}) async {
  final log = printMessage ?? print;
  final logError = printError ?? stderr.writeln;
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final state = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(
      sanadHomeOverride: sanadHomePath,
    ),
    activeClients: await discoverClientInstances(),
    runtime: runtime,
  );
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: resolveActiveSanadHome(runtime, state),
  );
  if (!ownership.isManaged) {
    log(
      'Nothing to apply for ${runtime.worktreeId}: runtime class is '
      '${ownership.classification.name}. Run "sanad-dev run" first.',
    );
    return;
  }
  final record = ownership.record!;
  final isDriverRuntime =
      driverClientsPresent ??
      selectManagedUiDriverClients(ownership).isNotEmpty;
  final startCommit = record.sourceCommit;
  final changed = await changedPathsSince(
    repositoryRoot: runtime.repositoryRoot,
    startCommit: startCommit,
  );
  if (startCommit.isEmpty) {
    log(
      'Note: the live runtime lease has no recorded start commit; only '
      'uncommitted working-tree changes are inspected.',
    );
  }
  final decision = decideSanadDevApply(
    changedPaths: changed,
    driverModeChange: driverMode && !isDriverRuntime,
  );
  log('Worktree: ${runtime.worktreeId}');
  log(
    'Runtime source commit at start: ${startCommit.isEmpty ? '-' : startCommit}',
  );
  log('Changed paths: ${changed.length}');
  log('Action: ${decision.actionLabel}');
  for (final reason in decision.reasons) {
    log('  reason: $reason');
  }
  if (decision.actions.isEmpty) {
    log('No runtime action is required.');
    return;
  }
  if (dryRun) return;

  final restartsRuntime = decision.actions.any(
    (action) =>
        action == SanadDevApplyAction.restartRuntime ||
        action == SanadDevApplyAction.restartAgent ||
        action == SanadDevApplyAction.restartClient,
  );
  if (restartsRuntime && !force) {
    final activities = await (detectActivity ?? detectForeignWorktreeActivity)(
      runtime.workspaceRoot,
    );
    if (activities.isNotEmpty) {
      logError(
        foreignWorktreeActivityMessage(
          worktreeId: runtime.worktreeId,
          activities: activities,
        ),
      );
      exitCode = 1;
      return;
    }
  }

  final home = record.sanadHome;
  for (final action in decision.actions) {
    switch (action) {
      case SanadDevApplyAction.reloadClient:
      case SanadDevApplyAction.restartClient:
        final client = ownership.state.ownedClients.isEmpty
            ? null
            : ownership.state.ownedClients.first;
        if (client == null) {
          log(
            'Skipped ${sanadDevApplyActionLabel(action)}: no managed Client is '
            'running for ${runtime.worktreeId}.',
          );
          continue;
        }
        await handleClientDeveloperAction(
          action == SanadDevApplyAction.reloadClient ? 'r' : 'R',
          client.port,
          sanadHomePath: home,
          // `apply` already ran the build guard for this decision.
          guardForeignActivity: false,
        );
      case SanadDevApplyAction.restartAgent:
        await handleAgentRestart(
          record.agentPort,
          sanadHomePath: home,
          exitOnError: false,
          // `apply` already ran the build guard for this decision.
          guardForeignActivity: false,
        );
      case SanadDevApplyAction.restartRuntime:
        await handleRuntimeStop(
          target: SanadDevComponentTarget.all,
          sanadHomePath: home,
        );
        if (exitCode != 0) return;
        await handleBackgroundRun(
          originalArguments: [
            'run',
            if (driverMode || isDriverRuntime) '--driver',
            '--home',
            home,
          ],
          target: SanadDevComponentTarget.all,
          device: _defaultDesktopDevice(),
          clientInstanceSlot: null,
          sanadHomePath: home,
        );
    }
  }
}
