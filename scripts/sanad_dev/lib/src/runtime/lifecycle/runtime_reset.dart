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
      String? clientInstanceSlot,
    });
typedef SanadDevResetPortsFreeProbe =
    Future<bool> Function(
      SanadDevRuntime runtime,
      String homePath, {
      int? agentPort,
    });

/// `sanad-dev reset [--fixture <name>] [--save-fixture <name>] [--keep-data]`.
///
/// Steps: stop this worktree's Agent and Client and prove the ports are free,
/// optionally save and/or restore a Home fixture, then launch a matched
/// driver-enabled runtime and print one summary line.
///
/// `--keep-data` is the documented default when no fixture is requested; the
/// flag exists so a scripted call states its intent explicitly, and it is
/// rejected together with `--fixture`.
Future<void> handleRuntimeReset({
  String? fixture,
  String? saveFixture,
  bool includeMcpConfig = false,
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
  void Function(int code)? setExitCode,
}) async {
  final log = printMessage ?? print;
  final logError = printError ?? stderr.writeln;
  // The exit status is injected so tests can assert it without reading
  // `dart:io`'s process-global [exitCode], which parallel suites share.
  final fail = setExitCode ?? _assignResetProcessExitCode;
  final env = environment ?? Platform.environment;
  if (fixture != null && keepData) {
    logError('--fixture and --keep-data cannot be combined.');
    fail(64);
    return;
  }
  for (final name in [fixture, saveFixture]) {
    if (name != null && !isValidSanadDevFixtureName(name)) {
      logError(
        'Invalid fixture name "$name": use lowercase letters, digits, ".", '
        '"_" or "-" (max 64 characters).',
      );
      fail(64);
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
    fail(1);
    return;
  }
  final assessment = assessSanadDevResetHome(
    runtime: runtime,
    userHome: userHome,
  );
  if (!assessment.allowed) {
    logError('Refusing to reset ${runtime.worktreeId}: ${assessment.reason}');
    fail(64);
    return;
  }
  // Every later step uses the resolved canonical Home, so the validated path and
  // the path that is stopped, restored and launched are the same inode.
  final home = canonicalComparablePath(assessment.homePath);
  if (includeMcpConfig) {
    log(
      'Warning: --include-mcp-config captures mcp_config.json, which can '
      'contain provider headers and environment values.',
    );
  }
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

  // Probe the port the live lease actually published, not only the deterministic
  // per-worktree default, so a lease on an explicit port is still verified free.
  final leasedAgentPort =
      (await _readRuntimeLauncherRecordSafely(home, runtime.agentPort))?.agentPort;
  final stopped = await (stopRuntime ?? _defaultResetStop)(home);
  if (!stopped) {
    logError('Stopping this worktree runtime failed; Home data is unchanged.');
    fail(1);
    return;
  }
  final portsFree = await (portsFreeProbe ?? _waitForResetPortsFree)(
    runtime,
    home,
    agentPort: leasedAgentPort,
  );
  if (!portsFree) {
    logError(
      'Refusing to reset ${runtime.worktreeId}: the Agent port '
      '${runtime.agentPort} or a managed Client endpoint is still live.',
    );
    fail(1);
    return;
  }
  log('Stopped this worktree runtime; ports are free.');

  if (saveFixture != null) {
    try {
      final manifest = await saveHomeFixture(
        workspaceRoot: runtime.workspaceRoot,
        homePath: home,
        name: saveFixture,
        includeMcpConfig: includeMcpConfig,
      );
      log(
        'Saved fixture "$saveFixture" (${manifest.entries.length} files) to '
        '${sanadDevFixturePath(runtime.workspaceRoot, saveFixture)}.',
      );
    } on Object catch (error) {
      logError('Could not save fixture "$saveFixture": $error');
      fail(1);
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
        'Could not restore fixture "$fixture": $error\n'
        'The runtime is stopped and nothing was restarted. Read the message '
        'above for the Home state; rerun this command once the Home is as you '
        'want it, or rerun "sanad-dev reset --keep-data" to start it again.',
      );
      fail(1);
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
    clientInstanceSlot: clientInstanceSlot,
  );
  if (!started) {
    logError(
      'Restarting this worktree runtime failed; the Home is prepared but not '
      'running. Rerun "sanad-dev run".',
    );
    fail(1);
    return;
  }
  final summary = await _describeResetRuntime(
    runtime: runtime,
    homePath: home,
    fixture: fixture,
  );
  log(summary);
}

void _assignResetProcessExitCode(int code) => exitCode = code;

Future<bool> _defaultResetStop(String homePath) async {
  await handleRuntimeStop(
    target: SanadDevComponentTarget.all,
    sanadHomePath: homePath,
  );
  return exitCode == 0;
}

/// The child command line `reset` launches to bring the runtime back.
///
/// The `--client-instance` slot has to appear here, not only in the readiness
/// probe: the child process is what actually starts the Client, so dropping it
/// restarted the default instance while the operator watched the one they asked
/// for.
List<String> sanadDevResetStartArguments({
  required bool driverMode,
  required String homePath,
  required String device,
  String? clientInstanceSlot,
}) => [
  'run',
  if (driverMode) '--driver',
  '--home',
  homePath,
  '--device',
  device,
  if (clientInstanceSlot != null) ...['--client-instance', clientInstanceSlot],
];

Future<bool> _defaultResetStart({
  required SanadDevRuntime runtime,
  required String homePath,
  required bool driverMode,
  required String device,
  String? clientInstanceSlot,
}) async {
  await handleBackgroundRun(
    originalArguments: sanadDevResetStartArguments(
      driverMode: driverMode,
      homePath: homePath,
      device: device,
      clientInstanceSlot: clientInstanceSlot,
    ),
    target: SanadDevComponentTarget.all,
    device: device,
    clientInstanceSlot: clientInstanceSlot,
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
  int? agentPort,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  final leasedAgentPort = agentPort ?? runtime.agentPort;
  while (true) {
    final listening = <int>[];
    for (final port in {runtime.agentPort, leasedAgentPort, runtime.vmServicePort}) {
      if (await _isTcpPortListening(port)) listening.add(port);
    }
    final clients = await discoverClientInstances();
    final live = clients.where(
      (client) =>
          clientAgentPort(client) == runtime.agentPort ||
          clientAgentPort(client) == leasedAgentPort ||
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
