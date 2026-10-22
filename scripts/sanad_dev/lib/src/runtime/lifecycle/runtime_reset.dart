part of '../../../sanad_dev_cli.dart';

/// Why a Home may or may not be reset by this worktree.
enum SanadDevResetHomeClass {
  worktreeTestHome,
  primaryUserHome,
  foreignHome,
  unknownHome,
}

class SanadDevResetHomeAssessment {
  const SanadDevResetHomeAssessment({
    required this.classification,
    required this.homePath,
    required this.reason,
  });

  final SanadDevResetHomeClass classification;
  final String homePath;
  final String reason;

  bool get allowed => classification == SanadDevResetHomeClass.worktreeTestHome;
}

/// Decides whether [runtime]'s Home is the Test Home owned by this worktree.
///
/// `reset` destroys and restores runtime state, so it is deliberately narrower
/// than every other command:
///
/// - the primary user Home (`~/.sanad`) is always refused;
/// - any Home outside `<user home>/.sanad/dev/homes/<worktree id>` is refused,
///   which covers the shared `~/.sanad-test*` homes and every other worktree's
///   Test Home;
/// - the accepted Home is the worktree-scoped Test Home, or a path below it.
SanadDevResetHomeAssessment assessSanadDevResetHome({
  required SanadDevRuntime runtime,
  required String userHome,
}) {
  final primaryHome = p.join(userHome, '.sanad');
  final devHomesRoot = p.join(primaryHome, 'dev', 'homes');
  final worktreeHome = p.join(devHomesRoot, runtime.worktreeId);
  final home = runtime.sanadHome;
  if (equivalentPaths(home, primaryHome) || _isAncestor(home, primaryHome)) {
    return SanadDevResetHomeAssessment(
      classification: SanadDevResetHomeClass.primaryUserHome,
      homePath: home,
      reason:
          'the primary user Home $primaryHome is never reset by sanad-dev. '
          'Pass an explicit --home inside $worktreeHome.',
    );
  }
  if (!equivalentPaths(home, worktreeHome) && !_isWithin(home, worktreeHome)) {
    return SanadDevResetHomeAssessment(
      classification: _isWithin(home, devHomesRoot)
          ? SanadDevResetHomeClass.foreignHome
          : SanadDevResetHomeClass.unknownHome,
      homePath: home,
      reason:
          'this worktree owns only $worktreeHome. Other Test Homes and shared '
          'homes are never reset from here.',
    );
  }
  return SanadDevResetHomeAssessment(
    classification: SanadDevResetHomeClass.worktreeTestHome,
    homePath: home,
    reason: 'worktree-scoped Test Home',
  );
}

bool _isWithin(String path, String root) {
  final normalizedRoot = canonicalComparablePath(root);
  final normalizedPath = canonicalComparablePath(path);
  return p.isWithin(normalizedRoot, normalizedPath);
}

bool _isAncestor(String path, String child) => _isWithin(child, path);

typedef SanadDevResetRuntimeProvider =
    Future<SanadDevRuntime> Function({String? sanadHomeOverride});
typedef SanadDevResetStopper = Future<bool> Function(String homePath);
typedef SanadDevResetStarter =
    Future<bool> Function({
      required SanadDevRuntime runtime,
      required String homePath,
      required bool driverMode,
      required String device,
    });
typedef SanadDevResetPortsFreeProbe =
    Future<bool> Function(SanadDevRuntime runtime, String homePath);

/// `sanad-dev reset [--fixture <name>] [--save-fixture <name>] [--keep-data]`.
///
/// Steps: stop this worktree's Agent and Client and prove the ports are free,
/// optionally save and/or restore a Home fixture, then launch a matched
/// driver-enabled runtime and print one summary line.
Future<void> handleRuntimeReset({
  String? fixture,
  String? saveFixture,
  required bool keepData,
  required bool driverMode,
  required bool dryRun,
  required String device,
  String? clientInstanceSlot,
  String? sanadHomePath,
  Map<String, String>? environment,
  SanadDevResetRuntimeProvider? runtimeProvider,
  SanadDevResetStopper? stopRuntime,
  SanadDevResetStarter? startRuntime,
  SanadDevResetPortsFreeProbe? portsFreeProbe,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
}) async {
  final log = printMessage ?? print;
  final logError = printError ?? stderr.writeln;
  final env = environment ?? Platform.environment;
  if (fixture != null && keepData) {
    logError('--fixture and --keep-data cannot be combined.');
    exitCode = 64;
    return;
  }
  for (final name in [fixture, saveFixture]) {
    if (name != null && !isValidSanadDevFixtureName(name)) {
      logError(
        'Invalid fixture name "$name": use lowercase letters, digits, ".", '
        '"_" or "-" (max 64 characters).',
      );
      exitCode = 64;
      return;
    }
  }
  final runtime =
      await (runtimeProvider ??
          ({String? sanadHomeOverride}) => _currentRuntime(
            sanadHomePath: sanadHomeOverride,
          ))(sanadHomeOverride: sanadHomePath);
  final userHome = env[Platform.isWindows ? 'USERPROFILE' : 'HOME']?.trim();
  if (userHome == null || userHome.isEmpty) {
    logError('Could not determine the user home directory.');
    exitCode = 1;
    return;
  }
  final assessment = assessSanadDevResetHome(
    runtime: runtime,
    userHome: userHome,
  );
  if (!assessment.allowed) {
    logError('Refusing to reset ${runtime.worktreeId}: ${assessment.reason}');
    exitCode = 64;
    return;
  }
  final home = assessment.homePath;
  log('Worktree: ${runtime.worktreeId}');
  log('Test home: $home');
  log('Agent port: ${runtime.agentPort}');
  log('Client VM service port: ${runtime.vmServicePort}');
  log(
    'Data: ${fixture != null ? 'restore fixture "$fixture"' : 'keep existing data'}',
  );
  if (saveFixture != null) log('Save fixture: $saveFixture');
  log('Mode: ${driverMode ? 'interactive-driver' : 'interactive'}');
  if (dryRun) return;

  final stopped = await (stopRuntime ?? _defaultResetStop)(home);
  if (!stopped) {
    logError('Stopping this worktree runtime failed; Home data is unchanged.');
    exitCode = 1;
    return;
  }
  final portsFree = await (portsFreeProbe ?? _waitForResetPortsFree)(
    runtime,
    home,
  );
  if (!portsFree) {
    logError(
      'Refusing to reset ${runtime.worktreeId}: the Agent port '
      '${runtime.agentPort} or a managed Client endpoint is still live.',
    );
    exitCode = 1;
    return;
  }
  log('Stopped this worktree runtime; ports are free.');

  if (saveFixture != null) {
    try {
      final manifest = await saveHomeFixture(
        workspaceRoot: runtime.workspaceRoot,
        homePath: home,
        name: saveFixture,
      );
      log(
        'Saved fixture "$saveFixture" (${manifest.entries.length} files) to '
        '${sanadDevFixturePath(runtime.workspaceRoot, saveFixture)}.',
      );
    } on Object catch (error) {
      logError('Could not save fixture "$saveFixture": $error');
      exitCode = 1;
      return;
    }
  }
  if (fixture != null) {
    try {
      final report = await restoreHomeFixture(
        workspaceRoot: runtime.workspaceRoot,
        homePath: home,
        name: fixture,
      );
      log(
        'Restored fixture "$fixture": ${report.restoredFiles} files restored, '
        '${report.removedFiles} stale files removed; secrets, logs and dev '
        'state preserved.',
      );
    } on Object catch (error) {
      logError(
        'Could not restore fixture "$fixture": $error '
        'The runtime was stopped and left unchanged; rerun '
        '"sanad-dev reset --keep-data" to start it again.',
      );
      exitCode = 1;
      return;
    }
  } else {
    log('Kept existing Home data (--keep-data).');
  }

  final started = await (startRuntime ?? _defaultResetStart)(
    runtime: runtime,
    homePath: home,
    driverMode: driverMode,
    device: device,
  );
  if (!started) {
    logError(
      'Restarting this worktree runtime failed; the Home is prepared but not '
      'running. Rerun "sanad-dev run".',
    );
    exitCode = 1;
    return;
  }
  final summary = await _describeResetRuntime(
    runtime: runtime,
    homePath: home,
    fixture: fixture,
  );
  log(summary);
}

Future<bool> _defaultResetStop(String homePath) async {
  await handleRuntimeStop(
    target: SanadDevComponentTarget.all,
    sanadHomePath: homePath,
  );
  return exitCode == 0;
}

Future<bool> _defaultResetStart({
  required SanadDevRuntime runtime,
  required String homePath,
  required bool driverMode,
  required String device,
}) async {
  await handleBackgroundRun(
    originalArguments: [
      'run',
      if (driverMode) '--driver',
      '--home',
      homePath,
      '--device',
      device,
    ],
    target: SanadDevComponentTarget.all,
    device: device,
    clientInstanceSlot: null,
    sanadHomePath: homePath,
  );
  return exitCode == 0;
}

/// True when the Agent port, the reserved VM-service port, and every managed
/// Client endpoint are free.
///
/// The port probe is a plain TCP connect, so it does not depend on the Home
/// credential being readable, and it is combined with client discovery so a
/// Client that moved to another VM port is still detected.
Future<bool> _waitForResetPortsFree(
  SanadDevRuntime runtime,
  String homePath, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final listening = <int>[];
    for (final port in {runtime.agentPort, runtime.vmServicePort}) {
      if (await _isTcpPortListening(port)) listening.add(port);
    }
    final clients = await discoverClientInstances();
    final live = clients.where(
      (client) =>
          clientAgentPort(client) == runtime.agentPort ||
          client.launchProfile?.define('SANAD_HOME') == homePath,
    );
    if (listening.isEmpty && live.isEmpty) return true;
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<bool> _isTcpPortListening(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(milliseconds: 300),
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

Future<String> _describeResetRuntime({
  required SanadDevRuntime runtime,
  required String homePath,
  required String? fixture,
}) async {
  final state = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(sanadHomeOverride: homePath),
    activeClients: await discoverClientInstances(),
    runtime: runtime,
  );
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: homePath,
  );
  final record = ownership.record;
  final commit = record != null && record.sourceCommit.isNotEmpty
      ? record.sourceCommit
      : await readRuntimeSourceCommit(runtime.repositoryRoot);
  final stateLabel = ownership.isManaged
      ? runtimeStatusLabel(ownership.state)
      : ownership.classification.name;
  final vmPort = state.ownedClients.isEmpty
      ? runtime.vmServicePort
      : state.ownedClients.first.port;
  return 'reset: worktree=${runtime.worktreeId} agent=${runtime.agentPort} '
      'vm=$vmPort sha=${commit.isEmpty ? '-' : commit} state=$stateLabel '
      'home=${record?.sanadHome ?? homePath} '
      'fixture=${fixture ?? 'kept'}';
}
