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

/// Directories whose contents are compiled into the native Client binary.
const _clientNativeDirectories = <String>[
  'client/macos',
  'client/windows',
  'client/linux',
  'client/web',
  'client/ios',
  'client/android',
];

/// Public assets are packaged by the Flutter build, not by the Dart VM hot
/// reloader or hot restarter, so any extension under `client/assets/**` needs a
/// full stop and run.
bool _matchesClientNativeOrAssets(String path) {
  if (_isUnder(path, 'client/pubspec.yaml') ||
      _isUnder(path, 'client/pubspec.lock') ||
      _isUnder(path, 'client/assets')) {
    return true;
  }
  return _clientNativeDirectories.any((prefix) => _isUnder(path, prefix));
}

/// Dart files whose identity is fixed at process start.
bool _matchesClientStartup(String path) {
  if (!_isUnder(path, 'client/lib') || !path.endsWith('.dart')) return false;
  final segments = path.split('/');
  final file = segments.last;
  if (file == 'main.dart' || file == 'driver_main.dart') return true;
  if (file.contains('bootstrap') || file.contains('startup')) return true;
  return segments.any((segment) => segment == 'di' || segment == 'startup');
}

/// Client localization sources: the authored `.arb` catalogs and their config.
///
/// The generated `app_localizations*.dart` files are build output, so editing a
/// catalog is not a plain Dart edit: the strings must be regenerated before the
/// running Client can see them, and only a fresh client build does that. A hot
/// reload would keep showing the old strings and a hot restart cannot regenerate
/// them, so the change maps to `stop + run` and the reason says why.
bool _matchesClientLocalization(String path) {
  // `client/l10n.yaml` points `arb-dir` at `lib/l10n`, so the catalogs live
  // under `client/lib/l10n` and the config under `client/`.
  if (_isUnder(path, 'client/l10n') ||
      _isUnder(path, 'client/lib/l10n') ||
      path == 'client/l10n.yaml') {
    return true;
  }
  return _isUnder(path, 'client') && path.endsWith('.arb');
}

bool _matchesClientDart(String path) =>
    _isUnder(path, 'client/lib') && path.endsWith('.dart');

bool _matchesNonRuntime(String path) {
  // Assets are build inputs even when they are Markdown or another text format,
  // so the documentation rule must not shadow a packaged asset.
  if (_isUnder(path, 'client/assets')) return false;
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
/// | docs, tests, `.github/**`, `**.md` (except `client/assets/**`) | none |
/// | `scripts/sanad_dev/**`, `scripts/sanad-dev*` | `stop + run` |
/// | `agent/**` | `restart agent` |
/// | `client/lib/main.dart`, `driver_main.dart`, startup/DI Dart | `restart client` |
/// | `client/l10n/**`, `client/l10n.yaml`, `client/**.arb` | `stop + run` (regenerate) |
/// | `client/pubspec.*`, `client/assets/**` (any extension), native/Web directories | `stop + run` |
/// | other `client/lib/**.dart` | `reload client` |
/// | `shared/**`, `release/contract/**` | `restart agent` + `restart client` |
/// | anything else | `restart agent` + `restart client` |
/// `stop + run` subsumes every other action and `restart client` subsumes
/// `reload client`. Pubspec, asset, plugin, and native changes are compiled into
/// the desktop bundle, so a hot restart cannot apply them; they need a full
/// stop and run.
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
    id: 'client-startup',
    label: 'Client startup or dependency-injection Dart changed',
    actions: [SanadDevApplyAction.restartClient],
    matches: _matchesClientStartup,
  ),
  SanadDevApplyRule(
    id: 'client-localization',
    label:
        'Client localization source changed; the strings must be regenerated, '
        'which a hot reload or hot restart cannot do',
    actions: [SanadDevApplyAction.restartRuntime],
    matches: _matchesClientLocalization,
  ),
  SanadDevApplyRule(
    id: 'client-native-or-assets',
    label:
        'Client pubspec, plugin, asset or native source changed; a hot restart '
        'cannot apply it',
    actions: [SanadDevApplyAction.restartRuntime],
    matches: _matchesClientNativeOrAssets,
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
    required this.actionsByPath,
  });

  final List<SanadDevApplyAction> actions;
  final List<String> reasons;
  final List<String> changedPaths;

  /// Actions each changed path required, so `apply` can tell which paths were
  /// actually applied and which were skipped because their target was not
  /// running.
  final Map<String, List<SanadDevApplyAction>> actionsByPath;

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
  final actionsByPath = <String, List<SanadDevApplyAction>>{};
  for (final path in normalized) {
    for (final rule in sanadDevApplyRules) {
      if (!rule.matches(path)) continue;
      examplesByRule.putIfAbsent(rule.id, () => []).add(path);
      final required = driverModeChange
          ? <SanadDevApplyAction>{
              ...rule.actions,
              SanadDevApplyAction.restartRuntime,
            }.toList(growable: false)
          : rule.actions;
      actionsByPath[path] = List.unmodifiable(required);
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
    actionsByPath: Map.unmodifiable(actionsByPath),
  );
}

/// Recorded state of the last successful `sanad-dev apply`.
///
/// Advancing it is what makes a repeated `apply` idempotent: the commit baseline
/// moves to the applied `HEAD`, and the per-path content fingerprints record
/// exactly which bytes were applied. `git diff --name-only <start commit>`
/// reports a tracked working-tree edit on every call, so a whole-tree signature
/// (or the status list alone) cannot decide whether that edit was already
/// applied. Only comparing the file's current content with the content that was
/// applied can, and it does so for tracked and untracked files alike.
class SanadDevApplyBaseline {
  const SanadDevApplyBaseline({required this.commit, this.files = const {}});

  final String commit;

  /// Repository-relative path to the fingerprint applied for it.
  final Map<String, String> files;

  Map<String, Object?> toJson() => {
    'commit': commit,
    'files': files,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  };

  static SanadDevApplyBaseline? fromJson(Map<String, dynamic> json) {
    final commit = json['commit']?.toString() ?? '';
    final files = <String, String>{};
    final recorded = json['files'];
    if (recorded is Map) {
      recorded.forEach((key, value) {
        if (key is String && value is String) files[key] = value;
      });
    }
    if (commit.isEmpty && files.isEmpty) return null;
    return SanadDevApplyBaseline(
      commit: commit,
      files: Map.unmodifiable(files),
    );
  }
}

/// Fingerprint recorded for a path that does not exist.
const sanadDevApplyMissingPathFingerprint = 'missing';

/// Content fingerprint of [relativePath] inside [repositoryRoot].
///
/// A missing, deleted, or non-regular path is recorded as
/// [sanadDevApplyMissingPathFingerprint] so a deletion is applied exactly once.
String sanadDevApplyPathFingerprint(
  String repositoryRoot,
  String relativePath,
) {
  final file = File(p.join(repositoryRoot, relativePath));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return sanadDevApplyMissingPathFingerprint;
  }
  try {
    return sha256.convert(file.readAsBytesSync()).toString();
  } on FileSystemException {
    return sanadDevApplyMissingPathFingerprint;
  }
}

/// Fingerprints to record after an apply.
///
/// A path is recorded only when every action it required actually ran: an
/// action skipped because its target — typically the Client — is not running
/// must not advance that path's baseline, otherwise the change is silently
/// considered applied and the next `apply` reports nothing to do.
Map<String, String> sanadDevApplyRecordedFingerprints({
  required String repositoryRoot,
  required SanadDevApplyDecision decision,
  required Set<SanadDevApplyAction> skippedActions,
  Map<String, String> previous = const {},
}) {
  final recorded = <String, String>{...previous};
  for (final path in decision.changedPaths) {
    final required = decision.actionsByPath[path] ?? const [];
    if (required.any(skippedActions.contains)) continue;
    recorded[path] = sanadDevApplyPathFingerprint(repositoryRoot, path);
  }
  return recorded;
}

String sanadDevApplyBaselinePath(SanadDevRuntime runtime) =>
    p.join(runtime.runtimeDirectory, 'apply-baseline.json');

/// Reads the recorded apply baseline, or null when none is valid.
Future<SanadDevApplyBaseline?> readSanadDevApplyBaseline(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    return SanadDevApplyBaseline.fromJson(Map<String, dynamic>.from(decoded));
  } on Object {
    return null;
  }
}

Future<void> writeSanadDevApplyBaseline(
  String path,
  SanadDevApplyBaseline baseline,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString('${jsonEncode(baseline.toJson())}\n', flush: true);
  await restrictRuntimePath(file.path);
}

/// Changed paths plus the fingerprints they were derived from.
class SanadDevChangedPaths {
  const SanadDevChangedPaths({required this.paths});

  final List<String> paths;
}

/// Paths changed since [startCommit], minus the ones already applied.
///
/// [appliedFingerprints] is the per-path content snapshot recorded by the last
/// successful `apply`. A candidate is dropped only when its current content
/// matches the fingerprint that was applied for it, so an already-applied tracked
/// working-tree edit is not reported twice, a second edit of the same file is,
/// and untracked files behave identically.
Future<SanadDevChangedPaths> inspectChangedPaths({
  required String repositoryRoot,
  required String? startCommit,
  Map<String, String> appliedFingerprints = const {},
}) async {
  final candidates = <String>{};
  final statusOutput = await _gitOutput(repositoryRoot, [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ]);
  candidates.addAll(_porcelainPaths(statusOutput));
  if (startCommit != null && startCommit.trim().isNotEmpty) {
    candidates.addAll(
      await _gitChangedPaths(repositoryRoot, [
        'diff',
        '--name-only',
        startCommit.trim(),
      ]),
    );
  }
  final paths = <String>[];
  for (final path in candidates) {
    final applied = appliedFingerprints[path];
    if (applied != null &&
        applied == sanadDevApplyPathFingerprint(repositoryRoot, path)) {
      continue;
    }
    paths.add(path);
  }
  paths.sort();
  return SanadDevChangedPaths(paths: paths);
}

Future<String> _gitOutput(String repositoryRoot, List<String> arguments) async {
  final result = await Process.run('git', [
    '-C',
    repositoryRoot,
    ...arguments,
  ]);
  return result.exitCode == 0 ? result.stdout.toString() : '';
}

List<String> _porcelainPaths(String output) {
  final paths = <String>[];
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final path = line.length > 3 ? line.substring(3).trim() : '';
    if (path.isEmpty) continue;
    final renamed = path.contains(' -> ') ? path.split(' -> ').last.trim() : path;
    paths.add(renamed.replaceAll('"', ''));
  }
  return paths;
}

Future<List<String>> _gitChangedPaths(
  String repositoryRoot,
  List<String> arguments,
) async {
  final output = await _gitOutput(repositoryRoot, arguments);
  final paths = <String>[];
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    paths.add(line.replaceAll('"', ''));
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
  ForeignActivityDetector? detectActivity,
  Future<SanadDevRuntime> Function({String? sanadHomeOverride})? runtimeProvider,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
}) async {
  final log = printMessage ?? print;
  final void Function(String message) logError = printError ?? stderr.writeln;
  final runtime =
      await (runtimeProvider ??
          ({String? sanadHomeOverride}) => _currentRuntime(
            sanadHomePath: sanadHomeOverride,
          ))(sanadHomeOverride: sanadHomePath);
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
  final baselinePath = sanadDevApplyBaselinePath(runtime);
  final appliedBaseline = await readSanadDevApplyBaseline(baselinePath);
  final startCommit = record.sourceCommit.trim().isEmpty
      ? (appliedBaseline?.commit ?? '')
      : record.sourceCommit;
  final inspected = await inspectChangedPaths(
    repositoryRoot: runtime.repositoryRoot,
    startCommit: startCommit,
    appliedFingerprints: appliedBaseline?.files ?? const {},
  );
  if (startCommit.isEmpty) {
    log(
      'Note: the live runtime lease has no recorded start commit; only '
      'uncommitted working-tree changes are inspected.',
    );
  }
  final decision = decideSanadDevApply(
    changedPaths: inspected.paths,
    driverModeChange: driverMode && !isDriverRuntime,
  );
  log('Worktree: ${runtime.worktreeId}');
  log(
    'Runtime source commit at start: ${startCommit.isEmpty ? '-' : startCommit}',
  );
  log('Changed paths: ${inspected.paths.length}');
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
  if (restartsRuntime &&
      await refuseRestartDuringForeignActivity(
        runtime: runtime,
        force: force,
        detectActivity: detectActivity,
        printError: logError,
      )) {
    return;
  }

  final home = record.sanadHome;
  final skippedActions = <SanadDevApplyAction>{};
  for (final action in decision.actions) {
    switch (action) {
      case SanadDevApplyAction.reloadClient:
      case SanadDevApplyAction.restartClient:
        final client = ownership.state.ownedClients.isEmpty
            ? null
            : ownership.state.ownedClients.first;
        if (client == null) {
          // The change is still pending: a skipped action must not advance the
          // baseline, so the next apply reports it again.
          skippedActions.add(action);
          log(
            'Skipped ${sanadDevApplyActionLabel(action)}: no managed Client is '
            'running for ${runtime.worktreeId}. Start one, then rerun apply.',
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
  if (exitCode != 0) return;

  // Advance the baseline only after every action succeeded, and only for the
  // paths whose actions actually ran, so a repeated `apply` on an unchanged tree
  // reports no action instead of restarting again while a skipped change keeps
  // waiting for its target.
  final appliedCommit = await readRuntimeSourceCommit(runtime.repositoryRoot);
  final recordedFiles = sanadDevApplyRecordedFingerprints(
    repositoryRoot: runtime.repositoryRoot,
    decision: decision,
    skippedActions: skippedActions,
    previous: appliedBaseline?.files ?? const {},
  );
  final pendingPaths = _pendingPathCount(decision, skippedActions);
  final previousCommit = appliedBaseline?.commit ?? '';
  await writeSanadDevApplyBaseline(
    baselinePath,
    SanadDevApplyBaseline(
      // A pending change keeps the older commit baseline so its commit range is
      // still inspected until it is actually applied.
      commit: pendingPaths > 0 && previousCommit.isNotEmpty
          ? previousCommit
          : (appliedCommit.isEmpty ? startCommit : appliedCommit),
      files: recordedFiles,
    ),
  );
  log(
    'Applied at ${appliedCommit.isEmpty ? '-' : appliedCommit}; recorded '
    '${decision.changedPaths.length - pendingPaths} of '
    '${decision.changedPaths.length} changed file(s). The next '
    '"sanad-dev apply" starts from here.',
  );
}

/// How many changed paths still wait for a skipped action.
int _pendingPathCount(
  SanadDevApplyDecision decision,
  Set<SanadDevApplyAction> skippedActions,
) {
  if (skippedActions.isEmpty) return 0;
  return decision.changedPaths
      .where(
        (path) => (decision.actionsByPath[path] ?? const []).any(
          skippedActions.contains,
        ),
      )
      .length;
}
