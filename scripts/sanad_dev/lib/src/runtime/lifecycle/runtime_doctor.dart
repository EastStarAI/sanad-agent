part of '../../../sanad_dev_cli.dart';

bool canRemoveStaleLauncherRecord({
  required bool launcherLive,
  required bool endpointLive,
  required bool clientLive,
}) => !launcherLive && !endpointLive && !clientLive;

/// Driver-host grant check for one macOS TCC permission.
enum DriverHostGrantStatus { granted, missing, unknown, notApplicable }

class DriverHostGrantReport {
  const DriverHostGrantReport({
    required this.name,
    required this.status,
    required this.detail,
  });

  final String name;
  final DriverHostGrantStatus status;
  final String detail;
}

/// Classifies an Accessibility probe result without re-interpreting text at the
/// call site.
DriverHostGrantStatus classifyAccessibilityProbe({
  required int exitCode,
  required String output,
}) {
  final lower = output.toLowerCase();
  if (lower.contains('not allowed assistive access') ||
      lower.contains('(-1719)') ||
      lower.contains('(-1743)') ||
      lower.contains('not authorized')) {
    return DriverHostGrantStatus.missing;
  }
  return exitCode == 0
      ? DriverHostGrantStatus.granted
      : DriverHostGrantStatus.unknown;
}

/// Classifies a Screen Recording probe result (`screencapture`).
DriverHostGrantStatus classifyScreenRecordingProbe({
  required int exitCode,
  required String output,
}) {
  final lower = output.toLowerCase();
  if (lower.contains('could not create image from display') ||
      lower.contains('not authorized') ||
      lower.contains('not permitted')) {
    return DriverHostGrantStatus.missing;
  }
  return exitCode == 0
      ? DriverHostGrantStatus.granted
      : DriverHostGrantStatus.unknown;
}

typedef DriverHostGrantProbe = Future<DriverHostGrantReport> Function();

/// Accessibility grant used by `sanad-dev ui` taps and `osascript` actions.
Future<DriverHostGrantReport> probeAccessibilityGrant() async {
  if (!Platform.isMacOS) {
    return const DriverHostGrantReport(
      name: 'Accessibility',
      status: DriverHostGrantStatus.notApplicable,
      detail: 'macOS only',
    );
  }
  final result = await Process.run('osascript', [
    '-e',
    'tell application "System Events" to count processes',
  ]);
  final output = '${result.stdout}${result.stderr}';
  return DriverHostGrantReport(
    name: 'Accessibility',
    status: classifyAccessibilityProbe(
      exitCode: result.exitCode,
      output: output,
    ),
    detail: output.trim().isEmpty
        ? 'exit ${result.exitCode}'
        : output.trim().split('\n').first,
  );
}

/// Screen Recording grant used by `sanad-dev ui screenshot`.
Future<DriverHostGrantReport> probeScreenRecordingGrant() async {
  if (!Platform.isMacOS) {
    return const DriverHostGrantReport(
      name: 'Screen Recording',
      status: DriverHostGrantStatus.notApplicable,
      detail: 'macOS only',
    );
  }
  final result = await Process.run('screencapture', [
    '-x',
    '-t',
    'png',
    '/dev/null',
  ]);
  final output = '${result.stdout}${result.stderr}';
  return DriverHostGrantReport(
    name: 'Screen Recording',
    status: classifyScreenRecordingProbe(
      exitCode: result.exitCode,
      output: output,
    ),
    detail: output.trim().isEmpty
        ? 'exit ${result.exitCode}'
        : output.trim().split('\n').first,
  );
}

/// Report-only driver-host checks: TCC grants, driver entry point, and
/// port/Home ownership. Never mutates runtime or system state.
Future<void> reportSanadDevDoctorDriverHost({
  required SanadDevRuntime runtime,
  required RuntimeOwnershipAssessment ownership,
  required bool Function(String path) fileExists,
  DriverHostGrantProbe? accessibilityProbe,
  DriverHostGrantProbe? screenRecordingProbe,
  void Function(String message)? printMessage,
}) async {
  final log = printMessage ?? print;
  final driverEntryPoint = p.join(
    runtime.repositoryRoot,
    'client',
    'lib',
    'driver_main.dart',
  );
  log(
    'Driver entry point: '
    '${fileExists(driverEntryPoint) ? 'present' : 'missing'} '
    '($driverEntryPoint)',
  );
  final driverClients = selectManagedUiDriverClients(ownership);
  log(
    'Driver-enabled clients: ${driverClients.length}'
    '${driverClients.isEmpty ? ' (run "sanad-dev run --driver")' : ''}',
  );
  log(
    'Port ownership: agent ${runtime.agentPort} / vm '
    '${runtime.vmServicePort} selected by this worktree '
    '(${ownership.classification.name})',
  );
  log(
    'Home ownership: ${runtime.sanadHome} '
    '(${runtime.isLinkedWorktree ? 'worktree-scoped' : 'primary or explicit'})',
  );
  if (!Platform.isMacOS) {
    log('Driver host grants: not applicable on this platform');
    return;
  }
  final probes = [
    accessibilityProbe ?? probeAccessibilityGrant,
    screenRecordingProbe ?? probeScreenRecordingGrant,
  ];
  for (final probe in probes) {
    final report = await probe();
    log(
      'Driver host grant ${report.name}: ${report.status.name} '
      '(${report.detail})',
    );
  }
}

Future<void> handleRuntimeDoctor({
  required bool fix,
  String? sanadHomePath,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<List<AgentInstance>> Function({String? sanadHomeOverride})
      discoverAgents =
      discoverAgentInstances,
  Future<List<ClientInstance>> Function() discoverClients =
      discoverClientInstances,
  bool Function(String path)? fileExists,
  DriverHostGrantProbe? accessibilityProbe,
  DriverHostGrantProbe? screenRecordingProbe,
  void Function(String message)? printMessage,
}) async {
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final agents = await discoverAgents(sanadHomeOverride: sanadHomePath);
  final clients = await discoverClients();
  final state = selectRuntimeProcessState(
    activeAgents: agents,
    activeClients: clients,
    runtime: runtime,
  );
  final activeHome = resolveActiveSanadHome(runtime, state);
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: activeHome,
    processRunning: processRunning,
  );

  print('Runtime: ${runtime.worktreeId}');
  print('Class: ${ownership.classification.name}');
  print('Agent: ${state.agent?.port ?? '-'}');
  print('Owned clients: ${state.ownedClients.length}');
  print('Cross-owned clients: ${state.crossOwnedClients.length}');
  print('Unverifiable clients: ${state.ambiguousClients.length}');
  if (ownership.reason != null) print('Reason: ${ownership.reason}');

  final record =
      ownership.record ??
      await _readRuntimeLauncherRecordSafely(
        activeHome,
        state.agent?.port ?? runtime.agentPort,
      );
  var staleAgentRecoveryAvailable = false;
  var staleRecordRemovalAvailable = false;
  if (record != null) {
    final launcherLive = await processRunning(record.launcherPid);
    print(
      'Launcher lease: PID ${record.launcherPid} '
      '(${launcherLive ? 'live' : 'stale'})',
    );
    final staleAgentRecoveryError = staleAgentRecoveryBlocker(
      runtime: runtime,
      state: state,
      record: record,
      activeHome: activeHome,
      launcherLive: launcherLive,
    );
    staleAgentRecoveryAvailable =
        ownership.classification == RuntimeOwnershipClass.orphaned &&
        staleAgentRecoveryError == null;
    final endpointLive = agents.any(
      (agent) => agentMatchesLauncherRecord(agent, record),
    );
    final clientLive = clients.any(
      (client) => clientMatchesLauncherRecord(client, record),
    );
    staleRecordRemovalAvailable = canRemoveStaleLauncherRecord(
      launcherLive: launcherLive,
      endpointLive: endpointLive,
      clientLive: clientLive,
    );
    if (fix) {
      final switchPath = runtimeSwitchManifestPath(
        activeHome,
        state.agent?.port ?? runtime.agentPort,
      );
      try {
        final handoff = await readRuntimeSwitchRequest(switchPath);
        if (handoff != null &&
            isActiveRuntimeSwitch(handoff) &&
            !isRuntimeSwitchOwnedByLauncher(
              handoff,
              launcherId: record.launcherId,
              runtimeNonce: record.runtimeNonce,
            )) {
          await writeRuntimeSwitchRequest(
            switchPath,
            handoff.copyWith(
              status: 'failed',
              message:
                  'Stale runtime handoff discarded because its owning launcher is no longer active.',
            ),
          );
          print(
            'Fixed: terminalized stale runtime handoff ${handoff.id}; '
            'no process was signaled.',
          );
          return;
        }
      } on Object catch (error) {
        stderr.writeln(
          'No fix applied: runtime handoff record is invalid: $error',
        );
        exitCode = 1;
        return;
      }
      if (staleRecordRemovalAvailable) {
        await deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort);
        print(
          'Fixed: removed one stale launcher record; no process was signaled.',
        );
        return;
      }
      if (staleAgentRecoveryAvailable) {
        if (_hasAgentToolRequester) {
          stderr.writeln(
            'No fix applied: stale Agent recovery must run from a '
            'human-owned terminal so the recovering Agent cannot interrupt '
            'its own tool call. Run "sanad-dev doctor --fix" there.',
          );
          exitCode = 1;
          return;
        }
        print(
          'Draining the exact Agent-only orphan through its authenticated '
          'restart boundary...',
        );
        final recoveryError = await recoverStaleAgentLease(
          runtime: runtime,
          state: state,
          record: record,
          activeHome: activeHome,
          launcherLive: launcherLive,
          requestPermanentRestart: () =>
              _requestTakeoverRestart(record.agentPort, record.sanadHome),
          waitForAgentExit: () =>
              _waitForAgentPortToStop(record.agentPort, record.sanadHome),
          launcherIsRunning: () => processRunning(record.launcherPid),
          discoverAgents: () => discoverAgentInstances(
            sanadHomeOverride: record.sanadHome,
            runtime: runtime,
          ),
          discoverClients: discoverClientInstances,
          deleteRecord: () =>
              deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort),
        );
        if (recoveryError == null) {
          print(
            'Fixed: safely drained the exact Agent-only orphan and removed '
            'its stale launcher record.',
          );
          return;
        }
        stderr.writeln(
          'No fix applied: $recoveryError; the stale launcher record was '
          'preserved.',
        );
        exitCode = 1;
        return;
      }
      stderr.writeln(
        'No fix applied: '
        '${staleAgentRecoveryError ?? 'a launcher or runtime endpoint is still live'}; '
        'the lease was preserved.',
      );
      exitCode = 1;
      return;
    }
  } else if (fix) {
    final candidatePath = runtimeLauncherRecordPath(
      activeHome,
      state.agent?.port ?? runtime.agentPort,
    );
    final candidate = File(candidatePath);
    if (ownership.classification == RuntimeOwnershipClass.stopped &&
        await candidate.exists()) {
      await candidate.delete();
      print(
        'Fixed: removed one invalid stale launcher record; no process was '
        'signaled.',
      );
      return;
    }
    print('No stale launcher record requires repair.');
    return;
  }

  final nextAction = doctorNextAction(
    ownership: ownership,
    state: state,
    staleAgentRecoveryAvailable: staleAgentRecoveryAvailable,
    staleRecordRemovalAvailable: staleRecordRemovalAvailable,
  );
  print('Next action: $nextAction');
  await reportSanadDevDoctorDriverHost(
    runtime: runtime,
    ownership: ownership,
    fileExists: fileExists ?? (path) => File(path).existsSync(),
    accessibilityProbe: accessibilityProbe,
    screenRecordingProbe: screenRecordingProbe,
    printMessage: printMessage,
  );
}

String doctorNextAction({
  required RuntimeOwnershipAssessment ownership,
  required RuntimeProcessState state,
  required bool staleAgentRecoveryAvailable,
  required bool staleRecordRemovalAvailable,
}) => staleRecordRemovalAvailable
    ? 'Run "sanad-dev doctor --fix" to remove the stale record; no process '
          'will be signaled.'
    : switch (ownership.classification) {
        RuntimeOwnershipClass.managed => 'Use sanad-dev status/stop/switch.',
        RuntimeOwnershipClass.manual =>
          'Run "sanad-dev takeover" after confirming the listed manual pair.',
        RuntimeOwnershipClass.orphaned =>
          staleAgentRecoveryAvailable
              ? 'Run "sanad-dev doctor --fix" from a human-owned terminal to '
                    'safely drain this exact Agent-only orphan.'
              : state.agent != null
              ? 'Automatic recovery is refused because the live runtime does not '
                    'match the narrow Agent-only recovery contract.'
              : 'Run "sanad-dev cleanup-target-orphans"; it will proceed only when '
                    'target-only stale Client ownership is proven.',
        RuntimeOwnershipClass.stopped => 'Run "sanad-dev run".',
        RuntimeOwnershipClass.crossOwned =>
          'Run "sanad-dev doctor" from the owning worktree shown above.',
        _ =>
          'Close the listed IDE/manual Client, then rerun "sanad-dev doctor"; '
              'automatic mutation is refused.',
      };

Future<RuntimeLauncherRecord?> _readRuntimeLauncherRecordSafely(
  String sanadHome,
  int agentPort,
) async {
  try {
    return await readRuntimeLauncherRecord(sanadHome, agentPort);
  } on Object {
    return null;
  }
}
