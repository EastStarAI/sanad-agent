part of '../../../sanad_dev_cli.dart';

bool canRemoveStaleLauncherRecord({
  required bool launcherLive,
  required bool endpointLive,
  required bool clientLive,
}) => !launcherLive && !endpointLive && !clientLive;

Future<void> handleRuntimeDoctor({
  required bool fix,
  String? sanadHomePath,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final agents = await discoverAgentInstances(sanadHomeOverride: sanadHomePath);
  final clients = await discoverClientInstances();
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
  if (record != null) {
    final launcherLive = await processRunning(record.launcherPid);
    print(
      'Launcher lease: PID ${record.launcherPid} '
      '(${launcherLive ? 'live' : 'stale'})',
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
      final endpointLive = agents.any(
        (agent) => agent.port == record.agentPort,
      );
      final clientLive = clients.any(
        (client) =>
            clientAgentPort(client) == record.agentPort ||
            client.launchProfile?.define('SANAD_DEV_LAUNCHER_ID') ==
                record.launcherId,
      );
      if (canRemoveStaleLauncherRecord(
        launcherLive: launcherLive,
        endpointLive: endpointLive,
        clientLive: clientLive,
      )) {
        await deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort);
        print(
          'Fixed: removed one stale launcher record; no process was signaled.',
        );
        return;
      }
      stderr.writeln(
        'No fix applied: a launcher or runtime endpoint is still live; '
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

  final nextAction = switch (ownership.classification) {
    RuntimeOwnershipClass.managed => 'Use sanad-dev status/stop/switch.',
    RuntimeOwnershipClass.manual =>
      'Run "sanad-dev takeover" after confirming the listed manual pair.',
    RuntimeOwnershipClass.orphaned =>
      'Run "sanad-dev cleanup-target-orphans"; it will proceed only when '
          'target-only stale ownership is proven.',
    RuntimeOwnershipClass.stopped => 'Run "sanad-dev run".',
    RuntimeOwnershipClass.crossOwned =>
      'Run "sanad-dev doctor" from the owning worktree shown above.',
    _ =>
      'Close the listed IDE/manual Client, then rerun "sanad-dev doctor"; '
          'automatic mutation is refused.',
  };
  print('Next action: $nextAction');
}

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
